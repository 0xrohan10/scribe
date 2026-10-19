import Core
import Foundation

public enum SessionState: Sendable, Equatable {
    case idle
    case starting
    case recording
    case stopping
    case summarizing
    case finished
    case failed(String)
}

public enum SessionEvent: Sendable {
    case state(SessionState)
    case segment(TranscriptSegment)
    case summary(MeetingSummary)
    /// Non-fatal problems, e.g. the system tap failed but the mic is still recording.
    case warning(String)
}

public enum SessionError: Error, LocalizedError {
    case noAudioSources([String])

    public var errorDescription: String? {
        switch self {
        case .noAudioSources(let reasons): "Couldn't start any audio source. \(reasons.joined(separator: " "))"
        }
    }
}

public struct SessionEnvironment: Sendable {
    public var makeSources: @Sendable (SystemAudioScope) -> [any AudioSource]
    public var transcriber: any TranscriptionProvider
    public var summarizer: (any MeetingSummarizer)?
    public var meetings: any MeetingRepository
    public var transcripts: any TranscriptRepository
    public var notes: any NoteRepository
    public var summaries: any SummaryRepository
    public var audioFiles: any AudioFileStore
    /// Corrections applied to every segment as it arrives.
    public var vocabulary: Vocabulary
    /// How long `stop()` waits for transcribers to flush their last segments.
    public var drainTimeout: Duration

    public init(
        makeSources: @escaping @Sendable (SystemAudioScope) -> [any AudioSource],
        transcriber: any TranscriptionProvider,
        summarizer: (any MeetingSummarizer)?,
        meetings: any MeetingRepository,
        transcripts: any TranscriptRepository,
        notes: any NoteRepository,
        summaries: any SummaryRepository,
        audioFiles: any AudioFileStore,
        vocabulary: Vocabulary = Vocabulary(),
        drainTimeout: Duration = .seconds(15)
    ) {
        self.makeSources = makeSources
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.meetings = meetings
        self.transcripts = transcripts
        self.notes = notes
        self.summaries = summaries
        self.audioFiles = audioFiles
        self.vocabulary = vocabulary
        self.drainTimeout = drainTimeout
    }
}

/// Orchestrates one meeting: idle → starting → recording → stopping → summarizing → finished.
///
/// Each audio source streams PCM to its own `transcribe` call (one source per call, so speaker = source).
/// Segments are merged into one `Transcript`, broadcast to subscribers and persisted once final.
public actor MeetingSession {
    public nonisolated let meetingID: UUID
    /// Starts at init; audio, segments and notes are all stamped against it.
    public nonisolated let clock: SessionClock

    public private(set) var meeting: Meeting
    public private(set) var state: SessionState = .idle
    public private(set) var transcript = Transcript()

    private let scope: SystemAudioScope
    private let env: SessionEnvironment
    private let broadcaster = Broadcaster<SessionEvent>()
    private var sources: [any AudioSource] = []
    private var pumps: [Task<Void, Never>] = []
    /// `stop()` arrived while sources were still starting; `start()` stops once they're up.
    private var stopRequested = false
    /// Callers of `stopCapture()` waiting for audio to be released.
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    public init(meeting: Meeting, scope: SystemAudioScope, environment: SessionEnvironment, clock: SessionClock = SessionClock()) {
        self.meetingID = meeting.id
        self.meeting = meeting
        self.scope = scope
        self.env = environment
        self.clock = clock
    }

    public nonisolated func events() -> AsyncStream<SessionEvent> { broadcaster.subscribe() }

    public func setTemplate(_ templateID: String) async {
        meeting.templateID = templateID
        try? await env.meetings.save(meeting)
    }

    public func rename(_ title: String) async {
        meeting.title = title
        try? await env.meetings.save(meeting)
    }

    public func start() async throws {
        guard state == .idle else { return }
        transition(to: .starting)
        do {
            try await env.meetings.save(meeting)
        } catch {
            transition(to: .failed(error.localizedDescription))
            throw error
        }

        var started: [(any AudioSource, AsyncStream<AudioChunk>)] = []
        var failures: [String] = []
        for source in env.makeSources(scope) {
            do {
                let url = try env.audioFiles.recordingURL(meetingID: meetingID, source: source.source)
                started.append((source, try await source.start(clock: clock, recordingTo: url)))
                switch source.source {
                case .mic: meeting.micAudioPath = url.path
                case .system: meeting.systemAudioPath = url.path
                }
            } catch {
                failures.append("\(source.source == .mic ? "Microphone" : "System audio"): \(error.localizedDescription)")
            }
        }
        guard !started.isEmpty else {
            let error = SessionError.noAudioSources(failures)
            transition(to: .failed(error.localizedDescription))
            throw error
        }
        failures.forEach { broadcaster.send(.warning($0)) }
        try? await env.meetings.save(meeting)

        sources = started.map(\.0)
        for (_, audio) in started {
            let segments = env.transcriber.transcribe(audio)
            pumps.append(Task { await self.pump(segments) })
        }
        transition(to: .recording)
        if stopRequested { await stop() }
    }

    /// Stops capture, waits for the last segments, then summarizes (if a summarizer is configured).
    public func stop() async {
        if state == .starting { stopRequested = true }
        guard state == .recording else { return }
        transition(to: .stopping)
        for source in sources { await source.stop() }
        await drainPumps()

        // Anything still partial is the best text we'll get; keep it.
        let leftovers = transcript.segments.filter { !$0.isFinal }.map { var s = $0; s.isFinal = true; return s }
        leftovers.forEach { transcript.upsert($0) }
        try? await env.transcripts.upsert(leftovers, meetingID: meetingID)

        meeting.endedAt = .now
        try? await env.meetings.save(meeting)

        if let summarizer = env.summarizer, !transcript.isEmpty {
            transition(to: .summarizing)
            do {
                let notes = try await env.notes.notes(meetingID: meetingID)
                let summary = try await summarizer.summarize(meeting: meeting, transcript: transcript, notes: notes)
                try await env.summaries.save(summary)
                broadcaster.send(.summary(summary))
            } catch {
                broadcaster.send(.warning("Summary failed: \(error.localizedDescription)"))
            }
        }
        transition(to: .finished)
        broadcaster.finish()
    }

    /// Stops recording and returns once the audio sources are released and the transcript is drained.
    /// Summarizing carries on in the background, so a new session can start right away.
    /// A session that was never started is cancelled and can't be started afterwards.
    public func stopCapture() async {
        switch state {
        case .idle:
            transition(to: .failed("Cancelled before recording started."))
            broadcaster.finish()
            return
        case .summarizing, .finished, .failed:
            return
        case .starting:
            stopRequested = true
        case .recording:
            Task { await self.stop() }
        case .stopping:
            break
        }
        await withCheckedContinuation { captureWaiters.append($0) }
    }

    private func pump(_ segments: AsyncThrowingStream<TranscriptSegment, Error>) async {
        do {
            for try await segment in segments { await receive(segment) }
        } catch is CancellationError {
        } catch {
            broadcaster.send(.warning("Transcription: \(error.localizedDescription)"))
        }
    }

    private func receive(_ segment: TranscriptSegment) async {
        var segment = segment
        segment.text = env.vocabulary.correct(segment.text)
        transcript.upsert(segment)
        broadcaster.send(.segment(segment))
        guard segment.isFinal else { return }
        do {
            try await env.transcripts.upsert([segment], meetingID: meetingID)
        } catch {
            broadcaster.send(.warning("Couldn't save transcript: \(error.localizedDescription)"))
        }
    }

    private func drainPumps() async {
        let pumps = pumps
        self.pumps = []
        let timeout = env.drainTimeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for pump in pumps { await pump.value }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                pumps.forEach { $0.cancel() }
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func transition(to new: SessionState) {
        state = new
        broadcaster.send(.state(new))
        switch new {
        case .summarizing, .finished, .failed:
            captureWaiters.forEach { $0.resume() }
            captureWaiters = []
        default:
            break
        }
    }
}

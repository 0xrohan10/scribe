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
    /// A provisional microphone line was identified as speaker echo.
    case segmentRemoved(UUID)
    case transcriptionStatus(AudioChunk.Source, TranscriptionStatus)
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
    /// Corrections applied to every segment as it arrives.
    public var vocabulary: Vocabulary
    /// How long `stop()` waits for transcribers to flush their last segments.
    public var drainTimeout: Duration
    public var recoveryPolicy: TranscriptionRecoveryPolicy

    public init(
        makeSources: @escaping @Sendable (SystemAudioScope) -> [any AudioSource],
        transcriber: any TranscriptionProvider,
        summarizer: (any MeetingSummarizer)?,
        meetings: any MeetingRepository,
        transcripts: any TranscriptRepository,
        notes: any NoteRepository,
        summaries: any SummaryRepository,
        vocabulary: Vocabulary = Vocabulary(),
        drainTimeout: Duration = .seconds(15),
        recoveryPolicy: TranscriptionRecoveryPolicy = TranscriptionRecoveryPolicy()
    ) {
        self.makeSources = makeSources
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.meetings = meetings
        self.transcripts = transcripts
        self.notes = notes
        self.summaries = summaries
        self.vocabulary = vocabulary
        self.drainTimeout = drainTimeout
        self.recoveryPolicy = recoveryPolicy
    }
}

/// Manages one meeting: idle → starting → recording → stopping → summarizing → finished.
///
/// Each audio source streams PCM to its own `transcribe` call (one source per call, so speaker = source).
/// Segments are merged into one `Transcript`, broadcast to subscribers and persisted once final.
public actor MeetingSession {
    public nonisolated let meetingID: UUID
    /// Starts at init. Audio, segments and notes use this clock for timestamps.
    public nonisolated let clock: SessionClock

    public private(set) var meeting: Meeting
    public private(set) var state: SessionState = .idle
    public private(set) var transcript = Transcript()

    private let scope: SystemAudioScope
    private var env: SessionEnvironment
    private let broadcaster = Broadcaster<SessionEvent>()
    private var sources: [any AudioSource] = []
    private var pumps: [Task<Void, Never>] = []
    private var transcriptions: [AudioChunk.Source: LiveTranscription] = [:]
    private var suppressEcho = false
    private var echoEnvelope = EchoEnvelope()
    private var systemAudioEnded = false
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

    public func retryTranscription(_ source: AudioChunk.Source) async {
        guard state == .recording else { return }
        await transcriptions[source]?.retry()
    }

    public func setTemplate(_ templateID: String) async {
        meeting.templateID = templateID
        try? await env.meetings.save(meeting)
    }

    public func rename(_ title: String) async {
        meeting.title = title
        try? await env.meetings.save(meeting)
    }

    /// A correction made mid-meeting: rewrites what's been said so far and everything still to come.
    /// Subscribers aren't sent the rewritten segments; whoever asked for the correction already has them.
    public func learn(_ entry: VocabularyEntry) async throws {
        env.vocabulary.entries.append(entry)
        let changed = transcript.correct(with: Vocabulary(entries: [entry])).filter(\.isFinal)
        if !changed.isEmpty { try await env.transcripts.upsert(changed, meetingID: meetingID) }
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
                // Audio exists only in memory for live transcription, never as a meeting recording.
                started.append((source, try await source.start(clock: clock, recordingTo: nil)))
            } catch {
                failures.append("\(source.source == .mic ? "Microphone" : "System audio"): \(error.localizedDescription)")
                broadcaster.send(.transcriptionStatus(source.source, .unavailable(error.localizedDescription)))
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
        suppressEcho = Set(sources.map(\.source)) == Set(AudioChunk.Source.allCases)
        for (source, audio) in started {
            let kind = source.source
            let label = kind == .mic ? "Microphone" : "System audio"
            let recovery = LiveTranscription(
                provider: env.transcriber, policy: env.recoveryPolicy,
                onAudio: { [weak self] chunk in await self?.observe(chunk) },
                onAudioEnded: { [weak self] in await self?.audioEnded(kind) },
                onSegment: { [weak self] segment in await self?.receive(segment) },
                onStatus: { [broadcaster] status in broadcaster.send(.transcriptionStatus(kind, status)) },
                onWarning: { [broadcaster] warning in broadcaster.send(.warning("\(label): \(warning)")) })
            transcriptions[kind] = recovery
            pumps.append(Task { await recovery.run(audio) })
        }
        transition(to: .recording)
        if stopRequested { await stop() }
    }

    /// Stops capture, waits for the last segments, then summarizes (if a summarizer is configured).
    public func stop() async {
        if state == .starting { stopRequested = true }
        guard state == .recording else { return }
        transition(to: .stopping)
        for transcription in transcriptions.values { await transcription.stopRetrying() }
        for source in sources { await source.stop() }
        await drainPumps()
        transcriptions.removeAll()

        // Anything still partial is the best text we'll get; keep it.
        let leftovers = transcript.segments.filter { !$0.isFinal }.map { var s = $0; s.isFinal = true; return s }
        for segment in leftovers { await receive(segment) }

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
    /// The summary runs in the background, so a new session can start immediately.
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

    private func receive(_ segment: TranscriptSegment) async {
        guard !Task.isCancelled else { return }
        if suppressEcho, segment.speaker == .me {
            if segment.isFinal {
                // Let the system tap catch up, but never hold local text for more than half a second.
                // Keep this in the transcription task so stop() waits for the decision and its save.
                for _ in 0..<10 {
                    if systemAudioEnded || echoEnvelope.covered(.system) >= segment.end - 0.04 { break }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                guard !Task.isCancelled else { return }
            }
            await receiveMicrophone(segment)
        } else {
            await publish(segment)
        }
    }

    /// Observe both tracks before inference, so suppression does not depend on which model finishes first.
    private func observe(_ chunk: AudioChunk) {
        if suppressEcho { echoEnvelope.append(chunk) }
    }

    private func audioEnded(_ source: AudioChunk.Source) {
        if source == .system { systemAudioEnded = true }
        if state == .recording {
            broadcaster.send(.warning("\(source == .mic ? "Microphone" : "System audio") capture stopped. That track is no longer being transcribed."))
        }
    }

    private func receiveMicrophone(_ segment: TranscriptSegment) async {
        if echoEnvelope.assess(start: segment.start, end: segment.end) == .bleed {
            if transcript.segments.contains(where: { $0.id == segment.id }) {
                transcript.remove(id: segment.id)
                broadcaster.send(.segmentRemoved(segment.id))
            }
        } else {
            await publish(segment)
        }
    }

    private func publish(_ segment: TranscriptSegment) async {
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

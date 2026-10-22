import Core
import Foundation
import Testing
import Transcription

@testable import Session

/// Emits `seconds` of silence in 0.5 s chunks, then waits for `stop()`.
private actor FakeAudioSource: AudioSource {
    nonisolated let source: AudioChunk.Source
    let seconds: Double
    let fails: Bool
    private(set) var didStart = false
    private(set) var requestedRecording = false
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    init(_ source: AudioChunk.Source, seconds: Double = 9, fails: Bool = false) {
        self.source = source
        self.seconds = seconds
        self.fails = fails
    }

    func start(clock: SessionClock, recordingTo url: URL?) throws -> AsyncStream<AudioChunk> {
        didStart = true
        requestedRecording = url != nil
        if fails { throw CocoaError(.featureUnsupported) }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        for i in 0..<Int(seconds * 2) {
            continuation.yield(AudioChunk(source: source, pcm: .init(repeating: 0, count: 8000), sampleRate: 16000, timestamp: Double(i) / 2))
        }
        self.continuation = continuation
        return stream
    }

    func stop() { continuation?.finish() }
}

/// Its `start` doesn't return until `gate` finishes, like a process tap waiting on the TCC prompt.
private actor SlowAudioSource: AudioSource {
    nonisolated let source = AudioChunk.Source.mic
    let gate: AsyncStream<Void>
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    init(_ gate: AsyncStream<Void>) { self.gate = gate }

    func start(clock: SessionClock, recordingTo url: URL?) async throws -> AsyncStream<AudioChunk> {
        for await _ in gate {}
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        return stream
    }

    func stop() { continuation?.finish() }
}

private actor MemoryStore: MeetingRepository, TranscriptRepository, NoteRepository, SummaryRepository {
    var meetings: [UUID: Meeting] = [:]
    var segments: [UUID: TranscriptSegment] = [:]
    var notesByID: [UUID: Note] = [:]
    var summaries: [UUID: MeetingSummary] = [:]

    func save(_ meeting: Meeting) { meetings[meeting.id] = meeting }
    func meeting(id: UUID) -> Meeting? { meetings[id] }
    func recent(limit: Int) -> [Meeting] { Array(meetings.values.prefix(limit)) }
    func delete(id: UUID) { meetings[id] = nil; notesByID[id] = nil }
    func upsert(_ s: [TranscriptSegment], meetingID: UUID) { s.forEach { segments[$0.id] = $0 } }
    func segments(meetingID: UUID) -> [TranscriptSegment] { segments.values.sorted { $0.start < $1.start } }
    func save(_ note: Note) { notesByID[note.id] = note }
    func notes(meetingID: UUID) -> [Note] { Array(notesByID.values) }
    func save(_ summary: MeetingSummary) { summaries[summary.meetingID] = summary }
    func summary(meetingID: UUID) -> MeetingSummary? { summaries[meetingID] }
}

private struct EchoSummarizer: MeetingSummarizer {
    func summarize(meeting: Meeting, transcript: Transcript, notes: [Note]) async throws -> MeetingSummary {
        MeetingSummary(meetingID: meeting.id, templateID: meeting.templateID, overview: "\(transcript.segments.count) segments, \(notes.count) notes")
    }
}

/// Doesn't return until `gate` finishes, like a slow LLM call.
private struct GatedSummarizer: MeetingSummarizer {
    let gate: AsyncStream<Void>
    func summarize(meeting: Meeting, transcript: Transcript, notes: [Note]) async throws -> MeetingSummary {
        for await _ in gate {}
        return MeetingSummary(meetingID: meeting.id, templateID: meeting.templateID, overview: "late")
    }
}

/// Ignores the end of its audio and the session's cancellation, and keeps sending text, like a stuck
/// network provider that eventually wakes up.
private struct StubbornTranscriber: TranscriptionProvider {
    let id = "stubborn"
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptSegment.self)
        Task.detached {
            continuation.yield(TranscriptSegment(speaker: .them, text: "on time", start: 0, end: 1, isFinal: true))
            for await _ in audio {}
            try? await Task.sleep(for: .milliseconds(300))
            continuation.yield(TranscriptSegment(speaker: .them, text: "too late", start: 1, end: 2, isFinal: true))
            continuation.finish()
        }
        return stream
    }
}

@Suite struct MeetingSessionTests {
    private func environment(_ store: MemoryStore, sources: [any AudioSource], summarizer: any MeetingSummarizer = EchoSummarizer()) -> SessionEnvironment {
        SessionEnvironment(
            makeSources: { _ in sources }, transcriber: FakeTranscriptionProvider(segmentDuration: 2), summarizer: summarizer,
            meetings: store, transcripts: store, notes: store, summaries: store)
    }

    @Test func aFailedTranscriberRestartsWithoutEndingTheMeeting() async throws {
        let store = MemoryStore()
        let source = SampleAudioSource(.mic, samples: EchoFixture.speech(6, seed: 11))
        let provider = RestartTestProvider()
        var env = environment(store, sources: [source])
        env.transcriber = provider
        let session = MeetingSession(meeting: Meeting(title: "Recovery"), scope: .allApps, environment: env)
        try await session.start()
        // The second attempt must happen while capture is still running.
        let deadline = ContinuousClock.now + .seconds(3)
        while await provider.attempts.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await provider.attempts.count == 2)
        #expect(await session.state == .recording)
        await session.stop()
        #expect(await store.segments(meetingID: session.meetingID).map(\.text) == ["Before failure", "After recovery"])
    }

    @Test func oneTrackCanRecoverWhileTheOtherKeepsTranscribing() async throws {
        let store = MemoryStore(), provider = IndependentRecoveryProvider()
        let mic = SampleAudioSource(.mic, samples: EchoFixture.speech(6, seed: 29))
        let system = SampleAudioSource(.system, samples: EchoFixture.speech(6, seed: 11))
        var env = environment(store, sources: [mic, system])
        env.transcriber = provider
        env.recoveryPolicy = .init(retryDelay: .milliseconds(1))
        let session = MeetingSession(meeting: Meeting(title: "Independent tracks"), scope: .allApps, environment: env)
        let events = session.events()
        try await session.start()
        let deadline = ContinuousClock.now + .seconds(2)
        while await provider.attempts.counts[.mic, default: 0] < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await provider.attempts.counts[.mic] == 2)
        #expect(await provider.attempts.counts[.system] == 1)
        #expect(await session.state == .recording)
        await session.stop()
        #expect(Set(await store.segments(meetingID: session.meetingID).map(\.speaker)) == [.me, .them])
        var retried: [AudioChunk.Source] = []
        for await case .transcriptionStatus(let source, let status) in events {
            if case .retrying = status { retried.append(source) }
        }
        #expect(retried == [.mic])
    }

    @Test func meetingsTranscribeWithoutSavingAudio() async throws {
        let store = MemoryStore()
        let mic = FakeAudioSource(.mic), system = FakeAudioSource(.system)
        let session = MeetingSession(meeting: Meeting(title: "Text only"), scope: .allApps,
                                     environment: environment(store, sources: [mic, system]))
        try await session.start()
        await session.stop()
        #expect(await mic.didStart)
        #expect(await system.didStart)
        #expect(await !mic.requestedRecording)
        #expect(await !system.requestedRecording)
        let saved = try #require(await store.meeting(id: session.meetingID))
        #expect(saved.micAudioPath == nil)
        #expect(saved.systemAudioPath == nil)
        #expect(await !store.segments(meetingID: session.meetingID).isEmpty)
        #expect(await store.summary(meetingID: session.meetingID) != nil)
    }

    @Test func endToEndWithFakeTranscriber() async throws {
        let store = MemoryStore()
        let meeting = Meeting(title: "Test")
        let session = MeetingSession(meeting: meeting, scope: .allApps, environment: environment(store, sources: [FakeAudioSource(.mic), FakeAudioSource(.system)]))
        let events = session.events()
        await store.save(Note(meetingID: meeting.id, text: "flag this", timestamp: 1, flagged: true))

        try await session.start()
        await session.stop()

        var states: [SessionState] = []
        var summary: MeetingSummary?
        for await event in events {
            switch event {
            case .state(let s): states.append(s)
            case .summary(let s): summary = s
            default: break
            }
        }
        #expect(states == [.starting, .recording, .stopping, .summarizing, .finished])

        // 9 s of audio per source at 2 s/segment → 5 finals each (the last one flushed at end of stream).
        let saved = await store.segments(meetingID: meeting.id)
        #expect(saved.count == 10)
        #expect(saved.allSatisfy { $0.isFinal })
        #expect(Set(saved.map(\.speaker)) == [.me, .them])
        #expect(summary?.overview == "10 segments, 1 notes")
        #expect(await store.meeting(id: meeting.id)?.endedAt != nil)
        #expect(await store.meeting(id: meeting.id)?.micAudioPath == nil)
        #expect(await store.meeting(id: meeting.id)?.systemAudioPath == nil)
    }

    @Test func appliesVocabularyCorrectionsBeforeSavingAndBroadcasting() async throws {
        let store = MemoryStore()
        var env = environment(store, sources: [FakeAudioSource(.system, seconds: 4)])
        env.vocabulary = Vocabulary(entries: [VocabularyEntry(term: "Billing-o-matic", heardAs: "billing system")])
        let session = MeetingSession(meeting: Meeting(title: "T"), scope: .allApps, environment: env)
        let events = session.events()
        try await session.start()
        await session.stop()

        var broadcast: [String] = []
        for await case .segment(let s) in events where s.isFinal { broadcast.append(s.text) }
        let expected = "The main risk this quarter is the migration to the new Billing-o-matic."
        #expect(broadcast.contains(expected))
        #expect(await store.segments(meetingID: session.meetingID).map(\.text).contains(expected))
    }

    @Test func learnRewritesSavedTranscriptAndLaterSegments() async throws {
        let store = MemoryStore()
        let session = MeetingSession(meeting: Meeting(title: "T"), scope: .allApps, environment: environment(store, sources: [FakeAudioSource(.system, seconds: 4)]))
        try await session.start()
        await session.stop()
        try await session.learn(VocabularyEntry(term: "Billing-o-matic", heardAs: "billing system"))

        let expected = "The main risk this quarter is the migration to the new Billing-o-matic."
        #expect(await session.transcript.segments.map(\.text).contains(expected))
        #expect(await store.segments(meetingID: session.meetingID).map(\.text).contains(expected))
    }

    @Test func continuesWhenOneSourceFails() async throws {
        let store = MemoryStore()
        let session = MeetingSession(meeting: Meeting(title: "T"), scope: .allApps, environment: environment(store, sources: [FakeAudioSource(.mic), FakeAudioSource(.system, fails: true)]))
        let events = session.events()
        try await session.start()
        await session.stop()

        var warnings: [String] = []
        for await case .warning(let w) in events { warnings.append(w) }
        #expect(warnings.count == 1)
        #expect(warnings.first?.hasPrefix("System audio") == true)
        #expect(await session.state == .finished)
    }

    @Test func stopDuringStartStillStops() async throws {
        let store = MemoryStore()
        let gate = AsyncStream<Void>.makeStream()
        let session = MeetingSession(meeting: Meeting(title: "T"), scope: .allApps, environment: environment(store, sources: [SlowAudioSource(gate.stream)]))
        let starting = Task { try await session.start() }
        while await session.state != .starting { await Task.yield() }

        await session.stop()
        gate.continuation.finish()
        try await starting.value
        #expect(await session.state == .finished)
    }

    @Test func stopCaptureReturnsBeforeSummaryFinishes() async throws {
        let store = MemoryStore()
        let gate = AsyncStream<Void>.makeStream()
        let session = MeetingSession(
            meeting: Meeting(title: "T"), scope: .allApps,
            environment: environment(store, sources: [FakeAudioSource(.mic)], summarizer: GatedSummarizer(gate: gate.stream)))
        try await session.start()

        await session.stopCapture()
        #expect(await session.state == .summarizing)
        #expect(await store.segments(meetingID: session.meetingID).count == 5)

        let events = session.events()
        gate.continuation.finish()
        for await case .state(let s) in events where s == .finished { break }
        #expect(await store.summary(meetingID: session.meetingID)?.overview == "late")
    }

    @Test func stopCaptureDuringStartWaitsForSourcesThenStops() async throws {
        let store = MemoryStore()
        let gate = AsyncStream<Void>.makeStream()
        let session = MeetingSession(meeting: Meeting(title: "T"), scope: .allApps, environment: environment(store, sources: [SlowAudioSource(gate.stream)]))
        let starting = Task { try await session.start() }
        while await session.state != .starting { await Task.yield() }

        let stopping = Task { await session.stopCapture() }
        gate.continuation.finish()
        await stopping.value
        try await starting.value
        #expect(await session.state == .finished)
    }

    @Test func stopCaptureBeforeStartCancels() async throws {
        let store = MemoryStore()
        let session = MeetingSession(meeting: Meeting(title: "T"), scope: .allApps, environment: environment(store, sources: [FakeAudioSource(.mic)]))
        await session.stopCapture()
        try await session.start()
        if case .failed = await session.state {} else { Issue.record("expected failed state") }
        #expect(await store.meeting(id: session.meetingID) == nil)
    }

    @Test func textAfterStopTimeoutIsDropped() async throws {
        let store = MemoryStore()
        var env = environment(store, sources: [FakeAudioSource(.mic)])
        env.transcriber = StubbornTranscriber()
        env.drainTimeout = .milliseconds(100)
        let session = MeetingSession(meeting: Meeting(title: "T"), scope: .allApps, environment: env)
        try await session.start()
        // Let "on time" arrive before stopping.
        while await session.transcript.isEmpty { await Task.yield() }
        await session.stop()
        try await Task.sleep(for: .milliseconds(500))

        let saved = await store.segments(meetingID: session.meetingID).map(\.text)
        #expect(saved == ["on time"])
        #expect(await session.transcript.segments.map(\.text) == ["on time"])
    }

    @Test func failsWhenNoSourceStarts() async {
        let store = MemoryStore()
        let session = MeetingSession(meeting: Meeting(title: "T"), scope: .allApps, environment: environment(store, sources: [FakeAudioSource(.mic, fails: true)]))
        await #expect(throws: SessionError.self) { try await session.start() }
        if case .failed = await session.state {} else { Issue.record("expected failed state") }
    }

    @Test func speakerEchoIsNotPublishedSavedOrSummarized() async throws {
        let system = EchoFixture.speech(12, seed: 11)
        let store = MemoryStore()
        var env = environment(store, sources: [
            SampleAudioSource(.mic, samples: EchoFixture.bleed(system)), SampleAudioSource(.system, samples: system),
        ])
        env.transcriber = SampleTranscriber()
        let session = MeetingSession(meeting: Meeting(title: "Speakerphone"), scope: .allApps, environment: env)
        let events = session.events()
        try await session.start()
        await session.stop()

        let saved = await store.segments(meetingID: session.meetingID)
        #expect(saved.map(\.speaker) == [.them])
        #expect(await session.transcript.segments.map(\.speaker) == [.them])
        #expect(await store.summary(meetingID: session.meetingID)?.overview == "1 segments, 0 notes")
        for await case .segment(let segment) in events {
            #expect(segment.speaker == .them)
        }
    }

    @Test func localSpeechOverRemoteSpeechSurvivesEvenWithIdenticalText() async throws {
        let system = EchoFixture.speech(12, seed: 11)
        var microphone = EchoFixture.bleed(system)
        for (index, sample) in EchoFixture.speech(3, seed: 29).enumerated() {
            microphone[2 * EchoFixture.rate + index] += sample * 0.9
        }
        let store = MemoryStore()
        var env = environment(store, sources: [SampleAudioSource(.mic, samples: microphone), SampleAudioSource(.system, samples: system)])
        env.transcriber = SampleTranscriber()
        let session = MeetingSession(meeting: Meeting(title: "Double talk"), scope: .allApps, environment: env)
        try await session.start()
        await session.stop()
        #expect(Set(await store.segments(meetingID: session.meetingID).map(\.speaker)) == [.me, .them])
    }

    @Test func microphoneOnlyRecordingBypassesEchoSuppression() async throws {
        let store = MemoryStore()
        var env = environment(store, sources: [SampleAudioSource(.mic, samples: EchoFixture.speech(6, seed: 11))])
        env.transcriber = SampleTranscriber()
        let session = MeetingSession(meeting: Meeting(title: "Mic only"), scope: .allApps, environment: env)
        try await session.start()
        await session.stop()
        #expect(await store.segments(meetingID: session.meetingID).map(\.speaker) == [.me])
    }

    @Test func echoFinalRetractsAnEarlierPartialFromTheLiveTranscript() async throws {
        let system = EchoFixture.speech(12, seed: 11)
        let microphone = EchoFixture.bleed(system)
        let mic = SampleAudioSource(.mic), remote = SampleAudioSource(.system)
        let store = MemoryStore()
        var env = environment(store, sources: [mic, remote])
        let transcriber = SampleTranscriber(emitsPartial: true)
        env.transcriber = transcriber
        let session = MeetingSession(meeting: Meeting(title: "Late system audio"), scope: .allApps, environment: env)
        let events = session.events()
        try await session.start()
        await mic.send(Array(microphone.prefix(1600)), at: 0)
        while await session.transcript.segments.isEmpty { await Task.yield() }
        #expect(await session.transcript.segments.first?.isFinal == false)

        await mic.send(Array(microphone.dropFirst(1600)), at: 0.1)
        await remote.send(system, at: 0)
        await session.stop()
        var removed: [UUID] = []
        for await case .segmentRemoved(let id) in events { removed.append(id) }
        #expect(removed == [transcriber.microphoneID])
        #expect(await session.transcript.segments.map(\.speaker) == [.them])
        #expect(await store.segments(meetingID: session.meetingID).map(\.speaker) == [.them])
    }

    @Test func aSilentSystemTapDoesNotHoldLocalFinalsUntilStop() async throws {
        let store = MemoryStore()
        var env = environment(store, sources: [
            SampleAudioSource(.mic, samples: EchoFixture.speech(6, seed: 11)), SampleAudioSource(.system),
        ])
        env.transcriber = SampleTranscriber(emitsFinalEarly: true)
        let session = MeetingSession(meeting: Meeting(title: "Silent system tap"), scope: .allApps, environment: env)
        let events = session.events()
        try await session.start()
        for await case .segment(let segment) in events where segment.isFinal {
            #expect(segment.speaker == .me)
            break
        }
        #expect(await session.state == .recording)
        await session.stop()
        #expect(await store.segments(meetingID: session.meetingID).map(\.speaker) == [.me])
    }
}

private actor TrackAttempts {
    private(set) var counts: [AudioChunk.Source: Int] = [:]
    func next(_ source: AudioChunk.Source) -> Int {
        counts[source, default: 0] += 1
        return counts[source]!
    }
}

private struct IndependentRecoveryProvider: TranscriptionProvider {
    let id = "independent-recovery"
    let attempts = TrackAttempts()

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { out in
            let task = Task {
                var emitted = false
                for await chunk in audio where !emitted {
                    let attempt = await attempts.next(chunk.source)
                    if chunk.source == .mic, attempt == 1 { out.finish(throwing: CocoaError(.fileReadUnknown)); return }
                    out.yield(TranscriptSegment(speaker: chunk.source.speaker, text: chunk.source.rawValue,
                                                start: chunk.timestamp, end: chunk.timestamp + chunk.duration, isFinal: true))
                    emitted = true
                }
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }
}

private actor RestartAttempts {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private struct RestartTestProvider: TranscriptionProvider {
    let id = "restart-test"
    let attempts = RestartAttempts()

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { out in
            let task = Task {
                let attempt = await attempts.next()
                var emitted = false
                for await chunk in audio {
                    if !emitted {
                        out.yield(TranscriptSegment(speaker: chunk.source.speaker, text: attempt == 1 ? "Before failure" : "After recovery",
                                                    start: attempt == 1 ? 0 : chunk.timestamp, end: attempt == 1 ? 1 : chunk.timestamp + chunk.duration, isFinal: true))
                        emitted = true
                        if attempt == 1 { out.finish(throwing: CocoaError(.fileReadUnknown)); return }
                    }
                }
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }
}

private actor SampleAudioSource: AudioSource {
    nonisolated let source: AudioChunk.Source
    let samples: [Float]
    private var input: AsyncStream<AudioChunk>.Continuation?

    init(_ source: AudioChunk.Source, samples: [Float] = []) {
        self.source = source
        self.samples = samples
    }

    func start(clock: SessionClock, recordingTo url: URL?) -> AsyncStream<AudioChunk> {
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        self.input = input
        send(samples, at: 0)
        return audio
    }

    func send(_ pcm: [Float], at timestamp: TimeInterval) {
        guard !pcm.isEmpty else { return }
        input?.yield(AudioChunk(source: source, pcm: pcm, sampleRate: 16_000, timestamp: timestamp))
    }

    func stop() { input?.finish() }
}

private struct SampleTranscriber: TranscriptionProvider {
    let id = "samples"
    let microphoneID = UUID()
    var emitsPartial = false
    var emitsFinalEarly = false

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var speaker = Speaker.them
                var emittedPartial = false
                var emittedFinal = false
                var hasAudio = false
                func final() -> TranscriptSegment {
                    TranscriptSegment(id: speaker == .me ? microphoneID : UUID(), speaker: speaker, text: "Remote words", start: 2, end: 5, isFinal: true)
                }
                for await chunk in audio {
                    hasAudio = true
                    speaker = chunk.source.speaker
                    if emitsPartial, speaker == .me, !emittedPartial {
                        continuation.yield(TranscriptSegment(id: microphoneID, speaker: .me, text: "Remote words", start: 0, end: 0.1, isFinal: false))
                        emittedPartial = true
                    }
                    if emitsFinalEarly, !emittedFinal {
                        continuation.yield(final())
                        emittedFinal = true
                    }
                }
                if hasAudio, !emittedFinal { continuation.yield(final()) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

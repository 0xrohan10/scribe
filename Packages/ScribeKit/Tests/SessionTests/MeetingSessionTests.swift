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
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    init(_ source: AudioChunk.Source, seconds: Double = 9, fails: Bool = false) {
        self.source = source
        self.seconds = seconds
        self.fails = fails
    }

    func start(clock: SessionClock, recordingTo url: URL?) throws -> AsyncStream<AudioChunk> {
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

private actor MemoryStore: MeetingRepository, TranscriptRepository, NoteRepository, SummaryRepository, AudioFileStore {
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
    nonisolated func recordingURL(meetingID: UUID, source: AudioChunk.Source) -> URL { URL(filePath: "/tmp/\(source).m4a") }
    nonisolated func deleteRecordings(meetingID: UUID) {}
}

private struct EchoSummarizer: MeetingSummarizer {
    func summarize(meeting: Meeting, transcript: Transcript, notes: [Note]) async throws -> MeetingSummary {
        MeetingSummary(meetingID: meeting.id, templateID: meeting.templateID, overview: "\(transcript.segments.count) segments, \(notes.count) notes")
    }
}

@Suite struct MeetingSessionTests {
    private func environment(_ store: MemoryStore, sources: [any AudioSource]) -> SessionEnvironment {
        SessionEnvironment(
            makeSources: { _ in sources }, transcriber: FakeTranscriptionProvider(segmentDuration: 2), summarizer: EchoSummarizer(),
            meetings: store, transcripts: store, notes: store, summaries: store, audioFiles: store)
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
        #expect(await store.meeting(id: meeting.id)?.micAudioPath == "/tmp/mic.m4a")
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

    @Test func failsWhenNoSourceStarts() async {
        let store = MemoryStore()
        let session = MeetingSession(meeting: Meeting(title: "T"), scope: .allApps, environment: environment(store, sources: [FakeAudioSource(.mic, fails: true)]))
        await #expect(throws: SessionError.self) { try await session.start() }
        if case .failed = await session.state {} else { Issue.record("expected failed state") }
    }
}

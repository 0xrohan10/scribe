#if DEBUG
import AppKit
import Core
import Intelligence
import Notes
import Persistence
import Session
import Settings
import SwiftUI
import Transcription

/// `Scribe --screenshots <dir>` renders the main screens with demo data to PNGs, then quits.
/// Meetings run through the real session, notes and Q&A code with fake audio, transcription and LLM,
/// so no permissions, network or API keys are needed.
@MainActor
enum ScreenshotMode {
    static let directory: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count else { return nil }
        return URL(filePath: args[i + 1], directoryHint: .isDirectory)
    }()

    static func makeModel() -> AppModel {
        var settings = AppSettings()
        settings.transcriptionProviderID = "speech-analyzer"
        settings.webSearchProviderID = "parallel"
        settings.searchGateProviderID = "jev"
        return AppModel(preview: settings, secrets: DemoSecrets())
    }

    static func run(model: AppModel, to dir: URL) async {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let db = try ScribeDatabase.inMemory()
            let window = CGSize(width: 1240, height: 780)

            let live = try await liveMeeting(db)
            try await snapshot(MeetingWindow(vm: live, app: model), size: window, to: dir.appending(path: "1-live-meeting.png"))

            let finished = try await finishedMeeting(db, withSummary: true)
            await finished.ask("What does Acme Billing charge for usage-based plans?")
            try await snapshot(MeetingWindow(vm: finished, app: model), size: window, to: dir.appending(path: "2-summary.png"))

            let review = try await finishedMeeting(db, withSummary: false)
            review.focusedNote = review.notes.first { $0.flagged }
            try await snapshot(MeetingWindow(vm: review, app: model), size: window, to: dir.appending(path: "3-note-highlight.png"))

            try await snapshot(SettingsView(model: model), size: CGSize(width: 560, height: 520), to: dir.appending(path: "4-settings.png"))
            print("Saved screenshots to \(dir.path)")
            exit(0)
        } catch {
            print("Screenshot failed: \(error)")
            exit(1)
        }
    }

    // MARK: Demo meetings

    private static func liveMeeting(_ db: ScribeDatabase) async throws -> MeetingViewModel {
        let meeting = Meeting(title: "Q4 roadmap review", app: .zoom)
        let env = SessionEnvironment(
            makeSources: { _ in [DemoAudioSource(.system, from: 0, seconds: 33), DemoAudioSource(.mic, from: 3, seconds: 27)] },
            transcriber: FakeTranscriptionProvider(segmentDuration: 6), summarizer: nil,
            meetings: db.meetings, transcripts: db.transcripts, notes: db.notes, summaries: db.summaries,
            audioFiles: DiskAudioFileStore(root: URL.temporaryDirectory.appending(path: "scribe-preview")))
        // Back-date the clock so the timer and note stamps read as mid-meeting.
        let session = MeetingSession(meeting: meeting, scope: .allApps, environment: env, clock: SessionClock(originHostTime: hostTime(secondsAgo: 34)))
        let vm = MeetingViewModel(
            meeting: meeting, session: session, notes: NotesController(meetingID: meeting.id, clock: session.clock, repository: db.notes),
            qa: QAEngine(llm: DemoLLM()), summarizer: nil, summaries: db.summaries)
        await vm.start()
        vm.updateDraft("! Billing migration is the main Q4 risk")
        await vm.commitDraft()
        vm.updateDraft("Ask legal about the DPA timeline")
        await vm.ask("What did they just say?")
        return vm
    }

    private static func finishedMeeting(_ db: ScribeDatabase, withSummary: Bool) async throws -> MeetingViewModel {
        let meeting = Meeting(title: "Acme Billing — vendor call", app: .meet, startedAt: .now.addingTimeInterval(-3600), endedAt: .now.addingTimeInterval(-1800))
        try await db.meetings.save(meeting)
        let lines: [(Speaker, TimeInterval, String)] = [
            (.them, 4, "Thanks for making time. We'll walk through the migration plan and then pricing."),
            (.me, 12, "Great. Our main concern is moving existing subscriptions without double-charging anyone."),
            (.them, 21, "We run a dry-run import first, so you can diff every invoice before anything goes live."),
            (.me, 34, "How long did that take for customers our size?"),
            (.them, 41, "About two weeks end to end, mostly waiting on finance sign-off."),
            (.them, 58, "On pricing, usage-based plans are billed on volume, and there's a platform fee on top."),
            (.me, 71, "We'd need that in writing, and the budget for a second contractor isn't approved yet."),
            (.them, 83, "Understood. I'll send a quote and our standard DPA by Friday."),
            (.me, 95, "Perfect. Can we target the dry run for the week of the 10th?"),
            (.them, 101, "That works. Let's pencil in the 10th."),
        ]
        try await db.transcripts.upsert(
            lines.enumerated().map { i, line in
                let end = i + 1 < lines.count ? lines[i + 1].1 - 1 : line.1 + 5
                return TranscriptSegment(speaker: line.0, text: line.2, start: line.1, end: end, isFinal: true)
            }, meetingID: meeting.id)
        for (t, text, flagged) in [(22.0, "Dry-run import, diff invoices first", false), (72.0, "Contractor budget not approved", true), (84.0, "Quote + DPA from Acme by Friday", false)] {
            try await db.notes.save(Note(meetingID: meeting.id, text: text, timestamp: t, flagged: flagged))
        }
        if withSummary {
            try await db.summaries.save(
                MeetingSummary(
                    meetingID: meeting.id, templateID: "sales",
                    overview: "Acme walked through migrating existing subscriptions with a dry-run import and invoice diff. Pricing is volume-based plus a platform fee; a written quote is pending.",
                    decisions: ["Run a dry-run import before going live", "Target the dry run for the week of the 10th"],
                    actionItems: [
                        ActionItem(task: "Send a quote and standard DPA", owner: "Acme", due: "Friday"),
                        ActionItem(task: "Get finance sign-off on the migration plan", owner: "Me"),
                    ],
                    openQuestions: ["What's the platform fee at our volume?"],
                    flagged: ["Budget for a second contractor isn't approved, so migration staffing is at risk"]))
        }
        return try await MeetingViewModel.review(
            meeting, transcripts: db.transcripts, noteRepository: db.notes, summaries: db.summaries,
            qa: QAEngine(llm: DemoLLM()), summarizer: nil)
    }

    // MARK: Rendering

    private static func snapshot(_ view: some View, size: CGSize, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // One fixed appearance; offscreen rendering otherwise mixes light text into dark controls.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        // Let event streams, async loads and layout settle.
        try await Task.sleep(for: .milliseconds(800))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }

    private static func hostTime(secondsAgo: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return mach_absolute_time() - UInt64(secondsAgo * 1e9 * Double(info.denom) / Double(info.numer))
    }
}

private struct DemoSecrets: SecretStore {
    func secret(for key: String) -> String? { "demo-key" }
    func setSecret(_ value: String?, for key: String) throws {}
}

/// Emits `seconds` of silence starting at `from` on the session clock, then waits for `stop()`.
private actor DemoAudioSource: AudioSource {
    nonisolated let source: AudioChunk.Source
    let from: Double
    let seconds: Double
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    init(_ source: AudioChunk.Source, from: Double, seconds: Double) {
        self.source = source
        self.from = from
        self.seconds = seconds
    }

    func start(clock: SessionClock, recordingTo url: URL?) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        for i in 0..<Int(seconds * 2) {
            continuation.yield(AudioChunk(source: source, pcm: .init(repeating: 0, count: 8000), sampleRate: 16_000, timestamp: from + Double(i) / 2))
        }
        self.continuation = continuation
        return stream
    }

    func stop() { continuation?.finish() }
}

/// Answers every question with the same canned, web-sourced reply.
private struct DemoLLM: LLMProvider {
    let id = "demo"
    let capabilities = LLMCapabilities(serverWebSearch: true)

    func complete(_ req: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.sources([WebSource(title: "Acme Billing — Pricing", url: URL(string: "https://example.com/acme/pricing")!)]))
            continuation.yield(
                .text(
                    "Acme's public pricing page lists usage-based plans as a percentage of billing volume plus a monthly platform fee. On the call they confirmed the same structure at [0:58] and promised a written quote by Friday [1:23]."
                ))
            continuation.yield(.done(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}
#endif

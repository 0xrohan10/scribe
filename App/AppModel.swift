import AppKit
import Capture
import Core
import Detection
import Intelligence
import Notes
import Observation
import Persistence
import Session
import Settings
import Transcription

/// Composition root: owns the stores, wires domains together and drives the meeting lifecycle.
@MainActor @Observable
final class AppModel {
    var settings: AppSettings {
        didSet { settingsStore.save(settings) }
    }
    private(set) var detectedMeeting: DetectedMeeting?
    private(set) var current: MeetingViewModel?
    private(set) var recentMeetings: [Meeting] = []
    var lastError: String?

    let secrets: any SecretStore = KeychainSecretStore()
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let database: ScribeDatabase
    @ObservationIgnored private let audioFiles: DiskAudioFileStore
    @ObservationIgnored private let detector = MicTriggeredMeetingDetector()
    @ObservationIgnored private let prompter = MeetingPrompter()
    @ObservationIgnored private let meetingWindow = MeetingWindowController()
    @ObservationIgnored private var isSwitchingMeetings = false

    var isRecording: Bool { current?.isRecording == true }
    var isCapturing: Bool { current?.isCapturing == true }

    init() {
        let support = URL.applicationSupportDirectory.appending(path: "Scribe", directoryHint: .isDirectory)
        settings = settingsStore.load()
        audioFiles = DiskAudioFileStore(root: support.appending(path: "Recordings", directoryHint: .isDirectory))
        do {
            database = try ScribeDatabase(url: support.appending(path: "scribe.sqlite"))
        } catch {
            database = try! ScribeDatabase.inMemory()
            lastError = "Couldn't open the database, so nothing will be saved: \(error.localizedDescription)"
        }

        prompter.onRecord = { [weak self] in self?.startMeeting(from: self?.detectedMeeting) }
        prompter.onStop = { [weak self] in Task { await self?.current?.stop() } }
        prompter.setUp()
        Task { await runDetection() }
        Task { await refreshRecent() }
    }

    // MARK: Detection

    private func runDetection() async {
        let events = detector.events
        await detector.start()
        for await event in events {
            switch event {
            case .started:
                detectedMeeting = await detector.currentMeeting
                if let meeting = detectedMeeting, settings.promptWhenMeetingDetected, !isCapturing {
                    prompter.promptRecord(app: meeting.app)
                }
            case .ended:
                detectedMeeting = nil
                prompter.withdrawRecordPrompt()
                if isRecording { prompter.promptStop() }
            }
        }
    }

    // MARK: Meetings

    /// Scribe records one meeting at a time. If one is still capturing, ask before stopping it.
    func startMeeting(from detected: DetectedMeeting? = nil) {
        guard !isSwitchingMeetings else { return }
        guard let current, current.isCapturing else {
            beginMeeting(from: detected)
            return
        }
        guard confirmStopping(current) else {
            showCurrentMeeting()
            return
        }
        isSwitchingMeetings = true
        Task {
            await current.stopCapture()
            isSwitchingMeetings = false
            beginMeeting(from: detected)
        }
    }

    private func confirmStopping(_ current: MeetingViewModel) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Stop the current recording?"
        alert.informativeText = "“\(current.meeting.title)” is still recording. Scribe records one meeting at a time; its summary will finish in the background."
        alert.addButton(withTitle: "Stop and Start New")
        alert.addButton(withTitle: "Keep Recording")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func beginMeeting(from detected: DetectedMeeting?) {
        prompter.withdrawRecordPrompt()
        do {
            let transcriber = try makeProvider(Providers.transcription, id: settings.transcriptionProviderID)
            let llm = try? makeProvider(Providers.llm, id: settings.llmProviderID)
            let meeting = Meeting(title: Self.defaultTitle(for: detected?.app), app: detected?.app, templateID: settings.defaultTemplateID)
            let environment = SessionEnvironment(
                makeSources: { scope in [MicrophoneSource(), SystemAudioSource(scope: scope)] },
                transcriber: transcriber,
                summarizer: settings.summarizeWhenMeetingEnds ? llm.map { LLMSummarizer(llm: $0) } : nil,
                meetings: database.meetings, transcripts: database.transcripts, notes: database.notes,
                summaries: database.summaries, audioFiles: audioFiles)
            let session = MeetingSession(meeting: meeting, scope: systemAudioScope(for: detected), environment: environment)
            let vm = MeetingViewModel(
                meeting: meeting, session: session,
                notes: NotesController(meetingID: meeting.id, clock: session.clock, repository: database.notes),
                qa: llm.map { QAEngine(llm: $0) }, summarizer: llm.map { LLMSummarizer(llm: $0) },
                summaries: database.summaries, onFinish: { [weak self] in Task { await self?.refreshRecent() } })
            current = vm
            meetingWindow.show(vm, app: self)
            Task {
                guard await MicrophoneSource.requestPermission() else {
                    vm.warnings.append("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    await vm.stopCapture()  // Cancels the unstarted session so it doesn't block the next one.
                    return
                }
                await vm.start()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showCurrentMeeting() {
        if let current { meetingWindow.show(current, app: self) }
    }

    func openPast(_ meeting: Meeting) {
        if current?.id == meeting.id {
            showCurrentMeeting()
            return
        }
        Task {
            do {
                let llm = try? makeProvider(Providers.llm, id: settings.llmProviderID)
                let vm = try await MeetingViewModel.review(
                    meeting, transcripts: database.transcripts, noteRepository: database.notes, summaries: database.summaries,
                    qa: llm.map { QAEngine(llm: $0) }, summarizer: llm.map { LLMSummarizer(llm: $0) })
                if !isCapturing { current = vm }
                meetingWindow.show(vm, app: self)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func refreshRecent() async {
        recentMeetings = (try? await database.meetings.recent(limit: 15)) ?? []
    }

    // MARK: Helpers

    private func makeProvider<P>(_ registry: ProviderRegistry<P>, id: String) throws -> P {
        guard let descriptor = registry.descriptor(id: id) else { throw ProviderError.unknownProvider(id) }
        return try registry.make(id: id, config: settings.config(for: descriptor, secrets: secrets))
    }

    private func systemAudioScope(for detected: DetectedMeeting?) -> SystemAudioScope {
        guard settings.systemAudioMode == .meetingApp, let detected else { return .allApps }
        switch detected.app {
        case .zoom: return .bundleIDs(["us.zoom"])
        default: return detected.bundleID.map { .bundleIDs([$0]) } ?? .allApps
        }
    }

    private static func defaultTitle(for app: MeetingApp?) -> String {
        let when = Date.now.formatted(date: .abbreviated, time: .shortened)
        return app.map { "\($0.displayName) meeting · \(when)" } ?? "Meeting · \(when)"
    }
}

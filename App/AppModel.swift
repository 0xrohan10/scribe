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

/// What the main window shows beside the sidebar.
enum Route: Hashable {
    case library
    case meeting
    case settings
}

/// Composition root: owns the stores, wires domains together and drives the meeting lifecycle.
@MainActor @Observable
final class AppModel {
    var settings: AppSettings {
        didSet { settingsStore.save(settings) }
    }
    private(set) var detectedMeeting: DetectedMeeting?
    private(set) var current: MeetingViewModel?
    /// The meeting in the main window, live or past.
    private(set) var shown: MeetingViewModel?
    var route: Route = .library
    private(set) var recentMeetings: [Meeting] = []
    var lastError: String?

    let secrets: any SecretStore
    let library: LibraryModel
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let database: ScribeDatabase
    @ObservationIgnored private let audioFiles: DiskAudioFileStore
    @ObservationIgnored private let detector = MicTriggeredMeetingDetector()
    @ObservationIgnored private let prompter = MeetingPrompter()
    @ObservationIgnored private let mainWindow = MainWindowController()
    @ObservationIgnored private var isSwitchingMeetings = false
    /// Real hardware and providers, swapped for fakes in UI-testing mode.
    @ObservationIgnored private var makeSources: @Sendable (SystemAudioScope) -> [any AudioSource] = { [MicrophoneSource(), SystemAudioSource(scope: $0)] }
    @ObservationIgnored private var requestMicrophone: @Sendable () async -> Bool = { await MicrophoneSource.requestPermission() }
    @ObservationIgnored private var llmOverride: (any LLMProvider)?

    var isRecording: Bool { current?.isRecording == true }
    var isCapturing: Bool { current?.isCapturing == true }

    init() {
        let support = URL.applicationSupportDirectory.appending(path: "Scribe", directoryHint: .isDirectory)
        secrets = KeychainSecretStore()
        settingsStore = SettingsStore()
        settings = settingsStore.load()
        audioFiles = DiskAudioFileStore(root: support.appending(path: "Recordings", directoryHint: .isDirectory))
        do {
            database = try ScribeDatabase(url: support.appending(path: "scribe.sqlite"))
        } catch {
            database = try! ScribeDatabase.inMemory()
            lastError = "Couldn't open the database, so nothing will be saved: \(error.localizedDescription)"
        }
        library = LibraryModel(repository: database.library)

        prompter.onRecord = { [weak self] in self?.startMeeting(from: self?.detectedMeeting) }
        prompter.onStop = { [weak self] in Task { await self?.current?.stop() } }
        prompter.setUp()
        Task { await runDetection() }
        Task { await refreshRecent() }
    }

    #if DEBUG
    /// For screenshots: in-memory stores; no detection, notifications, Keychain or saved settings.
    init(preview settings: AppSettings, secrets: any SecretStore, database: ScribeDatabase) {
        self.secrets = secrets
        settingsStore = SettingsStore(defaults: UserDefaults(suiteName: "scribe.preview")!)
        self.settings = settings
        self.database = database
        library = LibraryModel(repository: database.library)
        audioFiles = DiskAudioFileStore(root: URL.temporaryDirectory.appending(path: "scribe-preview"))
    }

    /// For screenshots: puts `vm` in the main window without opening it.
    func display(_ vm: MeetingViewModel?, route: Route) {
        shown = vm
        self.route = route
    }

    /// For UI testing: the preview setup plus fake audio and LLM, so recording needs no permissions or network.
    convenience init(
        uiTesting settings: AppSettings, secrets: any SecretStore, database: ScribeDatabase,
        sources: @escaping @Sendable (SystemAudioScope) -> [any AudioSource], llm: any LLMProvider
    ) {
        self.init(preview: settings, secrets: secrets, database: database)
        makeSources = sources
        requestMicrophone = { true }
        llmOverride = llm
        Task { await refreshRecent() }
    }
    #endif

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
        guard let transcriberID = settings.transcriptionProviderID else {
            askToChooseTranscriber()
            return
        }
        guard let current, current.isCapturing else {
            beginMeeting(from: detected, transcriberID: transcriberID)
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
            beginMeeting(from: detected, transcriberID: transcriberID)
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

    private func askToChooseTranscriber() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Choose a transcriber first"
        alert.informativeText = "Scribe needs a transcription provider before it can record. Pick one in Settings ▸ Providers."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { showSettings() }
    }

    private func beginMeeting(from detected: DetectedMeeting?, transcriberID: String) {
        prompter.withdrawRecordPrompt()
        do {
            let transcriber = try makeProvider(Providers.transcription, id: transcriberID)
            let llm = makeLLM()
            let meeting = Meeting(title: Self.defaultTitle(for: detected?.app), app: detected?.app, templateID: settings.defaultTemplateID)
            let environment = SessionEnvironment(
                makeSources: makeSources,
                transcriber: transcriber,
                summarizer: settings.summarizeWhenMeetingEnds ? llm.map { LLMSummarizer(llm: $0) } : nil,
                meetings: database.meetings, transcripts: database.transcripts, notes: database.notes,
                summaries: database.summaries, audioFiles: audioFiles)
            let session = MeetingSession(meeting: meeting, scope: systemAudioScope(for: detected), environment: environment)
            let vm = MeetingViewModel(
                meeting: meeting, session: session,
                notes: NotesController(meetingID: meeting.id, clock: session.clock, repository: database.notes),
                qa: llm.map(makeQA), summarizer: llm.map { LLMSummarizer(llm: $0) },
                summaries: database.summaries, onFinish: { [weak self] in Task { await self?.refreshRecent() } })
            current = vm
            show(vm)
            Task {
                guard await requestMicrophone() else {
                    vm.warnings.append("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    await vm.stopCapture()  // Cancels the unstarted session so it doesn't block the next one.
                    return
                }
                await vm.start()
                await refreshRecent()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showCurrentMeeting() {
        if let current { show(current) }
    }

    func showWindow() {
        mainWindow.show(app: self)
    }

    func showLibrary(_ filter: LibraryFilter = .all) {
        library.selection = filter
        route = .library
        showWindow()
    }

    func showSettings() {
        route = .settings
        showWindow()
    }

    private func show(_ vm: MeetingViewModel) {
        shown = vm
        route = .meeting
        showWindow()
    }

    func openPast(_ meeting: Meeting) {
        if current?.id == meeting.id {
            showCurrentMeeting()
            return
        }
        Task {
            do {
                let llm = makeLLM()
                let vm = try await MeetingViewModel.review(
                    meeting, transcripts: database.transcripts, noteRepository: database.notes, summaries: database.summaries,
                    qa: llm.map(makeQA), summarizer: llm.map { LLMSummarizer(llm: $0) })
                if !isCapturing { current = vm }
                show(vm)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Deletes a finished meeting: transcript, notes and summary (via cascade) plus its audio files.
    func deleteMeeting(_ meeting: Meeting) {
        if let current, current.id == meeting.id, current.isLive, current.state != .finished { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Delete “\(meeting.title)”?"
        alert.informativeText = "This deletes the transcript, notes, summary and audio recordings. It can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                try await database.meetings.delete(id: meeting.id)
                try audioFiles.deleteRecordings(meetingID: meeting.id)
            } catch {
                lastError = "Couldn't delete the meeting: \(error.localizedDescription)"
            }
            if current?.id == meeting.id { current = nil }
            if shown?.id == meeting.id {
                shown = nil
                route = .library
            }
            await refreshRecent()
        }
    }

    func refreshRecent() async {
        recentMeetings = (try? await database.meetings.recent(limit: 15)) ?? []
        await library.reload()
    }

    // MARK: Helpers

    private func makeProvider<P>(_ registry: ProviderRegistry<P>, id: String) throws -> P {
        guard let descriptor = registry.descriptor(id: id) else { throw ProviderError.unknownProvider(id) }
        return try registry.make(id: id, config: settings.config(for: descriptor, secrets: secrets))
    }

    private func makeLLM() -> (any LLMProvider)? {
        llmOverride ?? (try? makeProvider(Providers.llm, id: settings.llmProviderID))
    }

    private func makeQA(_ llm: any LLMProvider) -> QAEngine {
        // A misconfigured search provider (e.g. no API key) falls back to the AI provider's own search.
        let webSearch = settings.webSearchProviderID.flatMap { try? makeProvider(Providers.webSearch, id: $0) }
        let searchGate = settings.searchGateProviderID.flatMap { try? makeProvider(Providers.searchGate, id: $0) }
        return QAEngine(llm: llm, webSearch: webSearch, searchGate: searchGate)
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

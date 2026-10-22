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
    case libraryQuestions
    case todos
    case meeting
    case settings
}

/// Whether the selected transcriber can record yet. Local models download and compile before their first meeting.
enum TranscriberStatus: Equatable {
    case ready
    case notDownloaded
    case preparing
    case failed(String)
}

/// Owns the stores, configures providers, and manages meeting state.
@MainActor @Observable
final class AppModel {
    var settings: AppSettings {
        didSet {
            settingsStore.save(settings)
            if settings.transcriptionProviderID != oldValue.transcriptionProviderID || settings.models != oldValue.models {
                prepareTranscriber()
            }
        }
    }
    private(set) var detectedMeeting: DetectedMeeting?
    private(set) var current: MeetingViewModel?
    /// The meeting in the main window, live or past.
    private(set) var shown: MeetingViewModel?
    var route: Route = .library
    private(set) var recentMeetings: [Meeting] = []
    var lastError: String?
    private(set) var transcriberStatus = TranscriberStatus.ready
    private(set) var localModelStatus: LocalModelStatus?
    private(set) var isDeletingModel = false

    let secrets: any SecretStore
    let library: LibraryModel
    let todos: TodosModel
    let libraryQuestions = LibraryQuestionsModel()
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
    @ObservationIgnored private var requestSystemAudio: @Sendable () async -> Bool = { await SystemAudioPermission.request() }
    @ObservationIgnored private var llmOverride: (any LLMProvider)?
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var modelLoading: Task<Void, Never>?

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
        todos = TodosModel(repository: database.todos)

        prompter.onRecord = { [weak self] in self?.startMeeting(from: self?.detectedMeeting) }
        prompter.onStop = { [weak self] in Task { await self?.current?.stop() } }
        prompter.setUp()
        Task { await runDetection() }
        Task { await refreshRecent() }
        prepareTranscriber()
    }

    #if DEBUG
    /// Uses in-memory stores for screenshots without detection, notifications, Keychain, or saved settings.
    init(preview settings: AppSettings, secrets: any SecretStore, database: ScribeDatabase) {
        self.secrets = secrets
        settingsStore = SettingsStore(defaults: UserDefaults(suiteName: "scribe.preview")!)
        self.settings = settings
        self.database = database
        library = LibraryModel(repository: database.library)
        todos = TodosModel(repository: database.todos)
        audioFiles = DiskAudioFileStore(root: URL.temporaryDirectory.appending(path: "scribe-preview"))
    }

    /// Sets the main window's content for screenshots without opening the window.
    func display(_ vm: MeetingViewModel?, route: Route) {
        shown = vm
        self.route = route
    }

    /// Adds fake audio and AI responses to the preview setup for UI tests without permissions or network access.
    convenience init(
        uiTesting settings: AppSettings, secrets: any SecretStore, database: ScribeDatabase,
        sources: @escaping @Sendable (SystemAudioScope) -> [any AudioSource], llm: any LLMProvider
    ) {
        self.init(preview: settings, secrets: secrets, database: database)
        makeSources = sources
        requestMicrophone = { true }
        requestSystemAudio = { true }
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
        guard transcriberStatus == .ready else {
            explainTranscriberNotReady()
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
        alert.informativeText = "\"\(current.meeting.title)\" is still recording. Scribe records one meeting at a time. After capture stops, its summary will finish in the background."
        alert.addButton(withTitle: "Stop and Start New")
        alert.addButton(withTitle: "Keep Recording")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func explainTranscriberNotReady() {
        NSApp.activate()
        let alert = NSAlert()
        switch transcriberStatus {
        case .ready: return
        case .notDownloaded:
            alert.messageText = "Download the transcription model?"
            alert.informativeText = "Download and load the model before recording. Check its progress in Settings."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { retryModel(); showSettings() }
        case .preparing:
            alert.messageText = "The transcription model is still loading"
            alert.informativeText = "Wait for the model to finish downloading and loading before recording. Check its progress in Settings."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failed(let message):
            alert.messageText = "The transcription model couldn't load"
            alert.informativeText = message
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { retryModel() }
        }
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
                summarizer: settings.summarizeWhenMeetingEnds ? llm.map(makeSummarizer) : nil,
                meetings: database.meetings, transcripts: database.transcripts, notes: database.notes,
                summaries: database.summaries, vocabulary: settings.vocabulary)
            let session = MeetingSession(meeting: meeting, scope: systemAudioScope(for: detected), environment: environment)
            let vm = MeetingViewModel(
                meeting: meeting, session: session,
                notes: NotesController(meetingID: meeting.id, clock: session.clock, repository: database.notes),
                qa: llm.map(makeQA), summarizer: llm.map(makeSummarizer),
                summaries: database.summaries, transcripts: database.transcripts, learn: learnCorrection, onFinish: { [weak self] in Task { await self?.refreshRecent() } })
            current = vm
            show(vm)
            Task {
                guard await requestMicrophone() else {
                    vm.warnings.append("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    await vm.stopCapture()  // Cancels the unstarted session so it doesn't block the next one.
                    return
                }
                if await !requestSystemAudio() {
                    vm.warnings.append("System audio access is off, so only your side will be transcribed. Enable it in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording.")
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

    func showLibraryQuestions() {
        route = .libraryQuestions
        showWindow()
    }

    func showTodos() {
        route = .todos
        showWindow()
    }

    func openTodoSource(_ item: TodoItem) {
        guard let id = item.meetingID else { return }
        Task {
            do {
                guard let meeting = try await database.meetings.meeting(id: id) else {
                    todos.lastError = "That meeting has been deleted. The todo is still saved."
                    await todos.reload()
                    return
                }
                openPast(meeting)
            } catch { todos.lastError = error.localizedDescription }
        }
    }

    func askMeetings(_ question: String) {
        libraryQuestions.ask(question) {
            let llm = try llmOverride ?? makeProvider(Providers.llm, id: settings.llmProviderID)
            return MeetingLibraryQA(llm: llm, search: database.meetingSearch, vocabulary: settings.vocabulary.terms)
        }
    }

    func openEvidence(_ source: MeetingEvidence) {
        libraryQuestions.sourceError = nil
        Task {
            do {
                guard let meeting = try await database.meetings.meeting(id: source.meeting.id) else {
                    libraryQuestions.sourceError = "That meeting has been deleted."
                    return
                }
                openPast(meeting)
            } catch {
                libraryQuestions.sourceError = "Couldn't open the source: \(error.localizedDescription)"
            }
        }
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
                    qa: llm.map(makeQA), summarizer: llm.map(makeSummarizer), learn: learnCorrection)
                if !isCapturing { current = vm }
                show(vm)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Deletes a finished meeting and its transcript, notes, summary, and old audio files.
    func deleteMeeting(_ meeting: Meeting) {
        if let current, current.id == meeting.id, current.isLive, current.state != .finished { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Delete \"\(meeting.title)\"?"
        alert.informativeText = "This deletes the transcript, notes, summary, and any old audio recordings. Scribe keeps the todos without a meeting link. You can't undo this."
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
        await todos.reload()
    }

    // MARK: Helpers

    private func makeProvider<P>(_ registry: ProviderRegistry<P>, id: String) throws -> P {
        guard let descriptor = registry.descriptor(id: id) else { throw ProviderError.unknownProvider(id) }
        return try registry.make(id: id, config: settings.config(for: descriptor, secrets: secrets))
    }

    /// Loads cached models on launch; missing models wait for an explicit download request.
    private func prepareTranscriber(download: Bool = false) {
        preparing?.cancel()
        modelLoading?.cancel()
        localModelStatus = nil
        guard let id = settings.transcriptionProviderID else {
            transcriberStatus = .ready
            return
        }
        transcriberStatus = .preparing
        let transcriber: any TranscriptionProvider
        do {
            transcriber = try makeProvider(Providers.transcription, id: id)
        } catch {
            transcriberStatus = .failed(error.localizedDescription)
            return
        }
        preparing = Task { [weak self] in
            do {
                if let managed = transcriber as? any LocalModelProvider {
                    let updates = try await managed.modelUpdates()
                    var first = true
                    for await status in updates {
                        guard !Task.isCancelled, let self else { return }
                        self.localModelStatus = status
                        switch status.phase {
                        case .ready: self.transcriberStatus = .ready
                        case .notDownloaded, .downloaded: self.transcriberStatus = .notDownloaded
                        case .downloading, .loading, .deleting: self.transcriberStatus = .preparing
                        case .failed(let message): self.transcriberStatus = .failed(message)
                        }
                        if first {
                            first = false
                            if status.phase != .ready, download || status.cachedBytes > 0 {
                                self.transcriberStatus = .preparing
                                self.modelLoading = Task {
                                    // ModelCache broadcasts errors and shares any existing load.
                                    do { try await managed.prepare() } catch {}
                                }
                            }
                        }
                    }
                } else {
                    try await transcriber.prepare()
                    guard !Task.isCancelled else { return }
                    self?.transcriberStatus = .ready
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.transcriberStatus = .failed(error.localizedDescription)
            }
        }
    }

    func retryModel() {
        guard !isCapturing, !isDeletingModel else { return }
        prepareTranscriber(download: true)
    }

    var canDeleteModel: Bool {
        guard !isCapturing, !isDeletingModel, transcriberStatus != .preparing,
              let status = localModelStatus, status.cachedBytes > 0 else { return false }
        switch status.phase {
        case .downloading, .loading, .deleting: return false
        default: return true
        }
    }

    func deleteModel() async {
        guard canDeleteModel, let id = settings.transcriptionProviderID else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the cached transcription model?"
        alert.informativeText = "Recordings and transcripts are not affected. Download the model again before using it."
        if id == "cohere-transcribe" {
            alert.informativeText += " Cohere's Hugging Face cache can also be used by other apps."
        }
        alert.addButton(withTitle: "Delete Model").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, canDeleteModel, settings.transcriptionProviderID == id else { return }
        isDeletingModel = true
        transcriberStatus = .preparing
        defer { isDeletingModel = false }
        do {
            let provider = try makeProvider(Providers.transcription, id: id)
            guard let managed = provider as? any LocalModelProvider else { return }
            try await managed.deleteModel()
        } catch {
            transcriberStatus = .failed(error.localizedDescription)
            localModelStatus = LocalModelStatus(phase: .failed(error.localizedDescription), cachedBytes: localModelStatus?.cachedBytes ?? 0)
            lastError = "Couldn't delete model: \(error.localizedDescription)"
        }
    }

    private func makeLLM() -> (any LLMProvider)? {
        llmOverride ?? (try? makeProvider(Providers.llm, id: settings.llmProviderID))
    }

    private func makeQA(_ llm: any LLMProvider) -> QAEngine {
        // Use the AI provider's search if the search provider lacks valid settings, such as an API key.
        let webSearch = settings.webSearchProviderID.flatMap { try? makeProvider(Providers.webSearch, id: $0) }
        let searchGate = settings.searchGateProviderID.flatMap { try? makeProvider(Providers.searchGate, id: $0) }
        return QAEngine(llm: llm, webSearch: webSearch, searchGate: searchGate, vocabulary: settings.vocabulary.terms)
    }

    /// Saves corrections from a meeting's chat in Settings ▸ Vocabulary.
    private func learnCorrection(term: String, heardAs: String) throws -> VocabularyEntry {
        try settings.vocabulary.learn(term, heardAs: heardAs)
    }

    private func makeSummarizer(_ llm: any LLMProvider) -> LLMSummarizer {
        LLMSummarizer(llm: llm, vocabulary: settings.vocabulary.terms)
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

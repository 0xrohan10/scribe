import AVFAudio
import Capture
import Core
import Detection
import Intelligence
import Settings
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(Theme.serif(30))
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            Form {
                ProviderSection(
                    title: "Transcription", registry: Providers.transcription,
                    selection: $model.settings.transcriptionProviderID, allowsNone: false, model: model)
                ProviderSection(
                    title: "AI (Q&A and summaries)", registry: Providers.llm,
                    selection: Binding($model.settings.llmProviderID), allowsNone: false, model: model,
                    listModels: { d in
                        try await Providers.llm.make(id: d.id, config: model.settings.config(for: d, secrets: model.secrets)).availableModels()
                    })
                ProviderSection(
                    title: "Web search (Q&A)", registry: Providers.webSearch,
                    selection: $model.settings.webSearchProviderID, allowsNone: true, model: model)
                if model.settings.webSearchProviderID != nil {
                    ProviderSection(
                        title: "Only search when needed", registry: Providers.searchGate,
                        selection: $model.settings.searchGateProviderID, allowsNone: true, model: model)
                }
                Section("Recording") {
                    Picker("System audio", selection: $model.settings.systemAudioMode) {
                        Text("All apps").tag(SystemAudioMode.allApps)
                        Text("Meeting app only").tag(SystemAudioMode.meetingApp)
                    }
                    Toggle("Ask to record when a meeting starts", isOn: $model.settings.promptWhenMeetingDetected)
                    Toggle("Summarize when the meeting ends", isOn: $model.settings.summarizeWhenMeetingEnds)
                    Picker("Default summary template", selection: $model.settings.defaultTemplateID) {
                        ForEach(SummaryTemplates.all) { Text($0.name).tag($0.id) }
                    }
                }
                PermissionsSection()
                AboutSection()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: 720)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
}

/// Lists a provider's current models for the model picker.
private typealias ModelLister = @MainActor (ProviderDescriptor) async throws -> [String]

private struct ProviderSection<P>: View {
    let title: String
    let registry: ProviderRegistry<P>
    @Binding var selection: String?
    let allowsNone: Bool
    @Bindable var model: AppModel
    /// Nil when the provider can't list its models.
    var listModels: ModelLister?

    var body: some View {
        Section(title) {
            Picker("Provider", selection: $selection) {
                if allowsNone { Text("None").tag(String?.none) }
                ForEach(registry.descriptors) { d in
                    Text(d.isAvailable ? d.displayName : "\(d.displayName) (unavailable)").tag(Optional(d.id)).disabled(!d.isAvailable)
                }
            }
            if let selection, let descriptor = registry.descriptor(id: selection) {
                ProviderFields(descriptor: descriptor, model: model, listModels: listModels).id(descriptor.id)
            }
        }
    }
}

private struct ProviderFields: View {
    let descriptor: ProviderDescriptor
    let model: AppModel
    let listModels: ModelLister?
    /// The key as saved in the Keychain, which SwiftUI can't observe.
    @State private var apiKey = ""
    @State private var customEndpoint: Bool

    init(descriptor: ProviderDescriptor, model: AppModel, listModels: ModelLister?) {
        self.descriptor = descriptor
        self.model = model
        self.listModels = listModels
        _customEndpoint = State(initialValue: model.settings.baseURLs[descriptor.id] != nil)
    }

    var body: some View {
        if descriptor.needsAPIKey || descriptor.needsBaseURL {
            CommitField(label: descriptor.needsAPIKey ? "API key" : "API key (optional)", secure: true, stored: apiKey) { value in
                try model.secrets.setSecret(value.isEmpty ? nil : value, for: descriptor.secretKey)
                apiKey = value
            }
            .onAppear { apiKey = model.secrets.secret(for: descriptor.secretKey) ?? "" }
        }
        if descriptor.needsBaseURL, let defaultURL = descriptor.defaultBaseURL {
            Toggle("Custom endpoint (Ollama, LM Studio, OpenRouter…)", isOn: $customEndpoint)
                .onChange(of: customEndpoint) { _, on in if !on { model.settings.baseURLs[descriptor.id] = nil } }
            if customEndpoint {
                CommitField(
                    label: "Base URL", prompt: "http://localhost:11434/v1",
                    stored: model.settings.baseURLs[descriptor.id]?.absoluteString ?? ""
                ) { value in
                    guard let url = URL(string: value), ["http", "https"].contains(url.scheme), url.host() != nil else {
                        throw SettingsInputError("Enter a full URL, like http://localhost:11434/v1")
                    }
                    model.settings.baseURLs[descriptor.id] = url
                }
            } else {
                LabeledContent("Base URL", value: defaultURL.absoluteString)
            }
        }
        if let defaultModel = descriptor.defaultModel {
            let stored = Binding(
                get: { model.settings.models[descriptor.id] ?? "" },
                set: { model.settings.models[descriptor.id] = $0.isEmpty ? nil : $0 })
            if let listModels {
                ModelPicker(defaultModel: defaultModel, stored: stored) { try await listModels(descriptor) }
                    // Refetch once the key or endpoint that decides which models exist is saved.
                    .id("\(apiKey)|\(model.settings.baseURLs[descriptor.id]?.absoluteString ?? "")")
            } else {
                CommitField(label: "Model", prompt: defaultModel, stored: stored.wrappedValue) { stored.wrappedValue = $0 }
            }
        }
    }
}

/// Picks from the provider's live model list, with a free-text fallback for anything it doesn't list.
private struct ModelPicker: View {
    let defaultModel: String
    @Binding var stored: String
    let load: @MainActor () async throws -> [String]
    @State private var models: [String]?
    @State private var loadError: String?
    @State private var custom = false

    private static let customTag = "\u{0}custom"

    var body: some View {
        if loadError == nil {
            LabeledContent("Model") {
                HStack {
                    if let models {
                        Picker("Model", selection: Binding(
                            get: { custom ? Self.customTag : stored },
                            set: { value in
                                custom = value == Self.customTag
                                if !custom { stored = value }
                            }
                        )) {
                            Text("Default (\(defaultModel))").tag("")
                            Divider()
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                            Divider()
                            Text("Custom…").tag(Self.customTag)
                        }
                        .labelsHidden()
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Loading models…").foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                do {
                    let list = try await load()
                    models = list
                    custom = !stored.isEmpty && !list.contains(stored)
                } catch {
                    loadError = error.localizedDescription
                }
            }
        }
        if custom || loadError != nil {
            CommitField(label: custom ? "Custom model" : "Model", prompt: defaultModel, stored: stored) { stored = $0 }
        }
        if let loadError {
            Text("Couldn't load models: \(loadError)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SettingsInputError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A bordered text field that only stores its value on Save or Return, and says whether what's shown is saved.
private struct CommitField: View {
    let label: String
    var prompt = ""
    var secure = false
    let stored: String
    let save: (String) throws -> Void
    @State private var draft = ""
    @State private var error: String?

    private var isDirty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines) != stored }

    var body: some View {
        LabeledContent(label) {
            HStack {
                Group {
                    if secure {
                        SecureField(label, text: $draft, prompt: Text(prompt))
                    } else {
                        TextField(label, text: $draft, prompt: Text(prompt))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(commit)
                Group {
                    if isDirty {
                        Button("Save", action: commit).buttonStyle(.borderedProminent)
                    } else if !stored.isEmpty {
                        Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .frame(width: 70, alignment: .leading)
            }
        }
        .onAppear { draft = stored }
        .onChange(of: stored) { _, new in draft = new }
        .onChange(of: draft) { error = nil }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try save(value)
            draft = value
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PermissionsSection: View {
    @State private var accessibility = Accessibility.isTrusted
    @State private var mic = AVAudioApplication.shared.recordPermission
    @State private var systemAudio = SystemAudioPermission.status

    var body: some View {
        Section {
            LabeledContent("Microphone") {
                switch mic {
                case .granted: Text("Allowed").foregroundStyle(.green)
                case .denied: Button("Open Settings") { open("Privacy_Microphone") }
                default: Button("Allow") { Task { _ = await AVAudioApplication.requestRecordPermission(); mic = AVAudioApplication.shared.recordPermission } }
                }
            }
            LabeledContent("System audio") {
                switch systemAudio {
                case .granted: Text("Allowed").foregroundStyle(.green)
                case .denied: Button("Open Settings") { open("Privacy_AudioCapture") }
                case .unknown: Button("Allow") { Task { _ = await SystemAudioPermission.request(); systemAudio = SystemAudioPermission.status } }
                }
            }
            LabeledContent("Accessibility (Teams & Meet detection)") {
                if accessibility {
                    Text("Allowed").foregroundStyle(.green)
                } else {
                    Button("Allow") { accessibility = Accessibility.requestTrust() }
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Without system audio, transcripts only include your side of the meeting.")
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibility = Accessibility.isTrusted
            mic = AVAudioApplication.shared.recordPermission
            systemAudio = SystemAudioPermission.status
        }
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

private struct AboutSection: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    var body: some View {
        Section("About") {
            // ScribeVersion and ScribeGitSHA are stamped into the built Info.plist by scripts/stamp-version.sh.
            LabeledContent("Version") {
                Text("\(info["ScribeVersion"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
                    .textSelection(.enabled)
            }
            LabeledContent("Commit") {
                Text(info["ScribeGitSHA"] as? String ?? "unknown")
                    .monospaced()
                    .textSelection(.enabled)
            }
        }
    }
}

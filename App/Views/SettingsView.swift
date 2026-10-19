import AVFAudio
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
                    selection: Binding($model.settings.llmProviderID), allowsNone: false, model: model)
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
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: 720)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
}

private struct ProviderSection<P>: View {
    let title: String
    let registry: ProviderRegistry<P>
    @Binding var selection: String?
    let allowsNone: Bool
    @Bindable var model: AppModel

    var body: some View {
        Section(title) {
            Picker("Provider", selection: $selection) {
                if allowsNone { Text("None").tag(String?.none) }
                ForEach(registry.descriptors) { d in
                    Text(d.isAvailable ? d.displayName : "\(d.displayName) (unavailable)").tag(Optional(d.id)).disabled(!d.isAvailable)
                }
            }
            if let selection, let descriptor = registry.descriptor(id: selection) {
                ProviderFields(descriptor: descriptor, model: model).id(descriptor.id)
            }
        }
    }
}

private struct ProviderFields: View {
    let descriptor: ProviderDescriptor
    @Bindable var model: AppModel
    @State private var apiKey = ""
    @State private var saved = false

    var body: some View {
        if descriptor.needsAPIKey || descriptor.needsBaseURL {
            HStack {
                SecureField(descriptor.needsAPIKey ? "API key" : "API key (optional)", text: $apiKey)
                Button(saved ? "Saved" : "Save") {
                    try? model.secrets.setSecret(apiKey, for: descriptor.secretKey)
                    saved = true
                }
                .disabled(saved)
            }
            .onAppear { apiKey = model.secrets.secret(for: descriptor.secretKey) ?? "" ; saved = true }
            .onChange(of: apiKey) { saved = false }
        }
        if let defaultModel = descriptor.defaultModel {
            TextField("Model", text: Binding(get: { model.settings.models[descriptor.id] ?? "" }, set: { model.settings.models[descriptor.id] = $0 }), prompt: Text(defaultModel))
        }
        if descriptor.needsBaseURL {
            TextField(
                "Base URL",
                text: Binding(
                    get: { model.settings.baseURLs[descriptor.id]?.absoluteString ?? "" },
                    set: { model.settings.baseURLs[descriptor.id] = URL(string: $0) }),
                prompt: Text(descriptor.defaultBaseURL?.absoluteString ?? ""))
        }
    }
}

private struct PermissionsSection: View {
    @State private var accessibility = Accessibility.isTrusted
    @State private var mic = AVAudioApplication.shared.recordPermission

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
                Button("Open Settings") { open("Privacy_AudioCapture") }
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
            Text("System audio permission is requested the first time you record. If the other side is missing from transcripts, check it's allowed.")
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibility = Accessibility.isTrusted
            mic = AVAudioApplication.shared.recordPermission
        }
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

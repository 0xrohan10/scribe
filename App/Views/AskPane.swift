import SwiftUI

struct AskPane: View {
    let vm: MeetingViewModel
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Ask", subtitle: "Transcript + web")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(vm.messages) { MessageView(message: $0).id($0.id) }
                    }
                    .padding(12)
                }
                .onChange(of: vm.messages.last?.text) {
                    if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .overlay {
                if vm.messages.isEmpty {
                    Text(vm.canAsk ? "Try “what did they just say?” or “what's their pricing?”" : "Add an AI provider in Settings to ask questions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            Divider()
            TextField("Ask about this meeting…", text: $question)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(!vm.canAsk)
                .onSubmit {
                    let q = question
                    question = ""
                    Task { await vm.ask(q) }
                }
                .padding(10)
        }
    }
}

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if let activity = message.activity {
                Label(activity, systemImage: "globe").font(.caption).foregroundStyle(.secondary)
            }
            if !message.text.isEmpty || message.isStreaming {
                Text(LocalizedStringKey(message.text.isEmpty ? "…" : message.text))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = message.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(message.sources, id: \.url) { source in
                        Link(source.title, destination: source.url).font(.caption).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

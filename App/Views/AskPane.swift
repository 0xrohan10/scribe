import SwiftUI

/// Questions about the meeting, answered from the transcript and, when needed, the web.
struct AskPane: View {
    let vm: MeetingViewModel
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(vm.messages) { MessageView(message: $0).id($0.id).transition(.rise) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .motion(Motion.quick, value: vm.messages.map(\.id))
                }
                .onChange(of: vm.messages.last?.text) {
                    if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .overlay {
                if vm.messages.isEmpty {
                    Text(vm.canAsk ? "Try “what did they just say?” or “what's their pricing?”" : "Add an AI provider in Settings to ask questions.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(28)
                }
            }
            ComposerCard(isFocused: focused) {
                HStack(spacing: 8) {
                    TextField("Ask about this meeting…", text: $question)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .disabled(!vm.canAsk)
                        .accessibilityIdentifier("ask.field")
                        .onSubmit(submit)
                    SendButton(isEnabled: vm.canAsk && !question.trimmingCharacters(in: .whitespaces).isEmpty, action: submit)
                        .accessibilityLabel("Send question")
                }
            }
            .padding(12)
        }
    }

    private func submit() {
        let q = question
        question = ""
        Task { await vm.ask(q) }
    }
}

/// My questions sit in a bubble on the right; answers read as plain text, like a chat.
private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if let activity = message.activity {
                Label(activity, systemImage: "globe").font(.system(size: 11)).foregroundStyle(Theme.secondary).transition(.opacity)
            }
            if message.role == .user {
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if !message.text.isEmpty || message.isStreaming {
                Text(LocalizedStringKey(message.text.isEmpty ? "…" : message.text))
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
            }
            if let error = message.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.recording)
            }
            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(message.sources, id: \.url) { source in
                        Link(destination: source.url) {
                            Label(source.title, systemImage: "link").lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    }
                }

            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .motion(Motion.quick, value: message.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(message.isStreaming ? "ask.streaming" : message.role == .user ? "ask.question" : "ask.answer")
    }
}

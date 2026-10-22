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
                        ForEach(vm.messages) { message in
                            MessageView(message: message)
                                .id(message.id)
                                // Scale each bubble from its tail corner. Delay the answer by 80 ms.
                                .transition(
                                    message.role == .user
                                        ? .rise(from: .bottomTrailing)
                                        : .rise(from: .bottomLeading).animation(Motion.quick.delay(0.08)))
                        }
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
                    Text(vm.canAsk ? "Try \"what did they just say?\" or \"what's their pricing?\"" : "Add an AI provider in Settings to ask questions.")
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

/// Questions appear on the right and answers on the left. Each bubble's tail points toward its side.
private struct MessageView: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if let activity = message.activity {
                Label(activity, systemImage: "globe")
                    .symbolEffect(.pulse)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .transition(.opacity)
            }
            if isUser {
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.onAccent)
                    .textSelection(.enabled)
                    .bubble(Theme.accent, tail: .trailing)
            } else if !message.text.isEmpty {
                Text(LocalizedStringKey(message.text))
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .contentTransition(.opacity)
                    .bubble(Theme.surface, tail: .leading)
            } else if message.isStreaming {
                TypingIndicator().bubble(Theme.surface, tail: .leading)
            }
            if let error = message.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.recording)
            }
            if !message.sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(message.sources, id: \.url) { source in
                        Link(destination: source.url) {
                            Label(source.title, systemImage: "link")
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.bubble, in: Capsule())
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        // Limit bubble width to distinguish questions from answers.
        .padding(isUser ? .leading : .trailing, 36)
        .motion(Motion.quick, value: message.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(message.isStreaming ? "ask.streaming" : isUser ? "ask.question" : "ask.answer")
    }
}

extension View {
    /// Rounds the bubble with a smaller bottom corner on the speaker's side. Adds a thin border to answers.
    fileprivate func bubble(_ fill: Color, tail: HorizontalEdge) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 16, bottomLeadingRadius: tail == .leading ? 5 : 16, bottomTrailingRadius: tail == .trailing ? 5 : 16,
            topTrailingRadius: 16, style: .continuous)
        return padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(tail == .leading ? Theme.border : .clear))
    }
}

/// Animates three dots while waiting for an answer. Reduce Motion disables scaling but keeps fading.
private struct TypingIndicator: View {
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.tertiary)
                    .frame(width: 6, height: 6)
                    .opacity(isAnimating ? 1 : 0.35)
                    .offset(y: isAnimating && !reduceMotion ? -2 : 0)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.16), value: isAnimating)
            }
        }
        // The text line's height, so the bubble doesn't jump when the first words arrive.
        .frame(height: 17)
        .onAppear { isAnimating = true }
        .accessibilityLabel("Answering")
    }
}

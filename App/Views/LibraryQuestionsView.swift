import Core
import SwiftUI

struct LibraryQuestionsView: View {
    let app: AppModel
    let model: LibraryQuestionsModel
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ask your meetings").font(Theme.serif(30))
                    Text("Across all saved transcripts, notes, and summaries.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("New conversation", systemImage: "square.and.pencil") { model.clear(); focused = true }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.isAsking || model.answers.isEmpty)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if model.answers.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(app.library.entries.isEmpty ? "Start a meeting first." : "What would you like to find?")
                                    .font(.system(size: 17, weight: .medium))
                                Text(app.library.entries.isEmpty
                                     ? "Your saved meeting text will be available here. Audio is not needed."
                                     : "Try \"What did we decide about billing?\" or \"Who owns the migration?\"")
                                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                            }
                            .padding(.top, 40)
                        }
                        ForEach(model.answers) { answer in
                            LibraryAnswerView(answer: answer, open: app.openEvidence, retry: { app.askMeetings(answer.question) }, canRetry: !model.isAsking)
                                .id(answer.id)
                        }
                        Color.clear.frame(height: 1).id("libraryAsk.bottom")
                    }
                    .padding(.bottom, 20)
                }
                .onChange(of: model.answers.last?.text) { proxy.scrollTo("libraryAsk.bottom", anchor: .bottom) }
                .onChange(of: model.answers.count) { proxy.scrollTo("libraryAsk.bottom", anchor: .bottom) }
            }
            if let error = model.sourceError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.recording)
            }
            ComposerCard(isFocused: focused) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask across your meetings…", text: $question, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($focused)
                        .disabled(model.isAsking)
                        .onSubmit(submit)
                        .submitLabel(.send)
                        .accessibilityIdentifier("libraryAsk.field")
                    if model.isAsking {
                        Button("Stop answering", systemImage: "stop.fill") { model.cancel() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(QuietButtonStyle())
                            .accessibilityIdentifier("libraryAsk.cancel")
                    } else {
                        SendButton(isEnabled: !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: submit)
                            .accessibilityLabel("Ask your meetings")
                            .accessibilityIdentifier("libraryAsk.send")
                    }
                }
            }
            .padding(.top, 12)
            HStack {
                Text("Matching saved text is sent to your AI provider. No web search.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("AI Settings") { app.showSettings() }.buttonStyle(.borderless).font(.system(size: 11))
            }
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !model.isAsking, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let value = question
        question = ""
        app.askMeetings(value)
    }
}

private struct LibraryAnswerView: View {
    let answer: LibraryAnswer
    let open: (MeetingEvidence) -> Void
    let retry: () -> Void
    let canRetry: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(answer.question).font(.system(size: 18, weight: .medium)).textSelection(.enabled)
            if !answer.text.isEmpty {
                Text(LocalizedStringKey(linkedAnswer))
                    .font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "scribe-evidence", url.host == "source", let index = Int(url.lastPathComponent), index > 0,
                              answer.sources.indices.contains(index - 1) else { return .discarded }
                        open(answer.sources[index - 1])
                        return .handled
                    })
                    .accessibilityIdentifier("libraryAsk.answer")
            }
            if answer.isStreaming {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(answer.activity ?? "Answering…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            if let error = answer.error {
                HStack {
                    Text(error).foregroundStyle(Theme.recording)
                    Button("Retry", action: retry).buttonStyle(.borderless).disabled(!canRetry)
                }
                .font(.system(size: 12))
            }
            if !answer.sources.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(answer.sources.enumerated()), id: \.element.id) { index, source in
                            VStack(alignment: .leading, spacing: 5) {
                                Button { open(source) } label: {
                                    Text("[\(index + 1)] \(source.meeting.title) · \(source.meeting.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .multilineTextAlignment(.leading)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("libraryAsk.source")
                                Text(source.kind.rawValue + (source.timestamp.map { " · \($0.clockString)" } ?? ""))
                                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                Text("\"\(source.text)\"").font(.system(size: 13)).textSelection(.enabled)
                                if source.owner != nil || source.due != nil {
                                    Text([source.owner.map { "Owner: \($0)" }, source.due.map { "Due: \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Source quotes (\(answer.sources.count))")
                        .accessibilityIdentifier("libraryAsk.sources")
                }
                .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var linkedAnswer: String {
        answer.sources.indices.reduce(answer.text) { text, index in
            text.replacingOccurrences(of: "[\(index + 1)]", with: "[\(index + 1)](scribe-evidence://source/\(index + 1))")
        }
    }
}

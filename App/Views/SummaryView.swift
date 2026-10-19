import AppKit
import Core
import SwiftUI

struct SummaryView: View {
    let summary: MeetingSummary?
    let isLoading: Bool
    @State private var copied = false
    /// False while summarizing, then true once the summary is on screen, so its sections stagger in as it arrives.
    /// A summary that's already there when the view opens just appears.
    @State private var revealed = true

    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                if let summary, !isLoading {
                    VStack(alignment: .leading, spacing: 26) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Overview").font(.system(size: 18, weight: .semibold))
                            Spacer()
                            Button(copied ? "Copied" : "Copy Markdown", systemImage: copied ? "checkmark" : "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(summary.markdown, forType: .string)
                                copied = true
                                Task {
                                    try? await Task.sleep(for: .seconds(1.5))
                                    copied = false
                                }
                            }
                            .buttonStyle(QuietButtonStyle())
                            .contentTransition(.symbolEffect(.replace))
                            .motion(Motion.quick, value: copied)
                        }
                        .rise(isShown: revealed)
                        Text(summary.overview)
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .accessibilityIdentifier("summary.overview")
                            .padding(.top, -12)
                            .rise(isShown: revealed, delay: 0.05)
                        Section("Flagged", items: summary.flagged, icon: "star.fill", tint: Theme.flag)
                            .rise(isShown: revealed, delay: 0.1)
                        Section("Decisions", items: summary.decisions, icon: "checkmark.seal")
                            .rise(isShown: revealed, delay: 0.15)
                        Section(
                            "Action items",
                            items: summary.actionItems.map { item in
                                [item.owner.map { "\($0): " }, item.task, item.due.map { " (due \($0))" }].compactMap { $0 }.joined()
                            },
                            icon: "checklist"
                        )
                        .rise(isShown: revealed, delay: 0.2)
                        Section("Open questions", items: summary.openQuestions, icon: "questionmark.circle")
                            .rise(isShown: revealed, delay: 0.25)
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("summary")
                    // While the sections stagger in, the column itself only fades.
                    .transition(revealed ? .rise : .opacity)
                    // Once the sections are on screen, so they animate from hidden.
                    .onAppear { revealed = true }
                } else {
                    VStack(spacing: 12) {
                        if isLoading { ProgressView().controlSize(.small) }
                        Text(isLoading ? "Summarizing…" : "No summary yet.").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .motion(value: isLoading || summary == nil)
        }
        .onChange(of: isLoading, initial: true) { _, loading in
            if loading { revealed = false }
        }
    }
}

private struct Section: View {
    let title: String
    let items: [String]
    let icon: String
    var tint: Color = Theme.secondary

    init(_ title: String, items: [String], icon: String, tint: Color = Theme.secondary) {
        self.title = title
        self.items = items
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(title).font(.system(size: 15, weight: .semibold))
                } icon: {
                    Image(systemName: icon).foregroundStyle(tint)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(Theme.tertiary)
                        Text(item).font(.system(size: 14)).lineSpacing(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

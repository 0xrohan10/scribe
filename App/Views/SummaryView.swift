import AppKit
import Core
import SwiftUI

struct SummaryView: View {
    let summary: MeetingSummary?
    let isLoading: Bool
    @State private var copied = false

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
                        Text(summary.overview)
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .accessibilityIdentifier("summary.overview")
                            .padding(.top, -12)
                        Section("Flagged", items: summary.flagged, icon: "star.fill", tint: Theme.flag)
                        Section("Decisions", items: summary.decisions, icon: "checkmark.seal")
                        Section(
                            "Action items",
                            items: summary.actionItems.map { item in
                                [item.owner.map { "\($0): " }, item.task, item.due.map { " (due \($0))" }].compactMap { $0 }.joined()
                            },
                            icon: "checklist")
                        Section("Open questions", items: summary.openQuestions, icon: "questionmark.circle")
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("summary")
                    .transition(.rise)
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

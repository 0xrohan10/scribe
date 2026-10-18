import AppKit
import Core
import SwiftUI

struct SummaryView: View {
    let summary: MeetingSummary?
    let isLoading: Bool

    var body: some View {
        ScrollView {
            if let summary, !isLoading {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(summary.overview).font(.body)
                        Spacer()
                        Button("Copy Markdown", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary.markdown, forType: .string)
                        }
                        .labelStyle(.iconOnly)
                        .help("Copy as Markdown")
                    }
                    Section("Flagged", items: summary.flagged, icon: "star.fill")
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
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView(isLoading ? "Summarizing…" : "No summary yet.")
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct Section: View {
    let title: String
    let items: [String]
    let icon: String

    init(_ title: String, items: [String], icon: String) {
        self.title = title
        self.items = items
        self.icon = icon
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

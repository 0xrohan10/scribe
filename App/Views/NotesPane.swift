import Core
import SwiftUI

struct NotesPane: View {
    let vm: MeetingViewModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Notes", subtitle: "Start with ! to flag")
            List {
                ForEach(vm.notes) { note in
                    NoteRow(note: note, vm: vm)
                }
            }
            .listStyle(.plain)
            .overlay {
                if vm.notes.isEmpty {
                    Text("Notes are stamped with the transcript time you start typing them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            if vm.isLive {
                Divider()
                composer
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(get: { vm.draft.text }, set: { vm.updateDraft($0) }))
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .scrollContentBackground(.hidden)
            HStack {
                Text(vm.draft.anchor.map { "at \($0.clockString)" } ?? " ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Note") { Task { await vm.commitDraft() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(vm.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }
}

private struct NoteRow: View {
    let note: Note
    let vm: MeetingViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(note.timestamp.clockString) { vm.focusTime = note.timestamp }
                .buttonStyle(.link)
                .font(.caption.monospacedDigit())
                .help("Show in transcript")
            Text(note.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await vm.toggleFlag(note) }
            } label: {
                Image(systemName: note.flagged ? "star.fill" : "star")
                    .foregroundStyle(note.flagged ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(note.flagged ? "Unflag" : "Flag for the summary")
        }
        .contextMenu {
            Button("Delete", role: .destructive) { Task { await vm.delete(note) } }
        }
    }
}

struct PaneHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

import Core
import SwiftUI

/// Notes and questions beside the transcript.
struct SidePanel: View {
    let vm: MeetingViewModel
    @State private var tab = Tab.notes

    enum Tab { case notes, ask }

    var body: some View {
        VStack(spacing: 0) {
            PillTabs(selection: $tab, options: [(.notes, "Notes"), (.ask, "Ask")])
                .padding(.vertical, 14)
            ZStack {
                switch tab {
                case .notes: NotesList(vm: vm).transition(.opacity)
                case .ask: AskPane(vm: vm).transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.sidebar.opacity(0.5))
        .motion(Motion.quick, value: tab)
    }
}

struct NotesList: View {
    let vm: MeetingViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(vm.notes) { note in
                    NoteRow(note: note, vm: vm).transition(.rise)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .motion(Motion.quick, value: vm.notes)
        }
        .accessibilityIdentifier("notes")
        .overlay {
            if vm.notes.isEmpty {
                Text(vm.isLive ? "Notes are stamped with the moment you start typing them. Start with ! to flag one for the summary." : "No notes.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(28)
            }
        }
    }
}

/// The note being typed, under the transcript like a chat composer. Return adds it.
struct NoteComposer: View {
    let vm: MeetingViewModel
    @FocusState private var focused: Bool

    private var canAdd: Bool { !vm.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ComposerCard(isFocused: focused) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Write a note… start with ! to flag it", text: Binding(get: { vm.draft.text }, set: { vm.updateDraft($0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { Task { await vm.commitDraft() } }
                    .accessibilityIdentifier("notes.draft")
                HStack {
                    Text(vm.draft.anchor.map { "Note at \($0.clockString)" } ?? "Notes")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                        .contentTransition(.numericText())
                    Spacer()
                    SendButton(isEnabled: canAdd) { Task { await vm.commitDraft() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Add note (⌘↩)")
                        .accessibilityLabel("Add Note")
                        .accessibilityIdentifier("notes.add")
                }
            }
        }
        .motion(Motion.quick, value: vm.draft.anchor)
    }
}

private struct NoteRow: View {
    let note: Note
    let vm: MeetingViewModel
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(note.timestamp.clockString) { vm.focusedNote = note }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.highlight)
                .help("Show in transcript")
            Text(note.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await vm.toggleFlag(note) }
            } label: {
                Image(systemName: note.flagged ? "star.fill" : "star")
                    .foregroundStyle(note.flagged ? Theme.flag : Theme.tertiary)
                    .symbolEffect(.bounce, value: note.flagged)
                    .opacity(note.flagged || isHovered ? 1 : 0)
            }
            .buttonStyle(.borderless)
            .help(note.flagged ? "Unflag" : "Flag for the summary")
            .accessibilityIdentifier(note.flagged ? "notes.flagged" : "notes.unflagged")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(vm.focusedNote?.id == note.id ? Theme.highlight.opacity(0.08) : isHovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .motion(Motion.press, value: isHovered)
        // In step with the transcript's highlight of the same moment.
        .motion(value: vm.focusedNote?.id == note.id)
        .contextMenu {
            Button("Delete", role: .destructive) { Task { await vm.delete(note) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes.row")
    }
}

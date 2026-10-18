import Core
import SwiftUI

/// The meetings in the sidebar's selected folder or tag, as a centered reading column.
struct LibraryView: View {
    let app: AppModel
    let library: LibraryModel
    @State private var editingTags: UUID?

    var body: some View {
        if library.entries.isEmpty {
            Greeting(app: app)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.serif(30))
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)

                ScrollView {
                    if library.visibleEntries.isEmpty {
                        Text("No meetings here yet. Drag meetings onto a folder in the sidebar to file them.")
                            .foregroundStyle(Theme.secondary)
                            .padding(.top, 24)
                    }
                    LazyVStack(spacing: 6) {
                        ForEach(library.visibleEntries) { entry in
                            card(entry).transition(.rise)
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library.meetings")
                    .motion(Motion.quick, value: library.visibleEntries)
                }
            }
        }
    }

    private func card(_ entry: LibraryEntry) -> some View {
        MeetingCard(
            entry: entry, folder: library.folder(id: entry.folderID), showsFolder: library.selection == .all,
            isLive: app.current?.id == entry.id && app.isRecording
        ) {
            app.openPast(entry.meeting)
        }
        .draggable(entry.id.uuidString)
        .popover(isPresented: Binding(get: { editingTags == entry.id }, set: { if !$0 { editingTags = nil } }), arrowEdge: .bottom) {
            OrganizeBar(meetingID: entry.id, library: library).padding(12).frame(width: 420)
        }
        .contextMenu {
            Button("Open") { app.openPast(entry.meeting) }
            Menu("Move to Folder") { FolderMenuItems(meetingID: entry.id, library: library) }
            Button("Edit Tags…") { editingTags = entry.id }
            Divider()
            Button("Delete…", role: .destructive) { app.deleteMeeting(entry.meeting) }
        }
    }

    private var title: String {
        switch library.selection ?? .all {
        case .all: "Meetings"
        case .unfiled: "Unfiled"
        case .folder(let id): library.folder(id: id)?.name ?? "Folder"
        case .tag(let name): "#\(name)"
        }
    }

    private var subtitle: String {
        let count = library.visibleEntries.count
        return count == 1 ? "1 meeting" : "\(count) meetings"
    }
}

/// The empty library: a calm welcome and one obvious thing to do.
private struct Greeting: View {
    let app: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text(greeting).font(Theme.serif(34))
            Text("Record a meeting and Scribe keeps the transcript, your notes and a summary, all on this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Start recording", systemImage: "record.circle") { app.startMeeting() }
                .buttonStyle(CapsuleButtonStyle())
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

private struct MeetingCard: View {
    let entry: LibraryEntry
    let folder: Folder?
    let showsFolder: Bool
    let isLive: Bool
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if isLive { RecordingDot() }
                    Text(entry.meeting.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Spacer()
                    if showsFolder, let folder {
                        Label(folder.name, systemImage: "folder").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let app = entry.meeting.app { Text("·"); Text(app.displayName) }
                    if let ended = entry.meeting.endedAt {
                        Text("·")
                        Text(ended.timeIntervalSince(entry.meeting.startedAt).clockString).monospacedDigit()
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                if !entry.tags.isEmpty {
                    HStack(spacing: 4) { ForEach(entry.tags, id: \.self) { TagChip(name: $0) } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Theme.surface : Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border.opacity(isHovered ? 1 : 0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovered = $0 }
        .motion(Motion.press, value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.meeting")
    }
}

/// Folder menu plus tag chips and an add-tag field for one meeting.
struct OrganizeBar: View {
    let meetingID: UUID
    let library: LibraryModel
    @State private var newTag = ""

    var body: some View {
        let entry = library.entry(for: meetingID)
        HStack(spacing: 6) {
            Menu {
                FolderMenuItems(meetingID: meetingID, library: library)
            } label: {
                Label(library.folder(id: entry?.folderID)?.name ?? "No folder", systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(Theme.secondary)
            .accessibilityIdentifier("organize.folder")

            ForEach(entry?.tags ?? [], id: \.self) { tag in
                TagChip(name: tag) { Task { await library.removeTag(tag, from: meetingID) } }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tag")
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            TextField("Add tag", text: $newTag)
                .textFieldStyle(.plain)
                .frame(minWidth: 70, maxWidth: 140)
                .accessibilityIdentifier("organize.addTag")
                .onSubmit {
                    let tag = newTag
                    newTag = ""
                    Task { await library.addTag(tag, to: meetingID) }
                }
            Spacer(minLength: 0)
        }
        .disabled(entry == nil)
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
        .motion(Motion.quick, value: entry?.tags ?? [])
    }
}

/// "None" plus every folder; picking one files the meeting there.
struct FolderMenuItems: View {
    let meetingID: UUID
    let library: LibraryModel

    var body: some View {
        Button("None") { Task { await library.move(meetingID, to: nil) } }
        Divider()
        ForEach(library.folders) { folder in
            Button(folder.name) { Task { await library.move(meetingID, to: folder.id) } }
        }
    }
}

struct TagChip: View {
    let name: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text("#\(name)")
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .help("Remove tag")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Theme.bubble, in: Capsule())
    }
}

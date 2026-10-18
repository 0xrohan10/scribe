import Core
import SwiftUI

/// Folders and tags in the sidebar, meetings on the right. Drag a meeting onto a folder to file it.
struct LibraryWindow: View {
    let library: LibraryModel
    let app: AppModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(library: library).navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            LibraryMeetingList(library: library, app: app)
        }
        .frame(minWidth: 760, minHeight: 440)
        .task { await library.reload() }
        .alert(
            "Couldn't update the library", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(library.lastError ?? "")
        }
    }
}

struct LibrarySidebar: View {
    @Bindable var library: LibraryModel
    @State private var folderDraft = ""
    @State private var isCreatingFolder = false
    @State private var renaming: Folder?

    var body: some View {
        List(selection: $library.selection) {
            Label("All Meetings", systemImage: "tray.full").badge(library.entries.count).tag(LibraryFilter.all)
            Label("Unfiled", systemImage: "tray").tag(LibraryFilter.unfiled)
                .dropDestination(for: String.self) { ids, _ in file(ids, into: nil) }

            Section("Folders") {
                ForEach(library.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(library.count(in: folder))
                        .tag(LibraryFilter.folder(folder.id))
                        .dropDestination(for: String.self) { ids, _ in file(ids, into: folder.id) }
                        .contextMenu {
                            Button("Rename…") {
                                folderDraft = folder.name
                                renaming = folder
                            }
                            Button("Delete Folder", role: .destructive) { Task { await library.deleteFolder(folder) } }
                        }
                }
            }

            if !library.tags.isEmpty {
                Section("Tags") {
                    ForEach(library.tags) { tag in
                        Label(tag.name, systemImage: "tag").badge(tag.count).tag(LibraryFilter.tag(tag.name))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("New Folder", systemImage: "folder.badge.plus") {
                folderDraft = ""
                isCreatingFolder = true
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $folderDraft)
            Button("Create") {
                Task {
                    if let folder = await library.createFolder(named: folderDraft) { library.selection = .folder(folder.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $folderDraft)
            Button("Rename") {
                if let folder = renaming { Task { await library.renameFolder(folder, to: folderDraft) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Meetings are dragged as their UUID strings.
    private func file(_ ids: [String], into folderID: UUID?) -> Bool {
        let meetingIDs = ids.compactMap(UUID.init(uuidString:))
        guard !meetingIDs.isEmpty else { return false }
        Task { for id in meetingIDs { await library.move(id, to: folderID) } }
        return true
    }
}

struct LibraryMeetingList: View {
    let library: LibraryModel
    let app: AppModel
    @State private var editingTags: UUID?

    var body: some View {
        List {
            ForEach(library.visibleEntries) { entry in
                MeetingRow(entry: entry, folder: library.folder(id: entry.folderID), showsFolder: library.selection == .all)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { app.openPast(entry.meeting) }
                    .draggable(entry.id.uuidString)
                    .popover(isPresented: Binding(get: { editingTags == entry.id }, set: { if !$0 { editingTags = nil } })) {
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
        }
        .navigationTitle(title)
        .overlay {
            if library.visibleEntries.isEmpty {
                Text(library.entries.isEmpty ? "Recorded meetings appear here." : "No meetings here yet. Drag meetings onto a folder to file them.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch library.selection ?? .all {
        case .all: "All Meetings"
        case .unfiled: "Unfiled"
        case .folder(let id): library.folder(id: id)?.name ?? "Folder"
        case .tag(let name): "#\(name)"
        }
    }
}

private struct MeetingRow: View {
    let entry: LibraryEntry
    let folder: Folder?
    let showsFolder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.meeting.title).font(.headline)
            HStack(spacing: 8) {
                Text(entry.meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let app = entry.meeting.app { Text(app.displayName) }
                if let ended = entry.meeting.endedAt {
                    Text(ended.timeIntervalSince(entry.meeting.startedAt).clockString).monospacedDigit()
                }
                if showsFolder, let folder {
                    Label(folder.name, systemImage: "folder").labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !entry.tags.isEmpty {
                HStack(spacing: 4) { ForEach(entry.tags, id: \.self) { TagChip(name: $0) } }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Folder picker plus tag chips and an add-tag field for one meeting.
struct OrganizeBar: View {
    let meetingID: UUID
    let library: LibraryModel
    @State private var newTag = ""

    var body: some View {
        let entry = library.entry(for: meetingID)
        HStack(spacing: 8) {
            Menu {
                FolderMenuItems(meetingID: meetingID, library: library)
            } label: {
                Label(library.folder(id: entry?.folderID)?.name ?? "No folder", systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            ForEach(entry?.tags ?? [], id: \.self) { tag in
                TagChip(name: tag) { Task { await library.removeTag(tag, from: meetingID) } }
            }
            TextField("Add tag", text: $newTag)
                .textFieldStyle(.plain)
                .frame(minWidth: 80, maxWidth: 140)
                .onSubmit {
                    let tag = newTag
                    newTag = ""
                    Task { await library.addTag(tag, to: meetingID) }
                }
            Spacer(minLength: 0)
        }
        .disabled(entry == nil)
        .font(.callout)
    }
}

/// "None" plus every folder; picking one files the meeting there.
private struct FolderMenuItems: View {
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
                Button(action: onRemove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain)
                    .help("Remove tag")
            }
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

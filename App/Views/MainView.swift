import Core
import SwiftUI

/// The one window: sidebar on the left, then the library, a meeting or settings.
struct MainView: View {
    let app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(app: app, library: app.library)
                .frame(width: 256)
            Rectangle().fill(Theme.border).frame(width: 1).ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
        }
        .background(Theme.sidebar.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .tint(Theme.highlight)
        .frame(minWidth: 980, minHeight: 600)
        .task { await app.library.reload() }
        .alert(
            "Couldn't update the library",
            isPresented: Binding(get: { app.library.lastError != nil }, set: { if !$0 { app.library.lastError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(app.library.lastError ?? "")
        }
    }

    private var content: some View {
        ZStack {
            switch app.route {
            case .library:
                LibraryView(app: app, library: app.library).transition(.opacity)
            case .meeting:
                if let vm = app.shown {
                    MeetingView(vm: vm, app: app).id(vm.id).transition(.opacity)
                }
            case .settings:
                SettingsView(model: app).transition(.opacity)
            }
        }
        .motion(value: [String(describing: app.route), app.shown?.id.uuidString ?? ""])
    }
}

struct Sidebar: View {
    let app: AppModel
    @Bindable var library: LibraryModel
    /// True while a new folder is being named inline.
    @State private var isNamingFolder = false
    @State private var folderDraft = ""
    @State private var renaming: Folder?
    @State private var renameDraft = ""
    /// The row a dragged meeting is over.
    @State private var dropTarget: LibraryFilter?
    @FocusState private var namingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScribeLogo()
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 14)
            recordButton
                .padding(.horizontal, 10)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row("Meetings", icon: "tray.full", count: library.entries.count, filter: .all)
                        .accessibilityIdentifier("sidebar.all")
                    row("Unfiled", icon: "tray", filter: .unfiled)
                        .dropDestination(for: String.self, action: { ids, _ in file(ids, into: nil) }, isTargeted: targeting(.unfiled))

                    SectionHeader(title: "Folders") {
                        Button("New Folder", systemImage: "plus") {
                            folderDraft = ""
                            isNamingFolder = true
                            namingFocused = true
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("sidebar.newFolder")
                    }
                    ForEach(library.folders) { folder in
                        row(folder.name, icon: "folder", count: library.count(in: folder), filter: .folder(folder.id))
                            .dropDestination(for: String.self, action: { ids, _ in file(ids, into: folder.id) }, isTargeted: targeting(.folder(folder.id)))
                            .contextMenu {
                                Button("Rename…") {
                                    renameDraft = folder.name
                                    renaming = folder
                                }
                                Button("Delete Folder", role: .destructive) { Task { await library.deleteFolder(folder) } }
                            }
                            .transition(.rise)
                    }
                    if isNamingFolder { folderNameField.transition(.rise) }

                    if !library.tags.isEmpty {
                        SectionHeader(title: "Tags")
                        ForEach(library.tags) { tag in
                            row(tag.name, icon: "number", count: tag.count, filter: .tag(tag.name)).transition(.rise)
                        }
                    }

                    if !library.entries.isEmpty {
                        SectionHeader(title: "Recents")
                        ForEach(library.entries.prefix(20)) { entry in
                            recentRow(entry.meeting).transition(.rise)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .motion(Motion.quick, value: library.folders.map(\.id) + library.entries.map(\.id))
                .motion(Motion.quick, value: isNamingFolder)
            }
            .scrollIndicators(.never)

            Rectangle().fill(Theme.border).frame(height: 1)
            SidebarRow(title: "Settings", icon: "gearshape", isSelected: app.route == .settings) { app.showSettings() }
                .padding(10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
        .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let folder = renaming { Task { await library.renameFolder(folder, to: renameDraft) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var recordButton: some View {
        ZStack {
            if let current = app.current, current.isRecording {
                Button { app.showCurrentMeeting() } label: {
                    HStack(spacing: 10) {
                        RecordingDot()
                        Text("Recording").font(.system(size: 13, weight: .medium))
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(current.clock.now.clockString).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.recording.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("sidebar.recording")
                .transition(.rise)
            } else {
                Button { app.startMeeting() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle").frame(width: 18)
                        Text("New recording")
                        Spacer()
                        Image(systemName: "square.and.pencil").foregroundStyle(Theme.tertiary)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("sidebar.newRecording")
                .transition(.rise)
            }
        }
        .motion(value: app.current?.isRecording == true)
    }

    private var folderNameField: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").frame(width: 18).foregroundStyle(Theme.secondary)
            TextField("Folder name", text: $folderDraft)
                .textFieldStyle(.plain)
                .focused($namingFocused)
                .accessibilityIdentifier("sidebar.folderName")
                .onSubmit {
                    let name = folderDraft
                    isNamingFolder = false
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    Task { if let folder = await library.createFolder(named: name) { app.showLibrary(.folder(folder.id)) } }
                }
                .onExitCommand { isNamingFolder = false }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.highlight.opacity(0.5)))
    }

    private func row(_ title: String, icon: String, count: Int? = nil, filter: LibraryFilter) -> some View {
        SidebarRow(
            title: title, icon: icon, count: count, isSelected: app.route == .library && library.selection == filter,
            isTargeted: dropTarget == filter
        ) {
            app.showLibrary(filter)
        }
    }

    private func recentRow(_ meeting: Meeting) -> some View {
        let isLive = app.current?.id == meeting.id && app.isRecording
        return SidebarRow(title: meeting.title, isSelected: app.route == .meeting && app.shown?.id == meeting.id, trailingDot: isLive) {
            app.openPast(meeting)
        }
        .accessibilityIdentifier("sidebar.recent")
    }

    /// Meetings are dragged as their UUID strings.
    private func file(_ ids: [String], into folderID: UUID?) -> Bool {
        let meetingIDs = ids.compactMap(UUID.init(uuidString:))
        guard !meetingIDs.isEmpty else { return false }
        Task { for id in meetingIDs { await library.move(id, to: folderID) } }
        return true
    }

    /// Tracks which row a drag is over, so only that row highlights.
    private func targeting(_ filter: LibraryFilter) -> (Bool) -> Void {
        { isOver in
            if isOver { dropTarget = filter } else if dropTarget == filter { dropTarget = nil }
        }
    }
}

private struct SidebarRow: View {
    let title: String
    var icon: String?
    var count: Int?
    let isSelected: Bool
    var trailingDot = false
    /// A dragged meeting is over this row and would be filed here on drop.
    var isTargeted = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).frame(width: 18).foregroundStyle(isSelected ? Theme.text : Theme.secondary)
                }
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if trailingDot { RecordingDot() }
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isTargeted ? Theme.highlight.opacity(0.12) : isSelected ? Theme.hover : isHovered ? Theme.hover.opacity(0.5) : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.highlight.opacity(isTargeted ? 0.5 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovered = $0 }
        .motion(Motion.press, value: isHovered)
        .motion(Motion.press, value: isTargeted)
        .motion(Motion.quick, value: count)
    }
}

private struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            Spacer()
            accessory.buttonStyle(.borderless).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A steady red dot. It doesn't pulse: a slow loop in the corner of the eye is a distraction for a whole meeting.
struct RecordingDot: View {
    var body: some View {
        Circle().fill(Theme.recording).frame(width: 7, height: 7)
    }
}

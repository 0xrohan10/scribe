import Core
import Foundation
import Observation

struct TagCount: Identifiable, Hashable {
    let name: String
    let count: Int
    var id: String { name.lowercased() }
}

/// Folders, tags and every meeting, shared by the Library window and the meeting window's organize bar.
@MainActor @Observable
final class LibraryModel {
    private(set) var folders: [Folder] = []
    /// Every meeting, newest first. Filters run in memory.
    private(set) var entries: [LibraryEntry] = []
    var selection: LibraryFilter? = .all
    var lastError: String?

    @ObservationIgnored private let repository: any LibraryRepository

    init(repository: any LibraryRepository) {
        self.repository = repository
    }

    var visibleEntries: [LibraryEntry] {
        entries.filter { (selection ?? .all).matches($0) }
    }

    /// Case-insensitive, keeping the first spelling seen.
    var tags: [TagCount] {
        var counts: [String: (name: String, count: Int)] = [:]
        for tag in entries.flatMap(\.tags) {
            counts[tag.lowercased(), default: (tag, 0)].count += 1
        }
        return counts.values.map { TagCount(name: $0.name, count: $0.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func entry(for meetingID: UUID) -> LibraryEntry? {
        entries.first { $0.id == meetingID }
    }

    func folder(id: UUID?) -> Folder? {
        id.flatMap { id in folders.first { $0.id == id } }
    }

    func count(in folder: Folder) -> Int {
        entries.count { $0.folderID == folder.id }
    }

    func reload() async {
        do {
            folders = try await repository.folders()
            entries = try await repository.entries()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func createFolder(named name: String) async -> Folder? {
        var created: Folder?
        await perform { created = try await self.repository.createFolder(named: name) }
        return created
    }

    func renameFolder(_ folder: Folder, to name: String) async {
        await perform { try await self.repository.renameFolder(id: folder.id, to: name) }
    }

    func deleteFolder(_ folder: Folder) async {
        await perform { try await self.repository.deleteFolder(id: folder.id) }
        if selection == .folder(folder.id) { selection = .all }
    }

    func move(_ meetingID: UUID, to folderID: UUID?) async {
        await perform { try await self.repository.move(meetingID: meetingID, toFolder: folderID) }
    }

    func addTag(_ tag: String, to meetingID: UUID) async {
        guard let entry = entry(for: meetingID) else { return }
        await perform { try await self.repository.setTags(entry.tags + [tag], meetingID: meetingID) }
    }

    func removeTag(_ tag: String, from meetingID: UUID) async {
        guard let entry = entry(for: meetingID) else { return }
        await perform { try await self.repository.setTags(entry.tags.filter { $0 != tag }, meetingID: meetingID) }
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

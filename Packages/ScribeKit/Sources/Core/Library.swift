import Foundation

/// A flat folder of meetings. A meeting is in at most one folder.
public struct Folder: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A meeting plus how it's organized. Kept apart from `Meeting` so a running session, which re-saves its
/// own copy of the meeting, can't overwrite a folder or tags changed elsewhere in the meantime.
public struct LibraryEntry: Sendable, Identifiable, Hashable {
    public var meeting: Meeting
    public var folderID: UUID?
    public var tags: [String]

    public var id: UUID { meeting.id }

    public init(meeting: Meeting, folderID: UUID? = nil, tags: [String] = []) {
        self.meeting = meeting
        self.folderID = folderID
        self.tags = tags
    }
}

public enum LibraryFilter: Sendable, Hashable {
    case all
    case unfiled
    case folder(UUID)
    case tag(String)

    public func matches(_ entry: LibraryEntry) -> Bool {
        switch self {
        case .all: true
        case .unfiled: entry.folderID == nil
        case .folder(let id): entry.folderID == id
        case .tag(let name): entry.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
    }
}

public enum LibraryError: Error, LocalizedError, Equatable {
    case emptyFolderName
    case duplicateFolderName(String)

    public var errorDescription: String? {
        switch self {
        case .emptyFolderName: "Folder names can't be empty."
        case .duplicateFolderName(let name): "There's already a folder named \"\(name)\"."
        }
    }
}

public protocol LibraryRepository: Sendable {
    /// Alphabetical.
    func folders() async throws -> [Folder]
    func createFolder(named name: String) async throws -> Folder
    func renameFolder(id: UUID, to name: String) async throws
    /// Its meetings become unfiled.
    func deleteFolder(id: UUID) async throws
    /// Every meeting, newest first.
    func entries() async throws -> [LibraryEntry]
    func move(meetingID: UUID, toFolder folderID: UUID?) async throws
    /// Replaces the meeting's tags with `tags` after `Tags.normalize`.
    func setTags(_ tags: [String], meetingID: UUID) async throws
}

public enum Tags {
    /// Trims, drops a leading `#`, collapses inner whitespace, removes empties, and de-duplicates
    /// case-insensitively, keeping the first spelling.
    public static func normalize(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.hasPrefix("#") { tag = String(tag.dropFirst()).trimmingCharacters(in: .whitespaces) }
            tag = tag.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }
}

import Core
import Foundation
import GRDB

struct FolderRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "folder"

    var id: UUID
    var name: String
    var createdAt: Date

    var model: Folder { Folder(id: id, name: name, createdAt: createdAt) }
}

struct MeetingTagRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetingTag"

    var meetingID: UUID
    var name: String
}

struct GRDBLibraryRepository: LibraryRepository {
    let writer: any DatabaseWriter

    func folders() async throws -> [Folder] {
        try await writer.read { db in
            try FolderRecord.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db).map(\.model)
        }
    }

    func createFolder(named name: String) async throws -> Folder {
        let record = FolderRecord(id: UUID(), name: try Self.folderName(name), createdAt: .now)
        try await mapDuplicate(record.name) { try await writer.write { try record.insert($0) } }
        return record.model
    }

    func renameFolder(id: UUID, to name: String) async throws {
        let name = try Self.folderName(name)
        try await mapDuplicate(name) {
            try await writer.write { db in
                try db.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [name, id])
            }
        }
    }

    func deleteFolder(id: UUID) async throws {
        _ = try await writer.write { try FolderRecord.deleteOne($0, key: id) }
    }

    func entries() async throws -> [LibraryEntry] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM meeting ORDER BY startedAt DESC")
            var tags: [UUID: [String]] = [:]
            for tag in try MeetingTagRecord.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db) {
                tags[tag.meetingID, default: []].append(tag.name)
            }
            return try rows.map { row in
                let meeting = try MeetingRecord(row: row).model
                return LibraryEntry(meeting: meeting, folderID: row["folderID"], tags: tags[meeting.id] ?? [])
            }
        }
    }

    func move(meetingID: UUID, toFolder folderID: UUID?) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE meeting SET folderID = ? WHERE id = ?", arguments: [folderID, meetingID])
        }
    }

    func setTags(_ tags: [String], meetingID: UUID) async throws {
        let tags = Tags.normalize(tags)
        try await writer.write { db in
            try MeetingTagRecord.filter(Column("meetingID") == meetingID).deleteAll(db)
            for tag in tags { try MeetingTagRecord(meetingID: meetingID, name: tag).insert(db) }
        }
    }

    private static func folderName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyFolderName }
        return trimmed
    }

    private func mapDuplicate(_ name: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw LibraryError.duplicateFolderName(name)
        }
    }
}

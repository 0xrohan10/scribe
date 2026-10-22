import Core
import Foundation
import GRDB

public final class ScribeDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (creating if needed) the database at `url` and runs migrations.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        try self.init(writer: DatabasePool(path: url.path, configuration: config))
    }

    public static func inMemory() throws -> ScribeDatabase {
        try ScribeDatabase(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public var meetings: some MeetingRepository { GRDBMeetingRepository(writer: writer) }
    public var transcripts: some TranscriptRepository { GRDBTranscriptRepository(writer: writer) }
    public var notes: some NoteRepository { GRDBNoteRepository(writer: writer) }
    public var summaries: some SummaryRepository { GRDBSummaryRepository(writer: writer) }
    public var library: some LibraryRepository { GRDBLibraryRepository(writer: writer) }
    public var meetingSearch: some MeetingSearchRepository { GRDBMeetingSearchRepository(writer: writer) }
    public var todos: some TodoRepository { GRDBTodoRepository(writer: writer) }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("app", .text)
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("templateID", .text).notNull()
                t.column("micAudioPath", .text)
                t.column("systemAudioPath", .text)
            }
            try db.create(table: "segment") { t in
                t.primaryKey("id", .blob)
                t.column("meetingID", .blob).notNull().references("meeting", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("text", .text).notNull()
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("isFinal", .boolean).notNull()
            }
            try db.create(index: "segment_on_meeting_start", on: "segment", columns: ["meetingID", "start"])
            try db.create(table: "note") { t in
                t.primaryKey("id", .blob)
                t.column("meetingID", .blob).notNull().indexed().references("meeting", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("timestamp", .double).notNull()
                t.column("flagged", .boolean).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "summary") { t in
                t.primaryKey("meetingID", .blob).references("meeting", onDelete: .cascade)
                t.column("payload", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-folders-and-tags") { db in
            try db.create(table: "folder") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull().unique().collate(.nocase)
                t.column("createdAt", .datetime).notNull()
            }
            // Not part of MeetingRecord, so the session's re-saves of a meeting never touch it.
            try db.alter(table: "meeting") { t in
                t.add(column: "folderID", .blob).references("folder", onDelete: .setNull)
            }
            try db.create(table: "meetingTag") { t in
                t.column("meetingID", .blob).notNull().references("meeting", onDelete: .cascade)
                t.column("name", .text).notNull().collate(.nocase)
                t.primaryKey(["meetingID", "name"])
            }
            try db.create(index: "meetingTag_on_name", on: "meetingTag", columns: ["name"])
        }
        migrator.registerMigration("v3-todos") { db in
            try db.create(table: "todo") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("notes", .text).notNull()
                t.column("owner", .text)
                t.column("dueDate", .datetime)
                t.column("suggestedDue", .text)
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("meetingID", .blob).indexed().references("meeting", onDelete: .setNull)
                t.column("meetingTitle", .text)
            }
            try db.create(table: "todoImport") { t in
                t.primaryKey("sourceKey", .text)
                t.column("todoID", .blob).references("todo", onDelete: .setNull)
            }
            // A malformed old summary must not prevent the database from opening.
            for row in try Row.fetchAll(db, sql: "SELECT * FROM summary") {
                if let summary = try? SummaryRecord(row: row).payload { try importTodos(from: summary, in: db) }
            }
        }
        return migrator
    }
}

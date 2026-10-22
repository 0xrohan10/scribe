import Core
import CryptoKit
import Foundation
import GRDB

struct TodoRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "todo"
    var id: UUID
    var title: String
    var notes: String
    var owner: String?
    var dueDate: Date?
    var suggestedDue: String?
    var completedAt: Date?
    var createdAt: Date
    var meetingID: UUID?
    var meetingTitle: String?

    init(_ item: TodoItem) {
        id = item.id
        title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        notes = item.notes
        owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        if owner?.isEmpty == true { owner = nil }
        dueDate = item.dueDate
        suggestedDue = item.suggestedDue
        completedAt = item.completedAt
        createdAt = item.createdAt
        meetingID = item.meetingID
        meetingTitle = item.meetingTitle
    }

    var model: TodoItem {
        TodoItem(id: id, title: title, notes: notes, owner: owner, dueDate: dueDate, suggestedDue: suggestedDue,
                 completedAt: completedAt, createdAt: createdAt, meetingID: meetingID, meetingTitle: meetingTitle)
    }
}

struct GRDBTodoRepository: TodoRepository {
    let writer: any DatabaseWriter

    func items() async throws -> [TodoItem] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.*, m.title AS currentMeetingTitle FROM todo t LEFT JOIN meeting m ON m.id = t.meetingID
                ORDER BY t.createdAt DESC, t.id
                """).map { row in
                    var item = try TodoRecord(row: row).model
                    if let title: String = row["currentMeetingTitle"] { item.meetingTitle = title }
                    return item
                }
        }
    }

    func save(_ item: TodoItem) async throws {
        let record = TodoRecord(item)
        guard !record.title.isEmpty else { throw TodoError.emptyTitle }
        try await writer.write { [record] db in
            var record = record
            if let saved = try TodoRecord.fetchOne(db, key: record.id) {
                record.completedAt = saved.completedAt
                record.createdAt = saved.createdAt
                record.meetingID = saved.meetingID
                record.meetingTitle = saved.meetingTitle
                try record.update(db)
            } else {
                try record.insert(db)
            }
            if let meetingID = record.meetingID {
                let key = try todoSourceKey(meetingID: meetingID, title: record.title, owner: record.owner)
                try db.execute(sql: "INSERT INTO todoImport (sourceKey, todoID) VALUES (?, ?) ON CONFLICT(sourceKey) DO NOTHING", arguments: [key, record.id])
            }
        }
    }

    func setCompleted(id: UUID, completed: Bool) async throws {
        try await writer.write { db in
            let changed = try TodoRecord.filter(Column("id") == id).updateAll(db, Column("completedAt").set(to: completed ? Date.now : nil))
            guard changed == 1 else { throw TodoError.notFound }
        }
    }

    func delete(id: UUID) async throws {
        _ = try await writer.write { try TodoRecord.deleteOne($0, key: id) }
    }
}

/// Adds only new summary actions. The ledger prevents regeneration from resurrecting deleted tasks.
/// Existing todos are user-owned: importing never changes their title, owner, date, or completion.
func importTodos(from summary: MeetingSummary, in db: Database) throws {
    guard let meeting = try MeetingRecord.fetchOne(db, key: summary.meetingID)?.model else { return }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    for action in summary.actionItems {
        let title = action.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { continue }
        let key = try todoSourceKey(meetingID: meeting.id, title: title, owner: action.owner)
        if try Row.fetchOne(db, sql: "SELECT sourceKey FROM todoImport WHERE sourceKey = ?", arguments: [key]) != nil { continue }
        let rawDue = action.due?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = rawDue.flatMap { value -> Date? in
            guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
            return date
        }
        let item = TodoItem(title: title, owner: action.owner, dueDate: parsed,
                            suggestedDue: parsed == nil && rawDue?.isEmpty == false ? rawDue : nil,
                            createdAt: summary.createdAt, meetingID: meeting.id, meetingTitle: meeting.title)
        try TodoRecord(item).insert(db)
        try db.execute(sql: "INSERT INTO todoImport (sourceKey, todoID) VALUES (?, ?)", arguments: [key, item.id])
    }
}

private func todoSourceKey(meetingID: UUID, title: String, owner: String?) throws -> String {
    func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    let identity = try JSONEncoder().encode([meetingID.uuidString, normalized(title), normalized(owner ?? "")])
    return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
}

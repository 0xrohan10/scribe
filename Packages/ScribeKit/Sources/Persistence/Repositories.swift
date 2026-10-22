import Core
import Foundation
import GRDB

struct GRDBMeetingRepository: MeetingRepository {
    let writer: any DatabaseWriter

    func save(_ meeting: Meeting) async throws {
        try await writer.write { try MeetingRecord(meeting).save($0) }
    }

    func meeting(id: UUID) async throws -> Meeting? {
        try await writer.read { try MeetingRecord.fetchOne($0, key: id)?.model }
    }

    func recent(limit: Int) async throws -> [Meeting] {
        try await writer.read { db in
            try MeetingRecord.order(Column("startedAt").desc).limit(limit).fetchAll(db).map(\.model)
        }
    }

    func delete(id: UUID) async throws {
        _ = try await writer.write { try MeetingRecord.deleteOne($0, key: id) }
    }
}

struct GRDBTranscriptRepository: TranscriptRepository {
    let writer: any DatabaseWriter

    func upsert(_ segments: [TranscriptSegment], meetingID: UUID) async throws {
        try await writer.write { db in
            for segment in segments { try SegmentRecord(segment, meetingID: meetingID).save(db) }
        }
    }

    func segments(meetingID: UUID) async throws -> [TranscriptSegment] {
        try await writer.read { db in
            try SegmentRecord.filter(Column("meetingID") == meetingID).order(Column("start")).fetchAll(db).map(\.model)
        }
    }
}

struct GRDBNoteRepository: NoteRepository {
    let writer: any DatabaseWriter

    func save(_ note: Note) async throws {
        try await writer.write { try NoteRecord(note).save($0) }
    }

    func delete(id: UUID) async throws {
        _ = try await writer.write { try NoteRecord.deleteOne($0, key: id) }
    }

    func notes(meetingID: UUID) async throws -> [Note] {
        try await writer.read { db in
            try NoteRecord.filter(Column("meetingID") == meetingID).order(Column("timestamp")).fetchAll(db).map(\.model)
        }
    }
}

struct GRDBSummaryRepository: SummaryRepository {
    let writer: any DatabaseWriter

    func save(_ summary: MeetingSummary) async throws {
        try await writer.write { db in
            try SummaryRecord(meetingID: summary.meetingID, payload: summary, createdAt: summary.createdAt).save(db)
            try importTodos(from: summary, in: db)
        }
    }

    func summary(meetingID: UUID) async throws -> MeetingSummary? {
        try await writer.read { try SummaryRecord.fetchOne($0, key: meetingID)?.payload }
    }
}

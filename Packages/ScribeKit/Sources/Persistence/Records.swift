import Core
import Foundation
import GRDB

struct MeetingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting"

    var id: UUID
    var title: String
    var app: MeetingApp?
    var startedAt: Date
    var endedAt: Date?
    var templateID: String
    var micAudioPath: String?
    var systemAudioPath: String?

    init(_ m: Meeting) {
        (id, title, app, startedAt, endedAt, templateID, micAudioPath, systemAudioPath) =
            (m.id, m.title, m.app, m.startedAt, m.endedAt, m.templateID, m.micAudioPath, m.systemAudioPath)
    }

    var model: Meeting {
        Meeting(
            id: id, title: title, app: app, startedAt: startedAt, endedAt: endedAt, templateID: templateID,
            micAudioPath: micAudioPath, systemAudioPath: systemAudioPath)
    }
}

struct SegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segment"

    var id: UUID
    var meetingID: UUID
    var speaker: Speaker
    var text: String
    var start: Double
    var end: Double
    var isFinal: Bool

    init(_ s: TranscriptSegment, meetingID: UUID) {
        (id, self.meetingID, speaker, text, start, end, isFinal) = (s.id, meetingID, s.speaker, s.text, s.start, s.end, s.isFinal)
    }

    var model: TranscriptSegment {
        TranscriptSegment(id: id, speaker: speaker, text: text, start: start, end: end, isFinal: isFinal)
    }
}

struct NoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "note"

    var id: UUID
    var meetingID: UUID
    var text: String
    var timestamp: Double
    var flagged: Bool
    var createdAt: Date

    init(_ n: Note) {
        (id, meetingID, text, timestamp, flagged, createdAt) = (n.id, n.meetingID, n.text, n.timestamp, n.flagged, n.createdAt)
    }

    var model: Note {
        Note(id: id, meetingID: meetingID, text: text, timestamp: timestamp, flagged: flagged, createdAt: createdAt)
    }
}

struct SummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summary"

    var meetingID: UUID
    /// Stored as JSON so the summary shape can evolve without migrations.
    var payload: MeetingSummary
    var createdAt: Date
}

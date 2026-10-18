import Foundation

public protocol MeetingRepository: Sendable {
    func save(_ meeting: Meeting) async throws
    func meeting(id: UUID) async throws -> Meeting?
    func recent(limit: Int) async throws -> [Meeting]
    func delete(id: UUID) async throws
}

public protocol TranscriptRepository: Sendable {
    func upsert(_ segments: [TranscriptSegment], meetingID: UUID) async throws
    func segments(meetingID: UUID) async throws -> [TranscriptSegment]
}

public protocol NoteRepository: Sendable {
    func save(_ note: Note) async throws
    func delete(id: UUID) async throws
    func notes(meetingID: UUID) async throws -> [Note]
}

public protocol SummaryRepository: Sendable {
    func save(_ summary: MeetingSummary) async throws
    func summary(meetingID: UUID) async throws -> MeetingSummary?
}

/// Where per-meeting recordings live (`<root>/<meetingID>/mic.m4a`, `system.m4a`).
public protocol AudioFileStore: Sendable {
    func recordingURL(meetingID: UUID, source: AudioChunk.Source) throws -> URL
    func deleteRecordings(meetingID: UUID) throws
}

public protocol SecretStore: Sendable {
    func secret(for key: String) -> String?
    func setSecret(_ value: String?, for key: String) throws
}

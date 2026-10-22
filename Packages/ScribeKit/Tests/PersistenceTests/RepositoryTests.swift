import Core
import Foundation
import Testing

@testable import Persistence

@Suite struct RepositoryTests {
    let db = try! ScribeDatabase.inMemory()

    @Test func meetingRoundTripsWithApp() async throws {
        let meeting = Meeting(title: "Standup", app: .other("Slack Huddle"))
        try await db.meetings.save(meeting)
        let loaded = try await db.meetings.meeting(id: meeting.id)
        #expect(loaded?.app == .other("Slack Huddle"))
        #expect(loaded?.title == "Standup")
    }

    @Test func segmentsUpsertAndOrder() async throws {
        let meeting = Meeting(title: "m")
        try await db.meetings.save(meeting)
        var late = TranscriptSegment(speaker: .them, text: "partial", start: 5, end: 6, isFinal: false)
        let early = TranscriptSegment(speaker: .me, text: "hi", start: 1, end: 2, isFinal: true)
        try await db.transcripts.upsert([late, early], meetingID: meeting.id)
        late.text = "final"
        late.isFinal = true
        try await db.transcripts.upsert([late], meetingID: meeting.id)

        let segments = try await db.transcripts.segments(meetingID: meeting.id)
        #expect(segments.map(\.text) == ["hi", "final"])
    }

    @Test func deletingMeetingCascades() async throws {
        let meeting = Meeting(title: "m")
        try await db.meetings.save(meeting)
        try await db.notes.save(Note(meetingID: meeting.id, text: "n", timestamp: 3))
        try await db.summaries.save(MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "o"))
        try await db.meetings.delete(id: meeting.id)

        #expect(try await db.notes.notes(meetingID: meeting.id).isEmpty)
        #expect(try await db.summaries.summary(meetingID: meeting.id) == nil)
    }

    /// `MeetingSession` re-saves the meeting (end time, title, template) after segments exist. An
    /// INSERT OR REPLACE save would delete the row and cascade the deletion to its transcript and notes.
    @Test func resavingMeetingKeepsChildren() async throws {
        var meeting = Meeting(title: "m")
        try await db.meetings.save(meeting)
        try await db.transcripts.upsert([TranscriptSegment(speaker: .me, text: "hi", start: 1, end: 2, isFinal: true)], meetingID: meeting.id)
        try await db.notes.save(Note(meetingID: meeting.id, text: "n", timestamp: 3))
        meeting.endedAt = Date(timeIntervalSince1970: 2_000)
        try await db.meetings.save(meeting)

        #expect(try await db.meetings.meeting(id: meeting.id)?.endedAt == Date(timeIntervalSince1970: 2_000))
        #expect(try await db.transcripts.segments(meetingID: meeting.id).map(\.text) == ["hi"])
        #expect(try await db.notes.notes(meetingID: meeting.id).map(\.text) == ["n"])
    }

    @Test func summaryPayloadRoundTrips() async throws {
        let meeting = Meeting(title: "m")
        try await db.meetings.save(meeting)
        let summary = MeetingSummary(
            meetingID: meeting.id, templateID: "general", overview: "o",
            actionItems: [ActionItem(task: "Ship", owner: "Rohan")],
            createdAt: Date(timeIntervalSince1970: 1_000))
        try await db.summaries.save(summary)
        #expect(try await db.summaries.summary(meetingID: meeting.id) == summary)
    }
}

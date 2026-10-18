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

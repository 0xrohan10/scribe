import Core
import Foundation
import Testing
import Persistence

@Suite struct MeetingSearchTests {
    let db = try! ScribeDatabase.inMemory()

    @Test func findsTranscriptsNotesAndSummaryItemsAcrossMeetings() async throws {
        let first = Meeting(title: "Vendor review"), second = Meeting(title: "Follow-up")
        try await db.meetings.save(first)
        try await db.meetings.save(second)
        try await db.transcripts.upsert([TranscriptSegment(speaker: .them, text: "Billing starts on Monday.", start: 42, end: 48, isFinal: true)], meetingID: first.id)
        try await db.notes.save(Note(meetingID: second.id, text: "Rohan owns billing migration.", timestamp: 12))
        try await db.summaries.save(MeetingSummary(meetingID: second.id, templateID: "general", overview: "Vendor review", decisions: ["Use annual billing."]))
        let results = try await db.meetingSearch.search("What did we decide about billing?", limit: 12)
        #expect(Set(results.map(\.kind)) == [.transcript, .note, .decision])
        #expect(Set(results.map { $0.meeting.id }) == [first.id, second.id])
        #expect(results.first(where: { $0.kind == .transcript })?.timestamp == 42)
        #expect(results.contains { $0.text == "Use annual billing." })
    }

    @Test func olderMatchesAreNotLimitedToRecentMeetings() async throws {
        let old = Meeting(title: "Old review", startedAt: Date(timeIntervalSince1970: 100))
        try await db.meetings.save(old)
        try await db.notes.save(Note(meetingID: old.id, text: "Billing has an annual contract.", timestamp: 0))
        for index in 0..<25 { try await db.meetings.save(Meeting(title: "Unrelated \(index)")) }
        #expect(try await db.meetingSearch.search("billing", limit: 12).map { $0.meeting.id } == [old.id])
    }

    @Test func correctionsAndDeletionsAreReflectedImmediately() async throws {
        let meeting = Meeting(title: "Review")
        try await db.meetings.save(meeting)
        var segment = TranscriptSegment(speaker: .me, text: "Rowan owns billing.", start: 0, end: 2, isFinal: true)
        try await db.transcripts.upsert([segment], meetingID: meeting.id)
        #expect(try await db.meetingSearch.search("Rowan", limit: 12).count == 1)
        segment.text = "Rohan owns billing."
        try await db.transcripts.upsert([segment], meetingID: meeting.id)
        #expect(try await db.meetingSearch.search("Rowan", limit: 12).isEmpty)
        #expect(try await db.meetingSearch.search("Rohan", limit: 12).first?.text == segment.text)
        try await db.meetings.delete(id: meeting.id)
        #expect(try await db.meetingSearch.search("Rohan", limit: 12).isEmpty)
    }

    @Test func excludesPartialTextAndBoundsExactExcerpts() async throws {
        let meeting = Meeting(title: "Review")
        try await db.meetings.save(meeting)
        try await db.transcripts.upsert([TranscriptSegment(speaker: .me, text: "Billing partial", start: 0, end: 2, isFinal: false)], meetingID: meeting.id)
        let text = String(repeating: "Earlier discussion. ", count: 400) + "Billing starts next week. " + String(repeating: "Later. ", count: 400)
        try await db.notes.save(Note(meetingID: meeting.id, text: text, timestamp: 20))
        let results = try await db.meetingSearch.search("billing", limit: 12)
        #expect(results.count == 1)
        let quote = try #require(results.first?.text)
        #expect(quote.count <= 1200)
        #expect(quote.contains("Billing starts next week."))
        #expect(text.contains(quote))
    }

    @Test func decisionsCanBeFoundWithoutThatWordInTheirText() async throws {
        let meeting = Meeting(title: "Review")
        try await db.meetings.save(meeting)
        try await db.summaries.save(MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Review", decisions: ["Ship on Monday."]))
        let results = try await db.meetingSearch.search("What were our decisions?", limit: 12)
        #expect(results.map(\.text) == ["Ship on Monday."])
    }

    @Test func actionOwnersAreSearchableWithoutChangingTheSavedQuote() async throws {
        let meeting = Meeting(title: "Review")
        try await db.meetings.save(meeting)
        try await db.summaries.save(MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Review",
                                                   actionItems: [.init(task: "Ship the migration.", owner: "Rohan", due: "Friday")]))
        let source = try #require(try await db.meetingSearch.search("Rohan", limit: 12).first)
        #expect(source.text == "Ship the migration.")
        #expect(source.owner == "Rohan")
        #expect(source.due == "Friday")
    }

    @Test func oneLongMeetingDoesNotCrowdOutOtherSources() async throws {
        let long = Meeting(title: "Long review"), other = Meeting(title: "Old review", startedAt: Date(timeIntervalSince1970: 100))
        try await db.meetings.save(long)
        try await db.meetings.save(other)
        let segments = (0..<120).map { TranscriptSegment(speaker: .me, text: "Billing discussion \($0)", start: Double($0), end: Double($0 + 1), isFinal: true) }
        try await db.transcripts.upsert(segments, meetingID: long.id)
        try await db.transcripts.upsert([TranscriptSegment(speaker: .them, text: "Billing was approved.", start: 0, end: 1, isFinal: true)], meetingID: other.id)
        let results = try await db.meetingSearch.search("billing", limit: 12)
        #expect(results.filter { $0.meeting.id == long.id }.count == 4)
        #expect(results.contains { $0.meeting.id == other.id })
    }

    @Test func emptyQueriesLimitsAndSQLSyntaxAreSafe() async throws {
        let meeting = Meeting(title: "Review")
        try await db.meetings.save(meeting)
        try await db.notes.save(Note(meetingID: meeting.id, text: "Billing approved.", timestamp: 0))
        #expect(try await db.meetingSearch.search("what did we do?", limit: 12).isEmpty)
        #expect(try await db.meetingSearch.search("%_", limit: 12).isEmpty)
        #expect(try await db.meetingSearch.search("billing", limit: 0).isEmpty)
        #expect(try await db.meetingSearch.search("billing' OR 1=1 --", limit: 1).count == 1)
    }
}

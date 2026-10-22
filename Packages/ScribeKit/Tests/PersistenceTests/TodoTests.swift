import Core
import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct TodoTests {
    let db = try! ScribeDatabase.inMemory()

    private func meeting() async throws -> Meeting {
        let meeting = Meeting(title: "Planning")
        try await db.meetings.save(meeting)
        return meeting
    }

    @Test func standaloneTodosKeepEditsAndCompletionSeparate() async throws {
        var item = TodoItem(title: "  Send the proposal  ", notes: "Include pricing", owner: " Me ", dueDate: Date(timeIntervalSince1970: 2_000))
        try await db.todos.save(item)
        try await db.todos.setCompleted(id: item.id, completed: true)
        item.title = "Send the revised proposal"
        try await db.todos.save(item) // This draft predates the completion change.
        let saved = try #require(try await db.todos.items().first)
        #expect(saved.isCompleted)
        #expect(saved.title == "Send the revised proposal")
        #expect(saved.notes == "Include pricing")
        #expect(saved.owner == "Me")
        #expect(saved.meetingID == nil)
        #expect(saved.dueDate == item.dueDate)
        try await db.todos.setCompleted(id: item.id, completed: false)
        #expect(try await db.todos.items().first?.isCompleted == false)
        try await db.todos.delete(id: item.id)
        #expect(try await db.todos.items().isEmpty)
    }

    @Test func emptyTitlesAndMissingCompletionTargetsFail() async throws {
        await #expect(throws: TodoError.self) { try await db.todos.save(TodoItem(title: " \n ")) }
        await #expect(throws: TodoError.self) { try await db.todos.setCompleted(id: UUID(), completed: true) }
        #expect(try await db.todos.items().isEmpty)
    }

    @Test func summaryActionsBecomeTodosWithoutGuessingRelativeDates() async throws {
        let meeting = try await meeting()
        try await db.summaries.save(MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Plan", actionItems: [
            .init(task: "Send proposal", owner: "Me", due: "Friday"),
            .init(task: "Review contract", owner: "Maya", due: "2026-11-12"),
            .init(task: " ", due: "Tomorrow"),
        ]))
        let items = try await db.todos.items()
        #expect(items.count == 2)
        let relative = try #require(items.first { $0.title == "Send proposal" })
        #expect(relative.dueDate == nil)
        #expect(relative.suggestedDue == "Friday")
        #expect(relative.meetingID == meeting.id)
        #expect(relative.meetingTitle == meeting.title)
        #expect(items.first { $0.title == "Review contract" }?.dueDate != nil)
        #expect(items.first { $0.title == "Review contract" }?.suggestedDue == nil)
    }

    @Test func regenerationDoesNotDuplicateOrOverwriteUserChanges() async throws {
        let meeting = try await meeting()
        var summary = MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Plan",
                                     actionItems: [.init(task: "Send proposal", owner: "Rohan", due: "Friday")])
        try await db.summaries.save(summary)
        var item = try #require(try await db.todos.items().first)
        let id = item.id
        item.title = "Send revised proposal"
        item.owner = "Me"
        item.notes = "My additions"
        item.dueDate = Date(timeIntervalSince1970: 3_000)
        item.suggestedDue = nil
        item.meetingID = nil // An edit cannot detach the original source.
        try await db.todos.save(item)
        try await db.todos.setCompleted(id: id, completed: true)
        summary.actionItems = [.init(task: "  send   PROPOSAL ", owner: "rohan", due: "Monday")]
        try await db.summaries.save(summary)
        summary.actionItems = [.init(task: item.title, owner: item.owner, due: "Tuesday")]
        try await db.summaries.save(summary)
        let items = try await db.todos.items()
        #expect(items.count == 1)
        #expect(items.first?.id == id)
        #expect(items.first?.title == item.title)
        #expect(items.first?.owner == "Me")
        #expect(items.first?.notes == "My additions")
        #expect(items.first?.dueDate == item.dueDate)
        #expect(items.first?.suggestedDue == nil)
        #expect(items.first?.meetingID == meeting.id)
        #expect(items.first?.isCompleted == true)
    }

    @Test func deletedImportedActionsDoNotComeBackOnRegeneration() async throws {
        let meeting = try await meeting()
        var summary = MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Plan", actionItems: [.init(task: "Send proposal")])
        try await db.summaries.save(summary)
        let item = try #require(try await db.todos.items().first)
        try await db.todos.delete(id: item.id)
        summary.overview = "Revised plan"
        try await db.summaries.save(summary)
        #expect(try await db.todos.items().isEmpty)
        summary.actionItems.append(.init(task: "Call vendor"))
        try await db.summaries.save(summary)
        #expect(try await db.todos.items().map(\.title) == ["Call vendor"])
    }

    @Test func manualMeetingTasksAlsoDeduplicateAgainstSummaryActions() async throws {
        let meeting = try await meeting()
        let item = TodoItem(title: "Send proposal", owner: "Me", meetingID: meeting.id, meetingTitle: meeting.title)
        try await db.todos.save(item)
        let summary = MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Plan", actionItems: [.init(task: "Send proposal", owner: "Me")])
        try await db.summaries.save(summary)
        #expect(try await db.todos.items().map(\.id) == [item.id])
        try await db.todos.delete(id: item.id)
        try await db.summaries.save(summary)
        #expect(try await db.todos.items().isEmpty)
    }

    @Test func distinctMeetingsAndOwnersRemainDistinctTasks() async throws {
        let first = try await meeting(), second = try await meeting()
        try await db.summaries.save(MeetingSummary(meetingID: first.id, templateID: "general", overview: "Plan", actionItems: [
            .init(task: "Review proposal", owner: "Me"), .init(task: "Review proposal", owner: "Maya"), .init(task: "Review proposal", owner: "Me"),
        ]))
        try await db.summaries.save(MeetingSummary(meetingID: second.id, templateID: "general", overview: "Plan", actionItems: [.init(task: "Review proposal", owner: "Me")]))
        #expect(try await db.todos.items().count == 3)
    }

    @Test func deletingAMeetingKeepsItsTodosAndRenamesStayCurrent() async throws {
        var meeting = try await meeting()
        try await db.summaries.save(MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Plan", actionItems: [.init(task: "Send proposal")]))
        meeting.title = "Renamed planning"
        try await db.meetings.save(meeting)
        #expect(try await db.todos.items().first?.meetingTitle == meeting.title)
        try await db.meetings.delete(id: meeting.id)
        let item = try #require(try await db.todos.items().first)
        #expect(item.title == "Send proposal")
        #expect(item.meetingID == nil)
        #expect(item.meetingTitle != nil)
    }

    @Test func summaryAndTodoImportAreOneTransaction() async throws {
        let meeting = try await meeting()
        let original = MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Original")
        try await db.summaries.save(original)
        try await db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_todo BEFORE INSERT ON todo BEGIN SELECT RAISE(ABORT, 'storage unavailable'); END")
        }
        let revised = MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Revised", actionItems: [.init(task: "Send proposal")])
        await #expect(throws: DatabaseError.self) { try await db.summaries.save(revised) }
        #expect(try await db.summaries.summary(meetingID: meeting.id)?.overview == "Original")
        #expect(try await db.todos.items().isEmpty)
    }

    @Test func migrationBackfillsOldSummariesAndSkipsMalformedPayloads() async throws {
        let queue = try DatabaseQueue()
        try ScribeDatabase.migrator.migrate(queue, upTo: "v2-folders-and-tags")
        let meeting = Meeting(title: "Old meeting"), malformed = Meeting(title: "Malformed summary")
        let summary = MeetingSummary(meetingID: meeting.id, templateID: "general", overview: "Plan", actionItems: [.init(task: "Send proposal")])
        try await queue.write { db in
            try MeetingRecord(meeting).insert(db)
            try MeetingRecord(malformed).insert(db)
            try SummaryRecord(meetingID: meeting.id, payload: summary, createdAt: summary.createdAt).insert(db)
            try db.execute(sql: "INSERT INTO summary (meetingID, payload, createdAt) VALUES (?, ?, ?)", arguments: [malformed.id, "not-json", Date.now])
        }
        let upgraded = try ScribeDatabase(writer: queue)
        #expect(try await upgraded.todos.items().map(\.title) == ["Send proposal"])
        let reopened = try ScribeDatabase(writer: queue)
        #expect(try await reopened.todos.items().count == 1)
        #expect(try await reopened.meetings.meeting(id: malformed.id) != nil)
    }
}

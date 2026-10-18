import Core
import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct LibraryTests {
    let db = try! ScribeDatabase.inMemory()

    private func meeting(_ title: String, at t: TimeInterval = 0) async throws -> Meeting {
        let m = Meeting(title: title, startedAt: Date(timeIntervalSince1970: t))
        try await db.meetings.save(m)
        return m
    }

    @Test func foldersAreAlphabeticalAndUniqueIgnoringCase() async throws {
        _ = try await db.library.createFolder(named: "  sales ")
        _ = try await db.library.createFolder(named: "Hiring")
        #expect(try await db.library.folders().map(\.name) == ["Hiring", "sales"])
        await #expect(throws: LibraryError.duplicateFolderName("Sales")) { try await db.library.createFolder(named: "Sales") }
        await #expect(throws: LibraryError.emptyFolderName) { try await db.library.createFolder(named: "  ") }
    }

    @Test func renameRejectsDuplicates() async throws {
        let a = try await db.library.createFolder(named: "A")
        _ = try await db.library.createFolder(named: "B")
        try await db.library.renameFolder(id: a.id, to: "Customers")
        await #expect(throws: LibraryError.duplicateFolderName("b")) { try await db.library.renameFolder(id: a.id, to: "b") }
        #expect(try await db.library.folders().map(\.name) == ["B", "Customers"])
    }

    @Test func entriesCarryFolderAndTagsNewestFirst() async throws {
        let old = try await meeting("Old", at: 1)
        _ = try await meeting("New", at: 2)
        let folder = try await db.library.createFolder(named: "Sales")
        try await db.library.move(meetingID: old.id, toFolder: folder.id)
        try await db.library.setTags([" #acme", "Q4", "acme", ""], meetingID: old.id)

        let entries = try await db.library.entries()
        #expect(entries.map(\.meeting.title) == ["New", "Old"])
        #expect(entries[1].folderID == folder.id)
        #expect(entries[1].tags == ["acme", "Q4"])
        #expect(entries[0].folderID == nil && entries[0].tags.isEmpty)
    }

    /// The session re-saves its own copy of the meeting on stop, rename and template change.
    @Test func resavingMeetingKeepsFolderAndTags() async throws {
        var m = try await meeting("M")
        let folder = try await db.library.createFolder(named: "Sales")
        try await db.library.move(meetingID: m.id, toFolder: folder.id)
        try await db.library.setTags(["acme"], meetingID: m.id)
        m.endedAt = .now
        m.title = "Renamed"
        try await db.meetings.save(m)

        let entry = try #require(try await db.library.entries().first)
        #expect(entry.meeting.title == "Renamed")
        #expect(entry.folderID == folder.id)
        #expect(entry.tags == ["acme"])
    }

    @Test func deletingFolderUnfilesItsMeetings() async throws {
        let m = try await meeting("M")
        let folder = try await db.library.createFolder(named: "Sales")
        try await db.library.move(meetingID: m.id, toFolder: folder.id)
        try await db.library.deleteFolder(id: folder.id)
        #expect(try await db.library.entries().first?.folderID == nil)
        #expect(try await db.library.folders().isEmpty)
    }

    @Test func deletingMeetingRemovesItsTags() async throws {
        let m = try await meeting("M")
        try await db.library.setTags(["acme"], meetingID: m.id)
        try await db.meetings.delete(id: m.id)
        let count = try await db.writer.read { try MeetingTagRecord.fetchCount($0) }
        #expect(count == 0)
    }

    @Test func upgradesExistingV1Database() async throws {
        let queue = try DatabaseQueue()
        try ScribeDatabase.migrator.migrate(queue, upTo: "v1")
        let m = Meeting(title: "From v1")
        try await queue.write { try MeetingRecord(m).insert($0) }

        let upgraded = try ScribeDatabase(writer: queue)
        let entries = try await upgraded.library.entries()
        #expect(entries.map(\.meeting.title) == ["From v1"])
        #expect(entries.first?.folderID == nil)
    }
}

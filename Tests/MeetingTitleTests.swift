import Core
import Foundation
import Notes
import Persistence
import Testing

private actor TitleStore: MeetingRepository, NoteRepository, SummaryRepository {
    var saved: Meeting?
    var fails = false
    func failWrites() { fails = true }
    func save(_ meeting: Meeting) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        saved = meeting
    }
    func rename(id: UUID, to title: String) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        saved = Meeting(id: id, title: title)
    }
    func meeting(id: UUID) -> Meeting? { saved }
    func setTemplate(id: UUID, to templateID: String) { saved?.templateID = templateID }
    func finish(id: UUID, at endedAt: Date) { saved?.endedAt = endedAt }
    func recent(limit: Int) -> [Meeting] { saved.map { [$0] } ?? [] }
    func delete(id: UUID) {}
    func save(_ note: Note) {}
    func notes(meetingID: UUID) -> [Note] { [] }
    func save(_ summary: MeetingSummary) {}
    func summary(meetingID: UUID) -> MeetingSummary? { nil }
}

@MainActor
struct MeetingTitleTests {
    @Test func savedTitleSurvivesReopeningFromSQLite() async throws {
        let database = try ScribeDatabase.inMemory()
        let meeting = Meeting(title: "Original", endedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await database.meetings.save(meeting)
        let segment = TranscriptSegment(speaker: .them, text: "Plan the billing migration.", start: 0, end: 1, isFinal: true)
        try await database.transcripts.upsert([segment], meetingID: meeting.id)
        let vm = try await MeetingViewModel.review(
            meeting, transcripts: database.transcripts, noteRepository: database.notes, summaries: database.summaries,
            qa: nil, summarizer: nil, meetings: database.meetings)
        var latest = meeting
        let updatedEnd = Date(timeIntervalSince1970: 1_700_000_060)
        latest.endedAt = updatedEnd
        latest.templateID = "planning"
        try await database.meetings.finish(id: meeting.id, at: updatedEnd)
        try await database.meetings.setTemplate(id: meeting.id, to: latest.templateID)
        vm.titleDraft = "Billing migration planning"
        await vm.saveTitle()

        let saved = try #require(try await database.meetings.meeting(id: meeting.id))
        let reopened = try await MeetingViewModel.review(
            saved, transcripts: database.transcripts, noteRepository: database.notes, summaries: database.summaries,
            qa: nil, summarizer: nil, meetings: database.meetings)
        #expect(vm.warnings.isEmpty)
        #expect(reopened.meeting.title == "Billing migration planning")
        #expect(reopened.titleDraft == "Billing migration planning")
        #expect(reopened.transcript.segments == [segment])
        #expect(reopened.meeting.endedAt == latest.endedAt)
        #expect(reopened.meeting.templateID == latest.templateID)
        #expect(try await database.library.entries().first?.meeting.title == "Billing migration planning")
    }

    @Test func savingDeletedMeetingDoesNotRecreateIt() async throws {
        let database = try ScribeDatabase.inMemory()
        let meeting = Meeting(title: "Original")
        try await database.meetings.save(meeting)
        let vm = try await MeetingViewModel.review(
            meeting, transcripts: database.transcripts, noteRepository: database.notes, summaries: database.summaries,
            qa: nil, summarizer: nil, meetings: database.meetings)
        try await database.meetings.delete(id: meeting.id)
        vm.titleDraft = "Unsaved title"
        await vm.saveTitle()
        #expect(try await database.meetings.meeting(id: meeting.id) == nil)
        #expect(!vm.warnings.isEmpty)
        #expect(vm.titleDraft == "Unsaved title")
        #expect(vm.meeting.title == "Original")
    }

    private func model(store: TitleStore) -> MeetingViewModel {
        let meeting = Meeting(title: "Original")
        return MeetingViewModel(
            meeting: meeting, session: nil,
            notes: NotesController(meetingID: meeting.id, clock: SessionClock(), repository: store),
            qa: nil, summarizer: nil, summaries: store, meetings: store, state: .finished)
    }

    @Test func pastMeetingTitleChangesOnlyWhenSaved() async {
        let store = TitleStore()
        let vm = model(store: store)
        vm.titleDraft = "  Saved title  "
        #expect(vm.meeting.title == "Original")
        #expect(await store.saved == nil)
        await vm.saveTitle()
        #expect(vm.meeting.title == "Saved title")
        #expect(vm.titleDraft == "Saved title")
        #expect(await store.saved?.title == "Saved title")
        #expect(!vm.canSaveTitle)
    }

    @Test func failedSaveKeepsDraftAndOriginalTitle() async {
        let store = TitleStore()
        await store.failWrites()
        let vm = model(store: store)
        vm.titleDraft = "My title"
        await vm.saveTitle()
        #expect(vm.meeting.title == "Original")
        #expect(vm.titleDraft == "My title")
        #expect(vm.canSaveTitle)
        #expect(!vm.warnings.isEmpty)
    }

    @Test func blankTitleCannotBeSaved() async {
        let store = TitleStore()
        let vm = model(store: store)
        vm.titleDraft = " \n "
        #expect(!vm.canSaveTitle)
        await vm.saveTitle()
        #expect(await store.saved == nil)
        #expect(vm.meeting.title == "Original")
    }
}

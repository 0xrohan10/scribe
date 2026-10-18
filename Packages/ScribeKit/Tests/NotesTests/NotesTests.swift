import Core
import Foundation
import Testing

@testable import Notes

private actor NoteStore: NoteRepository {
    var saved: [UUID: Note] = [:]
    func save(_ note: Note) { saved[note.id] = note }
    func delete(id: UUID) { saved[id] = nil }
    func notes(meetingID: UUID) -> [Note] { saved.values.sorted { $0.timestamp < $1.timestamp } }
}

@Suite struct NotesTests {
    @Test func draftAnchorsWhenTypingStarts() {
        var draft = NoteDraft()
        draft.update("  ", now: 1)
        #expect(draft.anchor == nil)
        draft.update("b", now: 10)
        draft.update("budget", now: 14)
        #expect(draft.anchor == 10)
        draft.update("", now: 20)
        #expect(draft.anchor == nil)
    }

    @Test func commitUsesAnchorAndBangFlags() async throws {
        let store = NoteStore()
        let notes = NotesController(meetingID: UUID(), clock: SessionClock(), repository: store)
        var draft = NoteDraft()
        draft.update("! budget not approved", now: 42)

        let note = try #require(try await notes.commit(draft))
        #expect(note.timestamp == 42)
        #expect(note.flagged)
        #expect(note.text == "budget not approved")
        #expect(await store.saved[note.id] != nil)
        #expect(try await notes.commit(NoteDraft()) == nil)
    }

    @Test func notesStaySortedByTimestamp() async throws {
        let notes = NotesController(meetingID: UUID(), clock: SessionClock(), repository: NoteStore())
        for (t, text) in [(30.0, "b"), (10.0, "a"), (50.0, "c")] {
            var d = NoteDraft()
            d.update(text, now: t)
            try await notes.commit(d)
        }
        #expect(await notes.notes.map(\.text) == ["a", "b", "c"])
        let first = await notes.notes[0]
        #expect(try await notes.toggleFlag(first.id)?.flagged == true)
    }

    @Test func anchoringFindsSurroundingTranscript() {
        let transcript = Transcript(segments: [
            TranscriptSegment(speaker: .them, text: "early", start: 0, end: 5, isFinal: true),
            TranscriptSegment(speaker: .them, text: "relevant", start: 40, end: 48, isFinal: true),
            TranscriptSegment(speaker: .me, text: "late", start: 90, end: 92, isFinal: true),
        ])
        let note = Note(meetingID: UUID(), text: "n", timestamp: 50)
        #expect(NoteAnchoring.context(for: note, in: transcript).map(\.text) == ["relevant"])
    }
}

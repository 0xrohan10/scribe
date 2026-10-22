import Core
import Foundation

/// The draft note. Its timestamp records when typing starts, not when the note is committed,
/// so it matches the speech at that time.
public struct NoteDraft: Sendable, Equatable {
    public private(set) var text = ""
    public private(set) var anchor: TimeInterval?

    public init() {}

    public mutating func update(_ newText: String, now: TimeInterval) {
        let wasBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            anchor = nil
        } else if wasBlank {
            anchor = now
        }
        text = newText
    }

    public mutating func reset() {
        self = NoteDraft()
    }
}

/// Owns one meeting's notes. A leading `!` flags the note for the summary ("! budget isn't approved").
public actor NotesController {
    public nonisolated let meetingID: UUID
    private let clock: SessionClock
    private let repository: any NoteRepository
    public private(set) var notes: [Note] = []

    public init(meetingID: UUID, clock: SessionClock, repository: any NoteRepository) {
        self.meetingID = meetingID
        self.clock = clock
        self.repository = repository
    }

    @discardableResult
    public func load() async throws -> [Note] {
        notes = try await repository.notes(meetingID: meetingID)
        return notes
    }

    /// Commits a draft. Returns nil for blank text.
    @discardableResult
    public func commit(_ draft: NoteDraft, flagged: Bool = false) async throws -> Note? {
        var text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var flagged = flagged
        if text.hasPrefix("!") {
            flagged = true
            text = text.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        let note = Note(meetingID: meetingID, text: text, timestamp: draft.anchor ?? clock.now, flagged: flagged)
        try await repository.save(note)
        insert(note)
        return note
    }

    public func update(_ note: Note) async throws {
        try await repository.save(note)
        insert(note)
    }

    @discardableResult
    public func toggleFlag(_ id: UUID) async throws -> Note? {
        guard var note = notes.first(where: { $0.id == id }) else { return nil }
        note.flagged.toggle()
        try await update(note)
        return note
    }

    public func delete(_ id: UUID) async throws {
        try await repository.delete(id: id)
        notes.removeAll { $0.id == id }
    }

    private func insert(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        let index = notes.firstIndex { $0.timestamp > note.timestamp } ?? notes.endIndex
        notes.insert(note, at: index)
    }
}

public enum NoteAnchoring {
    /// The transcript around a note: what was said leading up to it, plus a little after.
    public static func context(for note: Note, in transcript: Transcript, before: TimeInterval = 20, after: TimeInterval = 5) -> [TranscriptSegment] {
        transcript.segments(from: note.timestamp - before, to: note.timestamp + after)
    }
}

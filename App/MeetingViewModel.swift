import Core
import Foundation
import Intelligence
import Notes
import Observation
import Session

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var activity: String?
    var sources: [WebSource] = []
    var isStreaming = false
    var error: String?
}

/// UI state for one meeting, live or reviewed afterwards.
@MainActor @Observable
final class MeetingViewModel: Identifiable {
    let id: UUID
    private(set) var meeting: Meeting
    private(set) var state: SessionState
    private(set) var transcript = Transcript()
    private(set) var notes: [Note] = []
    private(set) var draft = NoteDraft()
    private(set) var messages: [ChatMessage] = []
    private(set) var summary: MeetingSummary?
    private(set) var isRegenerating = false
    var warnings: [String] = []
    /// Transcript time the user jumped to from a note.
    var focusTime: TimeInterval?

    @ObservationIgnored private let session: MeetingSession?
    @ObservationIgnored private let notesController: NotesController
    @ObservationIgnored private let qa: QAEngine?
    @ObservationIgnored private let summarizer: LLMSummarizer?
    @ObservationIgnored private let summaries: any SummaryRepository
    @ObservationIgnored private let onFinish: () -> Void
    @ObservationIgnored let clock: SessionClock

    var isLive: Bool { session != nil }
    var isRecording: Bool { state == .recording || state == .starting }
    /// Holds (or is about to hold) the mic and system audio: includes a live session that hasn't started yet.
    var isCapturing: Bool {
        guard isLive else { return false }
        switch state {
        case .idle, .starting, .recording, .stopping: return true
        case .summarizing, .finished, .failed: return false
        }
    }
    var canAsk: Bool { qa != nil }
    var now: TimeInterval { isRecording ? clock.now : transcript.duration }

    init(
        meeting: Meeting, session: MeetingSession?, notes: NotesController, qa: QAEngine?, summarizer: LLMSummarizer?,
        summaries: any SummaryRepository, state: SessionState = .idle, clock: SessionClock? = nil, onFinish: @escaping () -> Void = {}
    ) {
        self.id = meeting.id
        self.meeting = meeting
        self.session = session
        self.notesController = notes
        self.qa = qa
        self.summarizer = summarizer
        self.summaries = summaries
        self.state = state
        self.clock = session?.clock ?? clock ?? SessionClock()
        self.onFinish = onFinish
        if let session {
            let events = session.events()
            Task { [weak self] in
                for await event in events { self?.handle(event) }
            }
        }
    }

    /// Loads a finished meeting for review.
    static func review(
        _ meeting: Meeting, transcripts: any TranscriptRepository, noteRepository: any NoteRepository, summaries: any SummaryRepository,
        qa: QAEngine?, summarizer: LLMSummarizer?
    ) async throws -> MeetingViewModel {
        let notes = NotesController(meetingID: meeting.id, clock: SessionClock(), repository: noteRepository)
        let vm = MeetingViewModel(meeting: meeting, session: nil, notes: notes, qa: qa, summarizer: summarizer, summaries: summaries, state: .finished)
        vm.transcript = Transcript(segments: try await transcripts.segments(meetingID: meeting.id))
        vm.notes = try await notes.load()
        vm.summary = try await summaries.summary(meetingID: meeting.id)
        return vm
    }

    // MARK: Lifecycle

    func start() async {
        guard let session else { return }
        do {
            try await session.start()
        } catch {
            warnings.append(error.localizedDescription)
        }
    }

    func stop() async {
        await session?.stop()
    }

    /// Returns once audio is released; the summary finishes in the background.
    func stopCapture() async {
        await session?.stopCapture()
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .state(let s):
            state = s
            if s == .finished { onFinish() }
        case .segment(let segment): transcript.upsert(segment)
        case .summary(let s): summary = s
        case .warning(let w): warnings.append(w)
        }
    }

    func rename(_ title: String) {
        meeting.title = title
        Task { await session?.rename(title) }
    }

    func setTemplate(_ id: String) {
        meeting.templateID = id
        Task { await session?.setTemplate(id) }
    }

    func regenerateSummary() async {
        guard let summarizer, !transcript.isEmpty else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            let s = try await summarizer.summarize(meeting: meeting, transcript: transcript, notes: notes)
            try await summaries.save(s)
            summary = s
        } catch {
            warnings.append("Summary failed: \(error.localizedDescription)")
        }
    }

    // MARK: Notes

    func updateDraft(_ text: String) {
        draft.update(text, now: clock.now)
    }

    func commitDraft() async {
        do {
            try await notesController.commit(draft)
            draft.reset()
            notes = await notesController.notes
        } catch {
            warnings.append("Couldn't save note: \(error.localizedDescription)")
        }
    }

    func toggleFlag(_ note: Note) async {
        _ = try? await notesController.toggleFlag(note.id)
        notes = await notesController.notes
    }

    func delete(_ note: Note) async {
        try? await notesController.delete(note.id)
        notes = await notesController.notes
    }

    // MARK: Q&A

    func ask(_ question: String) async {
        guard let qa, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let history = messages.filter { $0.error == nil && !$0.text.isEmpty }.suffix(10).map {
            LLMMessage(role: $0.role == .user ? .user : .assistant, content: $0.text)
        }
        messages.append(ChatMessage(role: .user, text: question))
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        let index = messages.count - 1

        do {
            for try await delta in qa.answer(question, transcript: transcript, now: now, history: Array(history)) {
                switch delta {
                case .text(let t):
                    messages[index].text += t
                    messages[index].activity = nil
                case .activity(let a): messages[index].activity = a
                case .sources(let s): messages[index].sources += s
                case .done: break
                }
            }
        } catch {
            messages[index].error = error.localizedDescription
        }
        messages[index].isStreaming = false
        messages[index].activity = nil
    }
}

extension MeetingSummary {
    var markdown: String {
        func section(_ title: String, _ items: [String]) -> String {
            items.isEmpty ? "" : "\n## \(title)\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        let actions = actionItems.map { item in
            [item.owner.map { "**\($0)**: " }, item.task, item.due.map { " (due \($0))" }].compactMap { $0 }.joined()
        }
        return "## Overview\n\(overview)\n" + section("Flagged", flagged) + section("Decisions", decisions)
            + section("Action items", actions) + section("Open questions", openQuestions)
    }
}

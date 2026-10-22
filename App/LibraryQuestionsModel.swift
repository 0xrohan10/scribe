import Core
import Foundation
import Intelligence
import Observation

struct LibraryAnswer: Identifiable {
    let id = UUID()
    let question: String
    var text = ""
    var sources: [MeetingEvidence] = []
    var activity: String?
    var error: String?
    var isStreaming = true
}

/// Library-wide questions stay separate from each meeting's chat and survive navigation to a source.
@MainActor @Observable
final class LibraryQuestionsModel {
    private(set) var answers: [LibraryAnswer] = []
    private(set) var isAsking = false
    var sourceError: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func ask(_ question: String, makeEngine: () throws -> MeetingLibraryQA) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAsking, !question.isEmpty else { return }
        sourceError = nil
        let history = answers.filter { $0.error == nil && !$0.text.isEmpty }.suffix(5).flatMap {
            [LLMMessage(role: .user, content: $0.question), LLMMessage(role: .assistant, content: $0.text)]
        }
        answers.append(LibraryAnswer(question: question))
        let index = answers.count - 1
        isAsking = true
        do {
            let engine = try makeEngine()
            task = Task {
                defer {
                    answers[index].isStreaming = false
                    answers[index].activity = nil
                    isAsking = false
                    task = nil
                }
                do {
                    for try await event in engine.answer(question, history: history) {
                        try Task.checkCancellation()
                        switch event {
                        case .activity(let message): answers[index].activity = message
                        case .sources(let sources): answers[index].sources = sources
                        case .text(let text):
                            answers[index].text += text
                            answers[index].activity = nil
                        }
                    }
                    try Task.checkCancellation()
                } catch {
                    answers[index].error = Task.isCancelled ? "Cancelled." : error.localizedDescription
                }
            }
        } catch {
            answers[index].isStreaming = false
            answers[index].error = error.localizedDescription
            isAsking = false
        }
    }

    func cancel() { task?.cancel() }

    func clear() {
        guard !isAsking else { return }
        answers = []
        sourceError = nil
    }
}

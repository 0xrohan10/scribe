import Core
import Foundation

public struct LLMSummarizer: MeetingSummarizer {
    public var llm: any LLMProvider
    public var templates: [SummaryTemplate]
    public var params: ModelParams

    public init(llm: any LLMProvider, templates: [SummaryTemplate] = SummaryTemplates.all, params: ModelParams = .init(maxTokens: 4096)) {
        self.llm = llm
        self.templates = templates
        self.params = params
    }

    public func summarize(meeting: Meeting, transcript: Transcript, notes: [Note]) async throws -> MeetingSummary {
        let template = templates.first { $0.id == meeting.templateID } ?? .general
        let request = LLMRequest(
            system: Prompts.summarySystem(template: template),
            messages: [LLMMessage(role: .user, content: Prompts.summaryInput(meeting: meeting, transcript: transcript, notes: notes))],
            params: params)
        let text = try await llm.completeText(request)
        return SummaryParser.parse(text, meetingID: meeting.id, templateID: template.id)
    }
}

enum SummaryParser {
    private struct Payload: Decodable {
        var overview: String?
        var decisions: [String]?
        var actionItems: [ActionItem]?
        var openQuestions: [String]?
        var flagged: [String]?
    }

    /// Extracts the JSON object from the model's reply. If there isn't a valid one, the raw text becomes the overview.
    static func parse(_ text: String, meetingID: UUID, templateID: String) -> MeetingSummary {
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
            let payload = try? JSONDecoder().decode(Payload.self, from: Data(text[open...close].utf8))
        {
            return MeetingSummary(
                meetingID: meetingID, templateID: templateID, overview: payload.overview ?? "", decisions: payload.decisions ?? [],
                actionItems: payload.actionItems ?? [], openQuestions: payload.openQuestions ?? [], flagged: payload.flagged ?? [])
        }
        return MeetingSummary(meetingID: meetingID, templateID: templateID, overview: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum SummaryTemplates {
    public static let all: [SummaryTemplate] = [
        .general,
        SummaryTemplate(
            id: "standup", name: "Standup",
            instructions: "Organise the overview by person: what they did, what's next, blockers. Keep it terse."),
        SummaryTemplate(
            id: "one-on-one", name: "1:1",
            instructions: "Focus on feedback given and received, career topics, concerns raised, and commitments each person made."),
        SummaryTemplate(
            id: "sales", name: "Sales / customer call",
            instructions: "Capture the customer's pain points, current tools, budget, timeline, decision makers, objections and agreed next steps."),
        SummaryTemplate(
            id: "interview", name: "Interview",
            instructions: "Summarise the candidate's answers per topic, notable strengths, concerns, and anything to verify. Avoid a hire/no-hire verdict."),
        SummaryTemplate(
            id: "planning", name: "Planning / design review",
            instructions: "Emphasise options considered, trade-offs, the chosen approach and why, risks, and unresolved design questions."),
    ]
}

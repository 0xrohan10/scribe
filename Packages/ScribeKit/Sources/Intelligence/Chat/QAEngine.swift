import Core
import Foundation

/// Supplies the transcript text the LLM sees for a question.
/// Seam for long meetings: swap in chunked summaries or retrieval without touching `QAEngine`.
public protocol TranscriptContextProvider: Sendable {
    func context(for question: String, transcript: Transcript) async -> String
}

/// The most recent `maxCharacters` of transcript (≈ 4 chars/token).
public struct RollingTranscriptContext: TranscriptContextProvider {
    public var maxCharacters: Int

    public init(maxCharacters: Int = 120_000) {
        self.maxCharacters = maxCharacters
    }

    public func context(for question: String, transcript: Transcript) async -> String {
        let full = transcript.formatted()
        guard full.count > maxCharacters else { return full }
        let tail = full.suffix(maxCharacters)
        let lineStart = tail.firstIndex(of: "\n").map { tail.index(after: $0) } ?? tail.startIndex
        return "[…earlier transcript omitted…]\n" + tail[lineStart...]
    }
}

/// Answers questions during a meeting: "what did they just say" locally, everything else via the LLM.
public struct QAEngine: Sendable {
    public var llm: any LLMProvider
    public var webSearch: (any WebSearchTool)?
    public var context: any TranscriptContextProvider
    public var params: ModelParams
    /// How far back the local "just said" answers look.
    public var recentWindow: TimeInterval

    public init(
        llm: any LLMProvider, webSearch: (any WebSearchTool)? = nil, context: any TranscriptContextProvider = RollingTranscriptContext(),
        params: ModelParams = .init(maxTokens: 1024), recentWindow: TimeInterval = 30
    ) {
        self.llm = llm
        self.webSearch = webSearch
        self.context = context
        self.params = params
        self.recentWindow = recentWindow
    }

    /// - Parameter history: earlier Q&A turns from this meeting, oldest first.
    public func answer(_ question: String, transcript: Transcript, now: TimeInterval, history: [LLMMessage] = []) -> AsyncThrowingStream<LLMDelta, Error> {
        if let local = RecentSpeechAnswerer.answer(question, transcript: transcript, now: now, window: recentWindow) {
            return AsyncThrowingStream { continuation in
                continuation.yield(.text(local))
                continuation.yield(.done(stopReason: "local"))
                continuation.finish()
            }
        }

        let (llm, webSearch, contextProvider, params) = (llm, webSearch, context, params)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let transcriptText = await contextProvider.context(for: question, transcript: transcript)
                    var prompt = question
                    var tools: [LLMTool] = []
                    // A configured search tool wins over the provider's hosted search, so the choice in
                    // Settings holds whichever model answers.
                    if let webSearch {
                        continuation.yield(.activity("Searching the web…"))
                        let results = try await webSearch.search(question, maxResults: 5)
                        continuation.yield(.sources(results.map { WebSource(title: $0.title, url: $0.url) }))
                        prompt += "\n\n" + Prompts.webResults(results)
                    } else if llm.capabilities.serverWebSearch {
                        tools = [.webSearch(maxUses: 3)]
                    }
                    let request = LLMRequest(
                        system: Prompts.qaSystem(transcript: transcriptText, now: now),
                        messages: history + [LLMMessage(role: .user, content: prompt)], tools: tools, params: params)
                    for try await delta in llm.complete(request) { continuation.yield(delta) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Handles "what did they just say?"-style questions straight from the transcript, with no LLM call.
public enum RecentSpeechAnswerer {
    private static let aboutThem = [
        #"what (did|was) (they|he|she|you|someone|that person) (just )?(say|said)"#,
        #"what was (just )?said"#,
        #"(repeat|say) that( again)?"#,
        #"what (did|was) the last thing (they|he|she) said"#,
        #"what did i miss"#,
    ]
    private static let aboutMe = [#"what did i (just )?say"#]

    public static func answer(_ question: String, transcript: Transcript, now: TimeInterval, window: TimeInterval) -> String? {
        let q = question.lowercased()
        let speaker: Speaker
        if matches(q, aboutMe) {
            speaker = .me
        } else if matches(q, aboutThem) {
            speaker = .them
        } else {
            return nil
        }

        let spoken = transcript.segments.filter { $0.speaker == speaker && !$0.text.isEmpty }
        var recent = spoken.filter { $0.end >= now - window }
        if recent.isEmpty, let last = spoken.last { recent = [last] }
        guard let first = recent.first else {
            return speaker == .me ? "You haven't said anything yet." : "Nobody else has said anything yet."
        }
        let who = speaker == .me ? "You said" : "They said"
        let quote = recent.map(\.text).joined(separator: " ")
        return "\(who) (from \(first.start.clockString)): “\(quote)”"
    }

    private static func matches(_ q: String, _ patterns: [String]) -> Bool {
        patterns.contains { q.range(of: $0, options: .regularExpression) != nil }
    }
}

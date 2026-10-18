import Core
import Foundation
import Testing

@testable import Intelligence

@Suite struct AnthropicDecoderTests {
    @Test func textCitationsSearchAndStop() throws {
        let lines = [
            #"{"type":"message_start","message":{"id":"msg_1"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","url":"https://example.com","title":"Example"}]}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://example.com"}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
        ]
        let deltas = try lines.flatMap(AnthropicStreamDecoder.decode)
        #expect(
            deltas == [
                .activity("Searching the web…"),
                .sources([WebSource(title: "Example", url: URL(string: "https://example.com")!)]),
                .text("Hello"),
                .done(stopReason: "end_turn"),
            ])
    }

    @Test func searchErrorContentIsIgnored() throws {
        let line = #"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}}}"#
        #expect(try AnthropicStreamDecoder.decode(line) == [])
    }

    @Test func errorEventThrows() {
        let error = #expect(throws: LLMError.self) {
            try AnthropicStreamDecoder.decode(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
        #expect(error?.localizedDescription == "Overloaded")
    }

    @Test func requestIncludesWebSearchTool() throws {
        let provider = AnthropicProvider(config: ProviderConfig(apiKey: "k"))
        let request = try provider.urlRequest(LLMRequest(system: "s", messages: [.init(role: .user, content: "q")], tools: [.webSearch(maxUses: 2)]))
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let tools = body["tools"] as! [[String: Any]]
        #expect(tools.first?["name"] as? String == "web_search")
        #expect(body["model"] as? String == AnthropicProvider.defaultModel)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
    }
}

@Suite struct OpenAIDecoderTests {
    @Test func decodesChunks() throws {
        #expect(try OpenAIStreamDecoder.decode(#"{"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#) == [.text("Hi")])
        #expect(try OpenAIStreamDecoder.decode(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == [.done(stopReason: "stop")])
        #expect(try OpenAIStreamDecoder.decode("[DONE]") == [])
    }

    @Test func midStreamErrorThrowsAPIMessage() {
        // OpenRouter and others send `{"error": …}` with no `choices` once the stream has started.
        let error = #expect(throws: LLMError.self) {
            try OpenAIStreamDecoder.decode(#"{"error":{"message":"Rate limited","code":429}}"#)
        }
        #expect(error?.localizedDescription == "Rate limited")
    }

    @Test func systemPromptBecomesFirstMessage() throws {
        let provider = OpenAICompatibleProvider(config: ProviderConfig(model: "llama3", baseURL: URL(string: "http://localhost:11434/v1")))
        let request = try provider.urlRequest(LLMRequest(system: "sys", messages: [.init(role: .user, content: "q")]))
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        #expect(messages.map { $0["role"]! } == ["system", "user"])
    }
}

@Suite struct QATests {
    let transcript = Transcript(segments: [
        TranscriptSegment(speaker: .them, text: "Old news.", start: 0, end: 5, isFinal: true),
        TranscriptSegment(speaker: .me, text: "I agree.", start: 50, end: 52, isFinal: true),
        TranscriptSegment(speaker: .them, text: "Ship on Monday.", start: 55, end: 58, isFinal: true),
        TranscriptSegment(speaker: .them, text: "With analytics.", start: 58, end: 60, isFinal: false),
    ])

    @Test func justSaidIsAnsweredLocally() {
        let answer = RecentSpeechAnswerer.answer("What did they just say?", transcript: transcript, now: 61, window: 30)
        #expect(answer == "They said (from 0:55): “Ship on Monday. With analytics.”")
        #expect(RecentSpeechAnswerer.answer("what did I just say", transcript: transcript, now: 61, window: 30)?.contains("I agree.") == true)
    }

    @Test func otherQuestionsGoToLLM() {
        #expect(RecentSpeechAnswerer.answer("What's the capital of France?", transcript: transcript, now: 61, window: 30) == nil)
    }

    @Test func fallsBackToLastUtteranceWhenWindowEmpty() {
        let answer = RecentSpeechAnswerer.answer("repeat that", transcript: transcript, now: 600, window: 30)
        #expect(answer?.contains("With analytics.") == true)
    }

    @Test func llmGetsTranscriptAndWebSearchTool() async throws {
        let llm = RecordingLLM()
        let engine = QAEngine(llm: llm)
        var text = ""
        for try await case .text(let t) in engine.answer("Who owns legal?", transcript: transcript, now: 61) { text += t }
        #expect(text == "ok")
        let request = try #require(await llm.last)
        #expect(request.tools == [.webSearch(maxUses: 3)])
        #expect(request.system?.contains("[0:55] Them: Ship on Monday.") == true)
    }

    @Test func configuredSearchToolWinsOverHostedSearch() async throws {
        let llm = RecordingLLM()
        let engine = QAEngine(llm: llm, webSearch: FakeSearch())
        var sources: [WebSource] = []
        for try await case .sources(let s) in engine.answer("What's their pricing?", transcript: transcript, now: 61) { sources += s }
        let request = try #require(await llm.last)
        #expect(request.tools.isEmpty)
        #expect(request.messages.last?.content.contains("[1] Pricing — https://example.com/pricing\n$10/seat") == true)
        #expect(sources == [WebSource(title: "Pricing", url: URL(string: "https://example.com/pricing")!)])
    }

    @Test func rollingContextTrimsToWholeLines() async {
        let context = await RollingTranscriptContext(maxCharacters: 40).context(for: "", transcript: transcript)
        #expect(context.hasPrefix("[…earlier transcript omitted…]\n["))
        #expect(context.hasSuffix("With analytics."))
    }
}

@Suite struct SummaryTests {
    @Test func parsesJSONWrappedInProse() {
        let text = """
            Here you go:
            ```json
            {"overview":"Shipped.","decisions":["Ship Monday"],"actionItems":[{"task":"Email legal","owner":"Me","due":null}],"openQuestions":[],"flagged":["Budget"]}
            ```
            """
        let s = SummaryParser.parse(text, meetingID: UUID(), templateID: "general")
        #expect(s.overview == "Shipped.")
        #expect(s.actionItems == [ActionItem(task: "Email legal", owner: "Me")])
        #expect(s.flagged == ["Budget"])
    }

    @Test func fallsBackToRawText() {
        #expect(SummaryParser.parse("Just prose.", meetingID: UUID(), templateID: "general").overview == "Just prose.")
    }

    @Test func notesComeFirstAndFlagged() {
        let meeting = Meeting(title: "Sync")
        let input = Prompts.summaryInput(
            meeting: meeting, transcript: Transcript(),
            notes: [Note(meetingID: meeting.id, text: "budget?", timestamp: 65, flagged: true)])
        #expect(input.contains("★ [1:05] budget?"))
        #expect(input.range(of: "<my_notes")!.lowerBound < input.range(of: "<transcript>")!.lowerBound)
    }
}

private struct FakeSearch: WebSearchTool {
    let id = "fake"
    func search(_ query: String, maxResults: Int) async throws -> [WebSearchResult] {
        [WebSearchResult(title: "Pricing", url: URL(string: "https://example.com/pricing")!, snippet: "$10/seat")]
    }
}

@Suite struct ParallelSearchTests {
    @Test func buildsFastSearchRequest() throws {
        let request = try ParallelSearchTool(config: ProviderConfig(apiKey: "pk")).urlRequest("acme pricing", maxResults: 5)
        #expect(request.url?.absoluteString == "https://api.parallel.ai/v1/search")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "pk")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["search_queries"] as? [String] == ["acme pricing"])
        #expect(body["objective"] as? String == "acme pricing")
        #expect(body["mode"] as? String == "fast")
        #expect((body["advanced_settings"] as? [String: Any])?["max_results"] as? Int == 5)
    }

    @Test func decodesResultsJoiningExcerpts() throws {
        let json = #"{"search_id":"s1","results":[{"url":"https://a.com","title":"A","publish_date":null,"excerpts":["one","two"]},{"url":"https://b.com","title":null,"excerpts":[]}],"warnings":null,"usage":[]}"#
        let results = try ParallelSearchTool.decode(Data(json.utf8), status: 200)
        #expect(results.map(\.snippet) == ["one\ntwo", ""])
        #expect(results.map(\.title) == ["A", "https://b.com"])
    }

    @Test func surfacesAPIErrorMessage() {
        let json = #"{"type":"error","error":{"ref_id":"r1","message":"Invalid API key"}}"#
        let error = #expect(throws: LLMError.self) { try ParallelSearchTool.decode(Data(json.utf8), status: 401) }
        #expect(error?.localizedDescription == "HTTP 401: Invalid API key")
    }
}

private actor RecordingLLM: LLMProvider {
    nonisolated let id = "recording"
    nonisolated let capabilities = LLMCapabilities(serverWebSearch: true)
    var last: LLMRequest?

    nonisolated func complete(_ req: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(req)
                continuation.yield(.text("ok"))
                continuation.finish()
            }
        }
    }

    private func record(_ req: LLMRequest) { last = req }
}

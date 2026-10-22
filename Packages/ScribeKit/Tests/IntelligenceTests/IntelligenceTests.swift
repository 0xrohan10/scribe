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
        var decoder = AnthropicStreamDecoder()
        let deltas = try lines.flatMap { try decoder.decode($0) }
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
        var decoder = AnthropicStreamDecoder()
        #expect(try decoder.decode(line) == [])
    }

    @Test func errorEventThrows() {
        var decoder = AnthropicStreamDecoder()
        let error = #expect(throws: LLMError.self) {
            try decoder.decode(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
        #expect(error?.localizedDescription == "Overloaded")
    }

    @Test func toolUseArrivesWholeWhenItsBlockStops() throws {
        let lines = [
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Fixing."}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"correct_transcript","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"heard\": \"Ro"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"wan\", \"correct\": \"Rohan\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]
        var decoder = AnthropicStreamDecoder()
        let deltas = try lines.flatMap { try decoder.decode($0) }
        #expect(
            deltas == [
                .text("Fixing."),
                .toolCall(LLMToolCall(name: "correct_transcript", arguments: ["heard": "Rowan", "correct": "Rohan"])),
                .done(stopReason: "tool_use"),
            ])
    }

    @Test func requestIncludesFunctionTool() throws {
        let provider = AnthropicProvider(config: ProviderConfig(apiKey: "k"))
        let tool = LLMTool.function(name: "f", description: "d", parameters: [LLMToolParameter("a", description: "A")])
        let request = try provider.urlRequest(LLMRequest(messages: [.init(role: .user, content: "q")], tools: [tool]))
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let sent = try #require((body["tools"] as? [[String: Any]])?.first)
        #expect(sent["name"] as? String == "f")
        let schema = try #require(sent["input_schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["a"])
        #expect((schema["properties"] as? [String: [String: String]])?["a"] == ["type": "string", "description": "A"])
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
        var decoder = OpenAIStreamDecoder()
        #expect(try decoder.decode(#"{"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#) == [.text("Hi")])
        #expect(try decoder.decode(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == [.done(stopReason: "stop")])
        #expect(try decoder.decode("[DONE]") == [])
    }

    @Test func midStreamErrorThrowsAPIMessage() {
        // OpenRouter and others send `{"error": …}` with no `choices` once the stream has started.
        var decoder = OpenAIStreamDecoder()
        let error = #expect(throws: LLMError.self) {
            try decoder.decode(#"{"error":{"message":"Rate limited","code":429}}"#)
        }
        #expect(error?.localizedDescription == "Rate limited")
    }

    @Test func toolCallFragmentsArriveWholeBeforeDone() throws {
        var decoder = OpenAIStreamDecoder()
        let lines = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"correct_transcript","arguments":""}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"heard\":\"Rowan\","}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"correct\":\"Rohan\"}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]
        let deltas = try lines.flatMap { try decoder.decode($0) }
        #expect(
            deltas == [
                .toolCall(LLMToolCall(name: "correct_transcript", arguments: ["heard": "Rowan", "correct": "Rohan"])),
                .done(stopReason: "tool_calls"),
            ])
    }

    @Test func requestSendsOnlyFunctionTools() throws {
        let provider = OpenAICompatibleProvider(config: ProviderConfig(model: "gpt-6-luna"))
        let tools: [LLMTool] = [.webSearch(maxUses: 3), .function(name: "f", description: "d", parameters: [])]
        let request = try provider.urlRequest(LLMRequest(messages: [.init(role: .user, content: "q")], tools: tools))
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let sent = try #require(body["tools"] as? [[String: Any]])
        #expect(sent.count == 1)
        #expect((sent.first?["function"] as? [String: Any])?["name"] as? String == "f")
    }

    @Test func systemPromptBecomesFirstMessage() throws {
        let provider = OpenAICompatibleProvider(config: ProviderConfig(model: "llama3", baseURL: URL(string: "http://localhost:11434/v1")))
        let request = try provider.urlRequest(LLMRequest(system: "sys", messages: [.init(role: .user, content: "q")]))
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        #expect(messages.map { $0["role"]! } == ["system", "user"])
        #expect(body["max_tokens"] as? Int == 2048)
        #expect(body["max_completion_tokens"] == nil)
    }

    @Test func openAIUsesMaxCompletionTokens() throws {
        let provider = OpenAICompatibleProvider(config: ProviderConfig(model: "gpt-6-luna"))
        let request = try provider.urlRequest(LLMRequest(system: nil, messages: [.init(role: .user, content: "q")]))
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["max_completion_tokens"] as? Int == 2048)
        #expect(body["max_tokens"] == nil)
    }

    @Test func modelListKeepsChatModelsNewestFirst() throws {
        let json = #"{"data":[{"id":"gpt-4.1","created":1},{"id":"text-embedding-3-large","created":3},{"id":"gpt-6-luna","created":5},{"id":"o3","created":2},{"id":"gpt-4o-realtime-preview","created":4},{"id":"dall-e-3","created":6}]}"#
        #expect(try OpenAIModelList.ids(from: Data(json.utf8), chatOnly: true) == ["gpt-6-luna", "o3", "gpt-4.1"])
        #expect(try OpenAIModelList.ids(from: Data(json.utf8), chatOnly: false).count == 6)
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

    @Test(arguments: [(GateAnswer.no, false), (.yes, true), (.fails, true)])
    func gateDecidesWhetherToSearch(gate: GateAnswer, searched: Bool) async throws {
        let llm = RecordingLLM()
        let engine = QAEngine(llm: llm, webSearch: FakeSearch(), searchGate: FakeGate(answer: gate))
        for try await _ in engine.answer("What did we decide on pricing?", transcript: transcript, now: 61) {}
        let request = try #require(await llm.last)
        #expect(request.messages.last?.content.contains("<web_results>") == searched)
        // Declining the configured search doesn't fall back to the provider's hosted search.
        #expect(request.tools.isEmpty)
    }

    @Test func correctionToolIsOfferedOnlyWithACorrector() async throws {
        let llm = RecordingLLM()
        for try await _ in QAEngine(llm: llm).answer("q", transcript: transcript, now: 61) {}
        #expect(await llm.last?.tools == [.webSearch(maxUses: 3)])
        for try await _ in QAEngine(llm: llm).answer("q", transcript: transcript, now: 61, correct: { _, _ in "" }) {}
        #expect(await llm.last?.tools == [.webSearch(maxUses: 3), QAEngine.correctionTool])
    }

    @Test func toolCallRunsTheCorrectorAndReportsBack() async throws {
        let call = LLMToolCall(name: "correct_transcript", arguments: ["heard": "Rowan", "correct": "Rohan"])
        let engine = QAEngine(llm: ScriptedLLM(deltas: [.text("On it."), .toolCall(call), .done(stopReason: "tool_use")]))
        let fixes = Fixes()
        var text = ""
        for try await case .text(let t) in engine.answer("It's Rohan, not Rowan", transcript: transcript, now: 61, correct: { heard, right in
            await fixes.add("\(heard)→\(right)")
            return "Fixed."
        }) { text += t }
        #expect(text == "On it.\n\nFixed.")
        #expect(await fixes.all == ["Rowan→Rohan"])
    }

    @Test func failedCorrectionIsReportedNotThrown() async throws {
        let call = LLMToolCall(name: "correct_transcript", arguments: ["heard": "Rowan", "correct": "Rowan"])
        let engine = QAEngine(llm: ScriptedLLM(deltas: [.toolCall(call)]))
        var text = ""
        for try await case .text(let t) in engine.answer("q", transcript: transcript, now: 61, correct: { _, right in
            throw VocabularyError.unchanged(right)
        }) { text += t }
        #expect(text == "Couldn't fix “Rowan”: “Rowan” is already spelled that way.")
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

    @Test func parsesUncertainTermsDroppingNonSuggestions() {
        let text = #"{"overview":"o","uncertainTerms":[{"heard":"Rowan","suggestion":"Rohan"},{"heard":"Scribe","suggestion":"Scribe"}]}"#
        let s = SummaryParser.parse(text, meetingID: UUID(), templateID: "general")
        #expect(s.uncertainTerms == [UncertainTerm(heard: "Rowan", suggestion: "Rohan")])
        #expect(Prompts.summarySystem(template: .general).contains(#""uncertainTerms": [{"heard""#))
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

    @Test func vocabularyOnlyAppearsWhenSet() {
        #expect(!Prompts.summarySystem(template: .general).contains("<vocabulary>"))
        #expect(!Prompts.qaSystem(transcript: "", now: 0).contains("<vocabulary>"))
        #expect(Prompts.summarySystem(template: .general, vocabulary: ["Rohan", "Scribe"]).contains("<vocabulary>\nRohan\nScribe\n</vocabulary>"))
        #expect(Prompts.qaSystem(transcript: "", now: 0, vocabulary: ["Rohan"]).contains("<vocabulary>\nRohan\n</vocabulary>"))
    }
}

private struct FakeSearch: WebSearchTool {
    let id = "fake"
    func search(_ query: String, maxResults: Int) async throws -> [WebSearchResult] {
        [WebSearchResult(title: "Pricing", url: URL(string: "https://example.com/pricing")!, snippet: "$10/seat")]
    }
}

enum GateAnswer: Sendable { case yes, no, fails }

private struct FakeGate: SearchGate {
    let answer: GateAnswer
    func shouldSearch(question: String, transcript: Transcript) async throws -> Bool {
        switch answer {
        case .yes: true
        case .no: false
        case .fails: throw LLMError.api("down")
        }
    }
}

@Suite struct JevSearchGateTests {
    @Test func buildsNoulRequestWithQuestionAndTranscript() async throws {
        let gate = JevSearchGate(config: ProviderConfig(apiKey: "tk"))
        let transcript = Transcript(segments: [TranscriptSegment(speaker: .them, text: "We use Acme.", start: 3, end: 4, isFinal: true)])
        let request = try await gate.urlRequest(question: "What does Acme cost?", transcript: transcript)
        #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tk")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "jev-latest")
        let state = body["state"] as! [String: String]
        #expect(state == ["question": "What does Acme cost?", "transcript": "[0:03] Them: We use Acme."])
        let question = (body["questions"] as! [String: [String: Any]])["needs_web"]!
        #expect(question["type"] as? String == "noul")
    }

    @Test func decodesProbabilityAndErrors() throws {
        let ok = #"{"model":"jev-1.13.0","answers":{"needs_web":{"type":"noul","noul":0.82}},"usage":{"input_tokens":300,"output_tokens":20}}"#
        #expect(try JevSearchGate.decodeProbability(Data(ok.utf8), status: 200) == 0.82)
        #expect(throws: LLMError.self) { try JevSearchGate.decodeProbability(Data(#"{"error":"bad key"}"#.utf8), status: 401) }
        #expect(throws: LLMError.self) { try JevSearchGate.decodeProbability(Data(#"{"answers":{}}"#.utf8), status: 200) }
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

private struct ScriptedLLM: LLMProvider {
    let id = "scripted"
    let capabilities = LLMCapabilities()
    let deltas: [LLMDelta]

    func complete(_ req: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            deltas.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private actor Fixes {
    var all: [String] = []
    func add(_ fix: String) { all.append(fix) }
}

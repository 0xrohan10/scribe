import Core
import Foundation
import Testing
import Intelligence

private actor LibrarySearchSpy: MeetingSearchRepository {
    let results: [MeetingEvidence]
    var query = ""
    var limit = 0
    let fails: Bool
    let gate: AsyncStream<Void>?

    init(_ results: [MeetingEvidence], fails: Bool = false, gate: AsyncStream<Void>? = nil) {
        self.results = results
        self.fails = fails
        self.gate = gate
    }
    func search(_ query: String, limit: Int) async throws -> [MeetingEvidence] {
        self.query = query
        self.limit = limit
        if fails { throw CocoaError(.fileReadUnknown) }
        if let gate { for await _ in gate {} }
        return results
    }
}

private actor LibraryRequestSpy {
    var requests: [LLMRequest] = []
    func record(_ request: LLMRequest) { requests.append(request) }
}

private struct LibraryTestLLM: LLMProvider {
    let id = "library-test"
    let capabilities = LLMCapabilities(serverWebSearch: true)
    let spy: LibraryRequestSpy
    var deltas: [LLMDelta] = [.text("Annual billing was approved [1]."), .done(stopReason: "end_turn")]

    func complete(_ req: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { out in
            let task = Task {
                await spy.record(req)
                for delta in deltas { out.yield(delta) }
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite struct MeetingLibraryQATests {
    private func evidence(_ index: Int = 0, text: String = "Use annual billing.") -> MeetingEvidence {
        MeetingEvidence(id: "saved-\(index)", meeting: Meeting(title: "Billing review", startedAt: Date(timeIntervalSince1970: 100)),
                        kind: .decision, text: text)
    }

    @Test func answersFromVerifiedSourcesWithoutWebOrEditingTools() async throws {
        let source = evidence(), search = LibrarySearchSpy([source]), requests = LibraryRequestSpy()
        let forged = WebSource(title: "Not a saved source", url: URL(string: "https://example.com")!)
        let llm = LibraryTestLLM(spy: requests, deltas: [.sources([forged]), .toolCall(.init(name: "correct_transcript", arguments: [:])), .text("Approved [1].")])
        let engine = MeetingLibraryQA(llm: llm, search: search, vocabulary: ["Scribe"])
        var quotes: [MeetingEvidence] = [], text = ""
        for try await event in engine.answer("What did we decide about billing?") {
            switch event {
            case .sources(let sources): quotes = sources
            case .text(let delta): text += delta
            case .activity: break
            }
        }
        #expect(quotes == [source])
        #expect(text == "Approved [1].")
        let request = try #require(await requests.requests.first)
        #expect(request.tools.isEmpty)
        #expect(request.system?.contains("Use annual billing.") == true)
        #expect(request.system?.contains("Billing review") == true)
        #expect(request.system?.contains("untrusted data") == true)
        #expect(request.system?.contains("Scribe") == true)
        #expect(await search.limit == 12)
    }

    @Test func noMatchesDoNotCallTheAI() async throws {
        let requests = LibraryRequestSpy()
        let engine = MeetingLibraryQA(llm: LibraryTestLLM(spy: requests), search: LibrarySearchSpy([]))
        var text = ""
        for try await event in engine.answer("billing") { if case .text(let delta) = event { text += delta } }
        #expect(text.contains("couldn't find matching saved meeting text"))
        #expect(await requests.requests.isEmpty)
    }

    @Test func followUpsSearchThePreviousTopicAndKeepHistory() async throws {
        let search = LibrarySearchSpy([evidence()]), requests = LibraryRequestSpy()
        let history: [LLMMessage] = [.init(role: .user, content: "What did we decide about billing?"), .init(role: .assistant, content: "Annual billing [1].")]
        let engine = MeetingLibraryQA(llm: LibraryTestLLM(spy: requests), search: search)
        for try await _ in engine.answer("Who owns it?", history: history) {}
        #expect(await search.query.contains("billing"))
        let request = try #require(await requests.requests.first)
        #expect(request.messages == history + [.init(role: .user, content: "Who owns it?")])
    }

    @Test func boundsSourceCountAndQuoteLength() async throws {
        let sources = (0..<30).map { evidence($0, text: String(repeating: "x", count: 5000)) }
        let requests = LibraryRequestSpy()
        let engine = MeetingLibraryQA(llm: LibraryTestLLM(spy: requests), search: LibrarySearchSpy(sources))
        for try await event in engine.answer("billing") {
            if case .sources(let sources) = event {
                #expect(sources.count == 12)
                #expect(sources.allSatisfy { $0.text.count == 1200 })
            }
        }
    }

    @Test func retrievalErrorsAndEmptyCompletionsAreNotSuccessfulAnswers() async throws {
        let requests = LibraryRequestSpy()
        let failedSearch = MeetingLibraryQA(llm: LibraryTestLLM(spy: requests), search: LibrarySearchSpy([], fails: true))
        await #expect(throws: CocoaError.self) { for try await _ in failedSearch.answer("billing") {} }
        #expect(await requests.requests.isEmpty)
        let noAnswer = MeetingLibraryQA(llm: LibraryTestLLM(spy: requests, deltas: [.done(stopReason: "end_turn")]), search: LibrarySearchSpy([evidence()]))
        await #expect(throws: LLMError.self) { for try await _ in noAnswer.answer("billing") {} }
    }

    @Test func inventedCitationNumbersAreReportedAsErrors() async throws {
        let engine = MeetingLibraryQA(llm: LibraryTestLLM(spy: LibraryRequestSpy(), deltas: [.text("Approved [99].")]),
                                      search: LibrarySearchSpy([evidence()]))
        await #expect(throws: LLMError.self) { for try await _ in engine.answer("billing") {} }
    }

    @Test func cancellationDuringRetrievalDoesNotStartAnAIRequest() async throws {
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        let search = LibrarySearchSpy([evidence()], gate: gate), requests = LibraryRequestSpy()
        let engine = MeetingLibraryQA(llm: LibraryTestLLM(spy: requests), search: search)
        let task = Task { for try await _ in engine.answer("billing") {} }
        while await search.query.isEmpty { await Task.yield() }
        task.cancel()
        _ = try? await task.value
        release.finish()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await requests.requests.isEmpty)
    }

    @Test func aNewTopicDoesNotRetrieveThePreviousTopicsSources() async throws {
        let search = LibrarySearchSpy([]), requests = LibraryRequestSpy()
        let engine = MeetingLibraryQA(llm: LibraryTestLLM(spy: requests), search: search)
        let history: [LLMMessage] = [.init(role: .user, content: "What did we decide about billing?")]
        for try await _ in engine.answer("Who owns onboarding?", history: history) {}
        #expect(await search.query == "Who owns onboarding?")
        #expect(await requests.requests.isEmpty)
    }
}

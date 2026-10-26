import Core
import Intelligence
import Testing

private struct TitleTestLLM: LLMProvider {
    let id = "title-test"
    let capabilities = LLMCapabilities()
    let response: String

    func complete(_ request: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(response))
            continuation.finish()
        }
    }
}

struct LLMTitleGeneratorTests {
    @Test func trimsWhitespaceAndQuotes() async throws {
        let generator = LLMTitleGenerator(llm: TitleTestLLM(response: " \n“Billing migration planning”\n"))
        let title = try await generator.title(meeting: Meeting(title: "Meeting"), transcript: Transcript())
        #expect(title == "Billing migration planning")
    }

    @Test(arguments: [" \n", "First title\nAnother title", String(repeating: "x", count: 121)])
    func rejectsInvalidTitles(_ response: String) async {
        let generator = LLMTitleGenerator(llm: TitleTestLLM(response: response))
        await #expect(throws: (any Error).self) {
            try await generator.title(meeting: Meeting(title: "Meeting"), transcript: Transcript())
        }
    }
}

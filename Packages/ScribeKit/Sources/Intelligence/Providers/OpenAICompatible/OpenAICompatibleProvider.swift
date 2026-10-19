import Core
import Foundation

/// Any `/chat/completions` endpoint: OpenAI, Ollama (`http://localhost:11434/v1`), LM Studio, vLLM, OpenRouter…
/// No hosted web search; `QAEngine` falls back to a `WebSearchTool` if one is configured.
public struct OpenAICompatibleProvider: LLMProvider {
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    public let id = "openai-compatible"
    public let capabilities = LLMCapabilities(serverWebSearch: false)
    let apiKey: String?
    let model: String
    let baseURL: URL
    let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.apiKey = config.apiKey
        self.model = config.model ?? "gpt-4.1"
        self.baseURL = config.baseURL ?? Self.defaultBaseURL
        self.session = session
    }

    public func complete(_ req: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error> {
        do {
            return ServerSentEvents.deltas(for: try urlRequest(req), session: session, decode: OpenAIStreamDecoder.decode)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func availableModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return try OpenAIModelList.ids(from: await session.checkedData(for: request), chatOnly: isOpenAI)
    }

    /// OpenAI itself, as opposed to a compatible server.
    var isOpenAI: Bool { baseURL.host() == Self.defaultBaseURL.host() }

    func urlRequest(_ req: LLMRequest) throws -> URLRequest {
        var messages: [[String: String]] = []
        if let system = req.system { messages.append(["role": "system", "content": system]) }
        messages += req.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        // OpenAI deprecated `max_tokens` and rejects it for reasoning models; many compatible servers only know `max_tokens`.
        let maxTokensKey = isOpenAI ? "max_completion_tokens" : "max_tokens"
        var body: [String: Any] = [
            "model": req.params.model ?? model,
            maxTokensKey: req.params.maxTokens,
            "stream": true,
            "messages": messages,
        ]
        if let temperature = req.params.temperature { body["temperature"] = temperature }

        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum OpenAIModelList {
    private struct Response: Decodable {
        var data: [Model]
        struct Model: Decodable {
            var id: String
            var created: Int?
        }
    }

    /// OpenAI's `/models` also lists embedding, audio, image and moderation models; `chatOnly` keeps the GPT and o-series chat models.
    static func ids(from data: Data, chatOnly: Bool) throws -> [String] {
        let models = try JSONDecoder().decode(Response.self, from: data).data
        return models
            .filter { !chatOnly || isChatModel($0.id) }
            .sorted { ($0.created ?? 0, $1.id) > ($1.created ?? 0, $0.id) }
            .map(\.id)
    }

    private static func isChatModel(_ id: String) -> Bool {
        let isFamily = id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-") || id.wholeMatch(of: /o\d.*/) != nil
        let excluded = ["audio", "realtime", "tts", "transcribe", "image", "search", "instruct", "embedding", "moderation"]
        return isFamily && !excluded.contains { id.contains($0) }
    }
}

enum OpenAIStreamDecoder {
    private struct Chunk: Decodable {
        /// Absent on error chunks.
        var choices: [Choice]?
        var error: APIError?

        struct Choice: Decodable {
            var delta: Delta?
            var finishReason: String?
        }

        struct Delta: Decodable {
            var content: String?
        }

        struct APIError: Decodable {
            var message: String
        }
    }

    static func decode(_ data: String) throws -> [LLMDelta] {
        if data == "[DONE]" { return [] }
        let chunk = try ServerSentEvents.snakeCaseDecoder.decode(Chunk.self, from: Data(data.utf8))
        if let error = chunk.error { throw LLMError.api(error.message) }
        guard let choice = chunk.choices?.first else { return [] }
        var deltas: [LLMDelta] = []
        if let text = choice.delta?.content, !text.isEmpty { deltas.append(.text(text)) }
        if let reason = choice.finishReason { deltas.append(.done(stopReason: reason)) }
        return deltas
    }
}

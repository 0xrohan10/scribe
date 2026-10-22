import Core
import Foundation

/// Claude via the Messages API, streamed, with the server-side web search tool.
public struct AnthropicProvider: LLMProvider {
    public static let defaultModel = "claude-sonnet-5-5"
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    public let id = "anthropic"
    public let capabilities = LLMCapabilities(serverWebSearch: true)
    let apiKey: String
    let model: String
    let baseURL: URL
    let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.apiKey = config.apiKey ?? ""
        self.model = config.model ?? Self.defaultModel
        self.baseURL = config.baseURL ?? Self.defaultBaseURL
        self.session = session
    }

    public func complete(_ req: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error> {
        do {
            return ServerSentEvents.deltas(for: try urlRequest(req), session: session, decoder: AnthropicStreamDecoder.self)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func availableModels() async throws -> [String] {
        struct Response: Decodable {
            var data: [Model]
            struct Model: Decodable { var id: String }
        }
        var request = URLRequest(url: baseURL.appending(path: "v1/models").appending(queryItems: [.init(name: "limit", value: "100")]))
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Already newest first.
        return try JSONDecoder().decode(Response.self, from: await session.checkedData(for: request)).data.map(\.id)
    }

    func urlRequest(_ req: LLMRequest) throws -> URLRequest {
        var body: [String: Any] = [
            "model": req.params.model ?? model,
            "max_tokens": req.params.maxTokens,
            "stream": true,
            "messages": req.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if let system = req.system { body["system"] = system }
        if let temperature = req.params.temperature { body["temperature"] = temperature }
        let tools: [[String: Any]] = req.tools.map { tool in
            switch tool {
            case .webSearch(let maxUses): ["type": "web_search_20250305", "name": "web_search", "max_uses": maxUses]
            case .function(let name, let description, let parameters):
                ["name": name, "description": description, "input_schema": parameters.jsonSchema]
            }
        }
        if !tools.isEmpty { body["tools"] = tools }

        var request = URLRequest(url: baseURL.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

struct AnthropicStreamDecoder: StreamDecoder {
    /// `tool_use` blocks whose arguments are still streaming, by content block index.
    private var toolUses: [Int: (name: String, json: String)] = [:]

    private struct Event: Decodable {
        var type: String
        var index: Int?
        var delta: Delta?
        var contentBlock: Block?
        var error: APIError?

        struct Delta: Decodable {
            var type: String?
            var text: String?
            var partialJson: String?
            var stopReason: String?
        }

        struct Block: Decodable {
            var type: String
            var name: String?
            var content: [SearchResult]?

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try c.decode(String.self, forKey: .type)
                name = try c.decodeIfPresent(String.self, forKey: .name)
                // `content` is an array of results, or an error object when the search failed.
                content = try? c.decode([SearchResult].self, forKey: .content)
            }

            enum CodingKeys: String, CodingKey { case type, name, content }
        }

        struct SearchResult: Decodable {
            var url: String
            var title: String?
        }

        struct APIError: Decodable {
            var message: String
        }
    }

    init() {}

    mutating func decode(_ data: String) throws -> [LLMDelta] {
        let event = try ServerSentEvents.snakeCaseDecoder.decode(Event.self, from: Data(data.utf8))
        switch event.type {
        case "content_block_delta" where event.delta?.type == "text_delta":
            return event.delta?.text.map { [.text($0)] } ?? []
        case "content_block_delta" where event.delta?.type == "input_json_delta":
            if let index = event.index, let json = event.delta?.partialJson { toolUses[index]?.json += json }
            return []
        case "content_block_stop":
            guard let index = event.index, let toolUse = toolUses.removeValue(forKey: index) else { return [] }
            return [.toolCall(LLMToolCall(name: toolUse.name, json: toolUse.json))]
        case "content_block_start":
            switch event.contentBlock?.type {
            case "tool_use":
                if let index = event.index, let name = event.contentBlock?.name { toolUses[index] = (name, "") }
                return []
            case "server_tool_use":
                return [.activity("Searching the web…")]
            case "web_search_tool_result":
                let sources = (event.contentBlock?.content ?? []).compactMap { r in
                    URL(string: r.url).map { WebSource(title: r.title ?? r.url, url: $0) }
                }
                return sources.isEmpty ? [] : [.sources(sources)]
            default:
                return []
            }
        case "message_delta":
            return event.delta?.stopReason.map { [.done(stopReason: $0)] } ?? []
        case "error":
            throw LLMError.api(event.error?.message ?? "Unknown Anthropic error")
        default:
            return []
        }
    }
}

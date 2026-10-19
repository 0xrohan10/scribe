import Foundation

public struct LLMMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public enum LLMTool: Sendable, Hashable {
    /// Provider-hosted web search (e.g. Anthropic's server tool). Only sent to providers that advertise it.
    case webSearch(maxUses: Int)
}

public struct ModelParams: Sendable, Hashable {
    /// Overrides the provider's configured model.
    public var model: String?
    public var maxTokens: Int
    public var temperature: Double?

    public init(model: String? = nil, maxTokens: Int = 2048, temperature: Double? = nil) {
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public struct LLMRequest: Sendable, Hashable {
    public var system: String?
    public var messages: [LLMMessage]
    public var tools: [LLMTool]
    public var params: ModelParams

    public init(system: String? = nil, messages: [LLMMessage], tools: [LLMTool] = [], params: ModelParams = .init()) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.params = params
    }
}

public struct WebSource: Sendable, Hashable, Codable {
    public var title: String
    public var url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

public enum LLMDelta: Sendable, Hashable {
    case text(String)
    /// Human-readable progress such as "Searching the web…".
    case activity(String)
    case sources([WebSource])
    case done(stopReason: String?)
}

public struct LLMCapabilities: Sendable, Hashable {
    public var serverWebSearch: Bool

    public init(serverWebSearch: Bool = false) {
        self.serverWebSearch = serverWebSearch
    }
}

public protocol LLMProvider: Sendable {
    var id: String { get }
    var capabilities: LLMCapabilities { get }
    func complete(_ req: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error>
    /// Model ids this provider can use right now, newest first. Empty when the provider can't list them.
    func availableModels() async throws -> [String]
}

extension LLMProvider {
    public func availableModels() async throws -> [String] { [] }

    /// Collects a streamed completion into a single string.
    public func completeText(_ req: LLMRequest) async throws -> String {
        var out = ""
        for try await delta in complete(req) {
            if case .text(let t) = delta { out += t }
        }
        return out
    }
}

public struct WebSearchResult: Sendable, Hashable {
    public var title: String
    public var url: URL
    public var snippet: String

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Client-side web search, so search isn't tied to an LLM vendor that hosts it.
public protocol WebSearchTool: Sendable {
    var id: String { get }
    func search(_ query: String, maxResults: Int) async throws -> [WebSearchResult]
}

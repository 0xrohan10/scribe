import Core
import Foundation

/// Parallel's Search API (`POST /v1/search`). Uses `fast` mode (≈1 s) since answers are needed mid-meeting.
public struct ParallelSearchTool: WebSearchTool {
    public static let defaultBaseURL = URL(string: "https://api.parallel.ai")!

    public let id = "parallel"
    let apiKey: String
    let baseURL: URL
    let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.apiKey = config.apiKey ?? ""
        self.baseURL = config.baseURL ?? Self.defaultBaseURL
        self.session = session
    }

    public func search(_ query: String, maxResults: Int) async throws -> [WebSearchResult] {
        let (data, response) = try await session.data(for: try urlRequest(query, maxResults: maxResults))
        return try Self.decode(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func urlRequest(_ query: String, maxResults: Int) throws -> URLRequest {
        let body: [String: Any] = [
            "objective": query,
            "search_queries": [query],
            "mode": "fast",
            // Keeps the prompt small: excerpts are injected into every Q&A request.
            "max_chars_total": 8_000,
            "advanced_settings": ["max_results": maxResults],
        ]
        var request = URLRequest(url: baseURL.appending(path: "v1/search"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private struct Response: Decodable {
        var results: [Result]

        struct Result: Decodable {
            var url: String
            var title: String?
            var excerpts: [String]?
        }
    }

    private struct ErrorResponse: Decodable {
        var error: Detail
        struct Detail: Decodable { var message: String }
    }

    static func decode(_ data: Data, status: Int) throws -> [WebSearchResult] {
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
            throw LLMError.http(status: status, body: message ?? String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Response.self, from: data).results.compactMap { result in
            URL(string: result.url).map { url in
                WebSearchResult(title: result.title ?? result.url, url: url, snippet: (result.excerpts ?? []).joined(separator: "\n"))
            }
        }
    }
}

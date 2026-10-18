import Core
import Foundation

/// Asks TypeSafe's Jev (one Noul) whether answering needs information from outside the meeting.
public struct JevSearchGate: SearchGate {
    public static let defaultModel = "jev-latest"
    public static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!

    let apiKey: String
    let model: String
    let baseURL: URL
    let session: URLSession
    /// Searches when P(needs web) ≥ this. Below 0.5 because a missed search costs more than an extra one.
    let threshold: Double

    public init(config: ProviderConfig, threshold: Double = 0.35, session: URLSession = .shared) {
        self.apiKey = config.apiKey ?? ""
        self.model = config.model ?? Self.defaultModel
        self.baseURL = config.baseURL ?? Self.defaultBaseURL
        self.threshold = threshold
        self.session = session
    }

    public func shouldSearch(question: String, transcript: Transcript) async throws -> Bool {
        let request = try await urlRequest(question: question, transcript: transcript)
        let (data, response) = try await session.data(for: request)
        return try Self.decodeProbability(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0) >= threshold
    }

    func urlRequest(question: String, transcript: Transcript) async throws -> URLRequest {
        // The recent stretch is what follow-up questions refer to; it also keeps the call small.
        let recent = await RollingTranscriptContext(maxCharacters: 8_000).context(for: question, transcript: transcript)
        let body: [String: Any] = [
            "model": model,
            "state": ["question": question, "transcript": recent],
            "questions": [
                "needs_web": [
                    "type": "noul",
                    "instructions":
                        "Answering `question` well requires information from the web that isn't in `transcript`, the live meeting transcript.",
                    "criteria": [
                        "true":
                            "The answer depends on facts from outside the meeting, such as a company's pricing or products, recent news, public people, technical documentation, or definitions the meeting doesn't explain.",
                        "false":
                            "The answer can come from the meeting itself: what was said, decided or asked, who said it, a summary, or a follow-up on the conversation.",
                    ],
                ]
            ],
        ]
        var request = URLRequest(url: baseURL.appending(path: "v1/systemone"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private struct Response: Decodable {
        var answers: [String: Answer]
        struct Answer: Decodable { var noul: Double? }
    }

    static func decodeProbability(_ data: Data, status: Int) throws -> Double {
        guard (200..<300).contains(status) else {
            throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        guard let p = try JSONDecoder().decode(Response.self, from: data).answers["needs_web"]?.noul else {
            throw LLMError.api("TypeSafe response had no needs_web answer.")
        }
        return p
    }
}

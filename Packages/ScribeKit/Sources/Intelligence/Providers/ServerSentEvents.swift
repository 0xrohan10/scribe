import Foundation

public enum LLMError: Error, LocalizedError {
    case http(status: Int, body: String)
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body): "HTTP \(status): \(body.prefix(500))"
        case .api(let message): message
        }
    }
}

enum ServerSentEvents {
    /// Both Anthropic and OpenAI stream snake_case JSON.
    static let snakeCaseDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Streams the payload of each `data:` line. Both Anthropic and OpenAI put one JSON object per data
    /// line and name the event inside it, so `event:` lines and blank separators can be ignored.
    static func dataLines(for request: URLRequest, session: URLSession) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.http(status: status, body: body)
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        continuation.yield(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs `decode` over each data line and forwards the deltas.
    static func deltas<Delta: Sendable>(
        for request: URLRequest, session: URLSession, decode: @escaping @Sendable (String) throws -> [Delta]
    ) -> AsyncThrowingStream<Delta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in dataLines(for: request, session: session) {
                        for delta in try decode(data) { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

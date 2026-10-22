import Core
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

extension URLSession {
    /// A non-streaming request that throws `LLMError.http` on a non-2xx status.
    func checkedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
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

    /// Runs a fresh `Decoder` over each data line and forwards the deltas.
    static func deltas<Decoder: StreamDecoder>(
        for request: URLRequest, session: URLSession, decoder: Decoder.Type
    ) -> AsyncThrowingStream<LLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var decoder = Decoder()
                    for try await data in dataLines(for: request, session: session) {
                        for delta in try decoder.decode(data) { continuation.yield(delta) }
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

/// Turns one stream's `data:` payloads into deltas. Stateful, since tool-call arguments arrive in pieces.
protocol StreamDecoder: Sendable {
    init()
    mutating func decode(_ data: String) throws -> [LLMDelta]
}

extension LLMToolCall {
    /// From streamed JSON arguments. Empty or malformed JSON gives no arguments.
    init(name: String, json: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        self.init(name: name, arguments: object?.compactMapValues { $0 as? String } ?? [:])
    }
}

extension [LLMToolParameter] {
    /// JSON Schema for an object whose properties are these required strings.
    var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": Dictionary(uniqueKeysWithValues: map { ($0.name, ["type": "string", "description": $0.description]) }),
            "required": map(\.name),
        ]
    }
}

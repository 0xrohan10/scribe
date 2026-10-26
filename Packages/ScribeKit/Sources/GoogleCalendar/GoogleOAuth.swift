import CryptoKit
import Foundation
import Network
import Security

enum GoogleOAuth {
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly", "openid", "email",
    ]

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GoogleCalendarError.invalidResponse
        }
        return base64URL(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(clientID: String, redirectURI: String, state: String, verifier: String) throws -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let result = url.url else { throw GoogleCalendarError.invalidConfiguration }
        return result
    }

    static func authorizationCode(from url: URL, state: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.path == "/oauth/callback", let items = components.queryItems,
            items.filter({ $0.name == "state" }).count == 1,
            items.first(where: { $0.name == "state" })?.value == state
        else { throw GoogleCalendarError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw GoogleCalendarError.authorizationDenied }
        guard items.filter({ $0.name == "code" }).count == 1,
            let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw GoogleCalendarError.invalidCallback }
        return code
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}

/// Mutable state is confined to `queue`. Streams allow task cancellation to stop waits.
final class OAuthLoopback: @unchecked Sendable {
    let state: String
    let verifier: String
    private let queue = DispatchQueue(label: "scribe.google-calendar.oauth")
    private let listener: NWListener
    private let ports: AsyncThrowingStream<UInt16, any Error>
    private let portContinuation: AsyncThrowingStream<UInt16, any Error>.Continuation
    private let callbacks: AsyncThrowingStream<URL, any Error>
    private let callbackContinuation: AsyncThrowingStream<URL, any Error>.Continuation
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false

    init() throws {
        state = try GoogleOAuth.randomToken()
        verifier = try GoogleOAuth.randomToken()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        (ports, portContinuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (callbacks, callbackContinuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port?.rawValue {
                    self.portContinuation.yield(port)
                    self.portContinuation.finish()
                } else { self.fail() }
            case .failed: self.fail()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            connection.start(queue: self.queue)
            self.read(connection, id: id, buffer: Data())
        }
        listener.start(queue: queue)
    }

    func port() async throws -> UInt16 {
        var iterator = ports.makeAsyncIterator()
        guard let port = try await iterator.next() else { throw CancellationError() }
        return port
    }

    func callback() async throws -> URL {
        var iterator = callbacks.makeAsyncIterator()
        guard let callback = try await iterator.next() else { throw CancellationError() }
        return callback
    }

    func stop() {
        queue.async { self.finish() }
    }

    private func finish() {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        portContinuation.finish()
        callbackContinuation.finish()
    }

    private func fail() {
        portContinuation.finish(throwing: GoogleCalendarError.invalidResponse)
        callbackContinuation.finish(throwing: GoogleCalendarError.invalidResponse)
        finish()
    }

    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 16384, error == nil else { self.close(id); return }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { self.close(id) } else { self.read(connection, id: id, buffer: buffer) }
                return
            }
            let parts = text.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/oauth/callback?"),
                let url = URL(string: "http://127.0.0.1\(parts[1])")
            else { self.close(id); return }
            let body = "Return to Scribe to finish connecting Google Calendar."
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                self?.close(id)
            })
            self.callbackContinuation.yield(url)
            self.callbackContinuation.finish()
        }
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }
}

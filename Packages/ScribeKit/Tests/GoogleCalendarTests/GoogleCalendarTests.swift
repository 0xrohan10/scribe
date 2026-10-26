import Foundation
import Testing
@testable import GoogleCalendar

// Each test uses its own key so parallel tests do not share a response queue.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let body: String }
    final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var replies: [Reply] = []
        var requests: [URLRequest] = []
        func take(_ request: URLRequest) -> Reply {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            return replies.isEmpty ? Reply(status: 500, body: "unexpected request") : replies.removeFirst()
        }
    }
    // URLSessionConfiguration.protocolClasses cannot carry instance state. The
    // session header selects a locked per-test transport instead.
    static let registry = Registry()
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Storage] = [:]
        func register(_ storage: Storage, key: String) {
            lock.lock(); defer { lock.unlock() }
            values[key] = storage
        }
        func remove(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            values.removeValue(forKey: key)
        }
        func get(_ key: String) -> Storage? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: "X-Test-ID"),
            let storage = Self.registry.get(key), let url = request.url
        else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let reply = storage.take(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class Transport {
    let storage = StubProtocol.Storage()
    let session: URLSession
    let key = UUID().uuidString
    init(_ replies: [StubProtocol.Reply]) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-ID": key]
        session = URLSession(configuration: config)
        storage.replies = replies
        StubProtocol.registry.register(storage, key: key)
    }
    deinit { session.invalidateAndCancel(); StubProtocol.registry.remove(key) }
    var requests: [URLRequest] {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.requests
    }
    func client(secret: String? = nil) -> GoogleCalendarClient {
        GoogleCalendarClient(clientID: "desktop-client", clientSecret: secret, session: session)
    }
}

@Suite struct GoogleCalendarTests {
    @Test func calendarsFollowPagesAndDefaultPrimary() async throws {
        let transport = Transport([
            .init(status: 200, body: #"{"items":[{"id":"one","summary":"Work","primary":true}],"nextPageToken":"next+page"}"#),
            .init(status: 200, body: #"{"items":[{"id":"two","summary":"Personal"}]}"#),
        ])
        let calendars = try await transport.client().calendars(accessToken: "test-token")
        #expect(calendars == [
            GoogleCalendarListEntry(id: "one", summary: "Work", primary: true),
            GoogleCalendarListEntry(id: "two", summary: "Personal"),
        ])
        #expect(transport.requests.count == 2)
        let second = try #require(transport.requests.last)
        #expect(second.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(URLComponents(url: second.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "pageToken" })?.value == "next+page")
    }

    @Test func eventsFilterUnusableEntriesAndFollowPages() async throws {
        let transport = Transport([
            .init(status: 200, body: #"""
            {"items":[
              {"id":"cancelled","status":"cancelled","start":{"dateTime":"2026-10-23T09:00:00Z"},"end":{"dateTime":"2026-10-23T09:30:00Z"}},
              {"id":"all-day","start":{"date":"2026-10-23"},"end":{"date":"2026-10-24"}},
              {"id":"declined","start":{"dateTime":"2026-10-23T09:00:00Z"},"end":{"dateTime":"2026-10-23T09:30:00Z"},"attendees":[{"self":true,"responseStatus":"declined"}]},
              {"id":"meeting","summary":"Meeting","start":{"dateTime":"2026-10-23T09:00:00-07:00"},"end":{"dateTime":"2026-10-23T09:30:00.123-07:00"},"attendees":[{"self":false,"responseStatus":"declined"}]}
            ],"nextPageToken":"p2"}
            """#),
            .init(status: 200, body: #"{"items":[{"id":"second","start":{"dateTime":"2026-10-23T18:00:00Z"},"end":{"dateTime":"2026-10-23T19:00:00Z"}}]}"#),
        ])
        let events = try await transport.client().events(
            accessToken: "token", accountID: "account", calendarID: "cal/+#@example.com",
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000))
        #expect(events.map(\.eventID) == ["meeting", "second"])
        #expect(events[0].title == "Meeting")
        #expect(abs(events[0].end.timeIntervalSince(events[0].start) - 1800.123) < 0.001)
        #expect(events[1].title == "Untitled event")
        #expect(events.allSatisfy { $0.accountID == "account" && $0.calendarID == "cal/+#@example.com" })
        let request = try #require(transport.requests.last)
        #expect(request.url!.absoluteString.contains("cal%2F%2B%23%40example.com/events"))
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.contains(URLQueryItem(name: "singleEvents", value: "true")))
        #expect(items.contains(URLQueryItem(name: "orderBy", value: "startTime")))
        #expect(items.contains(URLQueryItem(name: "pageToken", value: "p2")))
    }

    @Test func refreshEncodesSecretAndRefreshToken() async throws {
        let transport = Transport([.init(status: 200, body: #"{"access_token":"fresh"}"#)])
        let token = try await transport.client(secret: "secret+&").refresh(refreshToken: "refresh+&=")
        #expect(token == "fresh")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        // URLProtocol can receive the request body as a stream instead of Data.
        let body: Data
        if let data = request.httpBody {
            body = data
        } else {
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                #expect(count >= 0)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        }
        let fields = try #require(URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems)
        #expect(fields.contains(URLQueryItem(name: "client_id", value: "desktop-client")))
        #expect(fields.contains(URLQueryItem(name: "client_secret", value: "secret+&")))
        #expect(fields.contains(URLQueryItem(name: "refresh_token", value: "refresh+&=")))
        #expect(fields.contains(URLQueryItem(name: "grant_type", value: "refresh_token")))
    }

    @Test func eventsResolveLocalTimesUsingGoogleTimeZones() async throws {
        let transport = Transport([.init(status: 200, body: #"""
        {"items":[
          {"id":"local","summary":"Local time","start":{"dateTime":"2026-10-23T09:00:00","timeZone":"America/Los_Angeles"},"end":{"dateTime":"2026-10-23T17:00:00Z","timeZone":"America/Los_Angeles"}},
          {"id":"fractional","start":{"dateTime":"2026-10-23T09:00:00.123","timeZone":"Asia/Kathmandu"},"end":{"dateTime":"2026-10-23T10:00:00.123","timeZone":"Asia/Kathmandu"}}
        ]}
        """#)])
        let events = try await transport.client().events(
            accessToken: "token", accountID: "account", calendarID: "calendar",
            from: .distantPast, to: .distantFuture)
        #expect(events.map(\.eventID) == ["local", "fractional"])
        let formatter = ISO8601DateFormatter()
        #expect(events[0].start == formatter.date(from: "2026-10-23T16:00:00Z"))
        #expect(events[0].end == formatter.date(from: "2026-10-23T17:00:00Z"))
        #expect(abs(events[1].start.timeIntervalSince(try #require(formatter.date(from: "2026-10-23T03:15:00Z"))) - 0.123) < 0.001)
        #expect(events[1].end.timeIntervalSince(events[1].start) == 3600)
    }

    @Test func httpErrorsDoNotExposeResponseBody() async throws {
        let transport = Transport([.init(status: 401, body: #"{"error":"secret-token"}"#)])
        await #expect(throws: GoogleCalendarError.httpStatus(401)) {
            try await transport.client().calendars(accessToken: "secret-token")
        }
        #expect(!GoogleCalendarError.httpStatus(401).localizedDescription.contains("secret-token"))
    }

    @Test func malformedJSONAndRepeatedPagesFail() async throws {
        let malformed = Transport([.init(status: 200, body: "not JSON")])
        await #expect(throws: GoogleCalendarError.invalidResponse) {
            try await malformed.client().calendars(accessToken: "token")
        }
        let repeated = Transport([
            .init(status: 200, body: #"{"nextPageToken":"same"}"#),
            .init(status: 200, body: #"{"nextPageToken":"same"}"#),
        ])
        await #expect(throws: GoogleCalendarError.invalidResponse) {
            try await repeated.client().calendars(accessToken: "token")
        }
        #expect(repeated.requests.count == 2)
    }

    @Test func modelsRoundTripAndIdentityDoesNotCollide() throws {
        let first = GoogleCalendarEvent(id: "e", title: "Meeting", start: .distantPast, end: .distantFuture, calendarID: "b:c", accountID: "a")
        let second = GoogleCalendarEvent(id: "e", title: "Meeting", start: .distantPast, end: .distantFuture, calendarID: "c", accountID: "a:b")
        #expect(first.id != second.id)
        #expect(try JSONDecoder().decode(GoogleCalendarEvent.self, from: JSONEncoder().encode(first)) == first)
        let account = GoogleCalendarAccount(id: "sub", email: "email@example.com")
        #expect(try JSONDecoder().decode(GoogleCalendarAccount.self, from: JSONEncoder().encode(account)) == account)
    }

    @Test func oauthUsesPKCEOfflineConsentAndChecksState() throws {
        // RFC 7636, Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(GoogleOAuth.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = try GoogleOAuth.authorizationURL(
            clientID: "client", redirectURI: "http://127.0.0.1:12345/oauth/callback", state: "expected", verifier: verifier)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "access_type", value: "offline")))
        #expect(query.contains(URLQueryItem(name: "prompt", value: "consent select_account")))
        #expect(query.contains(URLQueryItem(name: "code_challenge_method", value: "S256")))
        let scopes = try #require(query.first { $0.name == "scope" }?.value)
        #expect(Set(scopes.split(separator: " ").map(String.init)) == [
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            "https://www.googleapis.com/auth/calendar.events.readonly", "openid", "email",
        ])
        #expect(try GoogleOAuth.authorizationCode(from: URL(string: "http://127.0.0.1/oauth/callback?state=expected&code=code%2Bvalue")!, state: "expected") == "code+value")
        #expect(throws: GoogleCalendarError.invalidCallback) {
            try GoogleOAuth.authorizationCode(from: URL(string: "http://127.0.0.1/oauth/callback?state=wrong&code=value")!, state: "expected")
        }
        #expect(throws: GoogleCalendarError.invalidCallback) {
            try GoogleOAuth.authorizationCode(from: URL(string: "http://127.0.0.1/oauth/callback?state=expected&state=wrong&code=value")!, state: "expected")
        }
        #expect(throws: GoogleCalendarError.authorizationDenied) {
            try GoogleOAuth.authorizationCode(from: URL(string: "http://127.0.0.1/oauth/callback?state=expected&error=access_denied")!, state: "expected")
        }
    }

    @Test func loopbackReceivesCallbackAndStops() async throws {
        let receiver = try OAuthLoopback()
        defer { receiver.stop() }
        let port = try await receiver.port()
        #expect(port > 0)
        let callback = URL(string: "http://127.0.0.1:\(port)/oauth/callback?state=\(receiver.state)&code=sample")!
        let (_, response) = try await URLSession.shared.data(from: callback)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let received = try await receiver.callback()
        #expect(try GoogleOAuth.authorizationCode(from: received, state: receiver.state) == "sample")
    }

    @Test func cancelledCallbackWaitEndsAndListenerCanStop() async throws {
        let receiver = try OAuthLoopback()
        defer { receiver.stop() }
        _ = try await receiver.port()
        let wait = Task { try await receiver.callback() }
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
    }
}

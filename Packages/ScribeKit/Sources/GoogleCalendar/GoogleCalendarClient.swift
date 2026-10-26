import AppKit
import Foundation

public struct GoogleCalendarClient: Sendable {
    private let clientID: String
    private let clientSecret: String?
    private let session: URLSession

    public init(clientID: String, clientSecret: String? = nil) {
        self.init(clientID: clientID, clientSecret: clientSecret, session: URLSession(configuration: .ephemeral))
    }

    // Internal injection keeps the public API independent of the HTTP test transport.
    init(clientID: String, clientSecret: String? = nil, session: URLSession) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.session = session
    }

    @MainActor
    public func authorize() async throws -> GoogleCalendarCredential {
        try Task.checkCancellation()
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoogleCalendarError.invalidConfiguration
        }
        let receiver = try OAuthLoopback()
        defer { receiver.stop() }
        let codeAndRedirect = try await withThrowingTaskGroup(of: (String, String).self) { group in
            group.addTask {
                let port = try await receiver.port()
                let redirect = "http://127.0.0.1:\(port)/oauth/callback"
                let url = try GoogleOAuth.authorizationURL(
                    clientID: clientID, redirectURI: redirect, state: receiver.state, verifier: receiver.verifier)
                try Task.checkCancellation()
                let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                guard opened else { throw GoogleCalendarError.browserUnavailable }
                let callback = try await receiver.callback()
                return (try GoogleOAuth.authorizationCode(from: callback, state: receiver.state), redirect)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw GoogleCalendarError.authorizationTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let token: TokenResponse = try await tokenRequest([
            "grant_type": "authorization_code", "code": codeAndRedirect.0,
            "redirect_uri": codeAndRedirect.1, "code_verifier": receiver.verifier,
        ])
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw GoogleCalendarError.missingRefreshToken
        }
        let user: UserInfo = try await get(
            URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!, accessToken: token.accessToken)
        guard !user.sub.isEmpty, !user.email.isEmpty else { throw GoogleCalendarError.invalidResponse }
        return GoogleCalendarCredential(
            account: GoogleCalendarAccount(id: user.sub, email: user.email), refreshToken: refreshToken)
    }

    public func refresh(refreshToken: String) async throws -> String {
        let response: TokenResponse = try await tokenRequest([
            "grant_type": "refresh_token", "refresh_token": refreshToken,
        ])
        return response.accessToken
    }

    public func calendars(accessToken: String) async throws -> [GoogleCalendarListEntry] {
        var result: [GoogleCalendarListEntry] = []
        var next: String?
        var seen: Set<String> = []
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "250")]
            if let next { query.append(URLQueryItem(name: "pageToken", value: next)) }
            let page: Page<GoogleCalendarListEntry> = try await get(
                apiURL(path: "users/me/calendarList", query: query), accessToken: accessToken)
            result.append(contentsOf: page.items ?? [])
            next = page.nextPageToken
            if let next, !seen.insert(next).inserted { throw GoogleCalendarError.invalidResponse }
        } while next != nil
        return result
    }

    public func events(
        accessToken: String, accountID: String, calendarID: String, from: Date, to: Date
    ) async throws -> [GoogleCalendarEvent] {
        guard from < to else { throw GoogleCalendarError.invalidConfiguration }
        // A calendar ID is one path segment, including IDs with '/', '+' or '#'.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedID = calendarID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw GoogleCalendarError.invalidConfiguration
        }
        let formatter = ISO8601DateFormatter()
        var result: [GoogleCalendarEvent] = []
        var next: String?
        var seen: Set<String> = []
        repeat {
            var query = [
                URLQueryItem(name: "timeMin", value: formatter.string(from: from)),
                URLQueryItem(name: "timeMax", value: formatter.string(from: to)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "2500"),
            ]
            if let next { query.append(URLQueryItem(name: "pageToken", value: next)) }
            let page: Page<EventResponse> = try await get(
                apiURL(path: "calendars/\(encodedID)/events", query: query), accessToken: accessToken)
            for event in page.items ?? [] {
                guard event.status != "cancelled",
                    !(event.attendees ?? []).contains(where: { $0.isSelf == true && $0.responseStatus == "declined" }),
                    let startString = event.start?.dateTime, let endString = event.end?.dateTime
                else { continue }
                guard let start = Self.parseDate(startString, timeZone: event.start?.timeZone),
                    let end = Self.parseDate(endString, timeZone: event.end?.timeZone), end > start else {
                    throw GoogleCalendarError.invalidResponse
                }
                let title = event.summary.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                result.append(GoogleCalendarEvent(
                    id: event.id, title: title ?? "Untitled event", start: start, end: end,
                    calendarID: calendarID, accountID: accountID))
            }
            next = page.nextPageToken
            if let next, !seen.insert(next).inserted { throw GoogleCalendarError.invalidResponse }
        } while next != nil
        return result
    }

    private static func parseDate(_ value: String, timeZone: String?) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        // Google permits an offsetless dateTime when an IANA timeZone is supplied.
        guard let timeZone, let zone = TimeZone(identifier: timeZone) else { return nil }
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.formatOptions.remove(.withTimeZone)
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.remove(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private func apiURL(path: String, query: [URLQueryItem]) -> URL {
        var url = URLComponents(string: "https://www.googleapis.com/calendar/v3/\(path)")!
        url.queryItems = query
        return url.url!
    }

    private func get<T: Decodable>(_ url: URL, accessToken: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var fields = fields
        fields["client_id"] = clientID
        if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuth.formBody(fields)
        let token: TokenResponse = try await send(request)
        guard !token.accessToken.isEmpty else { throw GoogleCalendarError.invalidResponse }
        return token
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // Foundation errors can contain the request and its credentials.
            throw GoogleCalendarError.invalidResponse
        }
        guard let response = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw GoogleCalendarError.httpStatus(response.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GoogleCalendarError.invalidResponse }
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct UserInfo: Decodable { let sub: String; let email: String }
private struct Page<Item: Decodable>: Decodable {
    let items: [Item]?
    let nextPageToken: String?
}
private struct EventResponse: Decodable {
    let id: String
    let summary: String?
    let status: String?
    let start: Time?
    let end: Time?
    let attendees: [Attendee]?
    struct Time: Decodable { let dateTime: String?; let timeZone: String? }
    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?
        enum CodingKeys: String, CodingKey { case isSelf = "self"; case responseStatus }
    }
}

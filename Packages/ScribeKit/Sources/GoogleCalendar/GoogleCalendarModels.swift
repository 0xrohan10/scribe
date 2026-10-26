import Foundation

public struct GoogleCalendarAccount: Sendable, Codable, Equatable, Identifiable {
    /// The Google OpenID Connect `sub`, not the email address.
    public let id: String
    public let email: String

    public init(id: String, email: String) {
        self.id = id
        self.email = email
    }
}

public struct GoogleCalendarListEntry: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let summary: String
    public let primary: Bool

    public init(id: String, summary: String, primary: Bool = false) {
        self.id = id
        self.summary = summary
        self.primary = primary
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        primary = try values.decodeIfPresent(Bool.self, forKey: .primary) ?? false
    }
}

public struct GoogleCalendarEvent: Sendable, Codable, Equatable, Identifiable {
    /// The original Google event ID. `id` is unique across accounts and calendars.
    public let eventID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let calendarID: String
    public let accountID: String

    public var id: String {
        [accountID, calendarID, eventID].map { "\($0.utf8.count):\($0)" }.joined()
    }

    public init(id: String, title: String, start: Date, end: Date, calendarID: String, accountID: String) {
        self.eventID = id
        self.title = title
        self.start = start
        self.end = end
        self.calendarID = calendarID
        self.accountID = accountID
    }
}

public struct GoogleCalendarCredential: Sendable, Codable, Equatable {
    public let account: GoogleCalendarAccount
    public let refreshToken: String

    public init(account: GoogleCalendarAccount, refreshToken: String) {
        self.account = account
        self.refreshToken = refreshToken
    }
}

/// Errors deliberately exclude response bodies, request URLs, and credentials.
public enum GoogleCalendarError: Error, Sendable, Equatable, LocalizedError {
    case httpStatus(Int)
    case invalidResponse
    case invalidConfiguration
    case authorizationDenied
    case invalidCallback
    case missingRefreshToken
    case browserUnavailable
    case authorizationTimedOut

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status): "Google Calendar request failed (HTTP \(status))."
        case .invalidResponse: "Google Calendar returned an invalid response."
        case .invalidConfiguration: "Google Calendar client configuration is invalid."
        case .authorizationDenied: "Google Calendar authorization was denied."
        case .invalidCallback: "Google Calendar authorization callback is invalid."
        case .missingRefreshToken: "Google did not return a refresh token. Reconnect the account."
        case .browserUnavailable: "The browser could not be opened."
        case .authorizationTimedOut: "Google Calendar authorization timed out."
        }
    }
}

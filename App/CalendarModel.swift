import Core
import Foundation
import GoogleCalendar
import Observation

/// Account metadata stays in preferences. OAuth credentials stay in Keychain.
@MainActor @Observable
final class CalendarModel {
    struct Connection: Codable, Identifiable {
        var account: GoogleCalendarAccount
        var calendars: [GoogleCalendarListEntry]
        var selectedIDs: Set<String>
        var id: String { account.id }
    }

    private struct Preferences: Codable {
        var clientID = ""
        var connections: [Connection] = []
    }

    private(set) var connections: [Connection]
    private(set) var clientID: String
    private(set) var events: [GoogleCalendarEvent] = []
    private(set) var isBusy = false
    private(set) var isConnecting = false
    private(set) var accountErrors: [String: String] = [:]
    var lastError: String?
    private(set) var lastRefresh: Date?
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    private static let preferencesKey = "scribe.googleCalendar.v1"
    private static let clientSecretKey = "googleCalendar.clientSecret"

    init(secrets: any SecretStore, defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults
        let preferences = defaults.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        clientID = preferences.clientID
        connections = preferences.connections
    }

    var clientSecret: String { secrets.secret(for: Self.clientSecretKey) ?? "" }

    func saveConfiguration(clientID: String, clientSecret: String) throws {
        guard connections.isEmpty, !isBusy else { return }
        try secrets.setSecret(clientSecret.isEmpty ? nil : clientSecret, for: Self.clientSecretKey)
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func connect() {
        guard !isBusy, !clientID.isEmpty else { return }
        isBusy = true
        isConnecting = true
        lastError = nil
        connectionTask = Task {
            defer { isBusy = false; isConnecting = false; connectionTask = nil }
            do {
                let client = makeClient()
                let credential = try await client.authorize()
                try Task.checkCancellation()
                let token = try await client.refresh(refreshToken: credential.refreshToken)
                let calendars = try await client.calendars(accessToken: token)
                try Task.checkCancellation()
                let existing = connections.first { $0.id == credential.account.id }
                // Store credentials first, so a Keychain failure never leaves a broken account row.
                try secrets.setSecret(credential.refreshToken, for: tokenKey(credential.account.id))
                let selection = existing?.selectedIDs ?? Set(calendars.filter(\.primary).map(\.id))
                connections.removeAll { $0.id == credential.account.id }
                connections.append(Connection(account: credential.account, calendars: calendars,
                                              selectedIDs: selection.intersection(calendars.map(\.id))))
                persist()
                await loadEvents()
            } catch is CancellationError {
                // The user cancelled sign-in.
            } catch {
                if !Task.isCancelled { lastError = error.localizedDescription }
            }
        }
    }

    func cancelConnection() { connectionTask?.cancel() }

    func disconnect(_ id: String) {
        guard !isBusy else { return }
        do {
            try secrets.setSecret(nil, for: tokenKey(id))
            connections.removeAll { $0.id == id }
            events.removeAll { $0.accountID == id }
            accountErrors[id] = nil
            persist()
        } catch { lastError = error.localizedDescription }
    }

    func select(_ calendarID: String, accountID: String, enabled: Bool) {
        guard !isBusy, let index = connections.firstIndex(where: { $0.id == accountID }) else { return }
        if enabled { connections[index].selectedIDs.insert(calendarID) }
        else { connections[index].selectedIDs.remove(calendarID) }
        events.removeAll { $0.accountID == accountID && !connections[index].selectedIDs.contains($0.calendarID) }
        persist()
    }

    func refresh() async {
        guard !isBusy, !connections.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        await loadEvents()
    }

    func calendarName(for event: GoogleCalendarEvent) -> String {
        connections.first { $0.id == event.accountID }?.calendars.first { $0.id == event.calendarID }?.summary ?? "Calendar"
    }

    func accountEmail(for event: GoogleCalendarEvent) -> String {
        connections.first { $0.id == event.accountID }?.account.email ?? ""
    }

    private func loadEvents() async {
        var loaded: [GoogleCalendarEvent] = []
        var errors: [String: String] = [:]
        let from = Date.now
        let to = from.addingTimeInterval(7 * 24 * 60 * 60)
        let client = makeClient()
        for index in connections.indices {
            let connection = connections[index]
            do {
                try Task.checkCancellation()
                guard let refreshToken = secrets.secret(for: tokenKey(connection.id)) else {
                    throw CalendarConnectionError.missingToken
                }
                let token = try await client.refresh(refreshToken: refreshToken)
                let calendars = try await client.calendars(accessToken: token)
                connections[index].calendars = calendars
                connections[index].selectedIDs.formIntersection(calendars.map(\.id))
                for calendar in calendars where connections[index].selectedIDs.contains(calendar.id) {
                    do {
                        loaded += try await client.events(accessToken: token, accountID: connection.id,
                                                          calendarID: calendar.id, from: from, to: to)
                    } catch {
                        if Task.isCancelled { return }
                        errors[connection.id] = error.localizedDescription
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                errors[connection.id] = error.localizedDescription
            }
        }
        guard !Task.isCancelled else { return }
        events = loaded.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        accountErrors = errors
        lastRefresh = .now
        persist()
    }

    private func makeClient() -> GoogleCalendarClient {
        let secret = clientSecret
        return GoogleCalendarClient(clientID: clientID, clientSecret: secret.isEmpty ? nil : secret)
    }

    private func tokenKey(_ id: String) -> String { "googleCalendar.refreshToken.\(id)" }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(Preferences(clientID: clientID, connections: connections)),
                     forKey: Self.preferencesKey)
    }
}

private enum CalendarConnectionError: LocalizedError {
    case missingToken
    var errorDescription: String? { "Sign in to this Google account again to restore calendar access." }
}

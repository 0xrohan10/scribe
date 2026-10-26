import Core
import Foundation
import GoogleCalendar
import Testing

@MainActor
struct CalendarModelTests {
    @Test func configurationStoresSecretsOnlyInSecretStore() throws {
        let name = "scribe.calendar-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = CalendarTestSecrets()
        let model = CalendarModel(secrets: secrets, defaults: defaults)
        try model.saveConfiguration(clientID: "  desktop.apps.googleusercontent.com \n", clientSecret: "private-secret")

        let restored = CalendarModel(secrets: secrets, defaults: defaults)
        #expect(restored.clientID == "desktop.apps.googleusercontent.com")
        #expect(restored.clientSecret == "private-secret")
        let data = try #require(defaults.data(forKey: "scribe.googleCalendar.v1"))
        #expect(!String(decoding: data, as: UTF8.self).contains("private-secret"))
    }

    @Test func selectionsAndDisconnectStayWithinTheirAccount() throws {
        let name = "scribe.calendar-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Identical calendar IDs in two accounts must not share selection state.
        let fixture = #"{"clientID":"desktop","connections":[{"account":{"id":"a","email":"a@example.com"},"calendars":[{"id":"shared","summary":"Work","primary":true}],"selectedIDs":["shared"]},{"account":{"id":"b","email":"b@example.com"},"calendars":[{"id":"shared","summary":"Work","primary":true}],"selectedIDs":["shared"]}]}"#
        defaults.set(Data(fixture.utf8), forKey: "scribe.googleCalendar.v1")
        let secrets = CalendarTestSecrets()
        try secrets.setSecret("token-a", for: "googleCalendar.refreshToken.a")
        try secrets.setSecret("token-b", for: "googleCalendar.refreshToken.b")
        let model = CalendarModel(secrets: secrets, defaults: defaults)
        #expect(model.connections.count == 2)
        model.select("shared", accountID: "a", enabled: false)
        #expect(model.connections[0].selectedIDs.isEmpty)
        #expect(model.connections[1].selectedIDs == ["shared"])
        let selections = CalendarModel(secrets: secrets, defaults: defaults)
        #expect(selections.connections[0].selectedIDs.isEmpty)
        #expect(selections.connections[1].selectedIDs == ["shared"])
        try model.saveConfiguration(clientID: "different-client", clientSecret: "different-secret")
        #expect(model.clientID == "desktop")
        #expect(model.clientSecret.isEmpty)

        model.disconnect("a")
        #expect(model.connections.map(\.id) == ["b"])
        #expect(secrets.secret(for: "googleCalendar.refreshToken.a") == nil)
        #expect(secrets.secret(for: "googleCalendar.refreshToken.b") == "token-b")
        let restored = CalendarModel(secrets: secrets, defaults: defaults)
        #expect(restored.connections.map(\.id) == ["b"])
    }

    @Test func failedKeychainDeletionKeepsTheConnection() throws {
        let name = "scribe.calendar-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data(#"{"clientID":"desktop","connections":[{"account":{"id":"a","email":"a@example.com"},"calendars":[],"selectedIDs":[]}]}"#.utf8), forKey: "scribe.googleCalendar.v1")
        let secrets = CalendarTestSecrets()
        secrets.failWrites = true
        let model = CalendarModel(secrets: secrets, defaults: defaults)
        model.disconnect("a")
        #expect(model.connections.count == 1)
        #expect(model.lastError != nil)
    }
}

private final class CalendarTestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failWrites = false

    func secret(for key: String) -> String? { lock.withLock { values[key] } }
    func setSecret(_ value: String?, for key: String) throws {
        try lock.withLock {
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            values[key] = value
        }
    }
}

import Core
import Foundation
import Testing

@testable import Settings

private struct MemorySecrets: SecretStore {
    let values: [String: String]
    func secret(for key: String) -> String? { values[key] }
    func setSecret(_ value: String?, for key: String) throws {}
}

@Suite struct SettingsTests {
    @Test func roundTripsThroughUserDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "scribe.tests.\(UUID())"))
        let store = SettingsStore(defaults: defaults)
        var settings = AppSettings()
        settings.llmProviderID = "openai-compatible"
        settings.transcriptionProviderID = "speech-analyzer"
        settings.webSearchProviderID = "parallel"
        settings.baseURLs["openai-compatible"] = URL(string: "http://localhost:11434/v1")
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func missingFieldsKeepDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"llmProviderID":"x"}"#.utf8))
        #expect(decoded.llmProviderID == "x")
        #expect(decoded.transcriptionProviderID == nil)
    }

    @Test func configMergesKeychainAndOverrides() {
        var settings = AppSettings()
        settings.models["anthropic"] = "claude-opus-5-5"
        let descriptor = ProviderDescriptor(id: "anthropic", displayName: "Claude", needsAPIKey: true, defaultModel: "claude-sonnet-5-5")
        let config = settings.config(for: descriptor, secrets: MemorySecrets(values: ["apiKey.anthropic": "sk"]))
        #expect(config == ProviderConfig(apiKey: "sk", model: "claude-opus-5-5"))

        settings.models["anthropic"] = ""
        #expect(settings.config(for: descriptor, secrets: MemorySecrets(values: [:])).model == "claude-sonnet-5-5")
    }
}

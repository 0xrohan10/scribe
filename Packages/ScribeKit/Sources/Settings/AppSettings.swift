import Core
import Foundation

public enum SystemAudioMode: String, Codable, Sendable, CaseIterable {
    /// Tap everything except Scribe (most reliable).
    case allApps
    /// Tap only the detected meeting app (Zoom, Teams, the browser running Meet). Falls back to all apps.
    case meetingApp
}

/// Non-secret preferences. API keys never live here; they're in the Keychain via `SecretStore`.
public struct AppSettings: Codable, Sendable, Equatable {
    /// No default: the user picks one before their first recording.
    public var transcriptionProviderID: String?
    public var llmProviderID: String = "anthropic"
    /// Client-side web search for Q&A. When unset, the AI provider's own hosted search is used if it has one.
    public var webSearchProviderID: String?
    /// Decides per question whether the web search is needed. When unset, every question searches.
    public var searchGateProviderID: String?
    /// Per-provider model override, keyed by provider id.
    public var models: [String: String] = [:]
    /// Per-provider base URL override, keyed by provider id.
    public var baseURLs: [String: URL] = [:]
    public var systemAudioMode: SystemAudioMode = .allApps
    public var defaultTemplateID: String = SummaryTemplate.general.id
    public var promptWhenMeetingDetected = true
    public var summarizeWhenMeetingEnds = true

    public init() {}

    public init(from decoder: any Decoder) throws {
        // Decode field-by-field with defaults so adding a setting never resets the others.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        transcriptionProviderID = try c.decodeIfPresent(String.self, forKey: .transcriptionProviderID)
        llmProviderID = try c.decodeIfPresent(String.self, forKey: .llmProviderID) ?? d.llmProviderID
        webSearchProviderID = try c.decodeIfPresent(String.self, forKey: .webSearchProviderID)
        searchGateProviderID = try c.decodeIfPresent(String.self, forKey: .searchGateProviderID)
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? d.models
        baseURLs = try c.decodeIfPresent([String: URL].self, forKey: .baseURLs) ?? d.baseURLs
        systemAudioMode = try c.decodeIfPresent(SystemAudioMode.self, forKey: .systemAudioMode) ?? d.systemAudioMode
        defaultTemplateID = try c.decodeIfPresent(String.self, forKey: .defaultTemplateID) ?? d.defaultTemplateID
        promptWhenMeetingDetected = try c.decodeIfPresent(Bool.self, forKey: .promptWhenMeetingDetected) ?? d.promptWhenMeetingDetected
        summarizeWhenMeetingEnds = try c.decodeIfPresent(Bool.self, forKey: .summarizeWhenMeetingEnds) ?? d.summarizeWhenMeetingEnds
    }

    /// Everything a provider factory needs: the Keychain key plus any model/base-URL overrides.
    public func config(for descriptor: ProviderDescriptor, secrets: any SecretStore) -> ProviderConfig {
        ProviderConfig(
            apiKey: secrets.secret(for: descriptor.secretKey),
            model: models[descriptor.id].flatMap { $0.isEmpty ? nil : $0 } ?? descriptor.defaultModel,
            baseURL: baseURLs[descriptor.id] ?? descriptor.defaultBaseURL)
    }
}

public struct SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "scribe.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }

    public func save(_ settings: AppSettings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: key)
    }
}

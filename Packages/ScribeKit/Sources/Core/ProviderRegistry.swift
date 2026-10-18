import Foundation

public struct ProviderDescriptor: Sendable, Identifiable, Hashable {
    public let id: String
    public var displayName: String
    public var needsAPIKey: Bool
    public var needsBaseURL: Bool
    public var defaultModel: String?
    public var defaultBaseURL: URL?
    /// False when the provider can't run here (e.g. SpeechAnalyzer before macOS 26).
    public var isAvailable: Bool

    public init(
        id: String, displayName: String, needsAPIKey: Bool = false, needsBaseURL: Bool = false,
        defaultModel: String? = nil, defaultBaseURL: URL? = nil, isAvailable: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.needsAPIKey = needsAPIKey
        self.needsBaseURL = needsBaseURL
        self.defaultModel = defaultModel
        self.defaultBaseURL = defaultBaseURL
        self.isAvailable = isAvailable
    }

    /// Keychain account for this provider's API key.
    public var secretKey: String { "apiKey.\(id)" }
}

public struct ProviderConfig: Sendable, Hashable {
    public var apiKey: String?
    public var model: String?
    public var baseURL: URL?

    public init(apiKey: String? = nil, model: String? = nil, baseURL: URL? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case unknownProvider(String)
    case unavailable(String)
    case missingAPIKey(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let id): "Unknown provider “\(id)”."
        case .unavailable(let id): "“\(id)” isn't available on this Mac."
        case .missingAPIKey(let id): "Add an API key for “\(id)” in Settings."
        case .notImplemented(let id): "“\(id)” isn't implemented yet."
        }
    }
}

/// Providers are registered once at the composition root and picked by id from Settings.
public struct ProviderRegistry<Provider>: Sendable {
    public typealias Factory = @Sendable (ProviderConfig) throws -> Provider

    private var entries: [(descriptor: ProviderDescriptor, make: Factory)] = []

    public init() {}

    public mutating func register(_ descriptor: ProviderDescriptor, _ make: @escaping Factory) {
        precondition(!entries.contains { $0.descriptor.id == descriptor.id }, "Duplicate provider id \(descriptor.id)")
        entries.append((descriptor, make))
    }

    public var descriptors: [ProviderDescriptor] { entries.map(\.descriptor) }

    public func descriptor(id: String) -> ProviderDescriptor? {
        entries.first { $0.descriptor.id == id }?.descriptor
    }

    public func make(id: String, config: ProviderConfig) throws -> Provider {
        guard let entry = entries.first(where: { $0.descriptor.id == id }) else { throw ProviderError.unknownProvider(id) }
        guard entry.descriptor.isAvailable else { throw ProviderError.unavailable(id) }
        if entry.descriptor.needsAPIKey, (config.apiKey ?? "").isEmpty { throw ProviderError.missingAPIKey(id) }
        return try entry.make(config)
    }
}

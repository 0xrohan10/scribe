import Foundation

public enum LocalModelPhase: Sendable, Equatable {
    case notDownloaded
    case downloaded
    /// Fraction of the download work reported by the provider, not a byte estimate.
    case downloading(Double?)
    case loading
    case ready
    case deleting
    case failed(String)
}

public struct LocalModelStatus: Sendable, Equatable {
    public var phase: LocalModelPhase
    public var cachedBytes: Int64

    public init(phase: LocalModelPhase, cachedBytes: Int64 = 0) {
        self.phase = phase
        self.cachedBytes = cachedBytes
    }
}

public protocol LocalModelProvider: TranscriptionProvider {
    func modelUpdates() async throws -> AsyncStream<LocalModelStatus>
    /// Call only while recording and transcription are stopped.
    func deleteModel() async throws
}

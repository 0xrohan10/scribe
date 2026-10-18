import Foundation

/// A block of mono Float32 PCM from one capture source.
public struct AudioChunk: Sendable {
    public enum Source: String, Sendable, Codable, CaseIterable {
        case mic
        case system
    }

    public let source: Source
    /// Mono Float32 samples at `sampleRate`.
    public let pcm: [Float]
    public let sampleRate: Double
    /// Seconds on the session clock at the first sample.
    public let timestamp: TimeInterval

    public init(source: Source, pcm: [Float], sampleRate: Double, timestamp: TimeInterval) {
        self.source = source
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }

    public var duration: TimeInterval { Double(pcm.count) / sampleRate }
}

extension AudioChunk.Source {
    /// Mic is always the local user; system audio is everyone else. This is what lets us skip diarization.
    public var speaker: Speaker {
        switch self {
        case .mic: .me
        case .system: .them
        }
    }
}

/// Which processes the system-audio tap listens to.
public enum SystemAudioScope: Sendable, Hashable, Codable {
    /// Every process except Scribe. Most reliable: catches browser/Zoom helper processes that start audio late.
    case allApps
    /// Only processes whose bundle ID has one of these prefixes (e.g. `com.google.Chrome` also matches its helpers).
    case bundleIDs([String])
}

/// A capture source that streams PCM to the session and writes its own recording file.
public protocol AudioSource: Sendable {
    var source: AudioChunk.Source { get }
    /// Starts capture. The returned stream finishes after `stop()`.
    func start(clock: SessionClock, recordingTo url: URL?) async throws -> AsyncStream<AudioChunk>
    func stop() async
}

import Core
import Foundation

/// TODO: WhisperKit (on-device). Add the WhisperKit package to this target and stream 16 kHz chunks into its streaming transcriber.
/// Once implemented, register it in `App/Providers.swift`.
public struct WhisperKitProvider: TranscriptionProvider {
    public let id = "whisperkit"
    public let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
    }

    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.notImplemented(id)) }
    }
}

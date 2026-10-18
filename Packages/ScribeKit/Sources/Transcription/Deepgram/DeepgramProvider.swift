import Core
import Foundation

/// TODO: Deepgram streaming (wss://api.deepgram.com/v1/listen, linear16 @ 16 kHz, interim_results=true).
/// Once implemented, register it in `App/Providers.swift`.
public struct DeepgramProvider: TranscriptionProvider {
    public let id = "deepgram"
    public let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
    }

    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.notImplemented(id)) }
    }
}

import Core
import Foundation

/// TODO: OpenAI Realtime transcription (wss://api.openai.com/v1/realtime?intent=transcription, pcm16 @ 24 kHz; resample with PCMConverter).
/// Once implemented, register it in `App/Providers.swift`.
public struct OpenAIRealtimeProvider: TranscriptionProvider {
    public let id = "openai-realtime"
    public let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
    }

    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.notImplemented(id)) }
    }
}

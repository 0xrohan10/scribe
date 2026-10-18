import Core
import Foundation

/// TODO: AssemblyAI Universal-Streaming (wss://streaming.assemblyai.com/v3/ws, pcm_s16le @ 16 kHz).
/// Once implemented, register it in `App/Providers.swift`.
public struct AssemblyAIProvider: TranscriptionProvider {
    public let id = "assemblyai"
    public let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
    }

    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.notImplemented(id)) }
    }
}

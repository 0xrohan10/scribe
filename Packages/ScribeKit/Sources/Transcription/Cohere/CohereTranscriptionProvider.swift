@preconcurrency import AVFAudio
import Core
import Foundation
import HuggingFace
import MLXAudioCore
#if arch(arm64)
import MLX
@preconcurrency import MLXAudioSTT
#endif
import os

/// Cohere Transcribe through MLX. Audio stays on this Mac; weights download on first use.
public struct CohereTranscriptionProvider: LocalModelProvider {
    public let id = "cohere-transcribe"
    public let model: String
    public let language: String

    public static let defaultModel = "beshkenadze/cohere-transcribe-03-2026-mlx-fp16"
    public static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    public init(config: ProviderConfig, language: String = "en") {
        self.model = config.model ?? Self.defaultModel
        self.language = language
    }

    public func prepare() async throws {
        #if arch(arm64)
        _ = try await CohereModels.load(model)
        #else
        throw ProviderError.unavailable(id)
        #endif
    }

    public func modelUpdates() async throws -> AsyncStream<LocalModelStatus> {
        #if arch(arm64)
        return await CohereModels.cache.updates(model, directories: try CohereModels.directories(model))
        #else
        throw ProviderError.unavailable(id)
        #endif
    }

    public func deleteModel() async throws {
        #if arch(arm64)
        try await CohereModels.cache.delete(model, directories: CohereModels.directories(model))
        #else
        throw ProviderError.unavailable(id)
        #endif
    }

    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        transcribe(audio) { samples in
            #if arch(arm64)
            let loaded = try await CohereModels.load(model)
            return try await loaded.transcribe(samples, language: language)
            #else
            throw ProviderError.unavailable(id)
            #endif
        }
    }

    /// Capture must not wait for inference. Finals are kept; pending partials are replaced by newer audio.
    func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        decode: @escaping @Sendable ([Float]) async throws -> String
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                    let speaker = OSAllocatedUnfairLock(initialState: Speaker.them)
                    let queue = OSAllocatedUnfairLock(initialState: DecodeQueue())
                    let (wake, wakeUp) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
                    var segmentID = UUID()

                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            defer { wakeUp.finish() }
                            let converter = PCMConverter(to: format)
                            var segmenter = UtteranceSegmenter()
                            // Re-decoding a 2B model every second wastes work. Finalize on pauses as usual.
                            segmenter.partialInterval = 3
                            func push(_ utterance: UtteranceSegmenter.Utterance?) {
                                guard let utterance else { return }
                                queue.withLock { $0.push(utterance) }
                                wakeUp.yield()
                            }
                            for await chunk in audio {
                                try Task.checkCancellation()
                                speaker.withLock { $0 = chunk.source.speaker }
                                guard let buffer = converter.convert(chunk), let data = buffer.floatChannelData else { continue }
                                push(segmenter.append(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))), at: chunk.timestamp))
                            }
                            push(segmenter.flush())
                        }
                        for await _ in wake {
                            while let utterance = queue.withLock({ $0.pop() }) {
                                try Task.checkCancellation()
                                let text = try await decode(utterance.samples).trimmingCharacters(in: .whitespacesAndNewlines)
                                try Task.checkCancellation()
                                // An empty final must still replace any earlier partial.
                                if !text.isEmpty || utterance.isFinal {
                                    continuation.yield(TranscriptSegment(
                                        id: segmentID, speaker: speaker.withLock { $0 }, text: text,
                                        start: utterance.start, end: utterance.end, isFinal: utterance.isFinal))
                                }
                                if utterance.isFinal { segmentID = UUID() }
                            }
                        }
                        try await group.waitForAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

#if arch(arm64)
/// One load per model, shared by both audio sources. Failed loads can be retried.
private enum CohereModels {
    static let cache = LocalModelCache<LoadedCohere>()

    static func directories(_ name: String) throws -> [URL] {
        try validateModelName(name, components: 2)
        return [HubCache.default.cacheDirectory.appending(path: "mlx-audio/\(name.replacingOccurrences(of: "/", with: "_"))"),
                HubCache.default.repoDirectory(repo: Repo.ID(rawValue: name)!, kind: .model)]
    }

    static func load(_ name: String) async throws -> LoadedCohere {
        try await Self.cache.load(name, directories: { try Self.directories(name) }) { report in
            let token = ProcessInfo.processInfo.environment["HF_TOKEN"] ?? Bundle.main.object(forInfoDictionaryKey: "HF_TOKEN") as? String
            let client = HubClient(host: HubClient.defaultHost, bearerToken: token, cache: .default)
            let directory = try await ModelUtils.resolveOrDownloadModel(
                client: client, repoID: Repo.ID(rawValue: name)!, requiredExtension: "safetensors",
                additionalMatchingPatterns: ["*.model"], progressHandler: { progress in
                    report(.downloading(progress.fractionCompleted))
                })
            report(.loading)
            return try await LoadedCohere.load(directory)
        }
    }
}

/// MLX models are mutable: all inference on this instance is serialized by the actor.
private actor LoadedCohere {
    private let model: CohereTranscribeModel

    private init(model: sending CohereTranscribeModel) { self.model = model }

    static func load(_ directory: URL) async throws -> LoadedCohere {
        let model = try CohereTranscribeModel.fromDirectory(directory)
        return LoadedCohere(model: model)
    }

    func transcribe(_ samples: [Float], language: String) throws -> String {
        try Task.checkCancellation()
        let output = model.generate(audio: MLXArray(samples), generationParameters: STTGenerateParameters(
            maxTokens: 512, temperature: 0, language: language))
        try Task.checkCancellation()
        return output.text
    }
}
#endif

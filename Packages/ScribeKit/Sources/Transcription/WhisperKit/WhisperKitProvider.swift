@preconcurrency import AVFAudio
import Core
import Foundation
@preconcurrency import WhisperKit

/// On-device Whisper via WhisperKit (Core ML). Downloads the model on first use.
/// Whisper isn't a streaming model, so each utterance is re-decoded as it grows (partials) and once more when it ends (final).
public struct WhisperKitProvider: TranscriptionProvider {
    public let id = "whisperkit"
    public let model: String
    public let language: String?

    public init(config: ProviderConfig, language: String? = Locale.current.language.languageCode?.identifier) {
        self.model = config.model ?? Self.defaultModel
        self.language = language
    }

    /// The largest model WhisperKit recommends for this Mac.
    public static var defaultModel: String { WhisperKit.recommendedModels().default }

    public func transcribe(_ audio: AsyncStream<Core.AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let (model, language) = (model, language)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let whisper = try await WhisperModels.shared.load(model)
                    let options = DecodingOptions(language: language, skipSpecialTokens: true, withoutTimestamps: true)
                    let format = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32, sampleRate: Double(WhisperKit.sampleRate), channels: 1, interleaved: false)!
                    let converter = PCMConverter(to: format)
                    var segmenter = UtteranceSegmenter()
                    var speaker = Speaker.them
                    var segmentID = UUID()

                    func emit(_ utterance: UtteranceSegmenter.Utterance) async throws {
                        let text = try await whisper.transcribe(utterance.samples, options: options)
                        if !text.isEmpty {
                            continuation.yield(
                                TranscriptSegment(
                                    id: segmentID, speaker: speaker, text: text,
                                    start: utterance.start, end: utterance.end, isFinal: utterance.isFinal))
                        }
                        if utterance.isFinal { segmentID = UUID() }
                    }

                    for await chunk in audio {
                        speaker = chunk.source.speaker
                        guard let buffer = converter.convert(chunk), let data = buffer.floatChannelData else { continue }
                        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
                        if let utterance = segmenter.append(samples, at: chunk.timestamp) { try await emit(utterance) }
                    }
                    if let utterance = segmenter.flush() { try await emit(utterance) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Splits a 16 kHz stream into utterances on silence, asking for a partial decode every `partialInterval` of new speech.
/// Pure so it can be tested without a model.
struct UtteranceSegmenter {
    struct Utterance: Equatable {
        var samples: [Float]
        var start: TimeInterval
        var end: TimeInterval
        var isFinal: Bool
    }

    var sampleRate = Double(WhisperKit.sampleRate)
    /// RMS above this counts as speech.
    var speechThreshold: Float = 0.01
    /// Trailing silence that ends an utterance.
    var endSilence: TimeInterval = 0.8
    var partialInterval: TimeInterval = 1
    /// Whisper's window is 30 s; cut before it so nothing is dropped.
    var maxDuration: TimeInterval = 25
    /// Audio kept before speech starts so the first word isn't clipped.
    var preRoll: TimeInterval = 0.3

    private var samples: [Float] = []
    private var start: TimeInterval = 0
    private var hasSpeech = false
    // Counted in samples so repeated chunk durations don't drift below the thresholds.
    private var silence = 0
    private var sinceDecode = 0

    mutating func append(_ chunk: [Float], at timestamp: TimeInterval) -> Utterance? {
        guard !chunk.isEmpty else { return nil }
        if samples.isEmpty { start = timestamp }
        samples += chunk
        let isSpeech = rms(chunk) >= speechThreshold

        guard hasSpeech || isSpeech else {
            // Still waiting for speech: keep only the pre-roll.
            let keep = sampleCount(preRoll)
            if samples.count > keep {
                start += Double(samples.count - keep) / sampleRate
                samples.removeFirst(samples.count - keep)
            }
            return nil
        }
        hasSpeech = true
        silence = isSpeech ? 0 : silence + chunk.count
        sinceDecode += chunk.count

        if silence >= sampleCount(endSilence) || samples.count >= sampleCount(maxDuration) { return flush() }
        if isSpeech, sinceDecode >= sampleCount(partialInterval) {
            sinceDecode = 0
            return utterance(isFinal: false)
        }
        return nil
    }

    /// Ends the current utterance, if it has any speech.
    mutating func flush() -> Utterance? {
        defer {
            samples = []
            hasSpeech = false
            silence = 0
            sinceDecode = 0
        }
        return hasSpeech ? utterance(isFinal: true) : nil
    }

    private func utterance(isFinal: Bool) -> Utterance {
        Utterance(samples: samples, start: start, end: start + Double(samples.count) / sampleRate, isFinal: isFinal)
    }

    private func sampleCount(_ seconds: TimeInterval) -> Int { Int((seconds * sampleRate).rounded()) }

    private func rms(_ x: [Float]) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }
}

/// Loaded pipelines, shared across sources and meetings so the model loads once per process.
/// WhisperKit runs concurrent `transcribe` calls on one instance itself (`concurrentWorkerCount`), so sharing is safe.
private actor WhisperModels {
    static let shared = WhisperModels()
    private var pipelines: [String: Task<LoadedWhisper, Error>] = [:]

    func load(_ model: String) async throws -> LoadedWhisper {
        if let existing = pipelines[model] { return try await existing.value }
        let task = Task {
            let folder = URL.applicationSupportDirectory.appending(path: "Scribe/WhisperKit", directoryHint: .isDirectory)
            let config = WhisperKitConfig(model: model, downloadBase: folder, verbose: false, load: true, download: true)
            return LoadedWhisper(kit: try await WhisperKit(config))
        }
        pipelines[model] = task
        do {
            return try await task.value
        } catch {
            pipelines[model] = nil
            throw error
        }
    }
}

private struct LoadedWhisper: @unchecked Sendable {
    let kit: WhisperKit

    func transcribe(_ samples: [Float], options: DecodingOptions) async throws -> String {
        try await kit.transcribe(audioArray: samples, decodeOptions: options)
            .flatMap(\.segments)
            // Whisper invents text ("Thank you.") over near-silence; drop segments it thinks aren't speech.
            .filter { $0.noSpeechProb < 0.6 }
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

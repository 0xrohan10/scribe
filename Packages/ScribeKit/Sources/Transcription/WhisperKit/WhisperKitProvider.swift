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

    /// Large-v3 turbo, quantized: near large-v3 accuracy at a fraction of the size, fast enough to keep up live.
    public static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"

    public func prepare() async throws {
        _ = try await WhisperModels.shared.load(model)
    }

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
                    // The last final line, so each utterance is decoded with what was just said as context.
                    var previous = ""

                    func emit(_ utterance: UtteranceSegmenter.Utterance) async throws {
                        let text = try await whisper.transcribe(utterance.samples, options: options, prompt: previous)
                        if !text.isEmpty {
                            continuation.yield(
                                TranscriptSegment(
                                    id: segmentID, speaker: speaker, text: text,
                                    start: utterance.start, end: utterance.end, isFinal: utterance.isFinal))
                        }
                        if utterance.isFinal {
                            segmentID = UUID()
                            if !text.isEmpty { previous = text }
                        }
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
    /// Speech is RMS this many times above the noise floor, clamped to `speechRMS`.
    var speechRatio: Float = 3
    var speechRMS: ClosedRange<Float> = 0.003...0.03
    /// The noise floor is the quietest chunk in this window.
    var floorWindow: TimeInterval = 10
    /// Trailing silence that ends an utterance.
    var endSilence: TimeInterval = 1
    /// Shorter utterances keep listening through pauses; Whisper does badly on 1 s clips with no context.
    var minDuration: TimeInterval = 3
    var partialInterval: TimeInterval = 1
    /// Whisper's window is 30 s; cut before it so nothing is dropped.
    var maxDuration: TimeInterval = 25
    /// Audio kept before speech starts so the first word isn't clipped.
    var preRoll: TimeInterval = 0.3

    private var samples: [Float] = []
    /// Recent chunk levels and sizes, for the noise floor.
    private var levels: [(rms: Float, count: Int)] = []
    private var start: TimeInterval = 0
    private var hasSpeech = false
    // Counted in samples so repeated chunk durations don't drift below the thresholds.
    private var silence = 0
    private var sinceDecode = 0

    mutating func append(_ chunk: [Float], at timestamp: TimeInterval) -> Utterance? {
        guard !chunk.isEmpty else { return nil }
        if samples.isEmpty { start = timestamp }
        samples += chunk
        let isSpeech = isSpeech(chunk)

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

        let endsOnPause = silence >= sampleCount(endSilence) && samples.count >= sampleCount(minDuration)
        if endsOnPause || samples.count >= sampleCount(maxDuration) { return flush() }
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

    /// The upper clamp means a stream that opens mid-sentence, with no quiet chunk yet, still counts as speech.
    private mutating func isSpeech(_ chunk: [Float]) -> Bool {
        let level = rms(chunk)
        levels.append((level, chunk.count))
        var total = levels.reduce(0) { $0 + $1.count }
        while total - levels[0].count >= sampleCount(floorWindow) {
            total -= levels.removeFirst().count
        }
        let floor = levels.map(\.rms).min()!
        return level >= min(max(floor * speechRatio, speechRMS.lowerBound), speechRMS.upperBound)
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

struct LoadedWhisper: @unchecked Sendable {
    let kit: WhisperKit

    func transcribe(_ samples: [Float], options: DecodingOptions, prompt: String) async throws -> String {
        var options = options
        if !prompt.isEmpty, let tokenizer = kit.tokenizer {
            // Whisper allows about 224 prompt tokens; the tail of the last line is the useful part.
            options.promptTokens = Array(
                tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }.suffix(200))
        }
        let text = try await kit.transcribe(audioArray: samples, decodeOptions: options).map(\.text).joined()
        return Self.removingTags(text)
    }

    /// Drops the non-speech tags Whisper emits, like "[BLANK_AUDIO]", "[Music]" or "( in foreign language )".
    static func removingTags(_ text: String) -> String {
        text.replacing(/\[[^\]]*\]|\([^)]*\)/, with: "")
            .replacing(/\s{2,}/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

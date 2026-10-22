@preconcurrency import AVFAudio
import Core
import CoreMedia
import Foundation
import Speech
import os

/// On-device transcription with `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+).
/// Downloads the locale's model on first use.
public struct SpeechAnalyzerProvider: TranscriptionProvider {
    public let id = "speech-analyzer"
    public let locale: Locale
    public let vocabulary: [String]

    public init(locale: Locale = .current, vocabulary: [String] = []) {
        self.locale = locale
        self.vocabulary = vocabulary
    }

    public static var isSupported: Bool {
        if #available(macOS 26, *) { SpeechTranscriber.isAvailable } else { false }
    }

    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        guard #available(macOS 26, *) else {
            return AsyncThrowingStream { $0.finish(throwing: ProviderError.unavailable(id)) }
        }
        return SpeechAnalyzerEngine(locale: locale, vocabulary: vocabulary).transcribe(audio)
    }
}

public enum SpeechAnalyzerError: Error, LocalizedError {
    case unsupportedLocale(Locale)
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let l): "On-device transcription doesn't support \(l.identifier)."
        case .noAudioFormat: "SpeechAnalyzer has no compatible audio format."
        }
    }
}

@available(macOS 26, *)
private struct SpeechAnalyzerEngine {
    let locale: Locale
    let vocabulary: [String]

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(audio, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ audio: AsyncStream<AudioChunk>, _ out: AsyncThrowingStream<TranscriptSegment, Error>.Continuation) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechAnalyzerError.unsupportedLocale(locale)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechAnalyzerError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        // The stream carries a single source, so the speaker is fixed once the first chunk arrives.
        let speaker = OSAllocatedUnfairLock(initialState: Speaker.them)

        // The reader is a child task, so it's cancelled whenever feeding throws or this task is cancelled.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // Volatile results update the partial segment. Reuse one id until it is final.
                var pendingID = UUID()
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    out.yield(
                        TranscriptSegment(
                            id: pendingID, speaker: speaker.withLock { $0 }, text: text,
                            start: result.range.start.seconds, end: result.range.end.seconds, isFinal: result.isFinal))
                    if result.isFinal { pendingID = UUID() }
                }
            }

            do {
                try await analyzer.start(inputSequence: inputs)
                let converter = PCMConverter(to: format)
                var first = true
                for await chunk in audio {
                    if first { speaker.withLock { $0 = chunk.source.speaker } }
                    guard let buffer = converter.convert(chunk) else { continue }
                    // Anchor the analyzer's timeline to the session clock once; later buffers are assumed contiguous.
                    let start = first ? CMTime(seconds: chunk.timestamp, preferredTimescale: 1_000_000) : nil
                    inputContinuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
                    first = false
                }
                inputContinuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                inputContinuation.finish()
                await analyzer.cancelAndFinishNow()
                throw error
            }
            try await group.waitForAll()
        }
    }
}

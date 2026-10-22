import Core
import Foundation
import Testing

@testable import Transcription

@Suite struct CohereTranscriptionTests {
    private let provider = CohereTranscriptionProvider(config: .init())

    @Test func defaultsToMLXCheckpointAndEnglish() {
        #expect(provider.model == CohereTranscriptionProvider.defaultModel)
        #expect(provider.language == "en")
        let custom = CohereTranscriptionProvider(config: .init(model: "example/cohere-mlx"), language: "fr")
        #expect(custom.model == "example/cohere-mlx")
        #expect(custom.language == "fr")
    }

    @Test func flushesShortSpeechWithSourceAndSessionTimestamps() async throws {
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        input.yield(AudioChunk(source: .mic, pcm: .init(repeating: 0.1, count: 8000), sampleRate: 16_000, timestamp: 12))
        input.finish()

        var segments: [TranscriptSegment] = []
        for try await segment in provider.transcribe(audio, decode: { samples in
            #expect(samples.count == 8000)
            return "  Hello world.\n"
        }) { segments.append(segment) }

        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        #expect(segment.text == "Hello world.")
        #expect(segment.speaker == .me)
        #expect(segment.start == 12)
        #expect(segment.end == 12.5)
        #expect(segment.isFinal)
    }

    @Test func finalReplacesPartialEvenWhenFinalTextIsEmpty() async throws {
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        let output = provider.transcribe(audio) { samples in samples.count == 48_000 ? "Draft" : "" }
        var iterator = output.makeAsyncIterator()
        for i in 0..<30 {
            input.yield(AudioChunk(source: .system, pcm: .init(repeating: 0.1, count: 1600), sampleRate: 16_000, timestamp: 5 + Double(i) / 10))
        }
        let partial = try #require(try await iterator.next())
        #expect(!partial.isFinal)
        #expect(partial.text == "Draft")
        input.yield(AudioChunk(source: .system, pcm: .init(repeating: 0.1, count: 1600), sampleRate: 16_000, timestamp: 8))
        input.finish()
        let final = try #require(try await iterator.next())
        #expect(final.isFinal)
        #expect(final.id == partial.id)
        #expect(final.speaker == .them)
        #expect(final.start == 5)
        #expect(abs(final.end - 8.1) < 0.001)
        #expect(final.text.isEmpty)
        #expect(try await iterator.next() == nil)
    }

    @Test func silenceDoesNotInvokeModel() async throws {
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        input.yield(AudioChunk(source: .system, pcm: .init(repeating: 0, count: 16_000), sampleRate: 16_000, timestamp: 0))
        input.finish()
        for try await _ in provider.transcribe(audio, decode: { _ in
            Issue.record("Silence must not be sent to the model")
            return "Hallucination"
        }) { Issue.record("Silence must not emit a segment") }
    }

    @Test func propagatesDecodeFailureAndStopsReadingAudio() async {
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        // Leave capture open: an inference failure must cancel the reader rather than wait for capture to end.
        defer { input.finish() }
        for i in 0..<30 {
            input.yield(AudioChunk(source: .mic, pcm: .init(repeating: 0.1, count: 1600), sampleRate: 16_000, timestamp: Double(i) / 10))
        }
        await #expect(throws: ProviderError.unavailable("test model")) {
            for try await _ in provider.transcribe(audio, decode: { _ in throw ProviderError.unavailable("test model") }) {}
        }
    }
}

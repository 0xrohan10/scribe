import AVFAudio
import Core
import Foundation
import Testing

@testable import Transcription

@Suite struct TranscriptionTests {
    @Test func fakeEmitsPartialThenFinalWithSameID() async throws {
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        for i in 0..<8 {
            input.yield(AudioChunk(source: .system, pcm: .init(repeating: 0, count: 8000), sampleRate: 16000, timestamp: 10 + Double(i) / 2))
        }
        input.finish()

        var segments: [TranscriptSegment] = []
        for try await s in FakeTranscriptionProvider(segmentDuration: 4).transcribe(audio) { segments.append(s) }
        #expect(segments.map(\.isFinal) == [false, true])
        #expect(segments[0].id == segments[1].id)
        #expect(segments[1].speaker == .them)
        #expect(segments[1].start == 10)
    }

    @Test func stubsFailWithNotImplemented() async {
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        input.finish()
        await #expect(throws: ProviderError.notImplemented("deepgram")) {
            for try await _ in DeepgramProvider(config: .init()).transcribe(audio) {}
        }
    }

    @Test func converterResamples() throws {
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let converter = PCMConverter(to: target)
        var frames = 0
        for i in 0..<10 {
            let chunk = AudioChunk(source: .mic, pcm: (0..<1600).map { sin(Float(i * 1600 + $0) / 10) * 0.5 }, sampleRate: 16_000, timestamp: 0)
            let buffer = try #require(converter.convert(chunk))
            #expect(buffer.format == target)
            frames += Int(buffer.frameLength)
        }
        // The resampler holds back a few priming frames, but nothing accumulates across a stream.
        #expect(abs(frames - 48_000) < 200)
    }
}

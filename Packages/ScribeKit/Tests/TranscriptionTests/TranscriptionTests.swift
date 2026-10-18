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

    @Test func segmenterEmitsPartialsThenFinalOnSilence() {
        var segmenter = UtteranceSegmenter()
        let speech = [Float](repeating: 0.1, count: 1600), silence = [Float](repeating: 0, count: 1600)
        var out: [UtteranceSegmenter.Utterance] = []
        var t = 5.0
        for chunk in Array(repeating: silence, count: 10) + Array(repeating: speech, count: 25) + Array(repeating: silence, count: 10) {
            if let u = segmenter.append(chunk, at: t) { out.append(u) }
            t += 0.1
        }
        #expect(out.map(\.isFinal) == [false, false, true])
        // Leading silence is trimmed to the 0.3 s pre-roll; the final ends after 0.8 s of trailing silence.
        #expect(abs(out[2].start - 5.7) < 0.001)
        #expect(abs(out[2].end - 9.3) < 0.001)
        #expect(segmenter.flush() == nil)
    }

    @Test func segmenterCutsLongSpeechAndFlushesTail() {
        var segmenter = UtteranceSegmenter()
        let speech = [Float](repeating: 0.1, count: 16000)
        var finals = 0
        for i in 0..<30 where segmenter.append(speech, at: Double(i))?.isFinal == true { finals += 1 }
        #expect(finals == 1)
        #expect(segmenter.flush()?.isFinal == true)
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

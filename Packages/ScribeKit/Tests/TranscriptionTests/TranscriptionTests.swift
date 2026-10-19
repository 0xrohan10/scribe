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
        // Leading silence is trimmed to the 0.3 s pre-roll; the final ends after 1 s of trailing silence.
        #expect(abs(out[2].start - 5.7) < 0.001)
        #expect(abs(out[2].end - 9.5) < 0.001)
        #expect(segmenter.flush() == nil)
    }

    @Test func segmenterKeepsShortUtterancesOpenThroughPauses() {
        var segmenter = UtteranceSegmenter()
        let speech = [Float](repeating: 0.1, count: 1600), silence = [Float](repeating: 0, count: 1600)
        // 0.5 s of speech, then a 1.2 s pause: too short to stand alone, so it waits for more.
        for (i, chunk) in (Array(repeating: speech, count: 5) + Array(repeating: silence, count: 12)).enumerated() {
            #expect(segmenter.append(chunk, at: Double(i) / 10)?.isFinal != true)
        }
        #expect(segmenter.flush()?.isFinal == true)
    }

    @Test func segmenterHearsSpeechAboveSteadyNoise() {
        var segmenter = UtteranceSegmenter()
        let noise = [Float](repeating: 0.02, count: 1600), speech = [Float](repeating: 0.1, count: 1600)
        var t = 0.0
        for _ in 0..<50 {
            // A fixed 0.01 threshold would call this noise speech; the floor learns it isn't.
            #expect(segmenter.append(noise, at: t) == nil)
            t += 0.1
        }
        var out: [UtteranceSegmenter.Utterance] = []
        for chunk in Array(repeating: speech, count: 20) + Array(repeating: noise, count: 20) {
            if let u = segmenter.append(chunk, at: t) { out.append(u) }
            t += 0.1
        }
        #expect(out.last?.isFinal == true)
    }

    @Test func decodeQueueKeepsFinalsAndOnlyTheNewestPartial() {
        func u(_ start: TimeInterval, final: Bool) -> UtteranceSegmenter.Utterance {
            .init(samples: [], start: start, end: start + 1, isFinal: final)
        }
        var queue = DecodeQueue()
        queue.push(u(0, final: false))
        queue.push(u(1, final: false))
        queue.push(u(2, final: true))
        queue.push(u(3, final: false))
        queue.push(u(4, final: false))
        queue.push(u(5, final: true))
        // Partials superseded while Whisper was busy are skipped; no final is ever dropped.
        #expect(queue.pending.map(\.start) == [2, 5])
        queue.push(u(6, final: false))
        #expect(queue.pop()?.start == 2)
        #expect(queue.pending.map(\.start) == [5, 6])
    }

    @Test func removesWhisperTags() {
        #expect(LoadedWhisper.removingTags("[BLANK_AUDIO]") == "")
        #expect(LoadedWhisper.removingTags("( in foreign language )") == "")
        #expect(LoadedWhisper.removingTags("So [Music] that's it (laughs).") == "So that's it .")
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

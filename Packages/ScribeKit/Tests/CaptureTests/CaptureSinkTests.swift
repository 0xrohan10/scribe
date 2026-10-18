@preconcurrency import AVFAudio
import Core
import Foundation
import Testing

@testable import Capture

@Suite struct CaptureSinkTests {
    /// 0.1 s of 48 kHz stereo, like a typical output device.
    private func stereoBuffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for ch in 0..<2 {
            for i in 0..<4800 { buffer.floatChannelData![ch][i] = sin(Float(i) / 10) * 0.5 }
        }
        return buffer
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID()).m4a")
    }

    @Test func normalizesTo16kMonoAndWritesRecording() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = SessionClock(originHostTime: 1_000)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let sink = try CaptureSink(source: .system, clock: clock, recordingTo: url, continuation: continuation)
        let buffer = try stereoBuffer()

        for _ in 0..<100 { sink.consume(buffer, hostTime: 1_000) }  // 10 s
        sink.finish()
        var chunks: [AudioChunk] = []
        for await chunk in stream { chunks.append(chunk) }

        #expect(chunks.allSatisfy { $0.source == .system && $0.sampleRate == 16_000 && $0.timestamp == 0 })
        // 10 s at 16 kHz. The resampler holds back a few hundred frames, but nothing accumulates.
        #expect(abs(chunks.map(\.pcm.count).reduce(0, +) - 160_000) < 300)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(abs(Double(file.length) / 16_000 - 10) < 0.05)
    }

    /// The actor's `stop()` can call `finish()` while a last tap callback is still in `consume()`.
    /// Run with `swift test --sanitize=thread` to catch races on the file.
    @Test func finishWhileCapturingLeavesReadableRecording() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let sink = try CaptureSink(source: .mic, clock: SessionClock(), recordingTo: url, continuation: continuation)
        let buffer = try stereoBuffer()

        let (consumed, consumedContinuation) = AsyncStream.makeStream(of: Void.self)
        Thread {
            for i in 0..<200 {
                sink.consume(buffer, hostTime: mach_absolute_time())
                if i == 10 { consumedContinuation.finish() }
            }
        }.start()
        for await _ in consumed {}
        sink.finish()
        for await _ in stream {}

        #expect(try AVAudioFile(forReading: url).length > 0)
    }
}

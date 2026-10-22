@preconcurrency import AVFAudio
import Core
import Foundation

public enum CaptureError: Error, LocalizedError {
    case noInputDevice
    case coreAudio(String, OSStatus)
    case noMatchingProcesses([String])
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .coreAudio(let what, let status): "\(what) failed (OSStatus \(status))."
        case .noMatchingProcesses(let ids): "None of \(ids.joined(separator: ", ")) is playing audio."
        case .unsupportedFormat: "The audio format isn't supported."
        }
    }
}

/// Normalizes captured buffers to 16 kHz mono Float32 and yields `AudioChunk`s.
/// Writes an m4a only when the caller supplies a recording URL (for diagnostic tools).
///
/// `consume` runs on the capture thread (the engine tap or the IOProc queue), which alone owns `converter`.
/// `finish` runs on the owning actor and can overlap a last `consume`, so `fileLock` protects `file`.
/// These access rules make `@unchecked Sendable` safe.
final class CaptureSink: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private let source: AudioChunk.Source
    private let clock: SessionClock
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let fileLock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?

    init(source: AudioChunk.Source, clock: SessionClock, recordingTo url: URL?, continuation: AsyncStream<AudioChunk>.Continuation) throws {
        self.source = source
        self.clock = clock
        self.continuation = continuation
        if let url {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard buffer.frameLength > 0, let out = normalize(buffer), out.frameLength > 0 else { return }
        fileLock.withLock { try? file?.write(from: out) }
        let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        continuation.yield(AudioChunk(source: source, pcm: samples, sampleRate: Self.sampleRate, timestamp: clock.seconds(atHostTime: hostTime)))
    }

    func finish() {
        continuation.finish()
        fileLock.withLock { file = nil }  // AVAudioFile finalizes the m4a on deinit.
    }

    private func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }
}

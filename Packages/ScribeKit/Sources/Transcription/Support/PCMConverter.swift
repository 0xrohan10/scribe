@preconcurrency import AVFAudio
import Core
import Foundation

/// Converts `AudioChunk` samples into `AVAudioPCMBuffer`s in whatever format a provider needs.
/// Not thread-safe; use from one task.
final class PCMConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(to outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard !chunk.pcm.isEmpty,
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: chunk.sampleRate, channels: 1, interleaved: false),
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.pcm.count))
        else { return nil }
        input.frameLength = input.frameCapacity
        chunk.pcm.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        if format == outputFormat { return input }

        if inputFormat != format {
            converter = AVAudioConverter(from: format, to: outputFormat)
            inputFormat = format
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(input.frameLength) * outputFormat.sampleRate / format.sampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : output
    }
}

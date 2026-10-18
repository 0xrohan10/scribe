@preconcurrency import AVFAudio
import Core
import Foundation

/// The local user's microphone via `AVAudioEngine`.
public actor MicrophoneSource: AudioSource {
    public nonisolated let source = AudioChunk.Source.mic

    private var engine: AVAudioEngine?
    private var sink: CaptureSink?

    public init() {}

    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func start(clock: SessionClock, recordingTo url: URL?) throws -> AsyncStream<AudioChunk> {
        precondition(engine == nil, "MicrophoneSource already started")
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(1000))
        let sink = try CaptureSink(source: .mic, clock: clock, recordingTo: url, continuation: continuation)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(sink))
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.finish()
            throw error
        }
        self.engine = engine
        self.sink = sink
        return stream
    }

    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        sink?.finish()
        sink = nil
    }

    /// Built outside actor isolation: the tap fires on a realtime audio thread, and a closure formed inside
    /// the actor would inherit its isolation and trap when called there.
    private nonisolated static func tapBlock(_ sink: CaptureSink) -> AVAudioNodeTapBlock {
        { buffer, time in sink.consume(buffer, hostTime: time.hostTime) }
    }
}

@preconcurrency import AVFAudio
import CoreAudio
import Core
import Foundation

/// Meeting audio via a Core Audio process tap (macOS 14.2+) on a private aggregate device.
///
/// Pipeline: `CATapDescription` → `AudioHardwareCreateProcessTap` → aggregate device containing the tap
/// (with the default output as main sub-device for clocking) → IOProc → `CaptureSink`.
/// The first tap creation triggers the "System Audio Recording" TCC prompt (`NSAudioCaptureUsageDescription`).
/// If the user denies it the tap still runs but delivers silence; `SystemAudioPermission` detects that.
public actor SystemAudioSource: AudioSource {
    public nonisolated let source = AudioChunk.Source.system
    public nonisolated let scope: SystemAudioScope

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sink: CaptureSink?
    private let queue = DispatchQueue(label: "scribe.system-audio", qos: .userInteractive)

    public init(scope: SystemAudioScope = .allApps) {
        self.scope = scope
    }

    public func start(clock: SessionClock, recordingTo url: URL?) throws -> AsyncStream<AudioChunk> {
        precondition(sink == nil, "SystemAudioSource already started")
        do {
            return try startTap(clock: clock, url: url)
        } catch {
            teardown()
            throw error
        }
    }

    public func stop() {
        teardown()
    }

    private func startTap(clock: SessionClock, url: URL?) throws -> AsyncStream<AudioChunk> {
        let description: CATapDescription
        switch scope {
        case .allApps:
            let ownProcess = AudioObject.processObject(pid: getpid()).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess)
        case .bundleIDs(let prefixes):
            let processes = try AudioObject.processObjects(bundleIDPrefixes: prefixes)
            guard !processes.isEmpty else { throw CaptureError.noMatchingProcesses(prefixes) }
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.uuid = UUID()
        description.name = "Scribe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try AudioObject.check(AudioHardwareCreateProcessTap(description, &tapID), "Creating process tap")

        let outputUID = try AudioObject.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribe Tap",
            kAudioAggregateDeviceUIDKey: "scribe.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        try AudioObject.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating aggregate device")

        var asbd = try AudioObject.read(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.unsupportedFormat }

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(1000))
        let sink = try CaptureSink(source: .system, clock: clock, recordingTo: url, continuation: continuation)
        self.sink = sink

        try AudioObject.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, Self.ioBlock(sink: sink, format: format)),
            "Creating IOProc")
        try AudioObject.check(AudioDeviceStart(aggregateID, procID), "Starting aggregate device")
        return stream
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        sink?.finish()
        sink = nil
    }

    /// Nonisolated for the same reason as `MicrophoneSource.tapBlock`: it runs on `queue`, not the actor.
    private nonisolated static func ioBlock(sink: CaptureSink, format: AVAudioFormat) -> AudioDeviceIOBlock {
        { _, inputData, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            sink.consume(buffer, hostTime: inputTime.pointee.mHostTime)
        }
    }
}

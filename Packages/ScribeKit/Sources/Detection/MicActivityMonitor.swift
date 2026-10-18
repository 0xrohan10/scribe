import CoreAudio
import Foundation

public protocol MicActivitySignal: Sendable {
    /// Emits the current state immediately, then every change.
    func changes() -> AsyncStream<Bool>
}

/// Watches `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device, i.e. "some app is
/// using the mic", and follows default-input changes.
public struct MicActivityMonitor: MicActivitySignal {
    public init() {}

    public func changes() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let listener = Listener { continuation.yield($0) }
            listener.start()
            continuation.onTermination = { _ in listener.stop() }
        }
    }
}

/// All state is confined to `queue`, which is also where Core Audio delivers property callbacks.
private final class Listener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "scribe.mic-activity")
    private let onChange: @Sendable (Bool) -> Void
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var last: Bool?
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var runningBlock: AudioObjectPropertyListenerBlock?

    private static let defaultInputAddress = address(kAudioHardwarePropertyDefaultInputDevice)
    private static let runningAddress = address(kAudioDevicePropertyDeviceIsRunningSomewhere)

    init(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebind() }
            defaultDeviceBlock = block
            var addr = Self.defaultInputAddress
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            rebind()
        }
    }

    func stop() {
        queue.async { [self] in
            unbindDevice()
            if let block = defaultDeviceBlock {
                var addr = Self.defaultInputAddress
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            }
            defaultDeviceBlock = nil
        }
    }

    private func rebind() {
        unbindDevice()
        var addr = Self.defaultInputAddress
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var id = AudioObjectID(kAudioObjectUnknown)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
            id != kAudioObjectUnknown
        else {
            publish(false)
            return
        }
        device = id
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.publishCurrent() }
        runningBlock = block
        var runningAddr = Self.runningAddress
        AudioObjectAddPropertyListenerBlock(id, &runningAddr, queue, block)
        publishCurrent()
    }

    private func unbindDevice() {
        if let block = runningBlock, device != kAudioObjectUnknown {
            var addr = Self.runningAddress
            AudioObjectRemovePropertyListenerBlock(device, &addr, queue, block)
        }
        runningBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func publishCurrent() {
        var addr = Self.runningAddress
        var size = UInt32(MemoryLayout<UInt32>.size)
        var running: UInt32 = 0
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
        publish(status == noErr && running != 0)
    }

    private func publish(_ value: Bool) {
        guard value != last else { return }
        last = value
        onChange(value)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

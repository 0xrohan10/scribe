import CoreAudio
import Foundation

/// Thin helpers over `AudioObjectGetPropertyData`.
enum AudioObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CaptureError.coreAudio(what, status) }
    }

    static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "Reading property \(fourCC(selector))")
        return value
    }

    static func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "Reading property \(fourCC(selector))")
        return value?.takeRetainedValue() as String? ?? ""
    }

    static func readIDs(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "Sizing property \(fourCC(selector))")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids), "Reading property \(fourCC(selector))")
        return ids
    }

    /// The Core Audio process object for a pid, or nil if that process has no audio client.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Process objects whose bundle ID starts with any of `prefixes`.
    static func processObjects(bundleIDPrefixes prefixes: [String]) throws -> [AudioObjectID] {
        try readIDs(system, kAudioHardwarePropertyProcessObjectList).filter { object in
            let bundleID = (try? readString(object, kAudioProcessPropertyBundleID)) ?? ""
            return prefixes.contains { bundleID.hasPrefix($0) }
        }
    }

    static func defaultOutputDeviceUID() throws -> String {
        let device = try read(system, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioDeviceID(kAudioObjectUnknown))
        return try readString(device, kAudioDevicePropertyDeviceUID)
    }

    private static func fourCC(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(v)"
    }
}

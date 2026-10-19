import Foundation

/// The "System Audio Recording" TCC permission that process taps need.
///
/// There's no public API for it: a denied tap still runs and just delivers silence. So this goes through
/// the private TCC framework (the same `kTCCServiceAudioCapture` service System Settings toggles), loaded
/// lazily so a missing symbol degrades to `.unknown` rather than crashing.
public enum SystemAudioPermission {
    public enum Status: Sendable { case granted, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture"
    /// An immutable handle, so sharing it across threads is fine.
    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    public static var status: Status {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown  // Not asked yet.
        }
    }

    /// Shows the system prompt if the user hasn't been asked yet; otherwise returns the stored answer.
    /// Without the SPI it only reports a known denial, so a missing symbol doesn't read as "off".
    public static func request() async -> Bool {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return status != .denied }
        let request = unsafeBitCast(symbol, to: Request.self)
        return await withCheckedContinuation { continuation in
            request(service as CFString, nil) { continuation.resume(returning: $0) }
        }
    }
}

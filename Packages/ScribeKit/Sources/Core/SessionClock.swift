import Darwin
import Foundation

/// The transcript clock. Every audio chunk, segment and note is stamped in seconds since `originHostTime`.
public struct SessionClock: Sendable, Hashable {
    public let originHostTime: UInt64

    public init(originHostTime: UInt64 = mach_absolute_time()) {
        self.originHostTime = originHostTime
    }

    public func seconds(atHostTime hostTime: UInt64) -> TimeInterval {
        let delta = Int64(bitPattern: hostTime &- originHostTime)
        return Double(delta) * Self.nanosPerTick / 1_000_000_000
    }

    public var now: TimeInterval { seconds(atHostTime: mach_absolute_time()) }

    private static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()
}

extension TimeInterval {
    /// `m:ss` or `h:mm:ss`, for transcript and note timestamps.
    public var clockString: String {
        let total = Int(max(0, self))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

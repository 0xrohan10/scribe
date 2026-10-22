import Core
import Foundation

/// Detects speaker audio leaking into the microphone without changing either recording.
/// Adapted from Hex's meeting_echo.rs (MIT); see THIRD_PARTY_NOTICES.md.
struct EchoEnvelope {
    enum Signal { case bleed, local }

    private static let frameMilliseconds = 20
    private static let silence: Float = -100
    private var system = Track()
    private var microphone = Track()
    private var couplings: [Int: Coupling] = [:]

    mutating func append(_ chunk: AudioChunk) {
        guard chunk.timestamp.isFinite, chunk.timestamp >= 0,
              chunk.sampleRate.isFinite, chunk.sampleRate > 0 else { return }
        switch chunk.source {
        case .system: system.append(chunk)
        case .mic: microphone.append(chunk)
        }
    }

    func covered(_ source: AudioChunk.Source) -> TimeInterval {
        (source == .system ? system : microphone).expectedTime
    }

    /// Preserves local speech, including a short local phrase during a long remote turn.
    mutating func assess(start: TimeInterval, end: TimeInterval) -> Signal? {
        guard start.isFinite, end.isFinite, end > start, start >= 0 else { return nil }
        let first = Int(start * 50), last = max(first + 1, Int(end * 50))
        guard microphone.frames.count > first, last <= microphone.frames.count + 1 else { return nil }
        let contextStart = max(0, first - 250)
        let contextEnd = max(last, min(last + 250, microphone.frames.count))
        guard let floor = Self.percentile((contextStart..<contextEnd).compactMap { microphone.recorded(at: $0) }, 0.1) else { return nil }
        let active = (first..<last).filter { microphone.at($0) >= floor + 6 }

        guard let coupling = coupling(first: first, last: last), coupling.correlation >= 0.2 else {
            return active.count >= 10 ? .local : nil
        }
        func remote(at frame: Int) -> Float {
            let source = frame - coupling.lag
            let tail = (0...8).map { system.at(source - $0) - Float($0) * 1.5 }
            return max(tail.max() ?? Self.silence, system.at(source + 1) - 1.5)
        }
        func gain(in range: Range<Int>, minimum: Int) -> Float? {
            let loud = range.map { system.at($0 - coupling.lag) }.filter { $0 > -55 }
            guard loud.count >= minimum, let threshold = Self.percentile(loud, 0.5) else { return nil }
            let differences = range.filter { system.at($0 - coupling.lag) >= threshold }
                .map { microphone.at($0) - remote(at: $0) }
            return Self.percentile(differences, 0.35)
        }
        // Estimate from both sides so a volume change does not make local speech look like echo.
        let outside = [gain(in: contextStart..<first, minimum: 10), gain(in: last..<contextEnd, minimum: 10)].compactMap { $0 }.max()
        guard let bleedGain = outside ?? gain(in: contextStart..<contextEnd, minimum: 1) else { return nil }
        let local = active.filter { microphone.at($0) > max(bleedGain + remote(at: $0), floor) + 9 }
        if active.count < 10 {
            let remoteFrames = (first..<last).filter { remote(at: $0) > -55 }.count
            return local.isEmpty && remoteFrames * 2 >= last - first ? .bleed : nil
        }

        var burst = 0, from = 0
        for (to, frame) in local.enumerated() {
            while local[from] <= frame - 50 { from += 1 }
            burst = max(burst, to + 1 - from)
        }
        let share = Float(local.count) / Float(active.count)
        if share >= 0.5 { return .local }
        if share <= 0.2, burst < 25 { return .bleed }
        return nil
    }

    private struct Coupling {
        var correlation: Float
        var lag: Int
    }

    private mutating func coupling(first: Int, last: Int) -> Coupling? {
        // One estimate per ten-second block once its surrounding audio is complete.
        let block = (first + last) / 2 / 500
        if let cached = couplings[block] { return cached }
        let center = block * 500 + 250
        let end = center + 3_000
        var best: Coupling?
        for lag in -15...30 {
            let pairs = (max(0, center - 3_000)..<min(end, microphone.frames.count))
                .compactMap { frame -> (Float, Float)? in
                    guard let microphone = microphone.recorded(at: frame) else { return nil }
                    let system = system.at(frame - lag)
                    return system > -55 ? (microphone, system) : nil
                }
            guard pairs.count >= 25 else { continue }
            let correlation = Self.correlation(pairs)
            if correlation > (best?.correlation ?? -.infinity) { best = Coupling(correlation: correlation, lag: lag) }
        }
        if end + 30 <= min(system.frames.count, microphone.frames.count), let best { couplings[block] = best }
        return best
    }

    private struct Track {
        var frames: [Float] = []
        var anchor: TimeInterval = 0
        var rate: Double = 0
        var samplesSinceAnchor = 0
        var sum: Double = 0
        var count = 0

        var expectedTime: TimeInterval { anchor + Double(samplesSinceAnchor) / max(1, rate) }

        mutating func append(_ chunk: AudioChunk) {
            guard !chunk.pcm.isEmpty else { return }
            if rate != chunk.sampleRate || abs(expectedTime - chunk.timestamp) > 0.04 {
                anchor = chunk.timestamp
                rate = chunk.sampleRate
                samplesSinceAnchor = 0
                sum = 0
                count = 0
            }
            let frameLength = max(1, Int(rate * Double(EchoEnvelope.frameMilliseconds) / 1_000))
            for sample in chunk.pcm {
                sum += Double(sample) * Double(sample)
                count += 1
                samplesSinceAnchor += 1
                if count == frameLength {
                    let start = anchor + Double(samplesSinceAnchor - frameLength) / rate
                    let index = Int((start * 50).rounded(.toNearestOrAwayFromZero))
                    // Missing capture is not digital silence: exclude gaps from the noise-floor estimate.
                    if frames.count <= index { frames += repeatElement(Float.nan, count: index + 1 - frames.count) }
                    frames[index] = Float(10 * log10(sum / Double(frameLength) + 1e-10))
                    sum = 0
                    count = 0
                }
            }
        }

        func recorded(at frame: Int) -> Float? {
            guard frames.indices.contains(frame), frames[frame].isFinite else { return nil }
            return frames[frame]
        }

        func at(_ frame: Int) -> Float { recorded(at: frame) ?? EchoEnvelope.silence }
    }

    private static func percentile(_ values: [Float], _ fraction: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[Int((Float(sorted.count - 1) * fraction).rounded())]
    }

    private static func correlation(_ pairs: [(Float, Float)]) -> Float {
        let count = Float(pairs.count)
        let means = pairs.reduce((Float(0), Float(0))) { ($0.0 + $1.0 / count, $0.1 + $1.1 / count) }
        var covariance: Float = 0, varianceX: Float = 0, varianceY: Float = 0
        for (x, y) in pairs {
            let dx = x - means.0, dy = y - means.1
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        let denominator = sqrt(varianceX * varianceY)
        return denominator > .ulpOfOne ? covariance / denominator : 0
    }
}

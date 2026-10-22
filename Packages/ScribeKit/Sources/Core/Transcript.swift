import Foundation

public enum Speaker: String, Sendable, Codable, Hashable {
    case me
    case them
}

public struct TranscriptSegment: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var speaker: Speaker
    public var text: String
    /// Seconds on the session clock.
    public var start: TimeInterval
    public var end: TimeInterval
    /// Partial segments are re-emitted with the same `id` until a final one replaces them.
    public var isFinal: Bool

    public init(id: UUID = UUID(), speaker: Speaker, text: String, start: TimeInterval, end: TimeInterval, isFinal: Bool) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }
}

public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    /// `audio` carries a single source; segments should take their speaker from `chunk.source.speaker`.
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error>
    /// Loads whatever `transcribe` needs (e.g. a local model) so the first meeting doesn't wait on it.
    func prepare() async throws
}

extension TranscriptionProvider {
    public func prepare() async throws {}
}

/// The live transcript: segments ordered by start time, partials replaced in place by id.
public struct Transcript: Sendable, Equatable {
    public private(set) var segments: [TranscriptSegment] = []

    public init(segments: [TranscriptSegment] = []) {
        segments.forEach { upsert($0) }
    }

    public mutating func upsert(_ segment: TranscriptSegment) {
        if let i = segments.firstIndex(where: { $0.id == segment.id }) {
            segments.remove(at: i)
        }
        let insertAt = segments.lastIndex(where: { $0.start <= segment.start }).map { $0 + 1 } ?? 0
        segments.insert(segment, at: insertAt)
    }

    /// Removes a provisional segment when later audio identifies it as speaker echo.
    public mutating func remove(id: UUID) {
        segments.removeAll { $0.id == id }
    }

    /// Rewrites every segment with `vocabulary`'s corrections and returns the ones that changed.
    public mutating func correct(with vocabulary: Vocabulary) -> [TranscriptSegment] {
        var changed: [TranscriptSegment] = []
        for i in segments.indices {
            let text = vocabulary.correct(segments[i].text)
            guard text != segments[i].text else { continue }
            segments[i].text = text
            changed.append(segments[i])
        }
        return changed
    }

    public var isEmpty: Bool { segments.isEmpty }
    public var duration: TimeInterval { segments.map(\.end).max() ?? 0 }

    /// Segments that overlap `[from, to]`.
    public func segments(from: TimeInterval, to: TimeInterval) -> [TranscriptSegment] {
        segments.filter { $0.end >= from && $0.start <= to }
    }

    /// Plain-text rendering used as LLM context: `[m:ss] Me: …`.
    public func formatted(_ subset: [TranscriptSegment]? = nil) -> String {
        (subset ?? segments)
            .filter { !$0.text.isEmpty }
            .map { "[\($0.start.clockString)] \($0.speaker == .me ? "Me" : "Them"): \($0.text)" }
            .joined(separator: "\n")
    }
}

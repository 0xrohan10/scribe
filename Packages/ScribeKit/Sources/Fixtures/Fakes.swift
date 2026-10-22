import Core
import Foundation

/// Real-time silence: a 0.5 s chunk every 0.5 s from `from` until `until` on the session clock, then holds
/// the stream open until `stop()`, like a live source would.
public actor SilentSource: AudioSource {
    public nonisolated let source: AudioChunk.Source
    let from: TimeInterval
    let until: TimeInterval
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var feeder: Task<Void, Never>?

    public init(_ source: AudioChunk.Source, from: TimeInterval = 0, until: TimeInterval = .infinity) {
        self.source = source
        self.from = from
        self.until = until
    }

    public func start(clock: SessionClock, recordingTo url: URL?) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        let (source, from, until) = (source, from, until)
        feeder = Task {
            var t = from
            while t + 0.5 <= until, !Task.isCancelled {
                // Deliver each chunk after its duration has elapsed, like a real capture buffer.
                let wait = t + 0.5 - clock.now
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                continuation.yield(AudioChunk(source: source, pcm: .init(repeating: 0, count: 8000), sampleRate: 16_000, timestamp: t))
                t += 0.5
            }
        }
        return stream
    }

    public func stop() {
        feeder?.cancel()
        continuation?.finish()
    }
}

/// Answers by describing what it was sent, so you can see what reached the model.
/// Summary requests get a JSON summary built from the prompt's transcript and notes.
public struct EchoLLM: LLMProvider {
    public let id = "echo"
    public let capabilities = LLMCapabilities()

    public init() {}

    public func complete(_ req: LLMRequest) -> AsyncThrowingStream<LLMDelta, Error> {
        let text = (req.system ?? "").contains("Reply with only a JSON object") ? Self.summary(req) : Self.answer(req)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.yield(.done(stopReason: "end_turn"))
            continuation.finish()
        }
    }

    private static func answer(_ req: LLMRequest) -> String {
        let transcriptLines = lines(in: req.system ?? "").filter { $0.hasPrefix("[") }
        let question = req.messages.last?.content ?? ""
        return "(echo) “\(question)” with \(transcriptLines.count) transcript lines, \(req.messages.count - 1) earlier messages, \(req.system?.count ?? 0) chars of system prompt."
    }

    private static func summary(_ req: LLMRequest) -> String {
        let input = lines(in: req.messages.last?.content ?? "")
        let transcript = input.filter { $0.hasPrefix("[") && ($0.contains("] Me:") || $0.contains("] Them:")) }
        let notes = input.filter { $0.hasPrefix("★ [") || ($0.hasPrefix("[") && !transcript.contains($0)) }
        let payload: [String: Any] = [
            "overview": "(echo) \(transcript.count) transcript lines and \(notes.count) notes.",
            "decisions": [],
            "actionItems": notes.filter { !$0.hasPrefix("★") }.map { ["task": $0, "owner": "Me"] },
            "openQuestions": transcript.filter { $0.hasSuffix("?") },
            "flagged": notes.filter { $0.hasPrefix("★") },
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func lines(in text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

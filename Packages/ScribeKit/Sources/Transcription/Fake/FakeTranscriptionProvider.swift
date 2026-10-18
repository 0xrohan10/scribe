import Core
import Foundation

/// Emits canned lines paced by the audio it receives (a partial halfway, then a final every
/// `segmentDuration` seconds of audio). Lets the whole pipeline run without a real ASR engine.
public struct FakeTranscriptionProvider: TranscriptionProvider {
    public let id = "fake"
    public let segmentDuration: TimeInterval

    public init(segmentDuration: TimeInterval = 4) {
        self.segmentDuration = segmentDuration
    }

    public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let segmentDuration = segmentDuration
        return AsyncThrowingStream { continuation in
            let task = Task {
                var speaker = Speaker.them
                var segmentID = UUID()
                var start: TimeInterval?
                var end: TimeInterval = 0
                var index = 0
                var sentPartial = false

                func line() -> String {
                    let lines = speaker == .me ? Self.myLines : Self.theirLines
                    return lines[index % lines.count]
                }
                func emit(final: Bool) {
                    let text = final ? line() : line().split(separator: " ").prefix(4).joined(separator: " ") + "…"
                    continuation.yield(TranscriptSegment(id: segmentID, speaker: speaker, text: text, start: start ?? end, end: end, isFinal: final))
                }

                for await chunk in audio {
                    speaker = chunk.source.speaker
                    if start == nil { start = chunk.timestamp }
                    end = chunk.timestamp + chunk.duration
                    let elapsed = end - start!
                    if !sentPartial, elapsed >= segmentDuration / 2 {
                        emit(final: false)
                        sentPartial = true
                    }
                    if elapsed >= segmentDuration {
                        emit(final: true)
                        index += 1
                        segmentID = UUID()
                        start = nil
                        sentPartial = false
                    }
                }
                if sentPartial { emit(final: true) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let theirLines = [
        "Thanks everyone for joining, let's get started with the roadmap review.",
        "The main risk this quarter is the migration to the new billing system.",
        "We decided to ship the beta to ten design partners on Monday.",
        "Can someone own the follow-up with legal about the data processing agreement?",
        "I'm not sure we have budget for the second contractor yet.",
    ]

    static let myLines = [
        "Sounds good, I can take the billing migration plan.",
        "Let's make sure the beta has analytics wired up before Monday.",
        "I'll follow up with legal by Thursday.",
        "What's the latest estimate on the contractor cost?",
    ]
}

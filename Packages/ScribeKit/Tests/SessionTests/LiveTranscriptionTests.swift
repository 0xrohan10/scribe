import Core
import Foundation
import Testing

@testable import Session

private actor RecoveryProbe {
    var calls = 0
    var transcript = Transcript()
    var finished = false
    func next() -> Int { calls += 1; return calls }
    func accept(_ segment: TranscriptSegment) { transcript.upsert(segment) }
    func markFinished() { finished = true }
}

private struct ScriptedRecoveryProvider: TranscriptionProvider {
    let id = "recovery-script"
    let probe: RecoveryProbe
    let script: @Sendable (Int, AsyncStream<AudioChunk>, AsyncThrowingStream<TranscriptSegment, Error>.Continuation) async -> Void

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { out in
            let task = Task { await script(probe.next(), audio, out) }
            out.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite struct LiveTranscriptionTests {
    private func runner(_ provider: ScriptedRecoveryProvider, policy: TranscriptionRecoveryPolicy) -> LiveTranscription {
        LiveTranscription(provider: provider, policy: policy, onAudio: { _ in }, onAudioEnded: {},
                          onSegment: { await provider.probe.accept($0) }, onStatus: { _ in }, onWarning: { _ in })
    }

    private func chunk(at timestamp: TimeInterval = 0, loud: Bool = true) -> AudioChunk {
        AudioChunk(source: .mic, pcm: .init(repeating: loud ? 0.1 : 0, count: 1000), sampleRate: 1000, timestamp: timestamp)
    }

    private func wait(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }

    @Test func speechWithoutResultsRestartsButSilenceDoesNot() async throws {
        for loud in [true, false] {
            let probe = RecoveryProbe()
            let provider = ScriptedRecoveryProvider(probe: probe) { attempt, audio, out in
                for await chunk in audio {
                    if attempt > 1 {
                        out.yield(TranscriptSegment(speaker: .me, text: "Recovered", start: chunk.timestamp,
                                                    end: chunk.timestamp + chunk.duration, isFinal: true))
                    }
                }
                out.finish()
            }
            let recovery = runner(provider, policy: .init(retryDelay: .milliseconds(1), stallTimeout: .milliseconds(60), checkInterval: .milliseconds(5)))
            let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
            let task = Task { await recovery.run(audio) }
            input.yield(chunk(loud: loud))
            if loud {
                try await wait { await !probe.transcript.isEmpty }
                #expect(await probe.calls == 2)
            } else {
                try await Task.sleep(for: .milliseconds(160))
                #expect(await probe.calls == 1)
            }
            input.finish()
            await task.value
        }
    }

    @Test func failuresAreBoundedAndManualRetryGetsAFreshAttempt() async throws {
        let probe = RecoveryProbe()
        let provider = ScriptedRecoveryProvider(probe: probe) { attempt, audio, out in
            if attempt <= 2 { out.finish(throwing: CocoaError(.fileReadUnknown)); return }
            for await chunk in audio {
                out.yield(TranscriptSegment(speaker: .me, text: "Recovered", start: chunk.timestamp,
                                            end: chunk.timestamp + chunk.duration, isFinal: true))
            }
            out.finish()
        }
        let recovery = runner(provider, policy: .init(maximumRetries: 1, retryDelay: .milliseconds(1)))
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        let task = Task { await recovery.run(audio) }
        input.yield(chunk())
        try await wait { await probe.calls == 2 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.calls == 2)
        await recovery.retry()
        try await wait { await !probe.transcript.isEmpty }
        #expect(await probe.calls == 3)
        input.finish()
        await task.value
    }

    @Test func retryKeepsPartialsAndDoesNotReplayTheirAudio() async throws {
        let probe = RecoveryProbe()
        let provider = ScriptedRecoveryProvider(probe: probe) { attempt, audio, out in
            for await chunk in audio {
                if attempt == 1 {
                    out.yield(TranscriptSegment(speaker: .me, text: "Kept partial", start: 0, end: 0.5, isFinal: false))
                    out.finish(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                #expect(chunk.timestamp >= 0.5)
                out.yield(TranscriptSegment(speaker: .me, text: "New words", start: chunk.timestamp,
                                            end: chunk.timestamp + chunk.duration, isFinal: true))
            }
            out.finish()
        }
        let recovery = runner(provider, policy: .init(retryDelay: .milliseconds(1)))
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        let task = Task { await recovery.run(audio) }
        input.yield(chunk())
        try await wait { await probe.transcript.segments.count == 2 }
        input.finish()
        await task.value
        #expect(await probe.transcript.segments.map(\.text) == ["Kept partial", "New words"])
        #expect(await probe.transcript.segments.allSatisfy(\.isFinal))
    }

    @Test func stoppingDuringBackoffDoesNotStartAnotherAttempt() async throws {
        let probe = RecoveryProbe()
        let provider = ScriptedRecoveryProvider(probe: probe) { _, audio, out in
            for await _ in audio { out.finish(throwing: CocoaError(.fileReadUnknown)); return }
            out.finish()
        }
        let recovery = runner(provider, policy: .init(retryDelay: .milliseconds(50)))
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        let task = Task { await recovery.run(audio) }
        input.yield(chunk())
        try await wait { await probe.calls == 1 }
        try await Task.sleep(for: .milliseconds(20))
        await recovery.stopRetrying()
        // Capture can take time to close; a queued retry must not start in that interval.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.calls == 1)
        input.finish()
        await task.value
        #expect(await probe.calls == 1)
    }

    @Test func anUnexpectedSuccessfulEndAlsoRestarts() async throws {
        let probe = RecoveryProbe()
        let provider = ScriptedRecoveryProvider(probe: probe) { attempt, audio, out in
            for await chunk in audio {
                if attempt == 1 { out.finish(); return }
                out.yield(TranscriptSegment(speaker: .me, text: "Recovered", start: chunk.timestamp,
                                            end: chunk.timestamp + chunk.duration, isFinal: true))
            }
            out.finish()
        }
        let recovery = runner(provider, policy: .init(retryDelay: .milliseconds(1)))
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        let task = Task { await recovery.run(audio) }
        input.yield(chunk())
        try await wait { await !probe.transcript.isEmpty }
        #expect(await probe.calls == 2)
        input.finish()
        await task.value
    }

    @Test func retryBufferRetainsOnlyTheMostRecentThirtySeconds() async throws {
        let probe = RecoveryProbe()
        let provider = ScriptedRecoveryProvider(probe: probe) { attempt, audio, out in
            if attempt == 1 {
                var read = 0
                for await _ in audio {
                    read += 1
                    if read == 40 { out.finish(throwing: CocoaError(.fileReadUnknown)); return }
                }
                out.finish()
                return
            }
            for await chunk in audio {
                #expect(chunk.timestamp >= 10)
                out.yield(TranscriptSegment(speaker: .me, text: "Recovered", start: chunk.timestamp,
                                            end: chunk.timestamp + chunk.duration, isFinal: true))
            }
            out.finish()
        }
        let recovery = runner(provider, policy: .init(retryDelay: .milliseconds(1)))
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        let task = Task { await recovery.run(audio) }
        for index in 0..<40 { input.yield(chunk(at: Double(index))) }
        try await wait { await !probe.transcript.isEmpty }
        input.finish()
        await task.value
        #expect(await probe.transcript.segments.count == 30)
    }

    @Test func stoppingWaitsForPartialTextBeingSavedDuringRecovery() async throws {
        let probe = RecoveryProbe()
        let provider = ScriptedRecoveryProvider(probe: probe) { _, audio, out in
            for await _ in audio {
                out.yield(TranscriptSegment(speaker: .me, text: "Kept", start: 0, end: 0.5, isFinal: false))
                out.finish(throwing: CocoaError(.fileReadUnknown))
                return
            }
            out.finish()
        }
        let (saving, startedSaving) = AsyncStream.makeStream(of: Void.self)
        let (saveGate, finishSave) = AsyncStream.makeStream(of: Void.self)
        let recovery = LiveTranscription(provider: provider, policy: .init(retryDelay: .milliseconds(1)),
                                         onAudio: { _ in }, onAudioEnded: {}, onSegment: { segment in
            if segment.isFinal {
                startedSaving.finish()
                for await _ in saveGate {}
            }
            await probe.accept(segment)
        }, onStatus: { _ in }, onWarning: { _ in })
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        let task = Task { await recovery.run(audio); await probe.markFinished() }
        input.yield(chunk())
        for await _ in saving {}
        input.finish()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await !probe.finished)
        finishSave.finish()
        await task.value
        #expect(await probe.transcript.segments.first?.isFinal == true)
    }

    @Test func fractionalSampleDurationsKeepRetryAudioBounded() async throws {
        let probe = RecoveryProbe()
        let provider = ScriptedRecoveryProvider(probe: probe) { attempt, audio, out in
            if attempt == 1 {
                var read = 0
                for await _ in audio {
                    read += 1
                    if read == 400 { out.finish(throwing: CocoaError(.fileReadUnknown)); return }
                }
                out.finish()
                return
            }
            for await chunk in audio {
                out.yield(TranscriptSegment(speaker: .me, text: "Recovered", start: chunk.timestamp,
                                            end: chunk.timestamp + chunk.duration, isFinal: true))
            }
            out.finish()
        }
        let recovery = runner(provider, policy: .init(retryDelay: .milliseconds(1)))
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
        let task = Task { await recovery.run(audio) }
        let samples = [Float](repeating: 0.1, count: 1000)
        for index in 0..<400 {
            input.yield(AudioChunk(source: .mic, pcm: samples, sampleRate: 10_001, timestamp: Double(index * 1000) / 10_001))
        }
        try await wait { await !probe.transcript.isEmpty }
        input.finish()
        await task.value
        let transcript = await probe.transcript
        let first = try #require(transcript.segments.first)
        #expect(transcript.duration - first.start <= 30.001)
        #expect(abs(transcript.duration - 400_000.0 / 10_001) < 0.001)
    }
}

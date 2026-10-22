import Core
import Foundation

public enum TranscriptionStatus: Sendable, Equatable {
    case waitingForAudio
    case listening
    case transcribing
    case retrying(attempt: Int, reason: String)
    case failed(String)
    case unavailable(String)
    case stopped
}

public struct TranscriptionRecoveryPolicy: Sendable {
    public let maximumRetries: Int
    public let retryDelay: Duration
    public let stallTimeout: Duration
    public let checkInterval: Duration

    public init(maximumRetries: Int = 3, retryDelay: Duration = .milliseconds(500),
                stallTimeout: Duration = .seconds(60), checkInterval: Duration = .seconds(1)) {
        self.maximumRetries = max(0, min(10, maximumRetries))
        self.retryDelay = max(.zero, retryDelay)
        self.stallTimeout = max(.milliseconds(1), stallTimeout)
        self.checkInterval = max(.milliseconds(1), checkInterval)
    }
}

/// One source keeps capturing while its transcription stream is replaced.
/// Only the most recent 30 seconds of unconfirmed audio are retained, in memory.
actor LiveTranscription {
    private let provider: any TranscriptionProvider
    private let policy: TranscriptionRecoveryPolicy
    private let onAudio: @Sendable (AudioChunk) async -> Void
    private let onAudioEnded: @Sendable () async -> Void
    private let onSegment: @Sendable (TranscriptSegment) async -> Void
    private let onStatus: @Sendable (TranscriptionStatus) -> Void
    private let onWarning: @Sendable (String) -> Void
    private var status = TranscriptionStatus.waitingForAudio
    private var input: AsyncStream<AudioChunk>.Continuation?
    private var attemptTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation: UUID?
    private var ending = false
    private var allowRetries = true
    private var retries = 0
    private var confirmedEnd: TimeInterval = 0
    private var discardedThrough: TimeInterval = 0
    private var pending = Transcript()
    private var recent: [AudioChunk] = []
    private var lastProgress = ContinuousClock.now
    private var lastAudio: ContinuousClock.Instant?
    private var pendingSpeech: TimeInterval = 0
    private var lastResult: TranscriptSegment?

    init(provider: any TranscriptionProvider, policy: TranscriptionRecoveryPolicy,
         onAudio: @escaping @Sendable (AudioChunk) async -> Void,
         onAudioEnded: @escaping @Sendable () async -> Void,
         onSegment: @escaping @Sendable (TranscriptSegment) async -> Void,
         onStatus: @escaping @Sendable (TranscriptionStatus) -> Void,
         onWarning: @escaping @Sendable (String) -> Void) {
        self.provider = provider
        self.policy = policy
        self.onAudio = onAudio
        self.onAudioEnded = onAudioEnded
        self.onSegment = onSegment
        self.onStatus = onStatus
        self.onWarning = onWarning
    }

    func run(_ audio: AsyncStream<AudioChunk>) async {
        await withTaskCancellationHandler {
            onStatus(.waitingForAudio)
            startAttempt()
            watchdog = Task { [weak self, interval = policy.checkInterval] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    await self?.checkHealth()
                }
            }
            for await chunk in audio {
                guard !Task.isCancelled else { break }
                await onAudio(chunk)
                await feed(chunk)
            }
            ending = true
            if case .retrying = status, !recent.isEmpty {
                onWarning("Capture ended before transcription recovered. Some recent audio was not transcribed.")
            }
            watchdog?.cancel()
            retryTask?.cancel()
            await onAudioEnded()
            input?.finish()
            await attemptTask?.value
            cancel()
            recent.removeAll()
            pending = Transcript()
            setStatus(.stopped)
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func retry() async {
        guard !ending, allowRetries, case .failed(let reason) = status else { return }
        retries = 0
        setStatus(.retrying(attempt: 1, reason: reason))
        startAttempt()
    }

    func stopRetrying() {
        allowRetries = false
        retryTask?.cancel()
        watchdog?.cancel()
    }

    private func startAttempt() {
        guard !ending else { return }
        let token = UUID()
        generation = token
        lastProgress = .now
        lastResult = nil
        pendingSpeech = recent.filter(Self.isActive).reduce(0) { $0 + $1.duration }
        let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(1000))
        self.input = input
        for chunk in recent { input.yield(chunk) }
        let segments = provider.transcribe(audio)
        attemptTask = Task { [weak self] in
            do {
                for try await segment in segments {
                    guard !Task.isCancelled else { return }
                    await self?.accept(segment, generation: token)
                }
                await self?.attemptEnded(token, reason: "The transcriber stopped unexpectedly.", failed: false)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.attemptEnded(token, reason: error.localizedDescription, failed: true)
            }
        }
    }

    private func feed(_ chunk: AudioChunk) async {
        lastAudio = .now
        if let chunk = Self.trim(chunk, after: confirmedEnd) {
            recent.append(chunk)
            trimBuffer()
        }
        let active = Self.isActive(chunk)
        if active { pendingSpeech += chunk.duration }
        if generation != nil {
            if case .retrying = status {} else { setStatus(active ? .transcribing : .listening) }
        }
        if case .dropped = input?.yield(chunk) {
            await recover("The transcriber could not keep up with incoming audio.")
        }
    }

    private func accept(_ segment: TranscriptSegment, generation token: UUID) async {
        guard generation == token, !Task.isCancelled, segment.end > confirmedEnd else { return }
        if segment.text != lastResult?.text || segment.end > (lastResult?.end ?? 0) {
            lastProgress = .now
            pendingSpeech = 0
            lastResult = segment
        }
        if segment.isFinal {
            pending.remove(id: segment.id)
            confirmedEnd = max(confirmedEnd, segment.end)
            trimBuffer()
            if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { retries = 0 }
        } else {
            pending.upsert(segment)
        }
        setStatus(.listening)
        await onSegment(segment)
    }

    private func attemptEnded(_ token: UUID, reason: String, failed: Bool) async {
        guard generation == token else { return }
        if ending {
            generation = nil
            if failed { onWarning("Transcription failed while finishing: \(reason). Captured text was kept.") }
            return
        }
        // Keep this task available for stop() to drain while partial text is saved.
        await recover(reason, cancelAttempt: false)
    }

    private func recover(_ reason: String, cancelAttempt: Bool = true) async {
        guard !ending else { return }
        generation = nil
        input?.finish()
        input = nil
        if cancelAttempt {
            attemptTask?.cancel()
            attemptTask = nil
        }
        retryTask?.cancel()
        retryTask = nil
        // Keep the best text already shown. Its audio must not be transcribed a second time.
        let partials = pending.segments
        pending = Transcript()
        for var segment in partials {
            segment.isFinal = true
            confirmedEnd = max(confirmedEnd, segment.end)
            await onSegment(segment)
        }
        trimBuffer()
        guard !ending else { return }
        guard allowRetries else {
            onWarning("Transcription was interrupted while capture stopped: \(reason). Captured text was kept.")
            return
        }
        if discardedThrough > confirmedEnd {
            onWarning("Only the most recent 30 seconds of audio are available for retry. Some earlier audio may be missing from the transcript.")
        }
        guard retries < policy.maximumRetries else {
            setStatus(.failed(reason))
            onWarning("Transcription recovery failed: \(reason) Captured text was kept. Use Retry to try again.")
            return
        }
        retries += 1
        setStatus(.retrying(attempt: retries, reason: reason))
        let delay = min(.seconds(8), policy.retryDelay * (1 << (retries - 1)))
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.retryAttempt()
        }
    }

    private func retryAttempt() {
        guard allowRetries else { return }
        startAttempt()
    }

    private func checkHealth() async {
        guard !ending, allowRetries, generation != nil else { return }
        if pendingSpeech >= 0.5, ContinuousClock.now - lastProgress >= policy.stallTimeout {
            await recover("Audio was received, but the transcriber stopped producing text.")
        } else if let lastAudio, ContinuousClock.now - lastAudio >= .seconds(5) {
            if case .retrying = status {} else { setStatus(.waitingForAudio) }
        }
    }

    private func cancel() {
        ending = true
        generation = nil
        input?.finish()
        input = nil
        attemptTask?.cancel()
        retryTask?.cancel()
        watchdog?.cancel()
    }

    private func setStatus(_ status: TranscriptionStatus) {
        guard self.status != status else { return }
        self.status = status
        onStatus(status)
    }

    private func trimBuffer() {
        recent = recent.compactMap { Self.trim($0, after: confirmedEnd) }
        let duration = recent.reduce(0) { $0 + $1.duration }
        var excess = max(0, duration - 30)
        while let first = recent.first, excess > 0 {
            if first.duration <= excess {
                discardedThrough = max(discardedThrough, first.timestamp + first.duration)
                excess -= first.duration
                recent.removeFirst()
            } else {
                if let tail = Self.trim(first, after: first.timestamp + excess) {
                    discardedThrough = max(discardedThrough, tail.timestamp)
                    recent[0] = tail
                } else {
                    // Rounding up to a sample can consume the whole first block.
                    discardedThrough = max(discardedThrough, first.timestamp + first.duration)
                    recent.removeFirst()
                }
                excess = 0
            }
        }
        if recent.count > 1000 {
            let dropped = recent.count - 1000
            discardedThrough = max(discardedThrough, recent[dropped - 1].timestamp + recent[dropped - 1].duration)
            recent.removeFirst(dropped)
        }
    }

    private static func trim(_ chunk: AudioChunk, after end: TimeInterval) -> AudioChunk? {
        guard chunk.sampleRate > 0, chunk.sampleRate.isFinite, chunk.timestamp.isFinite,
              chunk.timestamp + chunk.duration > end else { return nil }
        guard chunk.timestamp < end else { return chunk }
        let removed = min(chunk.pcm.count, max(0, Int(((end - chunk.timestamp) * chunk.sampleRate).rounded(.up))))
        guard removed < chunk.pcm.count else { return nil }
        return AudioChunk(source: chunk.source, pcm: Array(chunk.pcm.dropFirst(removed)), sampleRate: chunk.sampleRate,
                          timestamp: chunk.timestamp + Double(removed) / chunk.sampleRate)
    }

    private static func isActive(_ chunk: AudioChunk) -> Bool {
        guard !chunk.pcm.isEmpty else { return false }
        let energy = chunk.pcm.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.pcm.count)
        return energy >= 0.0001
    }
}

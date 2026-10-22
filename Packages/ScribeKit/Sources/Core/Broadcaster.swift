import Foundation
import os

/// Sends one producer's values to any number of `AsyncStream` subscribers.
public final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        let id = UUID()
        let finished = state.withLock { state in
            if !state.finished { state.continuations[id] = continuation }
            return state.finished
        }
        if finished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
        return stream
    }

    public func send(_ element: Element) {
        for continuation in state.withLock({ Array($0.continuations.values) }) {
            continuation.yield(element)
        }
    }

    public func finish() {
        let continuations = state.withLock { state in
            state.finished = true
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.finish() }
    }
}

import Core
import Foundation
import Testing

@testable import Transcription

private actor LoadCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}

@Suite struct LocalModelCacheTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "model-cache-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func concurrentLoadsShareOneTaskAndReportReadySize() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LocalModelCache<Int>(), counter = LoadCounter()
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        var updates = await cache.updates("test", directories: [root]).makeAsyncIterator()
        #expect(await updates.next()?.phase == .notDownloaded)
        let loader: @Sendable (@escaping LocalModelCache<Int>.Reporter) async throws -> Int = { report in
            let value = await counter.next()
            for await _ in gate {}
            report(.downloading(0.5))
            try Data(repeating: 1, count: 12).write(to: root.appending(path: "weights"))
            report(.loading)
            return value
        }
        let first = Task { try await cache.load("test", directories: { [root] }, loader: loader) }
        // Wait until the first load has started before attaching another caller.
        while await counter.count == 0 { await Task.yield() }
        let second = Task { try await cache.load("test", directories: { [root] }, loader: loader) }
        release.finish()
        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
        #expect(await counter.count == 1)
        while let status = await updates.next() {
            if status.phase == .ready {
                #expect(status.cachedBytes == 12)
                break
            }
        }
    }

    @Test func failureCanRetryAndDeletionUnloadsOnlyThatModel() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appending(path: "model"), other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: model.appending(path: "weights"))
        try Data([4]).write(to: other)
        let cache = LocalModelCache<Int>()
        var updates = await cache.updates("test", directories: [model]).makeAsyncIterator()
        #expect(await updates.next() == LocalModelStatus(phase: .downloaded, cachedBytes: 3))
        await #expect(throws: CocoaError.self) {
            try await cache.load("test", directories: { [model] }) { _ in throw CocoaError(.fileReadCorruptFile) }
        }
        while let status = await updates.next() {
            if case .failed = status.phase { break }
        }
        #expect(try await cache.load("test", directories: { [model] }) { _ in 7 } == 7)
        #expect(try await cache.load("alias", directories: { [model] }) { _ in 11 } == 11)
        try await cache.delete("test", directories: [model])
        #expect(!FileManager.default.fileExists(atPath: model.path))
        #expect(try Data(contentsOf: other) == Data([4]))
        while let status = await updates.next() {
            if status.phase == .notDownloaded {
                #expect(status.cachedBytes == 0)
                break
            }
        }
        #expect(try await cache.load("test", directories: { [model] }) { _ in 9 } == 9)
        #expect(try await cache.load("alias", directories: { [model] }) { _ in 12 } == 12)
    }

    @Test func deletionIsRejectedDuringLoading() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LocalModelCache<Int>(), counter = LoadCounter()
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            try await cache.load("test", directories: { [root] }) { _ in
                _ = await counter.next()
                for await _ in gate {}
                return 1
            }
        }
        while await counter.count == 0 { await Task.yield() }
        await #expect(throws: LocalModelError.self) { try await cache.delete("test", directories: [root]) }
        #expect(FileManager.default.fileExists(atPath: root.path))
        release.finish()
        _ = try await task.value
    }

    @Test func modelNamesCannotEscapeCacheOrExpandGlobs() throws {
        for name in ["", "..", "../model", "a/b", "model*", "/absolute", "a\\b"] {
            #expect(throws: LocalModelError.self) { try validateModelName(name, components: 1) }
        }
        for name in ["a/../b", "a/..", "/b", "a/", "a/*"] {
            #expect(throws: LocalModelError.self) { try validateModelName(name, components: 2) }
        }
        try validateModelName("openai_whisper-large-v3-v20240930_turbo_632MB", components: 1)
        try validateModelName("beshkenadze/cohere-transcribe-03-2026-mlx-fp16", components: 2)
    }
}

import Core
import Foundation

enum LocalModelError: Error, LocalizedError {
    case busy
    case invalidName

    var errorDescription: String? {
        switch self {
        case .busy: "Wait for model loading to finish before deleting it."
        case .invalidName: "Enter a full model name without path components such as '..'."
        }
    }
}

/// Shares loads and status across preparation, live transcription, and Settings.
actor LocalModelCache<Value: Sendable> {
    typealias Reporter = @Sendable (LocalModelPhase) -> Void
    private struct Entry {
        var status: LocalModelStatus
        var directories: [URL]
        var value: Value?
        var task: Task<Value, Error>?
        var generation: UUID?
        let events = Broadcaster<LocalModelStatus>()
    }
    private var entries: [String: Entry] = [:]

    func updates(_ name: String, directories: [URL]) -> AsyncStream<LocalModelStatus> {
        initialize(name, directories: directories)
        let entry = entries[name]!
        let stream = entry.events.subscribe()
        entry.events.send(entry.status)
        return stream
    }

    func load(
        _ name: String, directories: @Sendable () throws -> [URL],
        loader: @escaping @Sendable (@escaping Reporter) async throws -> Value
    ) async throws -> Value {
        let paths = try directories()
        initialize(name, directories: paths)
        if let value = entries[name]?.value { return value }
        if let task = entries[name]?.task { return try await task.value }
        let generation = UUID()
        entries[name]?.generation = generation
        set(.downloading(nil), name: name)
        let task = Task {
            try await loader { phase in
                Task { await self.report(phase, name: name, generation: generation) }
            }
        }
        entries[name]?.task = task
        do {
            let value = try await task.value
            entries[name]?.value = value
            entries[name]?.task = nil
            entries[name]?.generation = nil
            refreshSize(name, directories: (try? directories()) ?? paths)
            set(.ready, name: name)
            return value
        } catch {
            entries[name]?.task = nil
            entries[name]?.generation = nil
            refreshSize(name, directories: (try? directories()) ?? paths)
            set(.failed(error.localizedDescription), name: name)
            throw error
        }
    }

    func delete(_ name: String, directories: [URL]) throws {
        initialize(name, directories: directories)
        // Variant aliases can resolve to the same files. Do not race any load in this provider.
        guard !entries.values.contains(where: { $0.task != nil }) else { throw LocalModelError.busy }
        let paths = Set(directories.map(\.standardizedFileURL))
        let affected = entries.keys.filter { key in
            key == name || entries[key]!.directories.contains { paths.contains($0.standardizedFileURL) }
        }
        for key in affected {
            entries[key]?.value = nil
            set(.deleting, name: key)
        }
        do {
            for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            for key in affected {
                refreshSize(key, directories: entries[key]!.directories)
                set(.notDownloaded, name: key)
            }
        } catch {
            for key in affected {
                refreshSize(key, directories: entries[key]!.directories)
                set(.failed(error.localizedDescription), name: key)
            }
            throw error
        }
    }

    private func initialize(_ name: String, directories: [URL]) {
        guard entries[name] == nil else { return }
        let bytes = Self.size(directories)
        entries[name] = Entry(status: LocalModelStatus(phase: bytes > 0 ? .downloaded : .notDownloaded, cachedBytes: bytes), directories: directories)
    }

    private func report(_ phase: LocalModelPhase, name: String, generation: UUID) {
        guard entries[name]?.generation == generation else { return }
        // An asynchronously delivered progress callback must not replace the loading phase.
        if case .downloading = phase, entries[name]?.status.phase == .loading { return }
        set(phase, name: name)
    }

    private func refreshSize(_ name: String, directories: [URL]) {
        entries[name]?.directories = directories
        entries[name]?.status.cachedBytes = Self.size(directories)
    }

    private func set(_ phase: LocalModelPhase, name: String) {
        entries[name]?.status.phase = phase
        if let entry = entries[name] { entry.events.send(entry.status) }
    }

    private static func size(_ directories: [URL]) -> Int64 {
        directories.reduce(0) { total, directory in
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return total }
            return total + files.reduce(Int64(0)) { sum, item in
                guard let url = item as? URL,
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { return sum }
                return sum + Int64(values.fileSize ?? 0)
            }
        }
    }
}

/// Cache deletion accepts model identifiers, never arbitrary paths or search globs.
func validateModelName(_ name: String, components: Int) throws {
    let parts = name.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    guard parts.count == components, parts.allSatisfy({ part in
        !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy { allowed.contains($0) }
    }) else { throw LocalModelError.invalidName }
}

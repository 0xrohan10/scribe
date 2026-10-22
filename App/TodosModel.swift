import Core
import Foundation
import Observation

@MainActor @Observable
final class TodosModel {
    private(set) var items: [TodoItem] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var filter: TodoFilter = .open
    var query = ""
    var lastError: String?
    @ObservationIgnored private let repository: any TodoRepository
    @ObservationIgnored private var loadRevision = 0

    init(repository: any TodoRepository) { self.repository = repository }

    var openCount: Int { items.filter { !$0.isCompleted }.count }

    var visibleItems: [TodoItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date.now
        let calendar = Calendar.current
        return items.filter { item in
            filter.matches(item, now: now, calendar: calendar) && (query.isEmpty || [item.title, item.notes, item.owner, item.meetingTitle, item.suggestedDue]
                .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query))
        }.sorted {
            if filter == .completed { return ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            if $0.dueDate != $1.dueDate { return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func reload() async {
        loadRevision += 1
        let revision = loadRevision
        isLoading = true
        defer { if revision == loadRevision { isLoading = false } }
        do {
            let loaded = try await repository.items()
            guard revision == loadRevision else { return }
            items = loaded
        } catch {
            if revision == loadRevision { lastError = error.localizedDescription }
        }
    }

    @discardableResult
    func save(_ item: TodoItem) async -> Bool {
        await perform { try await self.repository.save(item) }
    }

    func toggle(_ item: TodoItem) async {
        await perform { try await self.repository.setCompleted(id: item.id, completed: !item.isCompleted) }
    }

    func delete(_ item: TodoItem) async {
        await perform { try await self.repository.delete(id: item.id) }
    }

    @discardableResult
    private func perform(_ action: () async throws -> Void) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        lastError = nil
        defer { isSaving = false }
        do {
            try await action()
            await reload()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

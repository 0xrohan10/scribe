import Foundation

public struct TodoItem: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var notes: String
    public var owner: String?
    public var dueDate: Date?
    /// Unconfirmed wording from a meeting summary, such as "next Friday".
    public var suggestedDue: String?
    public var completedAt: Date?
    public let createdAt: Date
    public var meetingID: UUID?
    public var meetingTitle: String?

    public init(id: UUID = UUID(), title: String, notes: String = "", owner: String? = nil, dueDate: Date? = nil,
                suggestedDue: String? = nil, completedAt: Date? = nil, createdAt: Date = .now,
                meetingID: UUID? = nil, meetingTitle: String? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.owner = owner
        self.dueDate = dueDate
        self.suggestedDue = suggestedDue
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
    }

    public var isCompleted: Bool { completedAt != nil }
}

public enum TodoError: Error, LocalizedError {
    case emptyTitle
    case notFound

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "Enter a task title."
        case .notFound: "This todo no longer exists."
        }
    }
}

public protocol TodoRepository: Sendable {
    func items() async throws -> [TodoItem]
    /// Saves editable fields. Existing completion state and meeting links are not overwritten.
    func save(_ item: TodoItem) async throws
    func setCompleted(id: UUID, completed: Bool) async throws
    func delete(id: UUID) async throws
}

public enum TodoFilter: String, Sendable, CaseIterable {
    case open = "Open"
    case today = "Today"
    case completed = "Completed"

    public func matches(_ item: TodoItem, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .open: return !item.isCompleted
        case .completed: return item.isCompleted
        case .today:
            guard !item.isCompleted, let due = item.dueDate,
                  let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return false }
            return due < tomorrow
        }
    }
}

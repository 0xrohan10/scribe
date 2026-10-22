import Core
import Foundation
import Testing

@Suite struct TodoFilterTests {
    @Test func todayIncludesOverdueButNotUnconfirmedDatesOrCompletedTasks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        #expect(TodoFilter.today.matches(TodoItem(title: "Overdue", dueDate: yesterday), now: now, calendar: calendar))
        #expect(TodoFilter.today.matches(TodoItem(title: "Today", dueDate: now), now: now, calendar: calendar))
        #expect(!TodoFilter.today.matches(TodoItem(title: "Tomorrow", dueDate: tomorrow), now: now, calendar: calendar))
        #expect(!TodoFilter.today.matches(TodoItem(title: "Suggested", suggestedDue: "Today"), now: now, calendar: calendar))
        #expect(!TodoFilter.today.matches(TodoItem(title: "Done", dueDate: yesterday, completedAt: now), now: now, calendar: calendar))
    }
}

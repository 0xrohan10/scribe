import Core
import UserNotifications

/// "Record this meeting?" notifications. Never starts recording on its own; the user has to act.
@MainActor
final class MeetingPrompter: NSObject, UNUserNotificationCenterDelegate {
    var onRecord: (() -> Void)?
    var onStop: (() -> Void)?

    private let center = UNUserNotificationCenter.current()
    private enum ID {
        static let detectedCategory = "MEETING_DETECTED"
        static let endedCategory = "MEETING_ENDED"
        static let record = "RECORD"
        static let stop = "STOP"
        static let detectedRequest = "meeting-detected"
        static let endedRequest = "meeting-ended"
    }

    func setUp() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: ID.detectedCategory,
                actions: [UNNotificationAction(identifier: ID.record, title: "Record", options: [.foreground])],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: ID.endedCategory,
                actions: [UNNotificationAction(identifier: ID.stop, title: "Stop Recording", options: [])],
                intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func promptRecord(app: MeetingApp) {
        post(id: ID.detectedRequest, category: ID.detectedCategory, title: "Record this meeting?", body: "\(app.displayName) meeting detected.")
    }

    func withdrawRecordPrompt() {
        center.removeDeliveredNotifications(withIdentifiers: [ID.detectedRequest])
    }

    func promptStop() {
        post(id: ID.endedRequest, category: ID.endedCategory, title: "Meeting ended?", body: "Scribe is still recording.")
    }

    private func post(id: String, category: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            switch (category, action) {
            // Clicking the banner itself counts as "Record": the question is the whole notification.
            case (ID.detectedCategory, ID.record), (ID.detectedCategory, UNNotificationDefaultActionIdentifier): onRecord?()
            case (ID.endedCategory, ID.stop): onStop?()
            default: break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions
    {
        [.banner, .sound]
    }
}

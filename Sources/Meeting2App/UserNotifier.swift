import Foundation
import UserNotifications

/// Best-effort local notifications. `UNUserNotificationCenter.current()` traps when there's no app
/// bundle (e.g. the raw SwiftPM binary), so every call no-ops unless we're a real `.app`. If
/// authorization is denied the posts simply don't appear — the menu is always the fallback.
enum UserNotifier {
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

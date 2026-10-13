import Foundation
import UserNotifications
import VocabCore

/// `UserNotifier` через `UNUserNotificationCenter` (§11).
/// `UNUserNotificationCenter.current()` береться лише в момент використання (не в `init`), щоб створення сервісу
/// не чіпало центр сповіщень (напр. під XCTest). Дозвіл запитується ліниво: при першому `post`, якщо статус
/// ще `notDetermined` (і окремо на старті з `AppDelegate`).
final class NotificationService: NSObject, UserNotifier, UNUserNotificationCenterDelegate {
    private let logger: RedactingLogger?

    init(logger: RedactingLogger? = nil) {
        self.logger = logger
        super.init()
    }

    private var center: UNUserNotificationCenter {
        UNUserNotificationCenter.current()
    }

    /// Робить сервіс делегатом центру, щоб сповіщення показувались і коли застосунок активний.
    func install() {
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            if !granted {
                logger?.info("Notifications not allowed by user")
            }
            return granted
        } catch {
            logger?.error("Notification authorization request failed: \(error.localizedDescription)")
            return false
        }
    }

    func post(_ content: NotificationContent) async {
        guard await isAuthorized() else {
            // Результат усе одно видно в меню (`AppModel.lastServiceMessage`).
            logger?.info("Notification not shown (not authorized): \(content.title)")
            return
        }
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: notification, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            logger?.error("Notification delivery failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    // MARK: - Private

    private func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return await requestAuthorization()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}

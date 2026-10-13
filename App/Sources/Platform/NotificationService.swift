import Foundation
import UserNotifications
import VocabCore

/// `UserNotifier` через `UNUserNotificationCenter` (§11).
///
/// `UNUserNotificationCenter.current()` береться лише в момент використання (не в `init`), щоб створення сервісу
/// не чіпало центр сповіщень (напр. під XCTest).
///
/// **Дозвіл запитується в одному місці** — на старті з `AppDelegate.applicationDidFinishLaunching` (§11).
/// `post` сам дозвіл не запитує: якщо статус ще `notDetermined`, він чекає на той самий стартовий запит
/// (холодний старт через Services: сповіщення з'явиться після відповіді користувача); якщо запиту не було —
/// сповіщення не показується (результат видно в меню, `AppModel.lastServiceMessage`).
/// Повторні виклики `requestAuthorization` повертають результат того самого запиту.
///
/// Конкурентність: `@unchecked Sendable` — єдиний змінюваний стан (`authorizationTask`) захищено `NSLock`
/// (лок не утримується через `await`); `logger` — незмінний і `Sendable`. Метод делегата викликається на
/// довільній черзі й не чіпає стану.
final class NotificationService: NSObject, UserNotifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let logger: RedactingLogger?
    private let lock = NSLock()
    private var authorizationTask: Task<Bool, Never>?

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
        await authorizationRequest().value
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

    /// Єдиний запит дозволу на весь час роботи: перший виклик створює задачу, наступні отримують її ж.
    private func authorizationRequest() -> Task<Bool, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let authorizationTask {
            return authorizationTask
        }
        let logger = self.logger
        let task = Task<Bool, Never> {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                if !granted {
                    logger?.info("Notifications not allowed by user")
                }
                return granted
            } catch {
                logger?.error("Notification authorization request failed: \(error.localizedDescription)")
                return false
            }
        }
        authorizationTask = task
        return task
    }

    /// Стартовий запит дозволу, якщо його вже зроблено (нічого не запитує сам).
    private func existingAuthorizationRequest() -> Task<Bool, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return authorizationTask
    }

    private func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            // Користувач ще не відповів на стартовий запит — чекаємо на нього, нового не робимо.
            guard let pending = existingAuthorizationRequest() else { return false }
            return await pending.value
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}

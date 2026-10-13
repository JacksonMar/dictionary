import Foundation
import VocabCore

/// Показ системних сповіщень (§11). Реальна реалізація — `NotificationService`; у тестах — заглушка.
protocol UserNotifier: AnyObject {
    /// Запитує дозвіл (якщо ще не визначено). Повертає `true`, якщо сповіщення дозволені.
    func requestAuthorization() async -> Bool
    /// Показує сповіщення; якщо дозволу нема — лише логує.
    func post(_ content: NotificationContent) async
}

/// Нічого не показує. Використовується під XCTest (без звернень до `UNUserNotificationCenter`).
final class SilentUserNotifier: UserNotifier {
    func requestAuthorization() async -> Bool {
        false
    }

    func post(_ content: NotificationContent) async {}
}

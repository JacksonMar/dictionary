import Foundation
import ServiceManagement

/// Стан автозапуску (незалежний від `SMAppService.Status`, щоб `AppModel` і тести не залежали від ServiceManagement).
enum LoginItemState: Equatable {
    /// Зареєстровано й дозволено: застосунок запуститься при вході.
    case enabled
    /// Не зареєстровано.
    case disabled
    /// Зареєстровано, але користувач має дозволити в System Settings → General → Login Items (U8).
    case requiresApproval
    /// Система не знайшла застосунок як login item (напр. запуск не з `/Applications`, U8).
    case notFound
}

/// Керування автозапуском (§11). Протокол — щоб `AppModel` і тумблер у Settings тестувались із заглушкою.
@MainActor
protocol LoginItemManaging: AnyObject {
    /// Поточний стан (істина — у системі, не в `UserDefaults`, §7.6).
    var state: LoginItemState { get }
    /// Увімкнути/вимкнути автозапуск. Помилка — з `SMAppService.register()/unregister()`.
    func setEnabled(_ enabled: Bool) throws
    /// Відкриває System Settings → General → Login Items.
    func openSystemSettings()
}

/// `SMAppService.mainApp` (macOS 13+): `register()` / `unregister()` / `status`.
@MainActor
final class LoginItemService: LoginItemManaging {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var state: LoginItemState {
        Self.state(for: service.status)
    }

    func setEnabled(_ enabled: Bool) throws {
        let current = state
        if enabled {
            // Повторна реєстрація вже дозволеного елемента не потрібна; для `requiresApproval` — теж
            // (елемент зареєстровано, чекає дозволу користувача).
            guard current != .enabled, current != .requiresApproval else { return }
            try service.register()
        } else {
            guard current != .disabled else { return }
            try service.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Чиста функція мапінгу (тестується без реєстрації, M5.4).
    nonisolated static func state(for status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }
}

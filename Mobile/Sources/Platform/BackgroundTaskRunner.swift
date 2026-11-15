import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Маркер фонової задачі, виданий `BackgroundTaskRunning.beginTask(named:)`.
struct BackgroundTaskToken: Hashable, Sendable {
    let rawValue: Int
}

/// Фонова задача навколо мережевої роботи (IOS_PLAN DI18): якщо користувач згорнув застосунок посеред запиту
/// до Claude, система дає кілька секунд, щоб його завершити. Якщо процес усе ж призупинено — запис уже `pending`,
/// його добере тригер `.foreground`.
///
/// Протокол без UIKit, щоб `MobileAppModel` тестувався (і тайпчекався на Linux) з `NoopBackgroundTaskRunner`.
@MainActor
protocol BackgroundTaskRunning: AnyObject {
    func beginTask(named name: String) -> BackgroundTaskToken
    /// Завершує задачу; повторний виклик або невідомий маркер — нічого не робить.
    func endTask(_ token: BackgroundTaskToken)
}

extension BackgroundTaskRunning {
    /// Виконує `operation` усередині фонової задачі; задача завершується за будь-якого результату.
    func run<T>(named name: String, _ operation: () async -> T) async -> T {
        let token = beginTask(named: name)
        let result = await operation()
        endTask(token)
        return result
    }
}

/// Без фонових задач (тести, Linux-харнес). Запам'ятовує імена, щоб тести перевіряли, що задачі збалансовані.
@MainActor
final class NoopBackgroundTaskRunner: BackgroundTaskRunning {
    private var nextID = 1
    private(set) var startedNames: [String] = []
    private(set) var activeTokens: Set<BackgroundTaskToken> = []

    init() {}

    func beginTask(named name: String) -> BackgroundTaskToken {
        let token = BackgroundTaskToken(rawValue: nextID)
        nextID += 1
        startedNames.append(name)
        activeTokens.insert(token)
        return token
    }

    func endTask(_ token: BackgroundTaskToken) {
        activeTokens.remove(token)
    }
}

#if canImport(UIKit)
/// `UIApplication.beginBackgroundTask` (DI18). Обробник закінчення часу завершує задачу синхронно (система викликає
/// його на головному потоці), інакше iOS завершить процес.
@MainActor
final class UIApplicationBackgroundTaskRunner: BackgroundTaskRunning {
    private var nextID = 1
    private var identifiers: [BackgroundTaskToken: UIBackgroundTaskIdentifier] = [:]

    init() {}

    func beginTask(named name: String) -> BackgroundTaskToken {
        let token = BackgroundTaskToken(rawValue: nextID)
        nextID += 1
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                self?.endTask(token)
            }
        }
        if identifier != .invalid {
            identifiers[token] = identifier
        }
        return token
    }

    func endTask(_ token: BackgroundTaskToken) {
        guard let identifier = identifiers.removeValue(forKey: token) else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
#endif

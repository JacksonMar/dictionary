import Foundation
import VocabCore

/// Середовище запуску: тести чи реальний запуск, шляхи до даних.
enum AppEnvironment {
    /// `true`, якщо процес запущено як host app для XCTest.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Реальні шляхи (`~/Library/Application Support/VocabApp`) або, під тестами, унікальний тимчасовий каталог,
    /// щоб тести ніколи не чіпали справжній словник.
    static func makePaths() -> AppPaths {
        if isRunningTests {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VocabAppTests-\(UUID().uuidString)", isDirectory: true)
            return AppPaths(applicationSupportDirectory: directory)
        }
        return AppPaths.standard()
    }
}

/// Ідентифікатори сцен `Window`.
enum WindowID {
    static let dictionary = "dictionary"
    static let settings = "settings"
}

/// Заголовки сцен `Window` (також — запасний критерій для закриття вікон при запуску, U12).
enum WindowTitle {
    static let dictionary = "Словник"
    static let settings = "Налаштування"
}

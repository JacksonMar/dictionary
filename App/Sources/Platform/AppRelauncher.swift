import AppKit
import Foundation

/// Перезапуск застосунку для застосування мови інтерфейсу (M9, D37). Протокол — для фейка в тестах.
@MainActor
protocol AppRelaunching {
    /// Запускає відкладений повторний старт і завершує поточний процес. Помилка — якщо запуск не вдався
    /// (тоді застосунок продовжує роботу).
    func relaunch() throws
}

/// `/bin/sh` чекає завершення поточного процесу (обмежено: `maxWaitIterations` × 0,2 с), далі
/// `/usr/bin/open <bundle>`; одразу після запуску скрипта — `NSApp.terminate(nil)` (звичайний шлях виходу).
/// Новий екземпляр стартує лише після завершення старого, тож двох власників `NSPortName` не буває. Якщо
/// старий процес не завершився за відведений час, скрипт виходить без `open` (U20).
/// Конформність — в extension: інакше `@MainActor` протоколу поширився б на весь тип (і на чисту
/// `arguments(pid:bundlePath:)`, яку тести викликають поза головним актором).
struct ProcessAppRelauncher {
    /// 100 × 0,2 с = до 20 с очікування.
    static let maxWaitIterations = 100
    static let shellPath = "/bin/sh"

    /// `$1` — pid поточного процесу, `$2` — шлях до бандла.
    static let script = """
        i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); if [ "$i" -ge \(maxWaitIterations) ]; then exit 1; fi; \
        sleep 0.2; done; /usr/bin/open "$2"
        """

    /// Аргументи `/bin/sh`: `-c <script> sh <pid> <bundlePath>` (`sh` — `$0` скрипта).
    static func arguments(pid: Int32, bundlePath: String) -> [String] {
        ["-c", script, "sh", String(pid), bundlePath]
    }
}

extension ProcessAppRelauncher: AppRelaunching {
    @MainActor
    func relaunch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.shellPath)
        process.arguments = Self.arguments(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundlePath: Bundle.main.bundlePath
        )
        try process.run()
        NSApp.terminate(nil)
    }
}

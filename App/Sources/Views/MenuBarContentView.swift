import AppKit
import SwiftUI

/// Меню в menu bar (§11, M5): останній результат Services, «Відкрити словник», «Повторити очікувані (N)»,
/// «Налаштування…», «Вийти».
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let message = model.lastServiceMessage {
            // Останній результат «Додати в словник» (видно й тоді, коли сповіщення заборонені).
            Text(message)
            Divider()
        }
        if let loadError = model.loadError {
            Text(loadError)
            Divider()
        }

        Button("Відкрити словник") {
            show(WindowID.dictionary)
        }
        .keyboardShortcut("d")

        if model.isClaudeAvailable && model.retryableCount > 0 {
            Button(retryTitle) {
                Task { @MainActor in
                    await model.retryAll()
                }
            }
            .disabled(model.isRetryingAll)
        }

        if model.isClaudeAvailable && model.isLoaded && !model.hasAPIKey {
            Button("API-ключ не задано — відкрити налаштування") {
                show(WindowID.settings)
            }
        }

        Divider()
        Button("Налаштування…") {
            show(WindowID.settings)
        }
        .keyboardShortcut(",")
        Divider()
        Button("Вийти") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// «Повторити очікувані (N)»: N — записи `pending` + `failed` (їх обробляє «Повторити всі»).
    private var retryTitle: String {
        let count = model.retryableCount
        return model.isRetryingAll ? "Повторюємо… (\(count))" : "Повторити очікувані (\(count))"
    }

    /// Відкриває (або виводить наперед) вікно сцени й активує застосунок: LSUIElement-застосунок
    /// не активується сам, інакше вікно лишиться під вікнами інших програм.
    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

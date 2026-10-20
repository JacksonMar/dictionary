import AppKit
import SwiftUI
import VocabCore

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

        Button(L10n.text(.menuOpenDictionary)) {
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
            Button(L10n.text(.menuNoAPIKey)) {
                show(WindowID.settings)
            }
        }

        Divider()
        Button(L10n.text(.menuSettings)) {
            show(WindowID.settings)
        }
        .keyboardShortcut(",")
        Divider()
        Button(L10n.text(.menuQuit)) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// «Повторити очікувані (N)»: N — записи `pending` + `failed` (їх обробляє «Повторити всі»).
    private var retryTitle: String {
        let count = model.retryableCount
        let key: L10nKey = model.isRetryingAll ? .menuRetrying : .menuRetryPending
        return L10n.text(key, ["count": String(count)])
    }

    /// Відкриває (або виводить наперед) вікно сцени й активує застосунок: LSUIElement-застосунок
    /// не активується сам, інакше вікно лишиться під вікнами інших програм.
    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

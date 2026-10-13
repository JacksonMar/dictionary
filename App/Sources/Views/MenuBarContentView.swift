import AppKit
import SwiftUI

/// Вміст меню в menu bar (M1–M3: «Відкрити словник», «Налаштування…», «Вийти», останній результат Services;
/// повне меню — M5).
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let message = model.lastServiceMessage {
            // Останній результат «Додати в словник» (видно й тоді, коли сповіщення заборонені).
            Text(message)
            Divider()
        }
        Button("Відкрити словник") {
            openWindow(id: WindowID.dictionary)
            // LSUIElement-застосунок не активується сам.
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Налаштування…") {
            openWindow(id: WindowID.settings)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Divider()
        Button("Вийти") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

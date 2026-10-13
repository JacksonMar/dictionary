import AppKit
import SwiftUI

/// Вміст меню в menu bar (M1–M2: «Відкрити словник», «Налаштування…», «Вийти»; повне меню — M5).
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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

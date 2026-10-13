import AppKit
import SwiftUI

/// Вміст меню в menu bar (M1: мінімальний).
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Відкрити словник") {
            openWindow(id: WindowID.dictionary)
            // LSUIElement-застосунок не активується сам.
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Вийти") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

import SwiftUI
import VocabCore

@main
struct VocabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Словник", systemImage: "character.book.closed") {
            MenuBarContentView()
                .environmentObject(appDelegate.model)
        }
        .menuBarExtraStyle(.menu)

        Window("Словник", id: WindowID.dictionary) {
            DictionaryWindowView()
                .environmentObject(appDelegate.model)
        }

        // Окреме вікно замість `Settings`-сцени: відкривається через `openWindow` на macOS 13 (§11).
        Window("Налаштування", id: WindowID.settings) {
            SettingsView()
                .environmentObject(appDelegate.model)
        }
        .windowResizability(.contentSize)
    }
}

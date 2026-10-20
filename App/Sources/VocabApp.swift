import SwiftUI
import VocabCore

@main
struct VocabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // M9 (D36): мова інтерфейсу — до побудови сцен (заголовки `Window`, `MenuBarExtra`).
        InterfaceLanguageBootstrap.applyAtLaunch()
    }

    var body: some Scene {
        MenuBarExtra(L10n.text(.appMenuBarTitle), systemImage: "character.book.closed") {
            MenuBarContentView()
                .environmentObject(appDelegate.model)
        }
        .menuBarExtraStyle(.menu)

        Window(WindowTitle.dictionary, id: WindowID.dictionary) {
            DictionaryWindowView()
                .environmentObject(appDelegate.model)
        }

        // Окреме вікно замість `Settings`-сцени: відкривається через `openWindow` на macOS 13 (§11).
        Window(WindowTitle.settings, id: WindowID.settings) {
            SettingsView()
                .environmentObject(appDelegate.model)
        }
        .windowResizability(.contentSize)
    }
}

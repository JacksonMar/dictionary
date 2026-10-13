import SwiftUI
import VocabCore

@main
struct VocabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Словник", systemImage: "character.book.closed") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.menu)

        Window("Словник", id: WindowID.dictionary) {
            DictionaryWindowView()
                .environmentObject(appDelegate.model)
        }
    }
}

import AppKit
import UniformTypeIdentifiers
import VocabCore

/// Вибір файлів для експорту/імпорту. Протокол — щоб логіку `AppModel` можна було тестувати без UI.
@MainActor
protocol FilePanelPresenting {
    /// URL для збереження експорту або `nil`, якщо користувач скасував.
    func chooseExportDestination(defaultFileName: String) -> URL?
    /// Файл для імпорту або `nil`, якщо користувач скасував.
    func chooseImportSource() -> URL?
}

/// `NSSavePanel` / `NSOpenPanel` з `allowedContentTypes = [.json]` (§11, macOS 11+).
@MainActor
struct SystemFilePanels: FilePanelPresenting {
    func chooseExportDestination(defaultFileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.text(.panelExportTitle)
        panel.prompt = L10n.text(.panelExportPrompt)
        panel.nameFieldStringValue = defaultFileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // LSUIElement-застосунок не активується сам — інакше панель може опинитися під іншими вікнами.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func chooseImportSource() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text(.panelImportTitle)
        panel.prompt = L10n.text(.panelImportPrompt)
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

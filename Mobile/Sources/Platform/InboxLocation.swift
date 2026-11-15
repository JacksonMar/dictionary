import Foundation

/// Де лежить inbox «Поділитися» (IOS_PLAN DI7, §2, §3.3): `<контейнер App Group>/Inbox/`. Id групи — з
/// Info.plist-ключа `VocabAppGroupID` (`$(VOCAB_APP_GROUP)` підставляє збірка). Файл спільний за шляхом для
/// застосунку й Share Extension (`project.yml`), тож обидва процеси рахують той самий каталог.
///
/// Немає ключа, ключ не підставлено (`$(…)`), або система не дала контейнер (App Group не підписано) → `nil`:
/// застосунок просто не інжестить (без помилок), розширення показує «недоступно». Лише Foundation (extension-safe).
enum InboxLocation {
    static let infoPlistKey = "VocabAppGroupID"
    static let directoryName = "Inbox"

    /// Id App Group з Info.plist; порожній або непідставлений `$(VOCAB_APP_GROUP)` → `nil`.
    static func groupID(infoDictionary: [String: Any]?) -> String? {
        guard let raw = infoDictionary?[infoPlistKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    /// Каталог inbox у контейнері групи; `containerURL` — `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
    /// (ін'єкція для тестів).
    static func directory(groupID: String?, containerURL: (String) -> URL?) -> URL? {
        guard let groupID, let container = containerURL(groupID) else { return nil }
        return container.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Каталог inbox поточного процесу (`Bundle.main`); `nil` — inbox вимкнено.
    static func live(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        directory(groupID: groupID(infoDictionary: bundle.infoDictionary)) { identifier in
            appGroupContainer(identifier, fileManager: fileManager)
        }
    }

    private static func appGroupContainer(_ identifier: String, fileManager: FileManager) -> URL? {
        #if os(iOS) || os(macOS)
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        #else
        // Linux-харнес: App Group немає.
        return nil
        #endif
    }
}

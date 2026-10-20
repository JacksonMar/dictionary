import Foundation

/// Ідентифікатор секрету (у Keychain — `kSecAttrAccount`).
public enum SecretKey: String, Sendable, CaseIterable {
    case anthropicAPIKey = "anthropic-api-key"
}

/// Помилки сховища секретів. Ніколи не містять значення секрету.
public enum SecretStoreError: Error, Equatable {
    /// `OSStatus` від Security framework.
    case keychain(status: Int32)
    /// Збережене значення не є коректним UTF-8.
    case encoding
}

extension SecretStoreError {
    /// Опис для UI поточною мовою інтерфейсу (`L10n.current`).
    public var userMessage: String {
        userMessage(in: L10n.current)
    }

    public func userMessage(in language: AppLanguage) -> String {
        switch self {
        case .keychain(let status):
            return L10n.text(.secretKeychain, ["status": String(status)], language: language)
        case .encoding:
            return L10n.text(.secretEncoding, language: language)
        }
    }
}

/// Сховище секретів. У застосунку — Keychain, у тестах/ядрі — `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    /// `nil`, якщо секрету немає.
    func readSecret(for key: SecretKey) throws -> String?
    /// Створює або перезаписує секрет.
    func writeSecret(_ value: String, for key: SecretKey) throws
    /// Видаляє секрет; відсутній секрет — не помилка.
    func deleteSecret(for key: SecretKey) throws
}

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
    public var userMessage: String {
        switch self {
        case .keychain(let status):
            return "Помилка Keychain (код \(status))"
        case .encoding:
            return "Не вдалося прочитати ключ з Keychain"
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

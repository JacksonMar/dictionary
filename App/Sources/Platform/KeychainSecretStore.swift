import Foundation
import Security
import VocabCore

/// `SecretStore` у login Keychain: `kSecClassGenericPassword`, `kSecAttrService = service`,
/// `kSecAttrAccount = SecretKey.rawValue`. Помилки — `SecretStoreError.keychain(status:)` без значення секрету.
final class KeychainSecretStore: SecretStore {
    static let defaultService = "com.vocabapp.VocabApp"

    let service: String

    init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    func readSecret(for key: SecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.encoding
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status: status)
        }
    }

    func writeSecret(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.keychain(status: addStatus)
            }
        default:
            throw SecretStoreError.keychain(status: updateStatus)
        }
    }

    func deleteSecret(for key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.keychain(status: status)
        }
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}

import Foundation

/// Потокобезпечне сховище секретів у пам'яті (тести, Linux).
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String]

    public init(values: [SecretKey: String] = [:]) {
        self.values = values
    }

    public func readSecret(for key: SecretKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func writeSecret(_ value: String, for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    public func deleteSecret(for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }
}

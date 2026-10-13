import Foundation

/// Приклад речення з перекладом.
public struct Example: Codable, Equatable, Sendable {
    public var source: String
    public var translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

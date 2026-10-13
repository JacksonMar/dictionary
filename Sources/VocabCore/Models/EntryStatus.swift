import Foundation

/// Стан запису словника.
public enum EntryStatus: String, Codable, Sendable, CaseIterable {
    case ready
    case pending
    case failed
}

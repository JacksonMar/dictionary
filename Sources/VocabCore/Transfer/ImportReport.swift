import Foundation

/// Режим імпорту (§10).
public enum ImportMode: Sendable, Equatable {
    /// Об'єднати (за замовчуванням): нові записи додаються, конфлікти — за `updatedAt` (D1).
    case merge
    /// Замінити: бекап поточного файлу, далі повна заміна.
    case replace
}

/// Звіт імпорту: «Додано X, оновлено Y, пропущено Z».
///
/// `skipped` рахує:
/// - невалідні окремі записи файлу (D13);
/// - дублікати всередині файлу, що програли згортанню (лишається новіший `updatedAt`);
/// - (merge) записи, для яких локальна версія новіша або однакова за `updatedAt`;
/// - (merge) імпортовані `pending`/`failed`, що не перезаписують локальний `ready`;
/// - (merge) записи, заміна якими дала б дубль іншого локального запису.
public struct ImportReport: Equatable, Sendable {
    public var added: Int
    public var updated: Int
    public var skipped: Int
    /// Причини пропуску (україномовні), по одній на пропущений запис.
    public var skippedReasons: [String]

    public init(added: Int = 0, updated: Int = 0, skipped: Int = 0, skippedReasons: [String] = []) {
        self.added = added
        self.updated = updated
        self.skipped = skipped
        self.skippedReasons = skippedReasons
    }

    /// «Додано X, оновлено Y, пропущено Z».
    public var summary: String {
        "Додано \(added), оновлено \(updated), пропущено \(skipped)"
    }

    /// Додає пропущені записи з іншого етапу (розбір файлу, згортання дублікатів).
    public mutating func addSkipped(_ reasons: [String]) {
        skipped += reasons.count
        skippedReasons.append(contentsOf: reasons)
    }
}

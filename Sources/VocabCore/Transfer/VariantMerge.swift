import Foundation

/// Об'єднання варіантів двох версій одного запису при імпорті (§10 M7, D30). Чиста функція.
public enum VariantMerge {
    /// Кандидати — варіанти обох записів, у яких `sourceKey == key(winner.word)`; варіант мови
    /// `winner.sourceLanguage` (слово користувача) береться від `winner`, якщо він там є.
    /// На кожну мову: `ready` перемагає не-ready; інакше (обидва ready або жоден) — варіант `winner`, якщо є,
    /// інакше `other`. Порожній результат → `nil`.
    public static func combine(winner: Entry, other: Entry) -> [String: EntryVariant]? {
        let key = TextNormalizer.key(winner.word)
        let winnerSource = winner.sourceLanguage
        let winnerVariants = (winner.variants ?? [:]).filter { languageID, variant in
            variant.sourceKey == key || languageID == winnerSource
        }
        let otherVariants = (other.variants ?? [:]).filter { _, variant in
            variant.sourceKey == key
        }

        var result: [String: EntryVariant] = [:]
        for languageID in Set(winnerVariants.keys).union(otherVariants.keys) {
            let fromWinner = winnerVariants[languageID]
            let fromOther = otherVariants[languageID]
            if languageID == winnerSource, let fromWinner {
                result[languageID] = fromWinner
                continue
            }
            switch (fromWinner, fromOther) {
            case let (winnerVariant?, otherVariant?):
                if otherVariant.status == .ready && winnerVariant.status != .ready {
                    result[languageID] = otherVariant
                } else {
                    result[languageID] = winnerVariant
                }
            case let (winnerVariant?, nil):
                result[languageID] = winnerVariant
            case let (nil, otherVariant?):
                result[languageID] = otherVariant
            case (nil, nil):
                break
            }
        }
        return result.isEmpty ? nil : result
    }
}

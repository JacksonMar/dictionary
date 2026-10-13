import Foundation

/// Слово чи фраза.
public enum SelectionKind: String, Sendable {
    case word
    case phrase
}

/// Очищене виділення: текст для показу/запиту, ключ дедуплікації, вид.
public struct CleanedSelection: Equatable, Sendable {
    public var text: String
    public var key: String
    public var kind: SelectionKind

    public init(text: String, key: String, kind: SelectionKind) {
        self.text = text
        self.key = key
        self.kind = kind
    }
}

/// Причина відхилення виділення (D3).
public enum SelectionRejection: Equatable, Sendable {
    case empty
    case tooLong(max: Int)
    case tooManyWords(max: Int)
    case noLetters
}

public enum SelectionValidation: Equatable, Sendable {
    case valid(CleanedSelection)
    case rejected(SelectionRejection)
}

/// Валідація виділеного тексту (§4, D3).
public enum SelectionValidator {
    public static let maxLength = 120
    public static let maxWords = 8

    public static func validate(_ raw: String?) -> SelectionValidation {
        let text = TextNormalizer.clean(raw ?? "")
        if text.isEmpty {
            return .rejected(.empty)
        }
        if text.count > maxLength {
            return .rejected(.tooLong(max: maxLength))
        }
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        if words.count > maxWords {
            return .rejected(.tooManyWords(max: maxWords))
        }
        let hasLetter = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if !hasLetter {
            return .rejected(.noLetters)
        }
        return .valid(CleanedSelection(text: text, key: text.lowercased(), kind: kind(of: text)))
    }

    /// Вид уже очищеного тексту: є пробіл → фраза.
    public static func kind(of cleanedText: String) -> SelectionKind {
        cleanedText.contains(" ") ? .phrase : .word
    }
}

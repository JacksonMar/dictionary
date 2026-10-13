import Foundation

/// Чисті функції нормалізації тексту (§4, D8).
public enum TextNormalizer {
    /// Символи, що замінюються на звичайний апостроф `'`.
    static let apostropheVariants: Set<Character> = ["\u{2019}", "\u{2018}", "\u{02BC}"]

    /// Символи, що знімаються з країв рядка (повторно, поки є).
    static let edgePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "\"", "\u{201C}", "\u{201D}", "«", "»",
        "(", ")", "[", "]", "{", "}", "…",
    ]

    /// Очищення: нормалізація апострофів, будь-які пробільні символи → один пробіл, trim,
    /// зняття крайньої пунктуації. Апостроф і дефіс усередині лишаються.
    public static func clean(_ text: String) -> String {
        var collapsed = ""
        collapsed.reserveCapacity(text.count)
        var previousWasSpace = false
        for character in text {
            if apostropheVariants.contains(character) {
                collapsed.append("'")
                previousWasSpace = false
            } else if isWhitespace(character) {
                if !previousWasSpace {
                    collapsed.append(" ")
                    previousWasSpace = true
                }
            } else {
                collapsed.append(character)
                previousWasSpace = false
            }
        }

        var result = Substring(collapsed)
        while true {
            let before = result.count
            result = trimSpaces(result)
            while let first = result.first, edgePunctuation.contains(first) {
                result = result.dropFirst()
            }
            while let last = result.last, edgePunctuation.contains(last) {
                result = result.dropLast()
            }
            if result.count == before {
                break
            }
        }
        return String(result)
    }

    /// Ключ дедуплікації: `clean` + lowercase.
    public static func key(_ text: String) -> String {
        clean(text).lowercased()
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func trimSpaces(_ text: Substring) -> Substring {
        var result = text
        while result.first == " " {
            result = result.dropFirst()
        }
        while result.last == " " {
            result = result.dropLast()
        }
        return result
    }
}

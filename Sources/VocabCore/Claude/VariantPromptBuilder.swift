import Foundation

/// Промт пакетного доповнення варіантів (§7.7).
public enum VariantPromptBuilder {
    /// Елемент у JSON-масиві `{{ITEMS}}`: `{"id":1,"keep":"casa","meaning":["бігти"],"pos":"verb","word":"run"}`.
    /// Відсутні значення не пишуться.
    struct EncodedItem: Encodable {
        let id: Int
        let word: String
        let pos: String?
        let meaning: [String]?
        let keep: String?
    }

    /// `system` = `language.prompt.batchSystem`; `user` = `batchUser`, де `{{ITEMS}}` — компактний JSON-масив
    /// (`.sortedKeys`, без `prettyPrinted`) усередині `<items>…</items>` (теги — у шаблоні).
    public static func buildBatch(items: [VariantRequestItem], language: RenderingLanguage, pair: LanguagePair) -> BuiltPrompt {
        let user = language.prompt.batchUser
            .replacingOccurrences(of: RenderingPromptTemplate.itemsPlaceholder, with: encodeItems(items))
        return BuiltPrompt(system: language.prompt.batchSystem, user: user)
    }

    /// Компактний JSON-масив елементів.
    static func encodeItems(_ items: [VariantRequestItem]) -> String {
        let encoded = items.map { item in
            EncodedItem(
                id: item.ref,
                word: item.word,
                pos: nonEmpty(item.partOfSpeech),
                meaning: item.meaning.isEmpty ? nil : Array(item.meaning.prefix(VariantRequestItem.maxMeaningCount)),
                keep: nonEmpty(item.keepWord)
            )
        }
        let encoder = JSONEncoder()
        // Без `.withoutEscapingSlashes`: «/» кодується як «\/», тож «</items>» у слові/перекладі не закриє тег;
        // «<» додатково екрануємо як «\u003c» (валідний JSON-escape) — жоден тег не з'явиться всередині даних.
        encoder.outputFormatting = [.sortedKeys]
        // Кодування рядків, цілих і масивів рядків не може завершитися помилкою (помилки JSONEncoder
        // стосуються лише нескінченних чисел і некоректних контейнерів), тож запасне значення — формальність.
        guard let data = try? encoder.encode(encoded), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text.replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

import Foundation

/// Результат розбору файлу імпорту: валідні записи (ще без згортання дублікатів) і причини пропуску невалідних.
public struct ParsedImport: Equatable, Sendable {
    public var entries: [Entry]
    public var skippedReasons: [String]

    public init(entries: [Entry], skippedReasons: [String] = []) {
        self.entries = entries
        self.skippedReasons = skippedReasons
    }
}

/// Валідація і розбір файлу імпорту (§10, D13).
///
/// Помилки рівня файлу (`ImportError`) відхиляють імпорт цілком. Окремі невалідні записи пропускаються з причиною
/// «Запис #N: …» (N — порядковий номер у `entries`, з 1). Обов'язкові поля запису: `id` (UUID), `languagePair`
/// (непорожній рядок; невідома пара допускається, §3.1), `word` (непорожній), `status` ∈ `ready|pending|failed`,
/// `createdAt`, `updatedAt` (ISO8601), `translations` (масив рядків; для `ready` — хоча б один непорожній після
/// очищення). `word` очищується `TextNormalizer.clean`, переклади — trim і згортання пробілів (див. `normalized`).
///
/// M7: некоректні варіанти відкидаються стійким декодуванням `Entry` (запис не пропускається, у звіт не
/// потрапляє); варіанти очищуються (`word` — `clean`, переклади — як для запису; `ready` без слова чи перекладів
/// відкидається); `sourceLanguage`, не допустимий для відомої пари, скидається в `nil`.
public enum DictionaryImporter {
    /// - Parameter registry: лише для перевірки `sourceLanguage` (допустимі мови відомої пари).
    public static func parse(_ data: Data, registry: LanguagePairRegistry = .shared) throws -> ParsedImport {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.notJSON
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ImportError.emptyFile
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ImportError.notJSON
        }
        guard let object = root as? [String: Any] else {
            throw ImportError.notJSON
        }

        guard object["schemaVersion"] != nil,
              let probe = try? JSONCoding.makeDecoder().decode(SchemaVersionProbe.self, from: data) else {
            throw ImportError.missingSchemaVersion
        }
        guard probe.schemaVersion == DictionaryFile.currentSchemaVersion else {
            throw ImportError.unsupportedSchemaVersion(probe.schemaVersion)
        }

        guard let rawEntries = object["entries"] as? [Any] else {
            throw ImportError.missingEntries
        }

        var entries: [Entry] = []
        var skipped: [String] = []
        for (index, raw) in rawEntries.enumerated() {
            switch validateEntry(raw, registry: registry) {
            case .success(let entry):
                entries.append(entry)
            case .failure(let problem):
                skipped.append(L10n.text(.importEntryProblem, ["index": String(index + 1), "problem": problem.text]))
            }
        }
        return ParsedImport(entries: entries, skippedReasons: skipped)
    }

    // MARK: - Private

    struct EntryProblem: Error {
        let text: String
    }

    private static func validateEntry(_ raw: Any, registry: LanguagePairRegistry) -> Result<Entry, EntryProblem> {
        guard let fields = raw as? [String: Any] else {
            return .failure(EntryProblem(text: L10n.text(.importEntryNotObject)))
        }

        func missing(_ name: String) -> Result<Entry, EntryProblem> {
            .failure(EntryProblem(text: L10n.text(
                fields[name] == nil ? .importEntryMissingField : .importEntryInvalidField,
                ["name": name]
            )))
        }

        guard let idText = fields["id"] as? String, UUID(uuidString: idText) != nil else {
            return missing("id")
        }
        guard let pair = fields["languagePair"] as? String,
              !pair.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return missing("languagePair")
        }
        guard let word = fields["word"] as? String,
              !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return missing("word")
        }
        guard let statusText = fields["status"] as? String, EntryStatus(rawValue: statusText) != nil else {
            return missing("status")
        }
        guard let created = fields["createdAt"] as? String, JSONCoding.parseDate(created) != nil else {
            return missing("createdAt")
        }
        guard let updated = fields["updatedAt"] as? String, JSONCoding.parseDate(updated) != nil else {
            return missing("updatedAt")
        }
        guard let translations = fields["translations"] as? [Any], translations.allSatisfy({ $0 is String }) else {
            return missing("translations")
        }
        // Обов'язкові поля перевірено; повне декодування ловить некоректні необов'язкові поля (example тощо).
        let decoded: Entry
        do {
            let data = try JSONSerialization.data(withJSONObject: fields)
            decoded = try JSONCoding.makeDecoder().decode(Entry.self, from: data)
        } catch let DecodingError.typeMismatch(_, context) {
            return .failure(EntryProblem(text: invalidFieldText(context)))
        } catch let DecodingError.valueNotFound(_, context) {
            return .failure(EntryProblem(text: invalidFieldText(context)))
        } catch let DecodingError.keyNotFound(key, context) {
            let path = (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            return .failure(EntryProblem(text: L10n.text(.importEntryMissingField, ["name": path])))
        } catch let DecodingError.dataCorrupted(context) {
            return .failure(EntryProblem(text: invalidFieldText(context)))
        } catch {
            return .failure(EntryProblem(text: L10n.text(.importEntryInvalidFormat)))
        }
        return normalized(decoded, registry: registry)
    }

    /// Очищення імпортованого запису (як для виділення/ручного додавання): `word` — `TextNormalizer.clean`;
    /// переклади — згорнуті пробіли + trim, порожні відкидаються. Крайня пунктуація перекладів **не** знімається
    /// (`clean` зрізав би, напр., дужку в «бігти (швидко)»). `ready` без жодного непорожнього перекладу — пропуск.
    static func normalized(_ entry: Entry, registry: LanguagePairRegistry = .shared) -> Result<Entry, EntryProblem> {
        var result = entry
        result.word = TextNormalizer.clean(entry.word)
        guard !result.word.isEmpty else {
            return .failure(EntryProblem(text: L10n.text(.importEntryInvalidField, ["name": "word"])))
        }
        result.translations = entry.translations
            .map(collapseWhitespace)
            .filter { !$0.isEmpty }
        if result.status == .ready && result.translations.isEmpty {
            return .failure(EntryProblem(text: L10n.text(.importEntryReadyWithoutTranslations)))
        }
        result.variants = normalizedVariants(entry.variants)
        if let sourceLanguage = result.sourceLanguage, let pair = registry.pair(id: result.languagePair) {
            // Мова пари — це `nil` за визначенням; недопустима мова — теж `nil`.
            if sourceLanguage == pair.sourceLanguageCode || pair.rendering(id: sourceLanguage) == nil {
                result.sourceLanguage = nil
            }
        }
        return .success(result)
    }

    /// Очищення варіантів: `word` → `clean` (порожнє → `nil`), переклади — як для запису; `ready` без слова чи
    /// без перекладів відкидається. Порожній результат → `nil`.
    static func normalizedVariants(_ variants: [String: EntryVariant]?) -> [String: EntryVariant]? {
        guard let variants else { return nil }
        var result: [String: EntryVariant] = [:]
        for (languageID, variant) in variants {
            var cleaned = variant
            if let word = variant.word {
                let cleanedWord = TextNormalizer.clean(word)
                cleaned.word = cleanedWord.isEmpty ? nil : cleanedWord
            }
            cleaned.translations = variant.translations
                .map(collapseWhitespace)
                .filter { !$0.isEmpty }
            if cleaned.status == .ready && (cleaned.word == nil || cleaned.translations.isEmpty) {
                continue
            }
            result[languageID] = cleaned
        }
        return result.isEmpty ? nil : result
    }

    /// Будь-які пробільні символи → один пробіл, trim.
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { character in
            character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        })
        .joined(separator: " ")
    }

    /// «некоректне поле <шлях>»; порожній шлях (помилка на рівні самого запису) — «некоректне поле запису».
    private static func invalidFieldText(_ context: DecodingError.Context) -> String {
        let path = context.codingPath
            .filter { $0.intValue == nil }
            .map(\.stringValue)
            .joined(separator: ".")
        return path.isEmpty
            ? L10n.text(.importEntryInvalidRecordField)
            : L10n.text(.importEntryInvalidField, ["name": path])
    }
}

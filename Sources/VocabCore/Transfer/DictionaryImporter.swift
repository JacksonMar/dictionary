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
public enum DictionaryImporter {
    public static func parse(_ data: Data) throws -> ParsedImport {
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
            switch validateEntry(raw) {
            case .success(let entry):
                entries.append(entry)
            case .failure(let problem):
                skipped.append("Запис #\(index + 1): \(problem.text)")
            }
        }
        return ParsedImport(entries: entries, skippedReasons: skipped)
    }

    // MARK: - Private

    struct EntryProblem: Error {
        let text: String
    }

    private static func validateEntry(_ raw: Any) -> Result<Entry, EntryProblem> {
        guard let fields = raw as? [String: Any] else {
            return .failure(EntryProblem(text: "не є об'єктом"))
        }

        func missing(_ name: String) -> Result<Entry, EntryProblem> {
            .failure(EntryProblem(text: fields[name] == nil ? "відсутнє поле \(name)" : "некоректне поле \(name)"))
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
            return .failure(EntryProblem(text: "некоректне поле \(fieldName(context))"))
        } catch let DecodingError.valueNotFound(_, context) {
            return .failure(EntryProblem(text: "некоректне поле \(fieldName(context))"))
        } catch let DecodingError.keyNotFound(key, context) {
            let path = (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            return .failure(EntryProblem(text: "відсутнє поле \(path)"))
        } catch let DecodingError.dataCorrupted(context) {
            return .failure(EntryProblem(text: "некоректне поле \(fieldName(context))"))
        } catch {
            return .failure(EntryProblem(text: "некоректний формат запису"))
        }
        return normalized(decoded)
    }

    /// Очищення імпортованого запису (як для виділення/ручного додавання): `word` — `TextNormalizer.clean`;
    /// переклади — згорнуті пробіли + trim, порожні відкидаються. Крайня пунктуація перекладів **не** знімається
    /// (`clean` зрізав би, напр., дужку в «бігти (швидко)»). `ready` без жодного непорожнього перекладу — пропуск.
    static func normalized(_ entry: Entry) -> Result<Entry, EntryProblem> {
        var result = entry
        result.word = TextNormalizer.clean(entry.word)
        guard !result.word.isEmpty else {
            return .failure(EntryProblem(text: "некоректне поле word"))
        }
        result.translations = entry.translations
            .map(collapseWhitespace)
            .filter { !$0.isEmpty }
        if result.status == .ready && result.translations.isEmpty {
            return .failure(EntryProblem(text: "готовий запис без перекладів"))
        }
        return .success(result)
    }

    /// Будь-які пробільні символи → один пробіл, trim.
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { character in
            character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        })
        .joined(separator: " ")
    }

    private static func fieldName(_ context: DecodingError.Context) -> String {
        let path = context.codingPath
            .filter { $0.intValue == nil }
            .map(\.stringValue)
            .joined(separator: ".")
        return path.isEmpty ? "запису" : path
    }
}

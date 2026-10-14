import Foundation

/// Розбір відповіді пакетного доповнення (§7.7): один JSON-масив елементів `{"id": 1, "word": …}`.
public enum VariantBatchResponseParser {
    /// - Не масив / не JSON → `ClaudeError.invalidResponse`.
    /// - `id` — ціле (або рядок-число) з запитаного набору; інакше елемент ігнорується; дубль `id` — перший виграє.
    /// - Поля валідуються як у §7.4 з `kind` елемента → `.ready` або `.invalid(reason)`.
    /// - Запитаний `id` без елемента → `.missing`. Часткова відповідь — успішна.
    public static func parse(_ text: String, items: [VariantRequestItem]) throws -> [Int: VariantItemOutcome] {
        let array = try jsonArray(in: text)
        var requested: [Int: VariantRequestItem] = [:]
        for item in items where requested[item.ref] == nil {
            requested[item.ref] = item
        }

        var outcomes: [Int: VariantItemOutcome] = [:]
        for element in array {
            guard let object = element as? [String: Any],
                  let ref = identifier(object["id"]),
                  let item = requested[ref],
                  outcomes[ref] == nil else {
                continue
            }
            do {
                outcomes[ref] = .ready(try LookupResponseParser.parseObject(object, kind: item.kind))
            } catch ClaudeError.invalidResponse(let reason) {
                outcomes[ref] = .invalid(reason)
            } catch {
                outcomes[ref] = .invalid("невідома помилка розбору")
            }
        }
        for ref in requested.keys where outcomes[ref] == nil {
            outcomes[ref] = .missing
        }
        return outcomes
    }

    // MARK: - Private

    /// Знімає code fence; підрядок від першої `[` до останньої `]`.
    static func jsonArray(in text: String) throws -> [Any] {
        let unfenced = LookupResponseParser.stripCodeFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let start = unfenced.firstIndex(of: "["),
              let end = unfenced.lastIndex(of: "]"),
              start < end else {
            throw ClaudeError.invalidResponse("відповідь не містить JSON-масиву")
        }
        let candidate = String(unfenced[start...end])
        guard let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)),
              let array = object as? [Any] else {
            throw ClaudeError.invalidResponse("невалідний JSON-масив")
        }
        return array
    }

    /// Ціле число або рядок-число; дробові та інші значення → `nil`.
    static func identifier(_ value: Any?) -> Int? {
        switch value {
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        case let int as Int:
            return int
        case let double as Double:
            guard double.isFinite, double == double.rounded(), abs(double) < Double(Int32.max) else {
                return nil
            }
            return Int(double)
        default:
            return nil
        }
    }
}

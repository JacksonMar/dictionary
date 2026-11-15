import Foundation

/// Один кандидат на текст із вхідних даних листа «Поділитися» (`NSExtensionItem`), уже прочитаний з
/// `NSItemProvider` (IOS_PLAN I3.3). Лише Foundation — тестується без UIKit.
enum ShareTextCandidate: Equatable, Sendable {
    /// `NSExtensionItem.attributedContentText` (рядок): текст елемента — часто заголовок сторінки або текст для
    /// допису, не обов'язково виділення.
    case attributedContentText(String)
    /// Вкладення `public.plain-text`: так застосунки (Safari, Notes, Telegram, Chrome) віддають **виділений** текст.
    case plainText(String)
    /// Вкладення `public.url` — ігнорується (посилання на сторінку не є словом для словника).
    case url(URL)
}

/// Результат вилучення тексту.
enum ShareTextExtraction: Equatable, Sendable {
    /// Текст для inbox (обрізаний з обох боків; не довший за `ShareTextExtractor.maxLength` символів);
    /// `truncated` — оригінал був довшим.
    case accepted(text: String, truncated: Bool)
    /// Тексту немає (лише URL, порожньо або самі пробіли) — нічого не зберігається.
    case rejected
}

/// Чиста функція «кандидати → текст для inbox» (IOS_PLAN §3.3, I3.3).
///
/// Порядок переваги: спершу вкладення `public.plain-text` (виділений текст), потім `attributedContentText`; у межах
/// одного виду — порядок надходження. Кандидат, що після обрізання пробілів порожній або є лише веб-посиланням
/// (`http(s)://…` без пробілів — Chrome/Safari віддають URL сторінки ще й як текст), пропускається; `.url` —
/// ігнорується завжди. Результат обрізається до `maxLength` символів (`Character`, без розриву графем).
/// Валідація слова (≤ 120 символів, ≤ 8 слів) — у застосунку при інжесті, а не тут.
enum ShareTextExtractor {
    static let maxLength = 2000

    static func extract(from candidates: [ShareTextCandidate]) -> ShareTextExtraction {
        var plainTexts: [String] = []
        var contentTexts: [String] = []
        for candidate in candidates {
            switch candidate {
            case .plainText(let text):
                plainTexts.append(text)
            case .attributedContentText(let text):
                contentTexts.append(text)
            case .url:
                continue
            }
        }
        for raw in plainTexts + contentTexts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isWebLink(trimmed) else { continue }
            if trimmed.count > maxLength {
                let prefix = String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
                return .accepted(text: prefix, truncated: true)
            }
            return .accepted(text: trimmed, truncated: false)
        }
        return .rejected
    }

    /// Увесь текст — одне посилання `http://` / `https://` (без пробілів).
    static func isWebLink(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        let lowered = text.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return false }
        return URL(string: text)?.host != nil
    }
}

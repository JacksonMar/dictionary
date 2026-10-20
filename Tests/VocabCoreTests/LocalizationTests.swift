import Foundation
import XCTest
@testable import VocabCore

/// M9.1 — таблиці текстів інтерфейсу повні й узгоджені (D32).
final class LocalizationTests: XCTestCase {
    override func tearDown() {
        L10n.setCurrent(.en)
        super.tearDown()
    }

    /// Множина імен плейсхолдерів `{name}` у шаблоні.
    static func placeholders(_ template: String) -> Set<String> {
        var result = Set<String>()
        var index = template.startIndex
        while let open = template[index...].firstIndex(of: "{") {
            guard let close = template[open...].firstIndex(of: "}") else { break }
            let name = String(template[template.index(after: open)..<close])
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                result.insert(name)
            }
            index = template.index(after: open)
        }
        return result
    }

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) }
    }

    func testEveryKeyHasNonEmptyTextInAllLanguages() {
        XCTAssertFalse(L10nKey.allCases.isEmpty)
        XCTAssertEqual(AppLanguage.allCases, [.en, .uk])
        for key in L10nKey.allCases {
            for language in AppLanguage.allCases {
                let text = L10n.text(key, language: language)
                XCTAssertFalse(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(key.rawValue) is empty in \(language.rawValue)"
                )
            }
        }
    }

    func testKeyRawValuesAreUniqueDottedIdentifiers() {
        let raws = L10nKey.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count, "duplicate raw values")
        for raw in raws {
            XCTAssertTrue(raw.contains("."), "\(raw) is not a dotted id")
            XCTAssertFalse(raw.contains(" "), raw)
        }
    }

    func testPlaceholdersMatchAcrossLanguages() {
        for key in L10nKey.allCases {
            let english = Self.placeholders(L10nEnglish.text(key))
            let ukrainian = Self.placeholders(L10nUkrainian.text(key))
            XCTAssertEqual(english, ukrainian, "placeholders differ for \(key.rawValue)")
        }
    }

    func testEnglishTableHasNoCyrillic() {
        for key in L10nKey.allCases {
            let text = L10n.text(key, language: .en)
            XCTAssertFalse(Self.containsCyrillic(text), "\(key.rawValue): \(text)")
        }
    }

    func testUkrainianTableIsActuallyTranslated() {
        // Санітарна перевірка: більшість українських текстів містить кирилицю і відрізняється від англійських.
        let translated = L10nKey.allCases.filter { key in
            Self.containsCyrillic(L10n.text(key, language: .uk))
                && L10n.text(key, language: .uk) != L10n.text(key, language: .en)
        }
        XCTAssertGreaterThan(Double(translated.count), Double(L10nKey.allCases.count) * 0.8)
    }

    func testDefaultLanguageIsEnglish() {
        XCTAssertEqual(AppLanguage.default, .en)
        // Жоден набір не лишає мову зміненою (pinInterfaceLanguage повертає `.en`), тож тут — стартове значення.
        XCTAssertEqual(L10n.current, .en)
        XCTAssertEqual(AppLanguage(storedValue: nil), .en)
        XCTAssertEqual(AppLanguage(storedValue: "xx"), .en)
        XCTAssertEqual(AppLanguage(storedValue: ""), .en)
        XCTAssertEqual(AppLanguage(storedValue: "en"), .en)
        XCTAssertEqual(AppLanguage(storedValue: "uk"), .uk)
        XCTAssertEqual(L10n.text(.notificationAddedTitle), "Added")
    }

    func testNativeNamesAndPickerLabel() {
        XCTAssertEqual(AppLanguage.en.nativeName, "English")
        XCTAssertEqual(AppLanguage.uk.nativeName, "Українська")
        XCTAssertTrue(AppLanguage.pickerLabel.contains("Interface language"))
        XCTAssertTrue(AppLanguage.pickerLabel.contains("Мова інтерфейсу"))
    }

    func testSetCurrentSwitchesDefaultLanguage() {
        L10n.setCurrent(.uk)
        XCTAssertEqual(L10n.current, .uk)
        XCTAssertEqual(L10n.text(.notificationAddedTitle), "Додано")
        XCTAssertEqual(L10n.text(.notificationAddedTitle, language: .en), "Added", "explicit language wins")

        L10n.setCurrent(.en)
        XCTAssertEqual(L10n.current, .en)
        XCTAssertEqual(L10n.text(.notificationAddedTitle), "Added")
        XCTAssertEqual(L10n.text(.notificationAddedTitle, language: .uk), "Додано")
    }

    func testCurrentIsSafeUnderConcurrentAccess() {
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index % 10 == 0 {
                L10n.setCurrent(index % 20 == 0 ? .uk : .en)
            }
            _ = L10n.text(.paginationLabel, ["number": "1", "count": "2"])
        }
        L10n.setCurrent(.en)
        XCTAssertEqual(L10n.current, .en)
    }

    func testFormatSubstitutesNamedPlaceholdersSinglePass() {
        XCTAssertEqual(
            L10n.text(.paginationLabel, ["number": "2", "count": "5"], language: .en),
            "Page 2 of 5"
        )
        XCTAssertEqual(
            L10n.text(.paginationLabel, ["number": "2", "count": "5"], language: .uk),
            "Сторінка 2 з 5"
        )
        // Значення не скануються повторно: `{count}` у підставленому значенні лишається буквально.
        XCTAssertEqual(L10n.format("{a} and {b}", ["a": "{b}", "b": "x"]), "{b} and x")
        XCTAssertEqual(
            L10n.text(.notificationAddedBody, ["word": "{word}"], language: .en),
            "Added: {word}"
        )
        XCTAssertEqual(L10n.format("{n}{n}", ["n": "1"]), "11", "repeated placeholder")
        XCTAssertEqual(L10n.format("no placeholders", ["n": "1"]), "no placeholders")
        XCTAssertEqual(L10n.format("{not a name} {n}", ["n": "1"]), "{not a name} 1")
        XCTAssertEqual(L10n.format("{{n}}", ["n": "1"]), "{1}")
        XCTAssertEqual(L10n.format("open { only", ["n": "1"]), "open { only")
    }

    func testMissingArgumentLeavesToken() {
        XCTAssertEqual(L10n.format("{a} {b}", ["a": "1"]), "1 {b}")
        XCTAssertEqual(L10n.format("{a} {b}", [:]), "{a} {b}")
        XCTAssertEqual(L10n.text(.paginationLabel, language: .en), "Page {number} of {count}")
        XCTAssertEqual(L10n.text(.paginationLabel, ["number": "3"], language: .en), "Page 3 of {count}")
    }
}

import Foundation
import XCTest

/// I4.3 (IOS_PLAN §7 I4, DI17) — Linux-side checks of the iOS stage-I4 resources in the repository sources (the iOS
/// targets cannot be built on Linux):
/// - `Mobile/Info.plist` registers the `vocabapp` URL scheme (`CFBundleURLTypes`) used by the widget / deep links;
/// - `Mobile/Resources/{en,uk}.lproj/AppShortcuts.strings`: valid, same keys, every key and value keeps
///   `${applicationName}`, keys = the phrases in `VocabShortcuts.swift`, Ukrainian values in Cyrillic;
/// - `Mobile/Resources/{en,uk}.lproj/Localizable.strings`: App Intents metadata, same keys, every literal from
///   `Mobile/Sources/Intents/*.swift` is a key, no stale keys, placeholders preserved, Ukrainian values in Cyrillic;
/// - `Extensions/Widget/Resources/{en,uk}.lproj/Localizable.strings`: same keys, every `Text("widget.…")` key used
///   by the widget source exists in both tables, the widget opens `vocabapp://voice`.
/// The hosted counterpart `InfoPlistMobileTests.testURLSchemeRegistered` reads the built app bundle on iOS.
final class MobileI4ResourcesTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func url(_ relativePath: String) -> URL {
        repositoryRoot.appendingPathComponent(relativePath)
    }

    private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value)
    }

    private static func hasCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCyrillic)
    }

    /// Brand names that legitimately stay untranslated in Ukrainian tables.
    private static let untranslatedBrandValues: Set<String> = ["VocabApp"]

    private func parseStrings(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let data = try Data(contentsOf: Self.url(relativePath))
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: String], "\(relativePath) is not a string table", file: file, line: line)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.url(relativePath), encoding: .utf8)
    }

    private func sources(in relativeDirectory: String) throws -> [(name: String, text: String)] {
        let directory = Self.url(relativeDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map { ($0, try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// All first capture groups of `pattern` in `text`.
    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            XCTFail("bad regex \(pattern)")
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    /// Swift interpolations in App Intents literals → the `.strings` placeholder form:
    /// `\(.applicationName)` → `${applicationName}`, `\(\.$text)` → `${text}`.
    private static func stringsKey(fromSwiftLiteral literal: String) -> String {
        var key = literal
        for (pattern, template) in [(#"\\\(\\\.\$(\w+)\)"#, "\\${$1}"), (#"\\\(\.(\w+)\)"#, "\\${$1}")] {
            let regex = try! NSRegularExpression(pattern: pattern) // swiftlint:disable:this force_try
            key = regex.stringByReplacingMatches(
                in: key, options: [], range: NSRange(key.startIndex..<key.endIndex, in: key), withTemplate: template
            )
        }
        return key
    }

    private static func placeholders(_ text: String) -> Set<String> {
        Set(captures(#"(\$\{\w+\})"#, in: text))
    }

    // MARK: - URL scheme

    func testMobileInfoPlistRegistersVocabappScheme() throws {
        let data = try Data(contentsOf: Self.url("Mobile/Info.plist"))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]], "CFBundleURLTypes missing")
        XCTAssertFalse(urlTypes.isEmpty)
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("vocabapp"), "schemes: \(schemes)")
        for type in urlTypes {
            let name = (type["CFBundleURLName"] as? String) ?? ""
            XCTAssertFalse(name.isEmpty, "CFBundleURLName should identify the scheme owner")
        }
        // The parser uses the same scheme.
        let router = try source("Mobile/Sources/Router.swift")
        XCTAssertTrue(router.contains(#"static let scheme = "vocabapp""#), "DeepLink.scheme must be vocabapp")
    }

    // MARK: - App Shortcuts phrases

    func testAppShortcutsStringsParityAndApplicationName() throws {
        let english = try parseStrings("Mobile/Resources/en.lproj/AppShortcuts.strings")
        let ukrainian = try parseStrings("Mobile/Resources/uk.lproj/AppShortcuts.strings")
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(ukrainian.keys), "en/uk AppShortcuts.strings must have the same keys")

        for (key, value) in english {
            XCTAssertTrue(key.contains("${applicationName}"), "key \(key)")
            XCTAssertTrue(value.contains("${applicationName}"), "en value \(value)")
            XCTAssertFalse(Self.hasCyrillic(value), "en value \(value) must be English")
        }
        for (key, value) in ukrainian {
            XCTAssertTrue(value.contains("${applicationName}"), "uk value for \(key): \(value)")
            XCTAssertTrue(Self.hasCyrillic(value), "uk value for \(key) must be Ukrainian: \(value)")
            XCTAssertNotEqual(value, key, "uk \(key) is untranslated")
        }
    }

    func testAppShortcutsKeysMatchPhrasesInSource() throws {
        let text = try source("Mobile/Sources/Intents/VocabShortcuts.swift")
        let phrases = Self.captures(#""([^"\n]*\\\(\.applicationName\)[^"\n]*)""#, in: text)
            .map(Self.stringsKey(fromSwiftLiteral:))
        XCTAssertEqual(phrases.count, 6, "phrases found: \(phrases)")
        XCTAssertEqual(Set(phrases).count, phrases.count, "duplicate phrases")
        let english = try parseStrings("Mobile/Resources/en.lproj/AppShortcuts.strings")
        XCTAssertEqual(Set(english.keys), Set(phrases), "AppShortcuts.strings keys must be exactly the source phrases")
    }

    // MARK: - App Intents metadata (Localizable.strings)

    /// System-read literals in `Mobile/Sources/Intents/*.swift` (titles, descriptions, parameters, summaries, enum
    /// display representations, App Shortcut short titles).
    private func intentMetadataLiterals() throws -> Set<String> {
        let patterns = [
            #"LocalizedStringResource\s*=\s*"([^"\n]+)""#,
            #"IntentDescription\("([^"\n]+)"\)"#,
            #"title:\s*"([^"\n]+)""#,
            #"requestValueDialog:\s*"([^"\n]+)""#,
            #"Summary\("([^"\n]+)""#,
            #"TypeDisplayRepresentation\s*=\s*"([^"\n]+)""#,
            #"^\s*\.\w+:\s*"([^"\n]+)",?\s*$"#,
            #"shortTitle:\s*"([^"\n]+)""#,
        ]
        var literals: Set<String> = []
        for (_, text) in try sources(in: "Mobile/Sources/Intents") {
            for pattern in patterns {
                Self.captures(pattern, in: text).forEach { literals.insert(Self.stringsKey(fromSwiftLiteral: $0)) }
            }
        }
        return literals
    }

    func testIntentMetadataLocalizedInBothLanguages() throws {
        let english = try parseStrings("Mobile/Resources/en.lproj/Localizable.strings")
        let ukrainian = try parseStrings("Mobile/Resources/uk.lproj/Localizable.strings")
        XCTAssertEqual(Set(english.keys), Set(ukrainian.keys), "en/uk Localizable.strings must have the same keys")

        let literals = try intentMetadataLiterals()
        // Sanity: the extraction found the known metadata.
        for expected in ["Add to Dictionary", "Add by Voice", "Word", "Which word?", "Language", "Auto", "English",
                         "Italian", "Add ${text} to the dictionary", "Add a word by voice in ${language}"] {
            XCTAssertTrue(literals.contains(expected), "extractor missed \(expected); found \(literals.sorted())")
        }
        for literal in literals {
            XCTAssertNotNil(english[literal], "en.lproj/Localizable.strings misses \(literal)")
            XCTAssertNotNil(ukrainian[literal], "uk.lproj/Localizable.strings misses \(literal)")
        }
        XCTAssertEqual(Set(english.keys).subtracting(literals), [], "stale keys not used by Intents sources")

        for (key, value) in english {
            XCTAssertEqual(value, key, "en value must equal the English key (DI17)")
        }
        for (key, value) in ukrainian {
            XCTAssertTrue(Self.hasCyrillic(value), "uk \(key) must be Ukrainian: \(value)")
            XCTAssertEqual(Self.placeholders(value), Self.placeholders(key), "uk \(key) placeholders: \(value)")
        }
    }

    // MARK: - Widget

    func testWidgetStringsParityAndTextKeysExist() throws {
        let english = try parseStrings("Extensions/Widget/Resources/en.lproj/Localizable.strings")
        let ukrainian = try parseStrings("Extensions/Widget/Resources/uk.lproj/Localizable.strings")
        XCTAssertEqual(Set(english.keys), Set(ukrainian.keys), "en/uk widget tables must have the same keys")

        var usedKeys: Set<String> = []
        for (_, text) in try sources(in: "Extensions/Widget/Sources") {
            Self.captures(#"Text\("(widget\.[^"\n]+)"\)"#, in: text).forEach { usedKeys.insert($0) }
        }
        XCTAssertTrue(usedKeys.isSuperset(of: ["widget.voice.displayName", "widget.voice.description",
                                               "widget.voice.title", "widget.voice.action"]),
                      "used keys: \(usedKeys.sorted())")
        for key in usedKeys {
            XCTAssertNotNil(english[key], "en widget table misses \(key)")
            XCTAssertNotNil(ukrainian[key], "uk widget table misses \(key)")
        }
        XCTAssertEqual(Set(english.keys).subtracting(usedKeys), [], "widget keys not used by the source")

        for (key, value) in english {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "en \(key)")
            XCTAssertFalse(Self.hasCyrillic(value), "en \(key) must be English")
        }
        for (key, value) in ukrainian {
            if Self.untranslatedBrandValues.contains(value) {
                XCTAssertEqual(value, english[key], "brand value \(key) identical in en/uk")
                continue
            }
            XCTAssertTrue(Self.hasCyrillic(value), "uk \(key) must be Ukrainian: \(value)")
        }
    }

    func testWidgetOpensVoiceDeepLinkAndShipsResources() throws {
        let widget = try sources(in: "Extensions/Widget/Sources").map(\.text).joined(separator: "\n")
        XCTAssertTrue(widget.contains(#"URL(string: "vocabapp://voice")"#), "widget must open vocabapp://voice")
        XCTAssertTrue(widget.contains(".widgetURL("))
        XCTAssertTrue(widget.contains("policy: .never"), "one static timeline entry, never refreshed")
        // The widget does not touch App Group / dictionary (IOS_PLAN §4).
        XCTAssertFalse(widget.contains("containerURL"))
        XCTAssertFalse(widget.contains("import VocabCore"))

        let project = try source("project.yml")
        XCTAssertTrue(project.contains("sources: [Extensions/Widget/Sources, Extensions/Widget/Resources]"),
                      "widget resources must be in the VocabWidget target")
    }
}

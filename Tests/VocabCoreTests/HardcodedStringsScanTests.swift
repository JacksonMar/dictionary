import Foundation
import XCTest

/// M9.2 — у коді ядра й застосунку немає жорстко закодованого українського тексту поза таблицями (D33).
///
/// Простий quote-aware токенізатор Swift: коментарі `//…` і `/* … */` (вкладені) вирізаються лише **поза**
/// рядковими літералами; літерали — `"…"`, `"""…"""`, raw `#"…"#`, з урахуванням екранування `\"` та
/// інтерполяції `\( … )` (усередині якої знову код із власними літералами).
/// Обмеження: англійські літерали не перевіряються — повноту англійського UI покриває ручна перевірка M9.md B.
final class HardcodedStringsScanTests: XCTestCase {
    struct Literal: Equatable {
        let line: Int
        let text: String
    }

    // MARK: - Tokenizer

    struct Tokenizer {
        private let s: [Unicode.Scalar]
        private var i = 0
        private var line = 1
        private(set) var literals: [Literal] = []

        init(_ source: String) {
            s = Array(source.unicodeScalars)
        }

        static func literals(in source: String) -> [Literal] {
            var tokenizer = Tokenizer(source)
            tokenizer.code(untilCloseParen: false)
            return tokenizer.literals
        }

        private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            i + offset < s.count ? s[i + offset] : nil
        }

        private mutating func advance() {
            if s[i] == "\n" { line += 1 }
            i += 1
        }

        private func matches(_ text: String, at offset: Int = 0) -> Bool {
            var k = i + offset
            for scalar in text.unicodeScalars {
                guard k < s.count, s[k] == scalar else { return false }
                k += 1
            }
            return true
        }

        mutating func code(untilCloseParen: Bool) {
            var depth = 0
            while let c = peek() {
                if matches("//") {
                    while let d = peek(), d != "\n" { advance() }
                } else if matches("/*") {
                    var nesting = 0
                    repeat {
                        if matches("/*") {
                            nesting += 1; advance(); advance()
                        } else if matches("*/") {
                            nesting -= 1; advance(); advance()
                        } else {
                            advance()
                        }
                    } while nesting > 0 && peek() != nil
                } else if c == "#" || c == "\"" {
                    var hashes = 0
                    while peek(hashes) == "#" { hashes += 1 }
                    if peek(hashes) == "\"" {
                        for _ in 0..<hashes { advance() }
                        stringLiteral(hashes: hashes)
                    } else {
                        advance()
                    }
                } else if c == "(" {
                    depth += 1; advance()
                } else if c == ")" {
                    if untilCloseParen && depth == 0 {
                        advance()
                        return
                    }
                    depth -= 1; advance()
                } else {
                    advance()
                }
            }
        }

        /// На вході `i` вказує на першу `"` відкривального роздільника.
        private mutating func stringLiteral(hashes: Int) {
            let startLine = line
            let multiline = matches("\"\"\"")
            let quote = multiline ? "\"\"\"" : "\""
            for _ in 0..<quote.unicodeScalars.count { advance() }
            let closing = quote + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            var text = ""
            while peek() != nil {
                if matches(closing) {
                    for _ in 0..<closing.unicodeScalars.count { advance() }
                    break
                }
                if matches(escape) {
                    let after = escape.unicodeScalars.count
                    if peek(after) == "(" {
                        for _ in 0...after { advance() }
                        // Інтерполяція: її вміст — код (з власними літералами), не текст літерала.
                        literals.append(Literal(line: startLine, text: text))
                        text = ""
                        code(untilCloseParen: true)
                        continue
                    }
                    if peek(after) != nil {
                        text.unicodeScalars.append(s[i + after])
                        for _ in 0...after { advance() }
                        continue
                    }
                }
                if !multiline && peek() == "\n" {
                    break // незакритий однорядковий літерал — не тягнемо далі
                }
                text.unicodeScalars.append(s[i])
                advance()
            }
            literals.append(Literal(line: startLine, text: text))
        }
    }

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x052F).contains($0.value) }
    }

    // MARK: - Repo

    /// Корінь репозиторію: `Tests/VocabCoreTests/<file>` → три рівні вгору.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func swiftFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    static func isExcludedDirectory(_ url: URL) -> Bool {
        url.pathComponents.contains("Localization") || url.pathComponents.contains("Languages")
    }

    // MARK: - Tests

    func testNoCyrillicStringLiteralsOutsideLocalizationTables() throws {
        let root = Self.repositoryRoot
        let core = root.appendingPathComponent("Sources/VocabCore")
        let app = root.appendingPathComponent("App/Sources")
        let coreFiles = Self.swiftFiles(under: core)
        let appFiles = Self.swiftFiles(under: app)
        XCTAssertGreaterThan(coreFiles.count, 20, "core sources not found at \(core.path)")
        XCTAssertGreaterThan(appFiles.count, 10, "app sources not found at \(app.path)")

        var violations: [String] = []
        var scannedLiterals = 0
        for file in (coreFiles + appFiles) where !Self.isExcludedDirectory(file) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.components(separatedBy: "\n")
            for literal in Tokenizer.literals(in: source) {
                scannedLiterals += 1
                guard Self.containsCyrillic(literal.text) else { continue }
                let lineText = literal.line - 1 < lines.count ? lines[literal.line - 1] : ""
                // Єдиний дозволений виняток — оголошення `PromptBuilder.retrySuffix` (частина промту, D34).
                if file.lastPathComponent == "PromptBuilder.swift", lineText.contains("static let retrySuffix") {
                    continue
                }
                let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                violations.append("\(relative):\(literal.line): \"\(literal.text)\"")
            }
        }
        XCTAssertGreaterThan(scannedLiterals, 100, "tokenizer found suspiciously few literals")
        XCTAssertTrue(violations.isEmpty, "Cyrillic string literals outside L10n tables:\n" + violations.joined(separator: "\n"))
    }

    func testRetrySuffixExceptionStillExists() throws {
        // Виняток вузький: якщо оголошення зникне чи переїде, виняток треба переглянути.
        let file = Self.repositoryRoot.appendingPathComponent("Sources/VocabCore/Claude/PromptBuilder.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let line = try XCTUnwrap(source.components(separatedBy: "\n").first { $0.contains("static let retrySuffix") })
        XCTAssertTrue(Self.containsCyrillic(line))
    }

    // MARK: - Tokenizer self-tests

    func testTokenizerIgnoresCommentsOutsideLiterals() {
        let source = """
        // Коментар «Додано»
        let a = "ok" /* блок «Додано» /* вкладений */ ще */
        let b = "x" // хвіст «Додано»
        """
        let texts = Tokenizer.literals(in: source).map(\.text)
        XCTAssertEqual(texts, ["ok", "x"])
    }

    func testTokenizerKeepsCommentMarkersInsideLiterals() {
        let source = #"""
        let url = "https://example.com/Додано"
        let c = "/* Привіт */"
        """#
        let literals = Tokenizer.literals(in: source)
        XCTAssertEqual(literals.map(\.text), ["https://example.com/Додано", "/* Привіт */"])
        XCTAssertEqual(literals.map(\.line), [1, 2])
        XCTAssertTrue(literals.allSatisfy { Self.containsCyrillic($0.text) })
    }

    func testTokenizerHandlesEscapedQuotesAndInterpolation() {
        let source = #"""
        let a = "say \"hi\" // not a comment Привіт"
        let b = "\(flag ? "так" : "no") end"
        let c = "x" // "Коментар"
        """#
        let texts = Tokenizer.literals(in: source).map(\.text)
        XCTAssertTrue(texts.contains("say \"hi\" // not a comment Привіт"), "\(texts)")
        XCTAssertTrue(texts.contains("так"), "\(texts)")
        XCTAssertTrue(texts.contains(" end"), "\(texts)")
        XCTAssertFalse(texts.contains { $0.contains("Коментар") }, "\(texts)")
    }

    func testTokenizerHandlesMultilineAndRawStrings() {
        let source = ##"""
        let m = """
            перший рядок "з лапками"
            // не коментар
            """
        let r = #"raw "Сира" \(not interpolation)"#
        // після: "Коментар"
        """##
        let literals = Tokenizer.literals(in: source)
        XCTAssertEqual(literals.count, 2, "\(literals)")
        XCTAssertTrue(literals[0].text.contains("перший рядок \"з лапками\""))
        XCTAssertTrue(literals[0].text.contains("// не коментар"))
        XCTAssertEqual(literals[0].line, 1)
        XCTAssertEqual(literals[1].text, #"raw "Сира" \(not interpolation)"#)
        XCTAssertEqual(literals[1].line, 5)
    }

    func testCyrillicDetection() {
        XCTAssertTrue(Self.containsCyrillic("Додано"))
        XCTAssertTrue(Self.containsCyrillic("ґіїє"))
        XCTAssertFalse(Self.containsCyrillic("Added — “run”"))
    }
}

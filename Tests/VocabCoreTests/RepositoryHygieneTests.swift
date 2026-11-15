import Foundation
import XCTest

/// I0.1 (IOS_PLAN.md §3.4, §6) — a real Apple Team ID never lands in the public repository.
///
/// Committed signing configuration (`project.yml`, `Config/*.xcconfig` except the gitignored `Local.xcconfig`) may only
/// assign `DEVELOPMENT_TEAM` / `VOCAB_DEVELOPMENT_TEAM` an empty value, `""` or a build-setting reference `$(…)`.
final class RepositoryHygieneTests: XCTestCase {
    /// Repository root: `Tests/VocabCoreTests/<file>` → three levels up.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    struct Assignment: Equatable {
        let file: String
        let line: Int
        let key: String
        let value: String
    }

    // MARK: - Parsing

    /// Matches `DEVELOPMENT_TEAM`, `VOCAB_DEVELOPMENT_TEAM`, optionally quoted and with a `[sdk=…]` condition,
    /// followed by `:` (YAML) or `=` (xcconfig).
    private static let assignmentPattern =
        #"^\s*["']?((?:VOCAB_)?DEVELOPMENT_TEAM(?:\[[^\]]*\])?)["']?\s*[:=](.*)$"#

    /// Strips a trailing comment: `#` for YAML (outside quotes), `//` for xcconfig.
    static func stripComment(_ text: String, yaml: Bool) -> String {
        if yaml {
            var inSingle = false
            var inDouble = false
            var previous: Character = " "
            for (offset, character) in text.enumerated() {
                switch character {
                case "'" where !inDouble: inSingle.toggle()
                case "\"" where !inSingle: inDouble.toggle()
                case "#" where !inSingle && !inDouble && (previous == " " || previous == "\t" || offset == 0):
                    return String(text.prefix(offset))
                default: break
                }
                previous = character
            }
            return text
        }
        if let range = text.range(of: "//") {
            return String(text[..<range.lowerBound])
        }
        return text
    }

    static func assignments(in source: String, file: String, yaml: Bool) -> [Assignment] {
        guard let regex = try? NSRegularExpression(pattern: assignmentPattern) else { return [] }
        var result: [Assignment] = []
        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let line = stripComment(rawLine, yaml: yaml)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            result.append(Assignment(
                file: file,
                line: index + 1,
                key: String(line[keyRange]),
                value: line[valueRange].trimmingCharacters(in: .whitespaces)
            ))
        }
        return result
    }

    /// Allowed: empty, `""`, `''`, or a single build-setting reference `$(NAME)` (optionally quoted).
    static func isAllowedValue(_ value: String) -> Bool {
        var unquoted = value
        if unquoted.count >= 2,
           let first = unquoted.first, let last = unquoted.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            unquoted = String(unquoted.dropFirst().dropLast())
        }
        unquoted = unquoted.trimmingCharacters(in: .whitespaces)
        if unquoted.isEmpty { return true }
        return unquoted.range(of: #"^\$\([A-Za-z_][A-Za-z0-9_]*\)$"#, options: .regularExpression) != nil
    }

    static func committedXcconfigs(root: URL) -> [URL] {
        let directory = root.appendingPathComponent("Config")
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "xcconfig" && $0.lastPathComponent != "Local.xcconfig" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Tests

    func testNoDevelopmentTeamCommitted() throws {
        let root = Self.repositoryRoot
        let projectURL = root.appendingPathComponent("project.yml")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        var all = Self.assignments(in: project, file: "project.yml", yaml: true)
        XCTAssertFalse(all.isEmpty, "project.yml must declare DEVELOPMENT_TEAM (found none)")

        let xcconfigs = Self.committedXcconfigs(root: root)
        let names = Set(xcconfigs.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("Signing.xcconfig"), "Config/Signing.xcconfig not found")
        XCTAssertTrue(names.contains("Local.example.xcconfig"), "Config/Local.example.xcconfig not found")
        for url in xcconfigs {
            let source = try String(contentsOf: url, encoding: .utf8)
            all += Self.assignments(in: source, file: "Config/\(url.lastPathComponent)", yaml: false)
        }

        let signingAssignments = all.filter { $0.file == "Config/Signing.xcconfig" }
        XCTAssertTrue(signingAssignments.contains { $0.key == "VOCAB_DEVELOPMENT_TEAM" })
        XCTAssertTrue(signingAssignments.contains { $0.key == "DEVELOPMENT_TEAM" })

        let violations = all.filter { !Self.isAllowedValue($0.value) }
        XCTAssertTrue(
            violations.isEmpty,
            "Team ID committed: " + violations.map { "\($0.file):\($0.line) \($0.key) = \($0.value)" }
                .joined(separator: "; ")
        )
    }

    func testSigningXcconfigIncludesLocalOverridesAfterDefaults() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Config/Signing.xcconfig")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func index(_ predicate: (String) -> Bool) -> Int? { lines.firstIndex(where: predicate) }

        let include = index { $0 == #"#include? "Local.xcconfig""# }
        let defaultTeam = index { $0.hasPrefix("VOCAB_DEVELOPMENT_TEAM") }
        let defaultPrefix = index { $0.hasPrefix("VOCAB_BUNDLE_ID_PREFIX") }
        let team = index { $0.hasPrefix("DEVELOPMENT_TEAM") }
        let group = index { $0.hasPrefix("VOCAB_APP_GROUP") }
        let all = [include, defaultTeam, defaultPrefix, team, group]
        XCTAssertFalse(all.contains { $0 == nil }, "missing line in Signing.xcconfig: \(all)")
        guard let include, let defaultTeam, let defaultPrefix, let team, let group else { return }
        XCTAssertLessThan(defaultTeam, include, "defaults must precede the Local.xcconfig include")
        XCTAssertLessThan(defaultPrefix, include, "defaults must precede the Local.xcconfig include")
        XCTAssertGreaterThan(team, include)
        XCTAssertGreaterThan(group, include)
    }

    func testLocalXcconfigIsGitignored() throws {
        let gitignore = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )
        let entries = gitignore.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(entries.contains("Config/Local.xcconfig"), ".gitignore must list Config/Local.xcconfig")
    }

    // MARK: - Self-checks of the parser (so a broken regex cannot make the main test vacuous)

    func testParserFlagsLiteralTeamIDs() {
        let yaml = """
        settings:
          DEVELOPMENT_TEAM: ABCDE12345
          "DEVELOPMENT_TEAM[sdk=iphoneos*]": "ABCDE12345"
          DEVELOPMENT_TEAM: ""   # empty is fine
          DEVELOPMENT_TEAM: "$(VOCAB_DEVELOPMENT_TEAM)"
          # DEVELOPMENT_TEAM: commented-out lines are ignored
        """
        let found = Self.assignments(in: yaml, file: "test.yml", yaml: true)
        XCTAssertEqual(found.count, 4)
        XCTAssertEqual(found.map { Self.isAllowedValue($0.value) }, [false, false, true, true])

        let xcconfig = """
        VOCAB_DEVELOPMENT_TEAM = ABCDE12345 // trailing comment
        VOCAB_DEVELOPMENT_TEAM =
        DEVELOPMENT_TEAM = $(VOCAB_DEVELOPMENT_TEAM)
        // VOCAB_DEVELOPMENT_TEAM = comment only
        """
        let xc = Self.assignments(in: xcconfig, file: "test.xcconfig", yaml: false)
        XCTAssertEqual(xc.count, 3)
        XCTAssertEqual(xc.map { Self.isAllowedValue($0.value) }, [false, true, true])
    }
}

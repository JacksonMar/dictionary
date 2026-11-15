import Foundation
import XCTest

/// I0.1 (IOS_PLAN.md §3.4, §6) — Tester's additions to `RepositoryHygieneTests`.
///
/// `RepositoryHygieneTests.testNoDevelopmentTeamCommitted` only looks at line-leading `KEY: value` / `KEY = value` in
/// `project.yml` and `Config/*.xcconfig`. Mutation checks showed literal Team IDs slipping through in:
/// YAML inline flow maps (`base: { DEVELOPMENT_TEAM: X }` — a style `project.yml` already uses), XcodeGen target
/// `attributes: { DevelopmentTeam: X }`, a YAML value on the next line, a `- KEY: X` list item, xcconfig keys with
/// two conditions (`KEY[config=Debug][sdk=iphoneos*]`), copies like `Config/Local.xcconfig.bak`, and a `.gitignore`
/// negation (`!Config/Local.xcconfig`). These tests close those gaps:
/// - scan every *committable* file (`git ls-files --cached --others --exclude-standard`) of a config-like type,
///   anywhere in the line, for literal `DEVELOPMENT_TEAM` / `VOCAB_DEVELOPMENT_TEAM` / `DevelopmentTeam` values;
/// - verify with git itself that `Config/Local.xcconfig` is ignored and not tracked;
/// - if a real `Config/Local.xcconfig` exists locally, verify its Team ID literal appears in no committable file
///   (catches e.g. a verbatim Xcode error pasted into `docs/development/manual-tests/I0.md`).
/// A local `Config/Local.xcconfig` with a real team never makes these tests fail by itself (it is gitignored).
final class RepositoryHygieneLeakScanTests: XCTestCase {
    static var root: URL { RepositoryHygieneTests.repositoryRoot }

    struct Finding: Equatable, CustomStringConvertible {
        let file: String
        let line: Int
        let key: String
        let value: String
        var description: String { "\(file):\(line) \(key) = \(value)" }
    }

    // MARK: - git helpers

    struct GitResult {
        let status: Int32
        let stdout: String
    }

    /// Runs git in the repository root. `safe.directory=*` because CI runs the Linux tests as root in a container
    /// on a checkout owned by another user. A missing git binary is a test failure, not a skip.
    static func git(_ arguments: [String]) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "safe.directory=*", "-C", root.path] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }

    /// Paths (relative to the root) that `git add -A` would commit: tracked files plus untracked, non-ignored ones.
    static func committablePaths() throws -> [String] {
        let result = try git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        guard result.status == 0 else {
            throw NSError(domain: "git", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: "git ls-files failed"])
        }
        let paths = result.stdout.split(separator: "\u{0}").map(String.init)
        // Deleted-but-tracked files are listed too; keep only existing ones.
        return Array(Set(paths)).sorted().filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    // MARK: - Scanner

    static let configExtensions: Set<String> = [
        "yml", "yaml", "xcconfig", "pbxproj", "plist", "entitlements", "json", "xcscheme", "xcsettings",
    ]

    /// Config-like files: known extensions, anything under `Config/`, and any name containing `.xcconfig`
    /// (backups such as `Local.xcconfig.bak`, `Local.xcconfig~`, `Local.xcconfig.orig`).
    static func isConfigLike(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        return configExtensions.contains(ext) || path.hasPrefix("Config/") || name.contains(".xcconfig")
    }

    /// Key anywhere in the line (not part of a longer identifier), optional quotes, any number of `[cond]`,
    /// then `:` or `=`.
    private static let keyPattern =
        #"(?<![A-Za-z0-9_$(])["']?((?:VOCAB_)?DEVELOPMENT_TEAM|DevelopmentTeam|developmentTeam)((?:\[[^\]]*\])*)["']?\s*[:=]"#

    /// Value right after the separator: a quoted string, or text up to `,` `}` `;` (flow maps, pbxproj) or end.
    static func valueToken(_ rest: Substring) -> String {
        let trimmed = rest.drop { $0 == " " || $0 == "\t" }
        if let quote = trimmed.first, quote == "\"" || quote == "'" {
            let body = trimmed.dropFirst()
            if let end = body.firstIndex(of: quote) {
                return String(quote) + body[..<end] + String(quote)
            }
            return String(trimmed)
        }
        let end = trimmed.firstIndex { $0 == "," || $0 == "}" || $0 == ";" } ?? trimmed.endIndex
        return trimmed[..<end].trimmingCharacters(in: .whitespaces)
    }

    static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    static func stripComment(_ line: String, path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "yml" || ext == "yaml" {
            return RepositoryHygieneTests.stripComment(line, yaml: true)
        }
        if ext == "xcconfig" || path.contains(".xcconfig") || path.hasPrefix("Config/") {
            return RepositoryHygieneTests.stripComment(line, yaml: false)
        }
        return line
    }

    static func findings(in source: String, path: String) -> [Finding] {
        guard let regex = try? NSRegularExpression(pattern: keyPattern) else { return [] }
        let isYAML = ["yml", "yaml"].contains((path as NSString).pathExtension.lowercased())
        let lines = source.components(separatedBy: "\n").map { stripComment($0, path: path) }
        var result: [Finding] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: line),
                      let conditionRange = Range(match.range(at: 2), in: line),
                      let whole = Range(match.range, in: line) else { continue }
                let key = String(line[keyRange]) + String(line[conditionRange])
                var value = valueToken(line[whole.upperBound...])
                // YAML: empty value with a more-indented continuation line → the scalar lives on the next line.
                if isYAML, value.isEmpty,
                   let next = lines[(index + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                   indentation(next) > indentation(line) {
                    value = next.trimmingCharacters(in: .whitespaces)
                }
                if !RepositoryHygieneTests.isAllowedValue(value) {
                    result.append(Finding(file: path, line: index + 1, key: key, value: value))
                }
            }
        }
        // Property lists: <key>DEVELOPMENT_TEAM</key> <string>X</string> (also the team-identifier entitlement).
        let plistPattern =
            #"<key>\s*((?:VOCAB_)?DEVELOPMENT_TEAM|DevelopmentTeam|com\.apple\.developer\.team-identifier)\s*</key>\s*<string>([^<]*)</string>"#
        if let plist = try? NSRegularExpression(pattern: plistPattern) {
            let range = NSRange(source.startIndex..., in: source)
            for match in plist.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source),
                      let valueRange = Range(match.range(at: 2), in: source) else { continue }
                let value = String(source[valueRange])
                if !RepositoryHygieneTests.isAllowedValue(value) {
                    let line = source[..<keyRange.lowerBound].filter { $0 == "\n" }.count + 1
                    result.append(Finding(file: path, line: line, key: String(source[keyRange]), value: value))
                }
            }
        }
        return result
    }

    // MARK: - Tests on the real repository

    func testNoLiteralTeamInAnyCommittableConfigFile() throws {
        let paths = try Self.committablePaths()
        XCTAssertTrue(paths.contains("project.yml"), "git ls-files did not list project.yml: \(paths.prefix(5))")
        XCTAssertFalse(paths.contains("Config/Local.xcconfig"), "Config/Local.xcconfig would be committed")

        var scanned = 0
        var all: [Finding] = []
        for path in paths where Self.isConfigLike(path) {
            guard let source = try? String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            else { continue }
            scanned += 1
            all += Self.findings(in: source, path: path)
        }
        XCTAssertGreaterThanOrEqual(scanned, 3, "expected at least project.yml + 2 xcconfigs to be scanned")
        XCTAssertTrue(all.isEmpty, "Team ID committed: " + all.map(\.description).joined(separator: "; "))
    }

    func testGitIgnoresAndDoesNotTrackLocalXcconfig() throws {
        // `--no-index`: evaluate the ignore rules even if the file were tracked; exit 0 = ignored.
        let ignored = try Self.git(["check-ignore", "-q", "--no-index", "Config/Local.xcconfig"])
        XCTAssertEqual(ignored.status, 0, "git does not ignore Config/Local.xcconfig (missing entry or a `!` negation?)")

        let tracked = try Self.git(["ls-files", "--", "Config/Local.xcconfig"])
        XCTAssertEqual(tracked.status, 0)
        XCTAssertEqual(
            tracked.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "",
            "Config/Local.xcconfig is tracked by git (git rm --cached it)"
        )
    }

    /// If the developer has a real `Config/Local.xcconfig`, its Team ID must not appear in any committable file
    /// (any type, including docs). Without a local file there is nothing to compare against and the test passes.
    func testLocalTeamIDLiteralAppearsInNoCommittableFile() throws {
        let localURL = Self.root.appendingPathComponent("Config/Local.xcconfig")
        guard let local = try? String(contentsOf: localURL, encoding: .utf8) else { return }
        let teams = RepositoryHygieneTests.assignments(in: local, file: "Config/Local.xcconfig", yaml: false)
            .map { $0.value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            .filter { $0.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil }
        guard !teams.isEmpty else { return }

        var leaks: [String] = []
        // The hygiene tests themselves contain fake fixture IDs only; skip them to avoid self-matches.
        for path in try Self.committablePaths() where !path.hasPrefix("Tests/VocabCoreTests/RepositoryHygiene") {
            guard let source = try? String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            else { continue }
            for team in teams where source.contains(team) {
                leaks.append(path)
            }
        }
        XCTAssertTrue(leaks.isEmpty, "Team ID from Config/Local.xcconfig found in committable files: \(leaks)")
    }

    // MARK: - Scanner self-checks (each case is a mutation that survived the original test)

    func testScannerFlagsFormsMissedByLineLeadingParser() {
        let yaml = """
        targets:
          VocabAppTests:
            settings:
              base: { GENERATE_INFOPLIST_FILE: YES, DEVELOPMENT_TEAM: ABCDE12345, PRODUCT_NAME: X }
          VocabShare:
            attributes:
              DevelopmentTeam: ABCDE12345
            settings:
              DEVELOPMENT_TEAM:
                ABCDE12345
          other:
            - DEVELOPMENT_TEAM: "ABCDE12345"
        """
        let found = Self.findings(in: yaml, path: "project.yml")
        XCTAssertEqual(found.map(\.line), [4, 7, 9, 12], "\(found)")
        XCTAssertEqual(found.map(\.value), ["ABCDE12345", "ABCDE12345", "ABCDE12345", "\"ABCDE12345\""])

        let xcconfig = """
        DEVELOPMENT_TEAM[config=Debug][sdk=iphoneos*] = ABCDE12345
        VOCAB_DEVELOPMENT_TEAM=ABCDE12345 // comment
        """
        let xc = Self.findings(in: xcconfig, path: "Config/Local.xcconfig.bak")
        XCTAssertEqual(xc.map(\.key), ["DEVELOPMENT_TEAM[config=Debug][sdk=iphoneos*]", "VOCAB_DEVELOPMENT_TEAM"])

        let pbxproj = """
        \t\t\t\tDEVELOPMENT_TEAM = ABCDE12345;
        \t\t\t\t\t\tDevelopmentTeam = ABCDE12345;
        """
        XCTAssertEqual(Self.findings(in: pbxproj, path: "X.xcodeproj/project.pbxproj").count, 2)

        let plist = """
        <key>com.apple.developer.team-identifier</key>
        <string>ABCDE12345</string>
        """
        XCTAssertEqual(Self.findings(in: plist, path: "Mobile/VocabMobile.entitlements").count, 1)
    }

    func testScannerAcceptsEmptyAndReferenceValues() {
        let yaml = """
        settings:
          base: { DEVELOPMENT_TEAM: "", CODE_SIGN_STYLE: Manual }
          DEVELOPMENT_TEAM: ""
          DEVELOPMENT_TEAM: "$(VOCAB_DEVELOPMENT_TEAM)"
          # DEVELOPMENT_TEAM: ABCDE12345 (comment)
          DEVELOPMENT_TEAM:
          NEXT_KEY: value
        """
        XCTAssertEqual(Self.findings(in: yaml, path: "project.yml"), [])

        let xcconfig = """
        VOCAB_DEVELOPMENT_TEAM =
        DEVELOPMENT_TEAM = $(VOCAB_DEVELOPMENT_TEAM)
        // VOCAB_DEVELOPMENT_TEAM = ABCDE12345
        """
        XCTAssertEqual(Self.findings(in: xcconfig, path: "Config/Signing.xcconfig"), [])

        let pbxproj = "\t\t\t\tDEVELOPMENT_TEAM = \"\";\n\t\t\t\tDEVELOPMENT_TEAM = \"$(VOCAB_DEVELOPMENT_TEAM)\";"
        XCTAssertEqual(Self.findings(in: pbxproj, path: "a/project.pbxproj"), [])
    }

    func testConfigLikeSelection() {
        XCTAssertTrue(Self.isConfigLike("project.yml"))
        XCTAssertTrue(Self.isConfigLike("Config/Local.xcconfig.bak"))
        XCTAssertTrue(Self.isConfigLike("Config/notes.txt"))
        XCTAssertTrue(Self.isConfigLike("Local.xcconfig~"))
        XCTAssertTrue(Self.isConfigLike("Mobile/VocabMobile.entitlements"))
        XCTAssertFalse(Self.isConfigLike("Tests/VocabCoreTests/RepositoryHygieneTests.swift"))
        XCTAssertFalse(Self.isConfigLike("docs/development/IOS_PLAN.md"))
    }
}

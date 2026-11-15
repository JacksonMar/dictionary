import Foundation
import XCTest

/// I2b.3 (IOS_PLAN §7 I2b, DI17) — Linux-side check of the iOS permission texts in the repository sources:
/// `Mobile/Info.plist` has `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`, and both
/// `Mobile/Resources/{en,uk}.lproj/InfoPlist.strings` localize them (non-empty, Ukrainian in Cyrillic, valid
/// `.strings` syntax). The hosted counterpart `InfoPlistMobileTests` reads the built app bundle on iOS.
final class InfoPlistLocalizationTests: XCTestCase {
    private static let usageKeys = ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value)
    }

    /// `.strings` (text, OpenStep plist) → dictionary. Fails on syntax errors (a broken file is dropped on device).
    private func parseStrings(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: String], "\(url.path) is not a string table", file: file, line: line)
    }

    func testInfoPlistDeclaresUsageDescriptions() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Mobile/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        for key in Self.usageKeys {
            let value = (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            XCTAssertFalse(value.isEmpty, "Mobile/Info.plist \(key)")
            XCTAssertFalse(value.contains("$("), "\(key) must be literal text, not a build variable")
        }
        let localizations = plist["CFBundleLocalizations"] as? [String] ?? []
        XCTAssertTrue(Set(localizations).isSuperset(of: ["en", "uk"]), "CFBundleLocalizations: \(localizations)")
    }

    func testUsageDescriptionsPresentInBothLocalizations() throws {
        let resources = Self.repositoryRoot.appendingPathComponent("Mobile/Resources")
        let english = try parseStrings(resources.appendingPathComponent("en.lproj/InfoPlist.strings"))
        let ukrainian = try parseStrings(resources.appendingPathComponent("uk.lproj/InfoPlist.strings"))

        for key in Self.usageKeys {
            let en = english[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let uk = ukrainian[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            XCTAssertFalse(en.isEmpty, "en.lproj \(key)")
            XCTAssertFalse(uk.isEmpty, "uk.lproj \(key)")
            XCTAssertNotEqual(en, uk, "\(key) must be translated")
            XCTAssertTrue(uk.unicodeScalars.contains(where: Self.isCyrillic), "uk.lproj \(key) must be Ukrainian")
            XCTAssertFalse(en.unicodeScalars.contains(where: Self.isCyrillic), "en.lproj \(key) must be English")
        }
        // Both tables localize the same keys (nothing forgotten in one language).
        XCTAssertEqual(Set(english.keys), Set(ukrainian.keys))
    }
}

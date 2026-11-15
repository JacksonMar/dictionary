// I2b.3 (IOS_PLAN §7 I2b, DI17): the microphone and speech-recognition usage descriptions are in the built app's
// Info.plist and localized in English and Ukrainian (`InfoPlist.strings` in en.lproj / uk.lproj of the app bundle).
// Hosted only: reads `Bundle.main` (the VocabMobile app). The same files are checked on Linux by the core test
// `InfoPlistLocalizationTests` (repository sources).
// I4.3 (IOS_PLAN §7 I4): the built app registers the `vocabapp` URL scheme (`CFBundleURLTypes`) used by the voice
// widget and deep links; Linux counterpart — core `MobileI4ResourcesTests`.
#if os(iOS)
import Foundation
import XCTest
@testable import VocabMobile

final class InfoPlistMobileTests: XCTestCase {
    private static let usageKeys = ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"]

    private func localizedStrings(_ localization: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let bundle = Bundle.main
        let path = try XCTUnwrap(
            bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: localization),
            "\(localization).lproj/InfoPlist.strings missing from \(bundle.bundlePath)",
            file: file, line: line
        )
        // Compiled .strings may be binary or text plists; NSDictionary reads both.
        let dictionary = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String],
                                       "unreadable \(path)", file: file, line: line)
        return dictionary
    }

    func testUsageDescriptionsPresentInBothLocalizations() throws {
        let bundle = Bundle.main
        XCTAssertTrue(bundle.bundleIdentifier?.hasSuffix(".VocabMobile") ?? false, "must run hosted in the app")

        // Raw Info.plist keys (without them iOS kills the app on the first microphone access).
        let info = try XCTUnwrap(bundle.infoDictionary)
        for key in Self.usageKeys {
            let value = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            XCTAssertFalse(value.isEmpty, "Info.plist \(key)")
        }

        let localizations = Set(bundle.localizations)
        XCTAssertTrue(localizations.isSuperset(of: ["en", "uk"]), "bundle localizations: \(bundle.localizations)")

        let english = try localizedStrings("en")
        let ukrainian = try localizedStrings("uk")
        for key in Self.usageKeys {
            let en = english[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let uk = ukrainian[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            XCTAssertFalse(en.isEmpty, "en \(key)")
            XCTAssertFalse(uk.isEmpty, "uk \(key)")
            XCTAssertNotEqual(en, uk, "\(key) must be translated")
            XCTAssertTrue(uk.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, "uk \(key) is Cyrillic")
            XCTAssertFalse(en.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, "en \(key) has no Cyrillic")
        }
    }

    func testURLSchemeRegistered() throws {
        let bundle = Bundle.main
        XCTAssertTrue(bundle.bundleIdentifier?.hasSuffix(".VocabMobile") ?? false, "must run hosted in the app")
        let info = try XCTUnwrap(bundle.infoDictionary)
        let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]], "CFBundleURLTypes missing")
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(DeepLink.scheme), "registered schemes: \(schemes)")
        XCTAssertEqual(DeepLink.scheme, "vocabapp")
        // The registered scheme really routes (widget URL).
        let widgetURL = try XCTUnwrap(URL(string: "\(DeepLink.scheme)://voice"))
        XCTAssertEqual(DeepLink.parse(widgetURL), .voiceCapture(languageID: nil))
    }
}
#endif

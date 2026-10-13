import AppKit
import XCTest
import VocabCore
@testable import VocabApp

/// M3.5 — `NSServices` у Info.plist host-застосунку (§2.3) і селектор обробника.
/// Тести hosted (TEST_HOST = VocabApp.app), тож `Bundle.main` — це сам застосунок.
final class InfoPlistServicesTests: XCTestCase {
    private func serviceEntry() throws -> [String: Any] {
        let info = try XCTUnwrap(Bundle.main.infoDictionary, "host app Info.plist")
        let services = try XCTUnwrap(info["NSServices"] as? [[String: Any]], "NSServices array")
        XCTAssertEqual(services.count, 1)
        return try XCTUnwrap(services.first)
    }

    func testHostBundleIsVocabApp() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.vocabapp.VocabApp")
    }

    func testNSServicesEntry() throws {
        let service = try serviceEntry()

        let menuItem = try XCTUnwrap(service["NSMenuItem"] as? [String: Any])
        XCTAssertEqual(menuItem["default"] as? String, "Додати в словник")

        XCTAssertEqual(service["NSMessage"] as? String, "addToDictionary")

        let portName = try XCTUnwrap(service["NSPortName"] as? String)
        XCTAssertEqual(portName, "VocabApp")
        XCTAssertEqual(portName, Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
                       "NSPortName matches CFBundleName (U1)")

        let sendTypes = try XCTUnwrap(service["NSSendTypes"] as? [String])
        XCTAssertTrue(sendTypes.contains("NSStringPboardType"), "\(sendTypes)")
        XCTAssertTrue(sendTypes.contains("public.utf8-plain-text"), "\(sendTypes)")
        XCTAssertEqual(Set(sendTypes), ["NSStringPboardType", "public.utf8-plain-text"])

        let requiredContext = try XCTUnwrap(service["NSRequiredContext"] as? [String: Any],
                                            "empty NSRequiredContext enables the service by default (U2)")
        XCTAssertTrue(requiredContext.isEmpty)

        XCTAssertNil(service["NSReturnTypes"], "service returns nothing")
        XCTAssertNil(service["NSKeyEquivalent"], "no key equivalent (avoid conflicts)")
    }

    func testLSUIElementTrue() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }

    @MainActor
    func testProviderRespondsToServiceSelector() throws {
        let service = try serviceEntry()
        let message = try XCTUnwrap(service["NSMessage"] as? String)
        let provider = ServicesProvider(handler: StubServiceRequestHandler(outcome: .rejected(.empty)),
                                        notifier: SpyUserNotifier())

        // AppKit викликає `<NSMessage>:userData:error:`.
        XCTAssertTrue(provider.responds(to: NSSelectorFromString("\(message):userData:error:")))
        XCTAssertTrue(provider.responds(to: NSSelectorFromString("addToDictionary:userData:error:")))
    }
}

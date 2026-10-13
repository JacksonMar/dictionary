import XCTest
@testable import VocabApp

/// Мінімальний тест, щоб таргет VocabAppTests компілювався і `xcodebuild test` мав що запускати.
/// Повноцінні тести (AppModelTests тощо) додає Tester.
final class AppSmokeTests: XCTestCase {
    func testHostAppDetectsTestEnvironment() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
    }
}

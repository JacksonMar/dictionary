// SPIKE TESTS (IOS_PLAN.md stage I0, КП I0.2) — replaced in I1a.
import XCTest
@testable import VocabMobile

final class SpikeTests: XCTestCase {
    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabMobileSpikeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectory = url
        return url
    }

    /// Hosted test: the host app launched, its Info.plist carries the expanded App Group ID, and the live probe
    /// returns a status without crashing (OK or unavailable — the simulator result is recorded in I0.md, iU8).
    func testAppLaunches() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        XCTAssertTrue(bundleID.hasSuffix(".VocabMobile"), "unexpected host bundle id: \(bundleID)")

        let rawGroupID = Bundle.main.object(forInfoDictionaryKey: AppGroupProbe.infoPlistKey) as? String
        let groupID = AppGroupProbe.normalizedGroupID(rawGroupID)
        XCTAssertNotNil(groupID, "VocabAppGroupID missing or not expanded: \(rawGroupID ?? "nil")")
        XCTAssertTrue(groupID?.hasPrefix("group.") ?? false)

        let status = AppGroupProbe.live().run()
        XCTAssertNotEqual(status, .missingGroupID)
    }

    func testNormalizedGroupIDRejectsEmptyAndUnexpanded() {
        XCTAssertNil(AppGroupProbe.normalizedGroupID(nil))
        XCTAssertNil(AppGroupProbe.normalizedGroupID("  "))
        XCTAssertNil(AppGroupProbe.normalizedGroupID("$(VOCAB_APP_GROUP)"))
        XCTAssertEqual(AppGroupProbe.normalizedGroupID(" group.com.example.vocab "), "group.com.example.vocab")
    }

    func testProbeReportsUnavailableContainerGracefully() {
        let probe = AppGroupProbe(groupID: "group.test") { _ in nil }
        XCTAssertEqual(probe.run(), .containerUnavailable(groupID: "group.test"))
        XCTAssertEqual(probe.shareProbeFiles(), [])
    }

    func testProbeWritesReadsAndListsShareFiles() throws {
        let container = try makeTemporaryDirectory()
        let probe = AppGroupProbe(groupID: "group.test") { _ in container }

        XCTAssertTrue(probe.run().isOK)

        let directory = container.appendingPathComponent(AppGroupProbe.probeDirectoryName, isDirectory: true)
        try Data("older".utf8).write(to: directory.appendingPathComponent("share-1000-A.txt"))
        try Data("newer".utf8).write(to: directory.appendingPathComponent("share-2000-B.txt"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent(".B.tmp"))

        let files = probe.shareProbeFiles()
        XCTAssertEqual(files.map(\.name), ["share-2000-B.txt", "share-1000-A.txt"])
        XCTAssertEqual(files.first?.content, "newer")
    }
}

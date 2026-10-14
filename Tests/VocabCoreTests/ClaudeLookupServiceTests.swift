import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VocabCore

/// M2.4–M2.5 — `ClaudeLookupService` через реальну `URLSession` з `MockURLProtocol`:
/// мапінг HTTP-/мережевих помилок, рівно один повтор лише при невалідній відповіді.
final class ClaudeLookupServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Success / request

    func testSuccessReturnsParsedResultWithOneRequest() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok()])
        let harness = LookupHarness()

        let result = try await harness.lookupRun()

        XCTAssertEqual(result, ClaudeFixtures.expectedRunResult)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testRequestSentThroughTransportHasHeadersAndBody() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok()])
        let harness = LookupHarness()

        _ = try await harness.lookupRun()

        let recorded = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(recorded.request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "x-api-key"), ClaudeFixtures.apiKey)
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try jsonObject(recorded.body)
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "system", "messages"])
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("<text>run</text>") ?? false)
    }

    func testModelTakenFromSettings() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok()])
        let harness = LookupHarness(model: "claude-custom-model")

        _ = try await harness.lookupRun()
        harness.settings.model = "claude-other-model"
        _ = try await harness.lookupRun()

        let models = try MockURLProtocol.requests.map { try jsonObject($0.body)["model"] as? String }
        XCTAssertEqual(models, ["claude-custom-model", "claude-other-model"], "model is read from Settings on each call")
    }

    func testKeyReadOnEveryCall() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok()])
        let harness = LookupHarness()

        _ = try await harness.lookupRun()
        try harness.secrets.writeSecret("sk-ant-api03-SECONDKEY_zzzzzzzzzzzz", for: .anthropicAPIKey)
        _ = try await harness.lookupRun()

        XCTAssertEqual(MockURLProtocol.requests.map { $0.request.value(forHTTPHeaderField: "x-api-key") },
                       [ClaudeFixtures.apiKey, "sk-ant-api03-SECONDKEY_zzzzzzzzzzzz"])
    }

    // MARK: - M2.4 retry once on invalid response

    func testInvalidJSONRetriedOnceThenSucceeds() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok("not json at all"), ClaudeFixtures.ok()])
        let harness = LookupHarness()

        let result = try await harness.lookupRun()

        XCTAssertEqual(result, ClaudeFixtures.expectedRunResult)
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        let bodies = try MockURLProtocol.requests.map { try jsonObject($0.body) }
        let firstUser = try XCTUnwrap((bodies[0]["messages"] as? [[String: Any]])?.first?["content"] as? String)
        let secondUser = try XCTUnwrap((bodies[1]["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertEqual(secondUser, firstUser + "\n\n" + PromptBuilder.retrySuffix)
        XCTAssertEqual(bodies[0]["system"] as? String, bodies[1]["system"] as? String)
    }

    func testInvalidJSONTwiceFails() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok("garbage 1"), ClaudeFixtures.ok("garbage 2"), ClaudeFixtures.ok()])
        let harness = LookupHarness()

        do {
            _ = try await harness.lookupRun()
            XCTFail("expected invalidResponse")
        } catch {
            guard case ClaudeError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "exactly one retry")
    }

    func testSchemaViolationRetriedOnce() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok("{\"word\":\"run\"}"), ClaudeFixtures.ok()])
        let harness = LookupHarness()

        let awaited1 = try await harness.lookupRun()
        XCTAssertEqual(awaited1, ClaudeFixtures.expectedRunResult)
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testMaxTokensTruncationRetriedOnceThenFails() async throws {
        let truncated = String(ClaudeFixtures.validWordJSON.prefix(50))
        MockURLProtocol.setReplies([
            ClaudeFixtures.ok(truncated, stopReason: "max_tokens"),
            ClaudeFixtures.ok(truncated, stopReason: "max_tokens"),
            ClaudeFixtures.ok(),
        ])
        let harness = LookupHarness()

        await XCTAssertThrowsClaudeError(try await harness.lookupRun(), .invalidResponse("max_tokens"))
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testRefusalNotRetried() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok("", stopReason: "refusal"), ClaudeFixtures.ok()])
        let harness = LookupHarness()

        await XCTAssertThrowsClaudeError(try await harness.lookupRun(), .refused)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testHTTPErrorsNotRetried() async throws {
        let cases: [(MockURLProtocol.Reply, ClaudeError)] = [
            (ClaudeFixtures.http(401), .unauthorized),
            (ClaudeFixtures.http(429), .rateLimited(retryAfter: nil)),
            (ClaudeFixtures.http(500), .server(status: 500)),
            (ClaudeFixtures.http(529), .server(status: 529)),
            (ClaudeFixtures.urlError(.notConnectedToInternet), .offline),
            (ClaudeFixtures.urlError(.timedOut), .timeout),
        ]
        for (reply, expected) in cases {
            MockURLProtocol.reset()
            MockURLProtocol.setReplies([reply, ClaudeFixtures.ok()])
            let harness = LookupHarness()

            await XCTAssertThrowsClaudeError(try await harness.lookupRun(), expected)
            XCTAssertEqual(MockURLProtocol.requestCount, 1, "\(expected) must not be retried by the client")
        }
    }

    // MARK: - M2.5 HTTP / network errors

    func test401Unauthorized() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(401, body: ClaudeFixtures.errorBody(
            type: "authentication_error", message: "invalid x-api-key"))])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .unauthorized)
    }

    func test403Forbidden() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(403, body: ClaudeFixtures.errorBody(
            type: "permission_error", message: "forbidden"))])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .forbidden)
    }

    func test402BillingMapsToForbidden() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(402)])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .forbidden)
    }

    func test429RateLimitedWithRetryAfter() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(429, headers: ["retry-after": "42"], body: ClaudeFixtures.errorBody(
            type: "rate_limit_error", message: "slow down"))])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .rateLimited(retryAfter: 42))
    }

    func test429WithoutOrInvalidRetryAfter() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(429)])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .rateLimited(retryAfter: nil))

        MockURLProtocol.reset()
        MockURLProtocol.setReplies([ClaudeFixtures.http(429, headers: ["retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"])])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .rateLimited(retryAfter: nil))
    }

    func test500Server() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(500)])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .server(status: 500))
    }

    func test529Overloaded() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(529, body: ClaudeFixtures.errorBody(
            type: "overloaded_error", message: "Overloaded"))])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .server(status: 529))
    }

    func test400BadRequestMessageExtracted() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(400, body: ClaudeFixtures.errorBody(
            type: "invalid_request_error", message: "  max_tokens: field required  "))])
        await XCTAssertThrowsClaudeError(
            try await LookupHarness().lookupRun(),
            .badRequest(status: 400, message: "max_tokens: field required")
        )
    }

    func test404UnknownModelIsBadRequest() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(404, body: ClaudeFixtures.errorBody(
            type: "not_found_error", message: "model: claude-nope"))])
        await XCTAssertThrowsClaudeError(
            try await LookupHarness(model: "claude-nope").lookupRun(),
            .badRequest(status: 404, message: "model: claude-nope")
        )
    }

    func testBadRequestMessageTruncatedTo200() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(400, body: ClaudeFixtures.errorBody(
            type: "invalid_request_error", message: String(repeating: "x", count: 500)))])
        await XCTAssertThrowsClaudeError(
            try await LookupHarness().lookupRun(),
            .badRequest(status: 400, message: String(repeating: "x", count: 200))
        )
    }

    func testBadRequestWithNonJSONBodyHasEmptyMessage() async {
        MockURLProtocol.setReplies([ClaudeFixtures.http(413, body: Data("<html>too large</html>".utf8))])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .badRequest(status: 413, message: ""))
    }

    func testTimeout() async {
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.timedOut)])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .timeout)
    }

    func testOffline() async {
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.notConnectedToInternet)])
        await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .offline)
    }

    func testOtherConnectivityErrorsMapToOffline() async {
        for code: URLError.Code in [.networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            MockURLProtocol.reset()
            MockURLProtocol.setReplies([ClaudeFixtures.urlError(code)])
            await XCTAssertThrowsClaudeError(try await LookupHarness().lookupRun(), .offline)
        }
    }

    func testOtherURLErrorMapsToTransport() async {
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.badServerResponse)])
        do {
            _ = try await LookupHarness().lookupRun()
            XCTFail("expected transport error")
        } catch {
            guard case ClaudeError.transport = error else {
                return XCTFail("expected transport, got \(error)")
            }
        }
    }

    func testMissingKeyNoRequest() async {
        MockURLProtocol.setReplies([ClaudeFixtures.ok()])

        await XCTAssertThrowsClaudeError(try await LookupHarness(apiKey: nil).lookupRun(), .missingAPIKey)
        await XCTAssertThrowsClaudeError(try await LookupHarness(apiKey: "").lookupRun(), .missingAPIKey)
        await XCTAssertThrowsClaudeError(try await LookupHarness(apiKey: "  \n").lookupRun(), .missingAPIKey)

        XCTAssertEqual(MockURLProtocol.requestCount, 0, "no HTTP request without a key")
    }

    func testFailingSecretStoreTreatedAsMissingKeyWithoutRequest() async {
        MockURLProtocol.setReplies([ClaudeFixtures.ok()])
        let service = ClaudeLookupService(
            transport: URLSessionTransport(session: MockURLProtocol.makeSession()),
            secrets: ThrowingSecretStore(),
            settings: InMemorySettingsStore(),
            logger: RedactingLogger(sink: CapturingLogSink(), secretsProvider: { [] })
        )

        await XCTAssertThrowsClaudeError(
            try await service.lookup(text: "run", kind: .word, pair: .englishUkrainianSourceOnly),
            .missingAPIKey
        )
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testUserMessagesAreUkrainianAndNonEmpty() {
        let errors: [ClaudeError] = [
            .missingAPIKey, .offline, .timeout, .unauthorized, .forbidden, .rateLimited(retryAfter: 1),
            .server(status: 529), .badRequest(status: 400, message: "x"), .invalidResponse("x"), .refused,
            .transport("x"),
        ]
        for error in errors {
            XCTAssertFalse(error.userMessage.isEmpty)
            XCTAssertTrue(error.userMessage.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) },
                          "\(error) message must be Ukrainian: \(error.userMessage)")
        }
    }
}

private final class ThrowingSecretStore: SecretStore, @unchecked Sendable {
    func readSecret(for key: SecretKey) throws -> String? { throw SecretStoreError.keychain(status: -25300) }
    func writeSecret(_ value: String, for key: SecretKey) throws { throw SecretStoreError.keychain(status: -1) }
    func deleteSecret(for key: SecretKey) throws { throw SecretStoreError.keychain(status: -1) }
}

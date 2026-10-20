import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Формує `URLRequest` до Messages API (§7.2). Тіло — рівно `{model, max_tokens, system, messages}`:
/// без sampling-параметрів, `thinking`, `output_config` і assistant prefill.
public enum ClaudeRequestBuilder {
    public static let apiKeyHeader = "x-api-key"
    public static let versionHeader = "anthropic-version"
    public static let contentTypeHeader = "content-type"

    struct Body: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }
    }

    public static func makeRequest(
        prompt: BuiltPrompt,
        apiKey: String,
        configuration: ClaudeConfiguration
    ) throws -> URLRequest {
        let body = Body(
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            system: prompt.system,
            messages: [Body.Message(role: "user", content: prompt.user)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw ClaudeError.transport(L10n.text(.claudeRequestEncodingFailed))
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue(apiKey, forHTTPHeaderField: apiKeyHeader)
        request.setValue(ClaudeConfiguration.apiVersion, forHTTPHeaderField: versionHeader)
        request.setValue("application/json", forHTTPHeaderField: contentTypeHeader)
        request.httpBody = data
        return request
    }
}

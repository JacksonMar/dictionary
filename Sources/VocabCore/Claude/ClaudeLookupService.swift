import Foundation

/// Пошук перекладу слова/фрази.
public protocol WordLookupService: Sendable {
    func lookup(text: String, kind: SelectionKind, pair: LanguagePair) async throws -> LookupResult
}

/// `WordLookupService` через Claude Messages API (§7.5).
/// - Ключ читається з `SecretStore` на кожен виклик; немає/порожній → `.missingAPIKey` без HTTP-запиту.
/// - Модель — з `SettingsStore` на кожен виклик.
/// - Повтор рівно один і лише при `.invalidResponse` (з інструкцією «Поверни лише JSON»).
///   HTTP/мережеві помилки не повторюються — це робота черги.
public final class ClaudeLookupService: WordLookupService {
    private let client: ClaudeAPIClient
    private let secrets: SecretStore
    private let settings: SettingsStore
    private let logger: RedactingLogger
    private let baseConfiguration: ClaudeConfiguration

    public init(
        transport: HTTPTransport,
        secrets: SecretStore,
        settings: SettingsStore,
        logger: RedactingLogger,
        configuration: ClaudeConfiguration = ClaudeConfiguration()
    ) {
        self.client = ClaudeAPIClient(transport: transport, logger: logger)
        self.secrets = secrets
        self.settings = settings
        self.logger = logger
        self.baseConfiguration = configuration
    }

    public func lookup(text: String, kind: SelectionKind, pair: LanguagePair) async throws -> LookupResult {
        let apiKey = try readAPIKey()
        let configuration = currentConfiguration()

        // M7: для пари з `renderings` — комбінований промт (усі мови одним запитом, §7.7).
        let prompt = PromptBuilder.build(text: text, kind: kind, pair: pair)
        let parse: (Data) throws -> LookupResult = { data in
            try LookupResponseParser.parseMessagesResponse(
                data,
                kind: kind,
                pair: pair,
                selectionKey: TextNormalizer.key(text)
            )
        }
        do {
            return try await attempt(prompt: prompt, apiKey: apiKey, configuration: configuration, parse: parse)
        } catch ClaudeError.invalidResponse(let reason) {
            logger.info("Claude response invalid (\(reason)); retrying once")
            return try await attempt(
                prompt: PromptBuilder.retrying(prompt),
                apiKey: apiKey,
                configuration: configuration,
                parse: parse
            )
        }
    }

    // MARK: - Private

    /// Один HTTP-запит + розбір відповіді. Помилка розбору логується (лише тип) і передається нагору.
    func attempt<T>(
        prompt: BuiltPrompt,
        apiKey: String,
        configuration: ClaudeConfiguration,
        parse: (Data) throws -> T
    ) async throws -> T {
        let data = try await client.send(prompt: prompt, apiKey: apiKey, configuration: configuration)
        do {
            return try parse(data)
        } catch let error as ClaudeError {
            logger.error("Claude response rejected: model=\(configuration.model) error=\(error.logName)")
            throw error
        } catch {
            throw ClaudeError.invalidResponse("невідома помилка розбору")
        }
    }

    /// Конфігурація поточного виклику: модель — з налаштувань.
    func currentConfiguration() -> ClaudeConfiguration {
        var configuration = baseConfiguration
        configuration.model = settings.model
        return configuration
    }

    func readAPIKey() throws -> String {
        let stored: String?
        do {
            stored = try secrets.readSecret(for: .anthropicAPIKey)
        } catch let error as SecretStoreError {
            logger.error("API key read failed: \(error.userMessage)")
            throw ClaudeError.missingAPIKey
        } catch {
            logger.error("API key read failed")
            throw ClaudeError.missingAPIKey
        }
        guard let key = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        return key
    }
}

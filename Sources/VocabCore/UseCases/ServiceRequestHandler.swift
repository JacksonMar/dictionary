import Foundation

/// Результат обробки запиту Services: outcome use-case і текст сповіщення.
public struct ServiceResponse: Equatable, Sendable {
    public var outcome: AddWordOutcome
    public var notification: NotificationContent

    public init(outcome: AddWordOutcome, notification: NotificationContent) {
        self.outcome = outcome
        self.notification = notification
    }

    public init(outcome: AddWordOutcome) {
        self.init(outcome: outcome, notification: NotificationText.make(for: outcome))
    }
}

/// Абстракція обробника для `ServicesProvider` (щоб у тестах застосунку підставляти заглушку).
public protocol ServiceRequestHandling: Sendable {
    func handle(text: String?) async -> ServiceResponse
}

/// Точка входу для Services і ручного «Додати через Claude» (§9):
/// сирий текст → `SelectionValidator` → `AddWordUseCase` → `ServiceResponse` з текстом сповіщення.
public final class ServiceRequestHandler: ServiceRequestHandling {
    private let useCase: AddWordUseCase

    public init(useCase: AddWordUseCase) {
        self.useCase = useCase
    }

    public func handle(text: String?) async -> ServiceResponse {
        // Валідація (`SelectionValidator`) виконується всередині `AddWordUseCase.execute`.
        let outcome = await useCase.execute(rawText: text)
        return ServiceResponse(outcome: outcome)
    }
}

import AppKit
import Foundation
import VocabCore

/// Обробник Services-пункту «Додати в словник» (§2.3, §11).
/// `NSMessage = addToDictionary` → AppKit викликає `addToDictionary:userData:error:`.
///
/// `addToDictionary` одразу повертає керування, а обробка йде в `Task`; цей `Task` доступний як
/// `lastTask`, тож тести можуть дочекатися результату (`await provider.lastTask?.value`).
/// Для прямого виклику без pasteboard — `handle(text:)`.
@MainActor
final class ServicesProvider: NSObject {
    /// Текст для `error.pointee`, якщо в pasteboard нема тексту.
    static let noTextErrorMessage = "Не вдалося отримати текст"
    /// Застарілий тип рядка (`NSStringPboardType`), який деякі застосунки досі кладуть у pasteboard.
    static let legacyStringType = NSPasteboard.PasteboardType("NSStringPboardType")

    private let handler: ServiceRequestHandling
    private let notifier: UserNotifier
    private var prepare: @MainActor () async -> Void
    private let onResponse: @MainActor (ServiceResponse) -> Void

    /// Задача обробки останнього запиту Services (результат — відповідь, що пішла в сповіщення).
    private(set) var lastTask: Task<ServiceResponse, Never>?

    /// - Parameters:
    ///   - handler: `ServiceRequestHandler` (або заглушка в тестах).
    ///   - notifier: показ сповіщень (`NotificationService` або заглушка).
    ///   - prepare: що дочекатися перед обробкою (у застосунку — завантаження словника; U5).
    ///   - onResponse: оновлення UI (`AppModel.recordServiceResponse`).
    init(
        handler: ServiceRequestHandling,
        notifier: UserNotifier,
        prepare: @escaping @MainActor () async -> Void = {},
        onResponse: @escaping @MainActor (ServiceResponse) -> Void = { _ in }
    ) {
        self.handler = handler
        self.notifier = notifier
        self.prepare = prepare
        self.onResponse = onResponse
        super.init()
    }

    /// Замінює те, чого чекати перед обробкою запиту (у застосунку — задачу завантаження словника).
    func setPreparation(_ prepare: @escaping @MainActor () async -> Void) {
        self.prepare = prepare
    }

    /// Точка входу Services. Читає текст з pasteboard і повертає керування одразу; обробка — у `lastTask`.
    @objc(addToDictionary:userData:error:)
    func addToDictionary(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = Self.text(from: pboard),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = Self.noTextErrorMessage as NSString
            let response = ServiceResponse(outcome: .rejected(.empty))
            lastTask = Task { @MainActor in
                await self.deliver(response)
                return response
            }
            return
        }
        // `self` захоплюється сильно: провайдер живе весь час роботи застосунку (`AppDelegate`), а задача
        // відпускає замикання після завершення. Тож гілки «провайдер уже знищено» з окремим текстом поза §9 нема —
        // кожен запит закінчується одним із текстів `NotificationText`.
        lastTask = Task { @MainActor in
            await self.handle(text: text)
        }
    }

    /// Обробляє текст: `ServiceRequestHandler` → сповіщення → оновлення UI. Повертає відповідь.
    @discardableResult
    func handle(text: String?) async -> ServiceResponse {
        await prepare()
        let response = await handler.handle(text: text)
        await deliver(response)
        return response
    }

    /// Текст з pasteboard: `.string` (= `public.utf8-plain-text`), інакше застарілий `NSStringPboardType`.
    static func text(from pboard: NSPasteboard) -> String? {
        if let text = pboard.string(forType: .string) {
            return text
        }
        return pboard.string(forType: legacyStringType)
    }

    // MARK: - Private

    private func deliver(_ response: ServiceResponse) async {
        onResponse(response)
        await notifier.post(response.notification)
    }
}

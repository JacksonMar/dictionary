import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VocabCore
import os

/// Share Extension «VocabApp» (IOS_PLAN DI7, DI9, §3.3, I3). Читає вхідні елементи листа «Поділитися»
/// (`attributedContentText`, вкладення `public.plain-text`; URL ігнорується) → `ShareTextExtractor` →
/// `ShareInboxWriter` (файл у `<App Group>/Inbox/`) → коротке підтвердження (`ShareView`) → `completeRequest`.
///
/// Claude не викликається, Keychain і словник не чіпаються: слово перекладе застосунок при наступній активації.
/// Запит завершується за будь-якого результату (успіх — автоматично через ~1,2 с або кнопкою «Готово»).
/// Мова — мова системи (`ShareInboxWriter.interfaceLanguage`): налаштування застосунку розширенню недоступні.
/// У лог — лише вид результату, ніколи не текст.
final class ShareViewController: UIViewController {
    private static let autoCloseDelay: TimeInterval = 1.2

    private let logger = Logger(subsystem: "VocabShare", category: "share")
    private var model: ShareViewModel?
    private var didStart = false
    private var didComplete = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let language = ShareInboxWriter.interfaceLanguage()
        L10n.setCurrent(language)
        let model = ShareViewModel(language: language) { [weak self] in
            self?.finish()
        }
        self.model = model

        let host = UIHostingController(rootView: ShareView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        Self.loadCandidates(from: extensionContext?.inputItems ?? []) { [weak self] candidates in
            self?.save(candidates)
        }
    }

    // MARK: - Save

    private func save(_ candidates: [ShareTextCandidate]) {
        let extraction = ShareTextExtractor.extract(from: candidates)
        let outcome = ShareInboxWriter.save(extraction, directory: InboxLocation.live())
        logger.info("Share finished: \(Self.logName(outcome), privacy: .public)")
        model?.show(outcome)
        if outcome.isSuccess {
            let delay = UInt64(Self.autoCloseDelay * 1_000_000_000)
            Task<Void, Never> { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                self?.finish()
            }
        }
    }

    private func finish() {
        guard !didComplete else { return }
        didComplete = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private static func logName(_ outcome: ShareSaveOutcome) -> String {
        switch outcome {
        case .saved(let truncated):
            return truncated ? "saved truncated" : "saved"
        case .empty:
            return "empty"
        case .unavailable:
            return "appGroupUnavailable"
        case .full:
            return "inboxFull"
        case .failed:
            return "storageFailed"
        }
    }

    // MARK: - Input

    /// Кандидати в порядку елементів: `attributedContentText` кожного елемента і текст кожного вкладення
    /// `public.plain-text`. URL-вкладення не читаються (`ShareTextExtractor` їх однаково ігнорує). `completion` —
    /// рівно один раз, на головній черзі. `nonisolated`: колбеки `loadItem` приходять з довільних черг.
    private nonisolated static func loadCandidates(
        from inputItems: [Any],
        completion: @escaping @MainActor @Sendable ([ShareTextCandidate]) -> Void
    ) {
        let items = inputItems.compactMap { $0 as? NSExtensionItem }
        let collector = CandidateCollector()
        let group = DispatchGroup()
        let plainText = UTType.plainText.identifier

        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty {
                collector.append(.attributedContentText(text), order: collector.nextOrder())
            }
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(plainText) {
                let order = collector.nextOrder()
                group.enter()
                provider.loadItem(forTypeIdentifier: plainText, options: nil) { loaded, error in
                    if let text = Self.string(from: loaded) {
                        collector.append(.plainText(text), order: order)
                    } else if error != nil {
                        Logger(subsystem: "VocabShare", category: "share").error("Plain-text attachment not loaded")
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                completion(collector.candidates())
            }
        }
    }

    private nonisolated static func string(from item: NSSecureCoding?) -> String? {
        if let string = item as? String {
            return string
        }
        if let attributed = item as? NSAttributedString {
            return attributed.string
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

/// Потокобезпечний збирач кандидатів: колбеки `loadItem` приходять з довільних черг; порядок — за `order`.
private final class CandidateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private var entries: [(order: Int, candidate: ShareTextCandidate)] = []

    func nextOrder() -> Int {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }

    func append(_ candidate: ShareTextCandidate, order: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((order, candidate))
    }

    func candidates() -> [ShareTextCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return entries.sorted { $0.order < $1.order }.map(\.candidate)
    }
}

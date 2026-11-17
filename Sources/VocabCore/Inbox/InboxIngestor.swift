import Foundation

/// Підсумок одного проходу інжесту inbox (банер у застосунку).
public struct InboxIngestReport: Equatable, Sendable {
    /// Нові записи, збережені як `pending` (переклад — через чергу, 1 запит на слово).
    public var queued: Int
    /// Уже є в словнику (будь-який статус) — 0 запитів, файл прибрано.
    public var duplicates: Int
    /// Відхилені валідацією (`SelectionValidator`: порожньо, > 120 символів, > 8 слів, без літер) або биті файли
    /// (перенесені в `Rejected/`).
    public var rejected: Int
    /// Не вдалося зберегти/прочитати: файл лишився в inbox, спроба — при наступній активації. Після зупинки проходу
    /// на помилці сховища — усі елементи цього проходу, що лишились у inbox (невдалий + ще не оброблені), плюс
    /// нечитабельні файли скану.
    public var failed: Int

    public init(queued: Int = 0, duplicates: Int = 0, rejected: Int = 0, failed: Int = 0) {
        self.queued = queued
        self.duplicates = duplicates
        self.rejected = rejected
        self.failed = failed
    }

    /// Нічого не оброблено (банер не показується).
    public var isEmpty: Bool {
        queued == 0 && duplicates == 0 && rejected == 0 && failed == 0
    }
}

/// Рядки логу інжесту: лише лічильники — без слів і тексту з inbox.
public enum InboxLog {
    /// `Inbox ingest finished: queued=2 duplicates=1 rejected=0 failed=0`.
    public static func finished(_ report: InboxIngestReport) -> String {
        "Inbox ingest finished: queued=\(report.queued) duplicates=\(report.duplicates)"
            + " rejected=\(report.rejected) failed=\(report.failed)"
    }
}

/// Забирає слова з inbox у словник (IOS_PLAN §3.3, §4). Працює лише в процесі застосунку.
///
/// Кожен елемент (у порядку `createdAt`) → `SelectionValidator` → `repository.add` як `pending` (з
/// `languageHint`, якщо він дозволений парою) → видалення файлу. Дубль — лічильник `duplicates`, файл прибрано,
/// 0 запитів. Відхилений текст — `rejected`, файл прибрано. Помилка збереження (диск, словник не завантажено) —
/// файл **лишається**, прохід зупиняється (решта — наступного разу); `failed` += невдалий елемент + усі ще не
/// оброблені елементи проходу (вони теж лишились у inbox — банер «Not saved yet: N» показує реальну кількість).
/// Після проходу — **один** `processAll` черги (тригер `.inbox`), якщо `queued > 0`.
///
/// Ідемпотентність (DI9): падіння між «додати» і «видалити файл» → наступний прохід побачить дубль (0 запитів).
/// Single-flight: поки прохід іде, нові виклики `ingest()` чекають на нього й отримують той самий звіт.
public actor InboxIngestor {
    private let store: InboxStore
    private let repository: DictionaryRepository
    private let processor: PendingQueueProcessor
    private let registry: LanguagePairRegistry
    private let settings: SettingsStore
    private let logger: RedactingLogger?

    private var current: Task<InboxIngestReport, Never>?

    public init(
        store: InboxStore,
        repository: DictionaryRepository,
        processor: PendingQueueProcessor,
        registry: LanguagePairRegistry,
        settings: SettingsStore,
        logger: RedactingLogger? = nil
    ) {
        self.store = store
        self.repository = repository
        self.processor = processor
        self.registry = registry
        self.settings = settings
        self.logger = logger
    }

    /// Один прохід inbox (single-flight). Слова, що з'явилися під час проходу, підхопить наступний виклик.
    public func ingest() async -> InboxIngestReport {
        if let current {
            return await current.value
        }
        // Тіло задачі ізольоване на цьому акторі й стартує лише після `await` нижче, тож `current` уже присвоєно;
        // `current = nil` — усередині задачі, щоб пізній викликач не скинув новіший прохід.
        let task = Task<InboxIngestReport, Never> {
            let report = await self.runPass()
            self.finishPass()
            return report
        }
        current = task
        return await task.value
    }

    private func finishPass() {
        current = nil
    }

    private func runPass() async -> InboxIngestReport {
        var report = InboxIngestReport()
        let scan: InboxScanResult
        do {
            scan = try store.scan()
        } catch {
            report.failed = 1
            logger?.error("Inbox scan failed")
            logger?.info(InboxLog.finished(report))
            return report
        }
        report.rejected += scan.rejectedFiles
        report.failed += scan.unreadableFiles

        // Невідома (незареєстрована) пара в налаштуваннях → пара за замовчуванням (як `AddWordUseCase`).
        let configuredPair = settings.languagePairID
        let pairID = registry.pair(id: configuredPair) != nil ? configuredPair : LanguagePairRegistry.defaultPairID
        let pair = registry.pair(id: pairID)

        for (index, stored) in scan.items.enumerated() {
            let cleaned: CleanedSelection
            switch SelectionValidator.validate(stored.item.text) {
            case .rejected:
                report.rejected += 1
                removeFile(stored)
                continue
            case .valid(let selection):
                cleaned = selection
            }

            let hint = AddWordUseCase.acceptedHint(stored.item.languageHint, pair: pair)
            do {
                _ = try await repository.add(
                    EntryDraft(word: cleaned.text, languagePair: pairID, status: .pending, languageHint: hint)
                )
                report.queued += 1
            } catch RepositoryError.duplicate {
                report.duplicates += 1
            } catch {
                // Диск / словник не завантажено: файл лишається, решта — наступного разу. Лишаються в inbox цей
                // елемент і всі наступні (вже відхилені/збережені раніше файли прибрано).
                report.failed += scan.items.count - index
                logger?.error("Inbox item not saved; ingest stopped")
                break
            }
            removeFile(stored)
        }

        if report.queued > 0 {
            logger?.info(QueueLog.started(.inbox))
            let results = await processor.processAll(ignoringBackoff: false)
            logger?.info(QueueLog.finished(.inbox, results: results))
        }
        logger?.info(InboxLog.finished(report))
        return report
    }

    /// Видалення файлу обробленого елемента. Невдача не зупиняє прохід: запис уже в словнику (або відхилений),
    /// тож наступний прохід дасть дубль/повторне відхилення без запитів.
    private func removeFile(_ stored: InboxStoredItem) {
        do {
            try store.remove(stored)
        } catch {
            logger?.error("Inbox file not removed")
        }
    }
}

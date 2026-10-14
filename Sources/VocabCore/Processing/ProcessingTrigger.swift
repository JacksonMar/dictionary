import Foundation

/// Що запустило прохід черги (§8.3, M6) — для логів (P5 зі звіту ручного тестування).
public enum ProcessingTrigger: String, CaseIterable, Sendable {
    /// Кнопка «Повторити» для одного запису.
    case manual
    /// «Повторити всі» / «Повторити очікувані».
    case retryAll
    /// Старт застосунку.
    case startup
    /// Відновлення мережі (`NetworkMonitor`).
    case network
    /// Збережено API-ключ.
    case keySaved
    /// Змінено модель.
    case modelChanged
    /// Після імпорту (імпортовані pending-записи).
    case imported
    /// Таймер `processDue`.
    case due
    /// M7: перемикання відображення на мову варіанта (автодоповнення).
    case displaySwitch
    /// M7: кнопка «Доповнити італійською (N)».
    case variantBackfill
    /// M7: «Оновити італійський переклад» для одного запису.
    case variantRefresh
}

/// Рядки логу навколо викликів черги (§8.3, M6). Лише тригер, UUID і лічильники — без слова, тексту помилки, ключа.
public enum QueueLog {
    /// `Queue run started: trigger=network` або `Queue run started: trigger=manual id=<UUID>`.
    public static func started(_ trigger: ProcessingTrigger, entryID: UUID? = nil) -> String {
        "Queue run started: trigger=\(trigger.rawValue)" + idSuffix(entryID)
    }

    /// `Queue run finished: trigger=manual id=<UUID> ready=1 pending=0 failed=0 skipped=0 notFound=0`.
    public static func finished(
        _ trigger: ProcessingTrigger,
        entryID: UUID? = nil,
        results: [ProcessingResult]
    ) -> String {
        var ready = 0
        var pending = 0
        var failed = 0
        var skipped = 0
        var notFound = 0
        var duplicate = 0
        for result in results {
            switch result {
            case .ready:
                ready += 1
            case .pending:
                pending += 1
            case .failed:
                failed += 1
            case .skipped:
                skipped += 1
            case .notFound:
                notFound += 1
            case .duplicate:
                duplicate += 1
            }
        }
        return "Queue run finished: trigger=\(trigger.rawValue)" + idSuffix(entryID)
            + " ready=\(ready) pending=\(pending) failed=\(failed) skipped=\(skipped) notFound=\(notFound)"
            + " duplicate=\(duplicate)"
    }

    /// M7: `Variant backfill started: trigger=displaySwitch language=it eligible=37`. Без слів.
    public static func variantStarted(_ trigger: ProcessingTrigger, languageID: String, eligible: Int) -> String {
        "Variant backfill started: trigger=\(trigger.rawValue) language=\(languageID) eligible=\(eligible)"
    }

    /// M7: `Variant backfill finished: trigger=displaySwitch language=it requests=3 ready=36 pending=1 failed=0`;
    /// якщо прохід зупинено — ` stoppedBy=<тип помилки>`, якщо інший прохід уже йшов — ` alreadyRunning`.
    public static func variantFinished(
        _ trigger: ProcessingTrigger,
        languageID: String,
        report: VariantBackfillReport
    ) -> String {
        var message = "Variant backfill finished: trigger=\(trigger.rawValue) language=\(languageID)"
            + " requests=\(report.requests) ready=\(report.ready) pending=\(report.pending) failed=\(report.failed)"
        if let stoppedBy = report.stoppedBy {
            message += " stoppedBy=\(stoppedBy.logName)"
        }
        if report.alreadyRunning {
            message += " alreadyRunning"
        }
        return message
    }

    private static func idSuffix(_ entryID: UUID?) -> String {
        guard let entryID else { return "" }
        return " id=\(entryID.uuidString)"
    }
}

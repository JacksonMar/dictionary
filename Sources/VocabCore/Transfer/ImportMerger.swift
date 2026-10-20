import Foundation

/// Об'єднання імпортованих записів з локальними (§10, D1). Чисті функції.
public enum ImportMerger {
    /// Згортає дублікати всередині файлу: збіг за `id` або за (`languagePair`, `TextNormalizer.key(word)`).
    /// Лишається запис зі строго новішим `updatedAt` (рівність → перший у файлі), інші — пропущені.
    /// Порядок — за першою появою.
    public static func collapseDuplicates(_ imported: [Entry]) -> (entries: [Entry], skippedReasons: [String]) {
        var index = EntryIndex()
        var skipped: [String] = []
        for candidate in imported {
            let byID = index.position(of: candidate.id)
            let byKey = index.position(ofKey: dedupKey(candidate))
            switch (byID, byKey) {
            case (nil, nil):
                index.append(candidate)
            case let (position?, nil), let (nil, position?):
                replaceIfNewer(&index, at: position, with: candidate, skipped: &skipped)
            case let (idPosition?, keyPosition?):
                if idPosition == keyPosition {
                    replaceIfNewer(&index, at: idPosition, with: candidate, skipped: &skipped)
                } else {
                    // Збігається з двома різними записами файлу — лишаємо наявні.
                    skipped.append(duplicateReason(candidate))
                }
            }
        }
        return (index.entries, skipped)
    }

    /// Merge (D1): спершу згортання дублікатів у файлі, далі для кожного імпортованого — пошук локального за `id`,
    /// інакше за (`languagePair`, `key(word)`):
    /// - нема збігу → додати (`added`);
    /// - збіг і `imported.updatedAt > local.updatedAt` → замінити вміст, зберігши `id` локального (`updated`);
    ///   виняток: імпортований `pending`/`failed` не перезаписує локальний `ready` (`skipped`);
    ///   заміна, що дала б дубль іншого локального запису, — `skipped`;
    /// - інакше (старіший або рівний) → `skipped`.
    /// `report.skipped` включає дублікати у файлі, але **не** невалідні записи з `ParsedImport` (їх додає виклик).
    public static func merge(local: [Entry], imported: [Entry]) -> (entries: [Entry], report: ImportReport) {
        let collapsed = collapseDuplicates(imported)
        var report = ImportReport()
        report.addSkipped(collapsed.skippedReasons)

        var index = EntryIndex(local)
        for candidate in collapsed.entries {
            let candidateKey = dedupKey(candidate)
            guard let position = index.position(of: candidate.id) ?? index.position(ofKey: candidateKey) else {
                index.append(candidate)
                report.added += 1
                continue
            }

            let current = index.entries[position]
            let skipReason: String?
            if candidate.updatedAt <= current.updatedAt {
                skipReason = L10n.text(.importSkipNotNewer, ["word": candidate.word])
            } else if current.status == .ready && candidate.status != .ready {
                skipReason = L10n.text(.importSkipNotProcessed, ["word": candidate.word])
            } else if let other = index.position(ofKey: candidateKey), other != position {
                skipReason = L10n.text(.importSkipConflict, ["word": candidate.word])
            } else {
                skipReason = nil
            }

            guard let skipReason else {
                var replacement = candidate
                replacement.id = current.id
                replacement.variants = VariantMerge.combine(winner: replacement, other: current)
                index.replace(at: position, with: replacement)
                report.updated += 1
                continue
            }
            // M7 (D30): основні поля лишаються локальними, але варіанти з файлу можуть доповнити локальні —
            // тоді запис рахується як `updated` (дані з файлу замість нових запитів). `updatedAt` не змінюється.
            let combined = VariantMerge.combine(winner: current, other: candidate)
            if !sameVariants(combined, current.variants) {
                var adopted = current
                adopted.variants = combined
                index.replace(at: position, with: adopted)
                report.updated += 1
            } else {
                report.addSkipped([skipReason])
            }
        }
        return (index.entries, report)
    }

    /// Порівняння варіантів з нормалізацією `nil` ≡ `[:]`.
    static func sameVariants(_ lhs: [String: EntryVariant]?, _ rhs: [String: EntryVariant]?) -> Bool {
        (lhs ?? [:]) == (rhs ?? [:])
    }

    // MARK: - Private

    /// Ключ дедуплікації D8: (`languagePair`, `TextNormalizer.key(word)`).
    fileprivate static func dedupKey(_ entry: Entry) -> String {
        entry.languagePair + "\u{0}" + TextNormalizer.key(entry.word)
    }

    /// Строго новіший `updatedAt` замінює запис файлу; інакше кандидат пропускається.
    private static func replaceIfNewer(
        _ index: inout EntryIndex,
        at position: Int,
        with candidate: Entry,
        skipped: inout [String]
    ) {
        let existing = index.entries[position]
        if candidate.updatedAt > existing.updatedAt {
            skipped.append(duplicateReason(existing))
            var winner = candidate
            winner.variants = VariantMerge.combine(winner: candidate, other: existing)
            index.replace(at: position, with: winner)
        } else {
            skipped.append(duplicateReason(candidate))
            // M7: варіанти програшного дубля можуть доповнити переможця (те саме правило, що й у merge).
            let combined = VariantMerge.combine(winner: existing, other: candidate)
            if !sameVariants(combined, existing.variants) {
                var winner = existing
                winner.variants = combined
                index.replace(at: position, with: winner)
            }
        }
    }

    private static func duplicateReason(_ entry: Entry) -> String {
        L10n.text(.importSkipDuplicateInFile, ["word": entry.word])
    }
}

/// Масив записів з індексами за `id` і ключем дедуплікації (щоб merge був O(n), а не O(n²)).
private struct EntryIndex {
    private(set) var entries: [Entry] = []
    private var byID: [UUID: Int] = [:]
    private var byKey: [String: Int] = [:]

    init(_ initial: [Entry] = []) {
        for entry in initial {
            append(entry)
        }
    }

    func position(of id: UUID) -> Int? {
        byID[id]
    }

    func position(ofKey key: String) -> Int? {
        byKey[key]
    }

    mutating func append(_ entry: Entry) {
        let position = entries.count
        entries.append(entry)
        if byID[entry.id] == nil {
            byID[entry.id] = position
        }
        let key = ImportMerger.dedupKey(entry)
        if byKey[key] == nil {
            byKey[key] = position
        }
    }

    mutating func replace(at position: Int, with entry: Entry) {
        let old = entries[position]
        if byID[old.id] == position {
            byID[old.id] = nil
        }
        let oldKey = ImportMerger.dedupKey(old)
        if byKey[oldKey] == position {
            byKey[oldKey] = nil
        }
        entries[position] = entry
        if byID[entry.id] == nil {
            byID[entry.id] = position
        }
        let newKey = ImportMerger.dedupKey(entry)
        if byKey[newKey] == nil {
            byKey[newKey] = position
        }
    }
}

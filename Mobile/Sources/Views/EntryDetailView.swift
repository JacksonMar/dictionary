import SwiftUI
import VocabCore

/// Деталі запису (IOS_PLAN §5): усі поля, озвучення слова й прикладу, стан і остання помилка (pending/failed),
/// «Повторити», «Редагувати», «Видалити» (з підтвердженням), блок мови варіанта з «Оновити італійський переклад»
/// (1 явний запит, M7). Дані — з актуального стану моделі (після повтору/оновлення екран перемальовується).
@MainActor
struct EntryDetailView: View {
    @ObservedObject var model: MobileAppModel
    let entryID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var editingEntry: Entry?
    @State private var isConfirmingDeletion: Bool = false

    var body: some View {
        Group {
            if let entry = model.entry(id: entryID) {
                details(entry)
            } else {
                ContentUnavailableView(L10n.text(.repositoryNotFound), systemImage: "questionmark.folder")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingEntry) { (entry: Entry) in
            EntryEditView(model: model, mode: .edit(entry))
        }
    }

    private func details(_ entry: Entry) -> some View {
        List {
            mainSection(entry)
            if entry.status != .ready {
                statusSection(entry)
            }
            if !entry.translations.isEmpty {
                Section {
                    ForEach(Array(entry.translations.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                        Text(item.element)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(L10n.text(.editorTranslations))
                }
            }
            if let example = entry.example, !example.source.isEmpty {
                exampleSection(example, entry: entry, languageID: nil)
            }
            if let rendering = model.activeRendering ?? model.renderings.first {
                variantSection(entry, rendering: rendering)
            }
            actionsSection(entry)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(entry.word)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text(.commonEdit)) {
                    editingEntry = entry
                }
            }
        }
        .confirmationDialog(
            Text(L10n.text(.dictionaryDeleteTitleOne)),
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button(L10n.text(.dictionaryDeleteOne, ["word": entry.word]), role: .destructive) {
                delete(entry.id)
            }
            Button(L10n.text(.commonCancel), role: .cancel) {}
        }
    }

    // MARK: - Sections

    private func mainSection(_ entry: Entry) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.word)
                        .font(.title2)
                        .bold()
                        .textSelection(.enabled)
                    if let transcription = nonEmpty(entry.transcription) {
                        Text(transcription)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer(minLength: 8)
                if model.isSpeechAvailable {
                    speakButton(entry.word, entry: entry, languageID: nil)
                }
            }
            if let partOfSpeech = nonEmpty(entry.partOfSpeech) {
                LabeledContent(L10n.text(.editorPartOfSpeech), value: partOfSpeech)
            }
            if let lemma = nonEmpty(entry.lemma), lemma != entry.word {
                LabeledContent(L10n.text(.editorLemma), value: lemma)
            }
        }
    }

    private func statusSection(_ entry: Entry) -> some View {
        Section {
            Text(entry.status == .failed ? L10n.text(.tableHelpFailed) : L10n.text(.tableHelpPending))
                .foregroundStyle(entry.status == .failed ? Color.red : Color.orange)
            if let lastError = nonEmpty(entry.lastError) {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        } header: {
            Text(L10n.text(.mobileDetailStatus))
        }
    }

    private func exampleSection(_ example: Example, entry: Entry, languageID: String?) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(example.source)
                        .italic()
                        .textSelection(.enabled)
                    if let translation = nonEmpty(example.translation) {
                        Text(translation)
                            .foregroundStyle(Color.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if model.isSpeechAvailable {
                    speakButton(example.source, entry: entry, languageID: languageID)
                }
            }
        } header: {
            Text(L10n.text(.editorExample))
        }
    }

    /// Блок мови варіанта (як macOS `VariantReadOnlySection`): поля ready-варіанта або стан, «Оновити …».
    private func variantSection(_ entry: Entry, rendering: RenderingLanguage) -> some View {
        let texts = RenderingLanguageTexts(rendering)
        let variant: EntryVariant? = entry.readyVariant(rendering.id)
        return Section {
            if let variant {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(variant.word ?? entry.word)
                            .font(.headline)
                            .textSelection(.enabled)
                        if let transcription = nonEmpty(variant.transcription) {
                            Text(transcription)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if model.isSpeechAvailable {
                        speakButton(variant.word ?? entry.word, entry: entry, languageID: rendering.id)
                    }
                }
                if !variant.translations.isEmpty {
                    Text(variant.translations.joined(separator: ", "))
                        .textSelection(.enabled)
                }
                if let example = variant.example, !example.source.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(example.source)
                            .italic()
                        if let translation = nonEmpty(example.translation) {
                            Text(translation)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
            } else if let status = MobileAppModel.variantStatusText(for: entry, rendering: rendering) {
                Text(status)
                    .foregroundStyle(Color.secondary)
            }
            Button {
                refreshVariant(entry.id, languageID: rendering.id)
            } label: {
                HStack(spacing: 8) {
                    Text(texts.refreshTitle)
                    if model.retryingIDs.contains(entry.id) {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(entry.status != .ready || model.retryingIDs.contains(entry.id))
        } header: {
            Text(texts.sectionTitle)
        } footer: {
            Text(L10n.text(.editorVariantRefreshHelp))
        }
    }

    private func actionsSection(_ entry: Entry) -> some View {
        Section {
            if entry.status != .ready {
                Button {
                    retry(entry.id)
                } label: {
                    HStack(spacing: 8) {
                        Label(L10n.text(.commonRetry), systemImage: "arrow.clockwise")
                        if model.retryingIDs.contains(entry.id) {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.retryingIDs.contains(entry.id))
            }
            Button(role: .destructive) {
                isConfirmingDeletion = true
            } label: {
                Label(L10n.text(.mobileActionDelete), systemImage: "trash")
            }
        }
    }

    private func speakButton(_ text: String, entry: Entry, languageID: String?) -> some View {
        Button {
            model.speak(text, entry: entry, languageID: languageID)
        } label: {
            Label(L10n.text(.commonSpeak), systemImage: "speaker.wave.2")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Actions

    private func retry(_ id: UUID) {
        Task<Void, Never> { @MainActor in
            _ = await model.retry(id: id)
        }
    }

    private func refreshVariant(_ id: UUID, languageID: String) {
        Task<Void, Never> { @MainActor in
            _ = await model.refreshVariant(id: id, languageID: languageID)
        }
    }

    private func delete(_ id: UUID) {
        Task<Void, Never> { @MainActor in
            if await model.delete(id: id) {
                dismiss()
            }
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

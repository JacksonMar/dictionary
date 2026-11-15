import SwiftUI
import VocabCore

/// Налаштування (IOS_PLAN §5, `Form`): API-ключ (`SecureField`, зберегти/видалити, статус; лише Keychain, DI8),
/// модель (+ скидання), мова інтерфейсу (миттєво, DI14), дані (шлях і кількість резервних копій). Теми немає (DI19);
/// експорт/імпорт — I5, мова голосу — I2b.
@MainActor
struct SettingsView: View {
    @ObservedObject var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var keyInput: String = ""
    @State private var modelInput: String = ""

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                modelSection
                languageSection
                dataSection
            }
            .navigationTitle(L10n.text(.windowSettings))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text(.mobileCommonDone)) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                model.refreshAPIKeyState()
                model.refreshStorageInfo()
                modelInput = model.modelName
            }
        }
    }

    // MARK: - Sections

    private var apiKeySection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: model.hasAPIKey ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.hasAPIKey ? Color.green : Color.orange)
                Text(model.hasAPIKey ? L10n.text(.settingsKeySaved) : L10n.text(.settingsKeyMissing))
            }
            SecureField(L10n.text(.settingsApiKey), text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Button(L10n.text(.settingsSaveKey)) {
                saveKey()
            }
            .disabled(trimmed(keyInput).isEmpty)
            if model.hasAPIKey {
                Button(L10n.text(.settingsDeleteKey), role: .destructive) {
                    _ = model.deleteAPIKey()
                }
            }
            if let error = model.settingsError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }
        } header: {
            Text(L10n.text(.settingsSectionClaude))
        } footer: {
            Text(L10n.text(.mobileSettingsKeyHint))
        }
    }

    private var modelSection: some View {
        Section {
            TextField(L10n.text(.settingsModel), text: $modelInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Button(L10n.text(.settingsSaveModel)) {
                model.setModel(trimmed(modelInput))
                modelInput = model.modelName
            }
            .disabled(trimmed(modelInput).isEmpty || trimmed(modelInput) == model.modelName)
            Button(L10n.text(.mobileSettingsResetModel)) {
                model.resetModelToDefault()
                modelInput = model.modelName
            }
            .disabled(model.modelName == model.defaultModelName)
        } header: {
            Text(L10n.text(.settingsSectionModel))
        } footer: {
            Text(modelFooter)
        }
    }

    private var languageSection: some View {
        Section {
            Picker(AppLanguage.pickerLabel, selection: interfaceLanguageBinding) {
                ForEach(AppLanguage.allCases, id: \.self) { (language: AppLanguage) in
                    Text(verbatim: language.nativeName)
                        .tag(language)
                }
            }
        } header: {
            Text(L10n.text(.mobileSettingsSectionLanguage))
        } footer: {
            Text(L10n.text(.mobileSettingsLanguageHint))
        }
    }

    private var dataSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(.mobileSettingsDataLocation))
                Text(verbatim: model.dataDirectoryPath)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent(L10n.text(.mobileSettingsBackups), value: String(model.backupCount))
        } header: {
            Text(L10n.text(.mobileSettingsSectionData))
        }
    }

    // MARK: - Helpers

    private var modelFooter: String {
        let current: String = L10n.text(.settingsCurrentModel, ["model": model.modelName])
        let fallback: String = L10n.text(.settingsDefaultModel, ["model": model.defaultModelName])
        return current + "\n" + fallback
    }

    private var interfaceLanguageBinding: Binding<AppLanguage> {
        Binding<AppLanguage>(
            get: { model.interfaceLanguage },
            set: { (language: AppLanguage) in
                model.setInterfaceLanguage(language)
            }
        )
    }

    private func saveKey() {
        // Значення ключа не логуємо й не зберігаємо поза Keychain; поле очищається після збереження.
        if model.saveAPIKey(keyInput) {
            keyInput = ""
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

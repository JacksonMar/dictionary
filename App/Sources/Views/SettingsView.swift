import AppKit
import SwiftUI
import VocabCore

/// Налаштування: API-ключ (лише в Keychain, значення ніколи не показується), модель Claude (M2),
/// вигляд — тема й розмір сторінки (M6), автозапуск (M5, `SMAppService`), мова інтерфейсу (M9),
/// перенесення словника — експорт/імпорт (M4).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKeyInput = ""
    @State private var modelInput = ""

    var body: some View {
        Form {
            Section {
                SecureField(L10n.text(.settingsApiKey), text: $apiKeyInput)
                HStack {
                    Button(L10n.text(.settingsSaveKey)) {
                        if model.saveAPIKey(apiKeyInput) {
                            apiKeyInput = ""
                        }
                    }
                    .disabled(trimmed(apiKeyInput).isEmpty)
                    if model.hasAPIKey {
                        Button(L10n.text(.settingsDeleteKey), role: .destructive) {
                            model.deleteAPIKey()
                        }
                    }
                    Spacer()
                }
                Label(
                    model.hasAPIKey ? L10n.text(.settingsKeySaved) : L10n.text(.settingsKeyMissing),
                    systemImage: model.hasAPIKey ? "checkmark.seal" : "exclamationmark.triangle"
                )
                .foregroundColor(model.hasAPIKey ? .secondary : .orange)
            } header: {
                Text(L10n.text(.settingsSectionClaude))
                    .font(.headline)
            }

            Section {
                TextField(L10n.text(.settingsModel), text: $modelInput)
                HStack {
                    Button(L10n.text(.settingsSaveModel)) {
                        model.setModel(modelInput)
                        modelInput = model.modelName
                    }
                    .disabled(trimmed(modelInput) == model.modelName)
                    Button(L10n.text(.settingsDefaultModel, ["model": SettingsDefaults.model])) {
                        model.resetModelToDefault()
                        modelInput = model.modelName
                    }
                    .disabled(model.modelName == SettingsDefaults.model)
                    Spacer()
                }
                Text(L10n.text(.settingsCurrentModel, ["model": model.modelName]))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text(L10n.text(.settingsSectionModel))
                    .font(.headline)
            }

            Section {
                Picker(L10n.text(.settingsTheme), selection: appearanceBinding) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker(L10n.text(.settingsPageSize), selection: pageSizeBinding) {
                    ForEach(Pagination.pageSizeOptions, id: \.self) { size in
                        Text(String(size)).tag(size)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            } header: {
                Text(L10n.text(.settingsSectionAppearance))
                    .font(.headline)
            }

            if model.isLoginItemAvailable {
                Section {
                    Toggle(L10n.text(.settingsLaunchAtLogin), isOn: launchAtLoginBinding)
                    loginItemStatus
                    if let error = model.loginItemError {
                        Text(error)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text(L10n.text(.settingsSectionLaunch))
                        .font(.headline)
                }
            }

            Section {
                Picker(AppLanguage.pickerLabel, selection: interfaceLanguageBinding) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                // Мітка дублює заголовок секції; лишається для VoiceOver.
                .labelsHidden()
                .fixedSize()
                if model.interfaceLanguageNeedsRestart {
                    HStack {
                        Text(L10n.text(.settingsLanguageRestartHint))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(L10n.text(.settingsLanguageRestartNow)) {
                            model.restartToApplyLanguage()
                        }
                    }
                }
            } header: {
                Text(AppLanguage.pickerLabel)
                    .font(.headline)
            }

            if model.isTransferAvailable {
                Section {
                    HStack {
                        Button(L10n.text(.settingsExport)) {
                            Task { @MainActor in
                                await model.exportWithPanel()
                            }
                        }
                        Button(L10n.text(.settingsImport)) {
                            model.beginImport()
                        }
                        if model.isTransferring {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                    .disabled(!model.isLoaded || model.isTransferring)
                    Text(L10n.text(.settingsTransferHint))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(L10n.text(.settingsSectionTransfer))
                        .font(.headline)
                }
            }

            if let error = model.settingsError {
                Text(error)
                    .foregroundColor(.red)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            modelInput = model.modelName
            model.refreshLoginItemState()
        }
        // Користувач міг дозволити/заборонити автозапуск у System Settings, поки вікно було відкрите.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItemState()
        }
        .importModeDialog(model: model)
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { model.appearance },
            set: { model.setAppearance($0) }
        )
    }

    private var interfaceLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.interfaceLanguageSelection },
            set: { model.setInterfaceLanguage($0) }
        )
    }

    private var pageSizeBinding: Binding<Int> {
        Binding(
            get: { model.pageSize },
            set: { model.setPageSize($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    @ViewBuilder
    private var loginItemStatus: some View {
        switch model.loginItemState {
        case .requiresApproval?:
            Text(L10n.text(.settingsLoginApproval))
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text(.settingsOpenLoginItems)) {
                model.openLoginItemsSettings()
            }
        case .notFound?:
            Text(L10n.text(.settingsLoginNotFound))
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .enabled?, .disabled?, nil:
            EmptyView()
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

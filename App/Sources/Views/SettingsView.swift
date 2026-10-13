import SwiftUI
import VocabCore

/// Налаштування (M2): API-ключ (лише в Keychain, значення ніколи не показується) і модель Claude.
/// Автозапуск — M5, експорт/імпорт — M4.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKeyInput = ""
    @State private var modelInput = ""

    var body: some View {
        Form {
            Section {
                SecureField("API-ключ", text: $apiKeyInput)
                HStack {
                    Button("Зберегти ключ") {
                        if model.saveAPIKey(apiKeyInput) {
                            apiKeyInput = ""
                        }
                    }
                    .disabled(trimmed(apiKeyInput).isEmpty)
                    if model.hasAPIKey {
                        Button("Видалити ключ", role: .destructive) {
                            model.deleteAPIKey()
                        }
                    }
                    Spacer()
                }
                Label(
                    model.hasAPIKey ? "Ключ збережено" : "Ключ не задано",
                    systemImage: model.hasAPIKey ? "checkmark.seal" : "exclamationmark.triangle"
                )
                .foregroundColor(model.hasAPIKey ? .secondary : .orange)
            } header: {
                Text("Claude API")
                    .font(.headline)
            }

            Section {
                TextField("Модель", text: $modelInput)
                HStack {
                    Button("Зберегти модель") {
                        model.setModel(modelInput)
                        modelInput = model.modelName
                    }
                    .disabled(trimmed(modelInput) == model.modelName)
                    Button("Типова (\(SettingsDefaults.model))") {
                        model.resetModelToDefault()
                        modelInput = model.modelName
                    }
                    .disabled(model.modelName == SettingsDefaults.model)
                    Spacer()
                }
                Text("Поточна модель: \(model.modelName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Модель")
                    .font(.headline)
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
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

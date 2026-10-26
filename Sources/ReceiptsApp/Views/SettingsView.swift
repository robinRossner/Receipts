import SwiftUI

/// The macOS Settings window (⌘,). Fields bind straight to UserDefaults via @AppStorage using
/// LLMSettings.Keys; every change asks the store to rebuild its providers.
struct SettingsView: View {
    @EnvironmentObject var store: ReceiptStore

    private static let d = LLMSettings.defaults

    @AppStorage(LLMSettings.Keys.backend) private var backend: LLMBackend = d.backend
    @AppStorage(LLMSettings.Keys.ollamaEndpoint) private var ollamaEndpoint = d.ollamaEndpoint
    @AppStorage(LLMSettings.Keys.ollamaVisionModel) private var ollamaVisionModel = d.ollamaVisionModel
    @AppStorage(LLMSettings.Keys.ollamaTextModel) private var ollamaTextModel = d.ollamaTextModel
    @AppStorage(LLMSettings.Keys.ollamaUseSchemaFormat) private var ollamaUseSchemaFormat = d.ollamaUseSchemaFormat
    @AppStorage(LLMSettings.Keys.debugDump) private var debugDump = d.debugDump

    @State private var isChecking = false

    /// Everything that should trigger a provider rebuild, as one Equatable value.
    private var snapshot: [String] {
        [backend.rawValue, ollamaEndpoint, ollamaVisionModel, ollamaTextModel, "\(ollamaUseSchemaFormat)", "\(debugDump)"]
    }

    var body: some View {
        Form {
            Section("AI backend") {
                Picker("Backend", selection: $backend) {
                    ForEach(LLMBackend.allCases) { Text($0.displayName).tag($0) }
                }
                backendSection
                statusRow
            }
            Section("Debugging") {
                Toggle("Write extraction debug dumps", isOn: $debugDump)
                Text("Saves each receipt's raw extraction as JSON in \(store.env.debugDir.path).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: snapshot) { store.applySettings() }
    }

    /// Backend-specific fields. A new LLMBackend case adds its own section here.
    @ViewBuilder
    private var backendSection: some View {
        switch backend {
        case .ollama:
            TextField("Endpoint", text: $ollamaEndpoint, prompt: Text(Self.d.ollamaEndpoint))
            TextField("Vision model", text: $ollamaVisionModel, prompt: Text(Self.d.ollamaVisionModel))
            TextField("Text model", text: $ollamaTextModel, prompt: Text(Self.d.ollamaTextModel))
            Toggle("Constrain output with JSON schema (Ollama 0.5+)", isOn: $ollamaUseSchemaFormat)
            Button("Restore Ollama defaults") {
                ollamaEndpoint = Self.d.ollamaEndpoint
                ollamaVisionModel = Self.d.ollamaVisionModel
                ollamaTextModel = Self.d.ollamaTextModel
                ollamaUseSchemaFormat = Self.d.ollamaUseSchemaFormat
            }
        }
    }

    private var statusRow: some View {
        HStack(alignment: .top) {
            if let warning = store.providerWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                Label("Ready", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isChecking ? "Checking…" : "Check now") {
                isChecking = true
                Task {
                    store.applySettings()
                    await store.checkProviderReadiness()
                    isChecking = false
                }
            }
            .disabled(isChecking)
        }
    }
}

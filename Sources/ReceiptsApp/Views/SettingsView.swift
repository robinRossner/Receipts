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
    @AppStorage(LLMSettings.Keys.anthropicModel) private var anthropicModel = d.anthropicModel
    @AppStorage(LLMSettings.Keys.claudeCLIPath) private var claudeCLIPath = d.claudeCLIPath
    @AppStorage(LLMSettings.Keys.claudeCLIModel) private var claudeCLIModel = d.claudeCLIModel
    @AppStorage(LLMSettings.Keys.fallbackToOllama) private var fallbackToOllama = d.fallbackToOllama

    @State private var isChecking = false
    /// SecureField contents; only written to the Keychain on Save, never to UserDefaults.
    @State private var secretInput = ""
    @State private var hasAPIKey = KeychainStore.contains(.anthropicAPIKey)
    @State private var hasToken = KeychainStore.contains(.claudeOAuthToken)

    /// Everything that should trigger a provider rebuild, as one Equatable value.
    private var snapshot: [String] {
        [backend.rawValue, ollamaEndpoint, ollamaVisionModel, ollamaTextModel, "\(ollamaUseSchemaFormat)", "\(debugDump)",
         anthropicModel, claudeCLIPath, claudeCLIModel, "\(fallbackToOllama)"]
    }

    var body: some View {
        TabView {
            general
                .tabItem { Label("AI Backend", systemImage: "cpu") }
            CloudSyncSettingsView(sync: store.sync)
                .tabItem { Label("Cloud sync", systemImage: "icloud") }
            DataSettingsView()
                .tabItem { Label("Data", systemImage: "externaldrive") }
            DictionaryEditorView()
                .frame(width: 560, height: 560)
                .tabItem { Label("Dictionary", systemImage: "books.vertical") }
        }
    }

    private var general: some View {
        Form {
            Section("AI backend") {
                Picker("Backend", selection: $backend) {
                    ForEach(LLMBackend.allCases) { Text($0.displayName).tag($0) }
                }
                backendSection
                if backend.isClaude {
                    Toggle("Fall back to local Ollama if Claude fails", isOn: $fallbackToOllama)
                    Label("Receipt images and item names are sent to Anthropic for processing.", systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                statusRow
            }
            if backend.isClaude && fallbackToOllama {
                Section("Ollama fallback") { ollamaFields }
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
        .onChange(of: backend) { secretInput = "" }
    }

    /// Backend-specific fields. A new LLMBackend case adds its own section here.
    @ViewBuilder
    private var backendSection: some View {
        switch backend {
        case .ollama:
            ollamaFields
        case .anthropicAPI:
            TextField("Model", text: $anthropicModel, prompt: Text(Self.d.anthropicModel))
            secretRow(title: "API key", account: .anthropicAPIKey, isSaved: $hasAPIKey)
            Text("Billed to your Anthropic Console account. Create a key at platform.claude.com.")
                .font(.caption).foregroundStyle(.secondary)
        case .claudeSubscriptionToken:
            cliFields
            secretRow(title: "Token", account: .claudeOAuthToken, isSaved: $hasToken)
            Text("Run `claude setup-token` in Terminal and paste the token here. For personal use with your own subscription only.")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .claudeCodeLogin:
            cliFields
            Text("Uses whatever account your `claude` CLI is already logged in with.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var ollamaFields: some View {
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

    @ViewBuilder
    private var cliFields: some View {
        HStack {
            TextField("Claude CLI path", text: $claudeCLIPath, prompt: Text(ClaudeCLILocator.detect() ?? "not found - enter path"))
            Button("Detect") {
                if let found = ClaudeCLILocator.detect() { claudeCLIPath = found }
            }
        }
        TextField("Model", text: $claudeCLIModel, prompt: Text(Self.d.claudeCLIModel))
    }

    private func secretRow(title: String, account: KeychainStore.Account, isSaved: Binding<Bool>) -> some View {
        HStack {
            SecureField(title, text: $secretInput, prompt: Text(isSaved.wrappedValue ? "Saved in Keychain" : "Not set"))
            Button("Save") {
                if KeychainStore.save(secretInput, for: account) {
                    isSaved.wrappedValue = KeychainStore.contains(account)
                    secretInput = ""
                    store.applySettings(secretsChanged: true)
                }
            }
            .disabled(secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Clear") {
                KeychainStore.delete(account)
                isSaved.wrappedValue = false
                secretInput = ""
                store.applySettings(secretsChanged: true)
            }
            .disabled(!isSaved.wrappedValue)
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
                    store.applySettings(secretsChanged: true)
                    await store.checkProviderReadiness()
                    isChecking = false
                }
            }
            .disabled(isChecking)
        }
    }
}


/// Backup settings: manual backup, optional weekly automatic backup, last-backup date.
struct DataSettingsView: View {
    @EnvironmentObject var store: ReceiptStore
    @AppStorage(BackupService.Keys.autoEnabled) private var autoEnabled = false
    @AppStorage(BackupService.Keys.autoFolder) private var autoFolder = ""
    @State private var backingUp = false

    var body: some View {
        Form {
            Section("Backup") {
                LabeledContent("Last backup") {
                    Text(store.lastBackupDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                }
                Button(backingUp ? "Backing up…" : "Back Up Data…") {
                    backingUp = true
                    Task { await store.backUpNow(); backingUp = false }
                }
                .disabled(backingUp)
                Text("Creates a zip with a consistent copy of the database and all receipt images.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Automatic weekly backup") {
                Toggle("Back up automatically (when the app starts and a week has passed)", isOn: $autoEnabled)
                HStack {
                    Text(autoFolder.isEmpty ? "No folder chosen" : autoFolder)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(autoFolder.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
                Text("Keeps the newest \(BackupService.keepCount) automatic backups in that folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Restore") {
                Text("To restore, quit the app, unzip a backup and replace receipts.db and receipts_archive in \(store.env.appSupportDir.path).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { autoFolder = url.path }
    }
}

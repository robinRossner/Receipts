import SwiftUI

/// Setup and status: the server address and the receipts token (kept in the Keychain), a connection test, sync status
/// and the photo cache. Cloud only: there are no AI settings on the phone.
struct SettingsScreen: View {
    @EnvironmentObject var store: ReceiptStore

    var body: some View {
        NavigationStack {
            SettingsForm(store: store, sync: store.sync)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(AppTheme.paper, for: .navigationBar)
        }
    }
}

private struct SettingsForm: View {
    @ObservedObject var store: ReceiptStore
    @ObservedObject var sync: SyncCoordinator

    @State private var serverURL = UserDefaults.standard.string(forKey: SyncSettings.Keys.serverURL) ?? ""
    /// SecureField contents; only ever written to the Keychain, never to UserDefaults.
    @State private var tokenInput = ""
    @State private var hasToken = KeychainStore.contains(.receiptsAPIToken)
    @State private var testing = false
    @State private var result: SyncCoordinator.ConnectionTest?
    @State private var cacheBytes = 0
    @State private var confirmClear = false
    @FocusState private var focus: Field?
    private enum Field { case url, token }

    private var urlProblem: String? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ServerURL.apiBase(from: trimmed) == nil else { return nil }
        #if DEBUG
        return "Not a valid address. Use https://… (plain http:// works for localhost in debug builds only)."
        #else
        return "Not a valid address. Use https://…"
        #endif
    }

    private var canSave: Bool {
        ServerURL.apiBase(from: serverURL) != nil && (hasToken || !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverURL, prompt: Text("https://receipts.example.com"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .focused($focus, equals: .url)
                    .accessibilityIdentifier("serverURLField")
                SecureField("Receipts token", text: $tokenInput, prompt: Text(hasToken ? "Saved in Keychain" : "Paste the token"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .token)
                    .accessibilityIdentifier("tokenField")
                if let urlProblem {
                    Text(urlProblem).font(.footnote).foregroundStyle(AppTheme.penRed)
                }
                Button("Save") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("saveSettingsButton")
                if hasToken {
                    Button("Remove token and disconnect", role: .destructive) { disconnect() }
                        .accessibilityIdentifier("disconnectButton")
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Your own receipts backend. Photos are sent there and read by it; this phone has no AI of its own. The token is stored in the iOS Keychain.")
            }
            .listRowBackground(AppTheme.paper)

            Section {
                Button(testing ? "Testing…" : "Test connection") { test() }
                    .disabled(testing || !canTest)
                    .accessibilityIdentifier("testConnectionButton")
                if let result {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle" : "xmark.octagon")
                        .font(.footnote)
                        .foregroundStyle(result.ok ? AppTheme.inkSoft : AppTheme.penRed)
                        .accessibilityIdentifier("testConnectionResult")
                }
            }
            .listRowBackground(AppTheme.paper)

            if SyncSettings.load().isConfigured {
                Section {
                    LabeledContent("Last sync") {
                        Text(sync.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                            .accessibilityIdentifier("lastSyncValue")
                    }
                    if sync.unsentChanges > 0 { LabeledContent("Not sent yet") { Text("\(sync.unsentChanges) change(s)") } }
                    if sync.rejectedRecords > 0 {
                        LabeledContent("Refused by the server") { Text("\(sync.rejectedRecords) record(s)") }
                        Text("Edit such a record again to send it again.").font(.footnote).foregroundStyle(AppTheme.inkSoft)
                    }
                    if let error = sync.lastError { Text(error).font(.footnote).foregroundStyle(AppTheme.penRed) }
                    Button(sync.phase == .syncing ? "Syncing…" : "Sync now") { Task { await sync.syncNow() } }
                        .disabled(sync.phase == .syncing)
                        .accessibilityIdentifier("syncNowButton")
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Syncs when the app opens, shortly after edits, and when you pull the list down.")
                }
                .listRowBackground(AppTheme.paper)
            }

            Section {
                LabeledContent("Cached photos") { Text(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file)) }
                Button("Clear cached photos", role: .destructive) { confirmClear = true }
                    .accessibilityIdentifier("clearCacheButton")
            } header: {
                Text("Photos")
            } footer: {
                Text("This phone keeps up to \(ByteCountFormatter.string(fromByteCount: Int64(SyncCapabilities.mobile.photoCacheBytes), countStyle: .file)) of receipt photos, oldest dropped first. The permanent photo archive is on your laptop: this phone never archives photos or releases the server's copy.")
            }
            .listRowBackground(AppTheme.paper)

            Section("About") {
                Text("Item categories (the dictionary) are edited on the Mac; changes sync here.")
                    .font(.footnote).foregroundStyle(AppTheme.inkSoft)
            }
            .listRowBackground(AppTheme.paper)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.desk)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { cacheBytes = sync.photoCacheBytes }
        .onChange(of: sync.phase) { cacheBytes = sync.photoCacheBytes }
        .confirmationDialog("Clear cached photos?", isPresented: $confirmClear) {
            Button("Clear cached photos", role: .destructive) {
                Task { await store.clearPhotoCache(); cacheBytes = sync.photoCacheBytes }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Receipts keep their data. A photo the server still holds is downloaded again when you open it; one that is only on your laptop shows “This photo is on your laptop”.")
        }
    }

    private var canTest: Bool {
        ServerURL.apiBase(from: serverURL) != nil && (hasToken || !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func save() {
        focus = nil
        let d = UserDefaults.standard
        d.set(serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: SyncSettings.Keys.serverURL)
        let typed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            guard KeychainStore.save(typed, for: .receiptsAPIToken) else {
                result = .init(ok: false, message: "The token could not be saved to the Keychain.")
                return
            }
            tokenInput = ""
        }
        hasToken = KeychainStore.contains(.receiptsAPIToken)
        d.set(true, forKey: SyncSettings.Keys.enabled)   // cloud only: saving the server turns sync on
        sync.configure()
        result = .init(ok: true, message: "Saved. Syncing…")
    }

    private func disconnect() {
        KeychainStore.delete(.receiptsAPIToken)
        hasToken = false
        UserDefaults.standard.set(false, forKey: SyncSettings.Keys.enabled)
        sync.configure()
        result = nil
    }

    private func test() {
        focus = nil
        testing = true
        let typed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = typed.isEmpty ? KeychainStore.read(.receiptsAPIToken) : typed
        Task {
            result = await sync.testConnection(serverURL: serverURL, token: token)
            testing = false
        }
    }
}

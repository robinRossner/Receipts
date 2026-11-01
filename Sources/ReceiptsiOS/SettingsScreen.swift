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
                .toolbarBackground(Theme.paper, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("Settings").font(Theme.display(20)).foregroundStyle(Theme.ink)
                    }
                }
        }
    }
}

private struct SettingsForm: View {
    @ObservedObject var store: ReceiptStore
    @ObservedObject var sync: SyncCoordinator

    private static let savedMessage = "Saved. Syncing…"

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

    private var canTest: Bool { canSave }

    var body: some View {
        Form {
            serverSection
            testSection
            if SyncSettings.load().isConfigured { syncSection }
            photosSection
            Section {
                Text("Item categories (the dictionary) are edited on the Mac; changes sync here. Items without a category can be sorted out under Overview.")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.inkSoft)
            } header: {
                header("About")
            }
            .listRowBackground(Theme.paper)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.desk)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { cacheBytes = sync.photoCacheBytes }
        .onChange(of: sync.phase) {
            cacheBytes = sync.photoCacheBytes
            if sync.phase == .idle, result?.message == Self.savedMessage { result = nil }   // the sync it announced is over
        }
        .confirmationDialog("Clear cached photos?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear cached photos", role: .destructive) {
                Task { await store.clearPhotoCache(); cacheBytes = sync.photoCacheBytes }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Receipts keep their data. A photo the server still holds is downloaded again when you open it; one that is only on your laptop shows “This photo is on your laptop”.")
        }
    }

    private func header(_ text: String) -> some View {
        SectionLabel(text: text).textCase(nil)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(Theme.body(12.5)).foregroundStyle(Theme.label)
    }

    // MARK: Sections

    private var serverSection: some View {
        Section {
            field("Server URL") {
                TextField("Server URL", text: $serverURL, prompt: Text(verbatim: "https://receipts.example.com"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .focused($focus, equals: .url)
                    .accessibilityIdentifier("serverURLField")
            }
            field("Receipts token") {
                SecureField("Receipts token", text: $tokenInput, prompt: Text(hasToken ? "Saved in Keychain" : "Paste the token"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .token)
                    .accessibilityIdentifier("tokenField")
            }
            if let urlProblem {
                Text(urlProblem)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.red)
            }
            Button { save() } label: {
                Label("Save", systemImage: "square.and.arrow.down").fontWeight(.medium)
            }
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.4)
            .accessibilityIdentifier("saveSettingsButton")
            if hasToken {
                Button(role: .destructive) { disconnect() } label: {
                    Label("Remove token and disconnect", systemImage: "xmark.circle")
                }
                .foregroundStyle(Theme.red)
                .accessibilityIdentifier("disconnectButton")
            }
        } header: {
            header("Server")
        } footer: {
            footer("Your own receipts backend. Photos are sent there and read by it; this phone has no AI of its own. The token is stored in the iOS Keychain.")
        }
        .listRowBackground(Theme.paper)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.body(12)).foregroundStyle(Theme.inkSoft)
            content().font(Theme.mono(14))
        }
        .padding(.vertical, 2)
    }

    private var testSection: some View {
        Section {
            Button { test() } label: {
                if testing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Testing…").fontWeight(.medium)
                    }
                } else {
                    Label("Test connection", systemImage: "network").fontWeight(.medium)
                }
            }
            .disabled(testing || !canTest)
            .opacity(canTest ? 1 : 0.4)
            .accessibilityIdentifier("testConnectionButton")
            if let result {
                NoteBox(
                    systemName: result.ok ? "checkmark.circle" : "xmark.octagon", text: result.message,
                    color: result.ok ? Theme.greenText : Theme.red, background: result.ok ? Theme.greenBg : Theme.redBg,
                    identifier: "testConnectionResult"
                )
            }
        }
        .listRowBackground(Theme.paper)
    }

    private var syncSection: some View {
        Section {
            HStack {
                Text("Last sync").font(Theme.body(15)).foregroundStyle(Theme.ink)
                Spacer()
                Text(sync.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.inkSoft)
                    .accessibilityIdentifier("lastSyncValue")
            }
            if sync.unsentChanges > 0 { count("Not sent yet", "\(sync.unsentChanges) change(s)", red: false) }
            if sync.rejectedRecords > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    count("Refused by the server", "\(sync.rejectedRecords) record(s)", red: true)
                    Text("Edit such a record again to send it again.")
                        .font(Theme.body(12.5))
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            if let error = sync.lastError {
                Text(error)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.red)
            }
            Button { Task { await sync.syncNow() } } label: {
                if sync.phase == .syncing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Syncing…").fontWeight(.medium)
                    }
                } else {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath").fontWeight(.medium)
                }
            }
            .disabled(sync.phase == .syncing)
            .accessibilityIdentifier("syncNowButton")
        } header: {
            header("Sync")
        } footer: {
            footer("Syncs when the app opens, shortly after edits, and when you pull the list down.")
        }
        .listRowBackground(Theme.paper)
    }

    private var photosSection: some View {
        Section {
            HStack {
                Text("Cached photos").font(Theme.body(15)).foregroundStyle(Theme.ink)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.inkSoft)
            }
            Button(role: .destructive) { confirmClear = true } label: {
                Label("Clear cached photos", systemImage: "trash")
            }
            .foregroundStyle(Theme.red)
            .accessibilityIdentifier("clearCacheButton")
        } header: {
            header("Photos")
        } footer: {
            footer("This phone keeps up to \(ByteCountFormatter.string(fromByteCount: Int64(SyncCapabilities.mobile.photoCacheBytes), countStyle: .file)) of receipt photos, oldest dropped first. The permanent photo archive is on your laptop: this phone never archives photos or releases the server's copy.")
        }
        .listRowBackground(Theme.paper)
    }

    private func count(_ title: String, _ text: String, red: Bool) -> some View {
        HStack {
            Text(title).font(Theme.body(15)).foregroundStyle(Theme.ink)
            Spacer()
            Text(text)
                .font(Theme.mono(12, .medium))
                .foregroundStyle(red ? Theme.red : Theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(red ? Theme.redBg : Theme.desk, in: Capsule())
        }
    }

    // MARK: Actions

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
        result = .init(ok: true, message: Self.savedMessage)
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

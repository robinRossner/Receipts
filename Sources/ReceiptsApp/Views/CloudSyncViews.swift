import SwiftUI

/// Small sync status in the top bar: what it is doing, when it last succeeded, a quiet note when it failed (the
/// details are in the tooltip; failed runs retry on their own), and a Sync now button.
struct SyncStatusView: View {
    @ObservedObject var sync: SyncCoordinator
    @EnvironmentObject var store: ReceiptStore

    var body: some View {
        if sync.phase != .off {
            HStack(spacing: 6) {
                if sync.phase == .syncing { ProgressView().controlSize(.mini) }
                Text(sync.statusText)
                    .font(AppTheme.body(11))
                    .foregroundColor(sync.lastError != nil ? AppTheme.penRed : AppTheme.inkSoft)
                    .lineLimit(1)
                Button { store.syncNow() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.inkSoft)
                .disabled(sync.phase == .syncing)
                .help("Sync now")
            }
            .help(helpText)
        }
    }

    private var helpText: String {
        var lines: [String] = []
        if let error = sync.lastError { lines.append(error) }
        if sync.unsentChanges > 0 { lines.append("\(sync.unsentChanges) local change(s) not sent yet.") }
        if let retry = sync.nextRetryAt { lines.append("Next attempt \(retry.formatted(.relative(presentation: .named))).") }
        return lines.isEmpty ? "Cloud sync" : lines.joined(separator: "\n")
    }
}

/// The server's `archive_overdue` / `disk_warning` flags and the 30 day reminder, visible until the cause is gone.
struct SyncBannersView: View {
    @ObservedObject var sync: SyncCoordinator
    @EnvironmentObject var store: ReceiptStore

    private let bannerPadding: CGFloat = 24

    var body: some View {
        ForEach(sync.banners, id: \.self) { text in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundColor(AppTheme.penRed).accessibilityHidden(true)
                Text(text)
                    .font(AppTheme.body(12))
                    .foregroundColor(AppTheme.penRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Sync now") { store.syncNow() }
                    .buttonStyle(.plain)
                    .font(AppTheme.body(12, weight: .medium))
                    .foregroundColor(AppTheme.penRed)
                    .disabled(sync.phase == .syncing)
            }
            .padding(.horizontal, bannerPadding)
            .padding(.vertical, 8)
            .background(AppTheme.penRedBg.ignoresSafeArea(edges: .top))
        }
    }
}

/// What the user can do about a receipt that is not an ordinary finished one (cloud sync only).
struct ReceiptProcessingPanel: View {
    @EnvironmentObject var store: ReceiptStore
    let detail: ReceiptDetail
    let processing: ReceiptProcessing
    @State private var confirmGiveUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if processing.isActive { ProgressView().controlSize(.small) }
                Text(processing.label).font(AppTheme.body(13, weight: .semibold))
            }
            switch processing {
            case .waitingForUpload(let error):
                Text("The photo is saved on this Mac and uploads as soon as the server is reachable." + (error.map { " Last attempt: \($0)" } ?? ""))
            case .uploadFailed(let error):
                Text((error ?? "The server did not accept this photo.") + " Retry, or remove this receipt and add a clearer photo.")
                HStack {
                    Button("Retry upload") { Task { await store.retryUpload(id: detail.id) } }
                    Button("Remove receipt", role: .destructive) { Task { await store.discardFailedUpload(id: detail.id) } }
                }
            case .processing:
                Text("The server reads the photo; the result appears here by itself.")
            case .failed(let error):
                Text((error ?? "The server could not read the receipt.") + " Retry it, or fill in the fields below by hand.")
                HStack {
                    Button("Retry extraction") { Task { await store.retryServerExtraction(id: detail.id) } }
                    if detail.photoLocation == "server" && store.sync.capabilities.archivesPhotos {
                        Button("Give up and archive the photo…") { confirmGiveUp = true }
                    }
                }
            }
        }
        .font(AppTheme.body(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.penRedBg.opacity(processing.isActive ? 0.5 : 1))
        .foregroundColor(processing.isActive ? AppTheme.ink : AppTheme.penRed)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(processing.isActive ? AppTheme.rule : AppTheme.penRed))
        .confirmationDialog("Give up on this receipt?", isPresented: $confirmGiveUp) {
            Button("Archive the photo here and release the server's copy", role: .destructive) {
                Task { await store.giveUpAndArchive(id: detail.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photo is saved on this Mac and then deleted from the server. The receipt stays as you filled it in; the server can no longer re-read the photo.")
        }
    }
}

/// Settings > Cloud sync: switch, server URL, token (Keychain), connection test, status.
struct CloudSyncSettingsView: View {
    @EnvironmentObject var store: ReceiptStore
    @ObservedObject var sync: SyncCoordinator

    @AppStorage(SyncSettings.Keys.enabled) private var enabled = false
    @AppStorage(SyncSettings.Keys.serverURL) private var serverURL = ""
    /// SecureField contents; only written to the Keychain on Save, never to UserDefaults.
    @State private var tokenInput = ""
    @State private var hasToken = KeychainStore.contains(.receiptsAPIToken)
    @State private var testing = false
    @State private var testResult: SyncCoordinator.ConnectionTest?

    var body: some View {
        Form {
            Section("Cloud sync") {
                Toggle("Sync receipts with my server", isOn: $enabled)
                Text(enabled
                     ? "New photos are straightened on this Mac and read by the server; receipts, items and your corrections sync both ways. This Mac keeps the permanent photo archive."
                     : "Off: everything stays on this Mac and photos are read by the AI backend chosen under AI Backend.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Server URL", text: $serverURL, prompt: Text("https://receipts.example.com"))
                    .disableAutocorrection(true)
                HStack {
                    SecureField("Receipts token", text: $tokenInput, prompt: Text(hasToken ? "Saved in Keychain" : "Not set"))
                    Button("Save") {
                        if KeychainStore.save(tokenInput, for: .receiptsAPIToken) {
                            hasToken = KeychainStore.contains(.receiptsAPIToken)
                            tokenInput = ""
                            store.syncSettingsChanged()
                        }
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Clear") {
                        KeychainStore.delete(.receiptsAPIToken)
                        hasToken = false
                        store.syncSettingsChanged()
                    }
                    .disabled(!hasToken)
                }
                HStack {
                    Button(testing ? "Testing…" : "Test connection") {
                        testing = true
                        Task {
                            testResult = await sync.testConnection(serverURL: serverURL, token: KeychainStore.read(.receiptsAPIToken))
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle" : "xmark.octagon")
                            .font(.caption)
                            .foregroundStyle(testResult.ok ? Color.secondary : Color.red)
                            .textSelection(.enabled)
                    }
                }
            }
            if enabled {
                Section("Status") {
                    LabeledContent("Last sync") {
                        Text(sync.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    }
                    if sync.unsentChanges > 0 {
                        LabeledContent("Not sent yet") { Text("\(sync.unsentChanges) change(s)") }
                    }
                    if sync.rejectedRecords > 0 {
                        LabeledContent("Refused by the server") { Text("\(sync.rejectedRecords) record(s)") }
                        Text("Edit such a record again to send it again.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = sync.lastError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Button(sync.phase == .syncing ? "Syncing…" : "Sync now") { store.syncNow() }
                        .disabled(sync.phase == .syncing)
                    Text("Syncs at launch, shortly after edits, every 15 minutes, and here. Failed attempts retry on their own. The Mac also reminds you when it has not synced for \(SyncReminder.days) days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: enabled) { store.syncSettingsChanged() }
        .onChange(of: serverURL) { store.syncSettingsChanged() }
    }
}

import LabCore
import SwiftUI

struct SettingsTab: View {
    @Bindable var model: GlassModel

    private var hasURL: Bool { !model.serverURL.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
              Form {
                serverSection
                testSection
                if model.connected { syncSection }
                photosSection
                Section("About") {
                    Text("Item categories (the dictionary) are edited on the Mac; changes sync here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .textCase(nil)
              }
              .task {
                if model.pendingClearCache {
                    try? await Task.sleep(for: .seconds(0.2))
                    proxy.scrollTo("clearCache", anchor: .center)
                    try? await Task.sleep(for: .seconds(0.5))
                    model.pendingClearCache = false
                    model.dialogClearCache = true
                }
              }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
    }

    private var serverSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Server URL")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField(text: $model.serverURL, prompt: Text(verbatim: "https://receipts.example.com")) { Text("Server URL") }
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Receipts token")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SecureField(model.connected ? "Saved in Keychain" : "Paste the token", text: $model.token)
            }
            if hasURL && !model.urlIsValid {
                Text(LabData.invalidURLMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button("Save") { model.saveSettings() }
                .disabled(!model.urlIsValid)
            if model.connected {
                Button("Remove token and disconnect", role: .destructive) { model.disconnect() }
            }
        } header: {
            Text("Server").textCase(nil)
        } footer: {
            Text("Your own receipts backend. Photos are sent there and read by it; this phone has no AI of its own. The token is stored in the iOS Keychain.")
        }
    }

    private var testSection: some View {
        Section {
            Button(model.testing ? "Testing…" : "Test connection") {
                Task { await model.testConnection() }
            }
            .disabled(!model.urlIsValid || model.testing)
            switch model.testResult {
            case .ok(let message):
                Label {
                    Text(message).font(.subheadline)
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        }
    }

    private var syncSection: some View {
        Section {
            LabeledContent("Last sync", value: LabData.lastSync)
            LabeledContent("Not sent yet", value: "\(LabData.unsentChanges) change(s)")
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Refused by the server", value: "\(LabData.rejectedRecords) record(s)")
                Text("Edit such a record again to send it again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(LabData.syncError)
                .font(.subheadline)
                .foregroundStyle(.red)
            Button(model.settingsSyncing ? "Syncing…" : "Sync now") {
                Task { await model.syncNow() }
            }
            .disabled(model.settingsSyncing)
        } header: {
            Text("Sync").textCase(nil)
        } footer: {
            Text("Syncs when the app opens, shortly after edits, and when you pull the list down.")
        }
    }

    private var photosSection: some View {
        Section {
            LabeledContent("Cached photos", value: model.cachedPhotos)
            Button("Clear cached photos", role: .destructive) { model.dialogClearCache = true }
                .id("clearCache")
                .confirmationDialog("Clear cached photos?", isPresented: $model.dialogClearCache, titleVisibility: .visible) {
                    Button("Clear cached photos", role: .destructive) { model.cachedPhotos = "0 MB" }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Receipts keep their data. A photo the server still holds is downloaded again when you open it; one that is only on your laptop shows “This photo is on your laptop”.")
                }
        } header: {
            Text("Photos").textCase(nil)
        } footer: {
            Text("This phone keeps up to \(LabData.photoCacheLimit) of receipt photos, oldest dropped first. The permanent photo archive is on your laptop: this phone never archives photos or releases the server's copy.")
        }
    }
}

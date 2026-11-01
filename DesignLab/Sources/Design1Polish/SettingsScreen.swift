import LabCore
import SwiftUI

struct SettingsScreen: View {
    @Bindable var store: PolishStore

    private var canSave: Bool { !store.serverURL.isEmpty && !store.urlIsInvalid && (store.hasToken || !store.token.isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                testSection
                if store.hasToken { syncSection }
                photosSection
                Section {
                    Text("Item categories (the dictionary) are edited on the Mac; changes sync here.")
                        .font(P.body(14))
                        .foregroundStyle(P.inkSoft)
                } header: {
                    header("About")
                }
                .listRowBackground(P.paper)
            }
            .scrollContentBackground(.hidden)
            .background(P.desk)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(P.paper, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings").font(P.display(20)).foregroundStyle(P.ink)
                }
            }
            .confirmationDialog("Clear cached photos?", isPresented: $store.clearCacheDialog, titleVisibility: .visible) {
                Button("Clear cached photos", role: .destructive) { store.cachedPhotos = "0 MB" }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Receipts keep their data. A photo the server still holds is downloaded again when you open it; one that is only on your laptop shows “This photo is on your laptop”.")
            }
        }
    }

    private func header(_ text: String) -> some View {
        SectionLabel(text: text).textCase(nil)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(P.body(12.5)).foregroundStyle(P.label)
    }

    // MARK: Sections

    private var serverSection: some View {
        Section {
            field("Server URL") {
                TextField("Server URL", text: $store.serverURL, prompt: Text(verbatim: "https://receipts.example.com"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: store.serverURL) { store.testResult = nil }
            }
            field("Receipts token") {
                SecureField("Receipts token", text: $store.token, prompt: Text(store.hasToken ? "Saved in Keychain" : "Paste the token"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if store.urlIsInvalid {
                Text(LabData.invalidURLMessage)
                    .font(P.body(13))
                    .foregroundStyle(P.red)
            }
            Button { save() } label: {
                Label("Save", systemImage: "square.and.arrow.down").fontWeight(.medium)
            }
                .disabled(!canSave)
            .opacity(canSave ? 1 : 0.4)
            if store.savedNote {
                NoteBox(systemName: "checkmark.circle", text: "Saved. Syncing…", color: P.greenText, background: P.greenBg)
            }
            if store.hasToken {
                Button(role: .destructive) { disconnect() } label: {
                    Label("Remove token and disconnect", systemImage: "xmark.circle")
                }
                .foregroundStyle(P.red)
            }
        } header: {
            header("Server")
        } footer: {
            footer("Your own receipts backend. Photos are sent there and read by it; this phone has no AI of its own. The token is stored in the iOS Keychain.")
        }
        .listRowBackground(P.paper)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(P.body(12)).foregroundStyle(P.inkSoft)
            content().font(P.mono(14))
        }
        .padding(.vertical, 2)
    }

    private var testSection: some View {
        Section {
            Button {
                test()
            } label: {
                if store.testing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Testing…").fontWeight(.medium)
                    }
                } else {
                    Label("Test connection", systemImage: "network").fontWeight(.medium)
                }
            }
            .disabled(store.testing || !canTest)
            .opacity(canTest ? 1 : 0.4)
            if store.testResult == true {
                NoteBox(systemName: "checkmark.circle", text: LabData.connectionOK, color: P.greenText, background: P.greenBg)
            } else if store.testResult == false {
                NoteBox(systemName: "xmark.octagon", text: LabData.connectionFailed, color: P.red, background: P.redBg)
            }
        }
        .listRowBackground(P.paper)
    }

    private var canTest: Bool { !store.serverURL.isEmpty && !store.urlIsInvalid && (store.hasToken || !store.token.isEmpty) }

    private var syncSection: some View {
        Section {
            value("Last sync", LabData.lastSync)
            count("Not sent yet", "\(LabData.unsentChanges) change(s)", red: false)
            VStack(alignment: .leading, spacing: 4) {
                count("Refused by the server", "\(LabData.rejectedRecords) record(s)", red: true)
                Text("Edit such a record again to send it again.")
                    .font(P.body(12.5))
                    .foregroundStyle(P.inkSoft)
            }
            Text(LabData.syncError)
                .font(P.body(13))
                .foregroundStyle(P.red)
            Button {
                Task {
                    store.settingsSyncing = true
                    await store.syncNow()
                    store.settingsSyncing = false
                }
            } label: {
                if store.settingsSyncing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Syncing…").fontWeight(.medium)
                    }
                } else {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath").fontWeight(.medium)
                }
            }
            .disabled(store.settingsSyncing)
        } header: {
            header("Sync")
        } footer: {
            footer("Syncs when the app opens, shortly after edits, and when you pull the list down.")
        }
        .listRowBackground(P.paper)
    }

    private var photosSection: some View {
        Section {
            value("Cached photos", store.cachedPhotos)
            Button(role: .destructive) { store.clearCacheDialog = true } label: {
                Label("Clear cached photos", systemImage: "trash")
            }
            .foregroundStyle(P.red)
        } header: {
            header("Photos")
        } footer: {
            footer("This phone keeps up to \(LabData.photoCacheLimit) of receipt photos, oldest dropped first. The permanent photo archive is on your laptop: this phone never archives photos or releases the server's copy.")
        }
        .listRowBackground(P.paper)
    }

    private func value(_ title: String, _ text: String) -> some View {
        HStack {
            Text(title).font(P.body(15)).foregroundStyle(P.ink)
            Spacer()
            Text(text).font(P.mono(13)).foregroundStyle(P.inkSoft)
        }
    }

    private func count(_ title: String, _ text: String, red: Bool) -> some View {
        HStack {
            Text(title).font(P.body(15)).foregroundStyle(P.ink)
            Spacer()
            Text(text)
                .font(P.mono(12, .medium))
                .foregroundStyle(red ? P.red : P.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(red ? P.redBg : P.desk, in: Capsule())
        }
    }

    // MARK: Actions

    private func save() {
        store.hasToken = true
        store.connected = true
        store.token = ""
        store.testResult = nil
        store.savedNote = true
        Task {
            await store.syncNow()
            store.savedNote = false
        }
    }

    private func disconnect() {
        store.hasToken = false
        store.connected = false
        store.token = ""
        store.testResult = nil
    }

    private func test() {
        store.testing = true
        store.testResult = nil
        Task {
            try? await Task.sleep(for: .seconds(1))
            store.testing = false
            store.testResult = true
        }
    }
}

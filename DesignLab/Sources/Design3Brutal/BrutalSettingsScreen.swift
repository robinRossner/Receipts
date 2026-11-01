import LabCore
import SwiftUI

struct BrutalSettingsScreen: View {
    @Bindable var model: BrutalModel
    @State private var testing = false
    @State private var saving = false

    private var isUnconfigured: Bool { !model.connected }

    var body: some View {
        VStack(spacing: 0) {
            HeroSlab {
                TitleBlock(text: "Settings", tab: .settings)
                    .frame(minHeight: 44)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    server
                    test
                    if !isUnconfigured { sync }
                    photos
                    about
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(BP.page)
    }

    // MARK: Sections

    private var server: some View {
        section("Server", fill: BP.blue, footer: "Your own receipts backend. Photos are sent there and read by it; this phone has no AI of its own. The token is stored in the iOS Keychain.") {
            labelled("Server URL") {
                BrutalField(prompt: "https://receipts.example.com", text: $model.serverURL, keyboard: .URL, autocap: false)
            }
            labelled("Receipts token") {
                BrutalField(prompt: isUnconfigured ? "Paste the token" : "Saved in Keychain", text: $model.token, secure: true, autocap: false)
            }
            if model.urlIsInvalid {
                Text(LabData.invalidURLMessage)
                    .font(BF.body(13, .semibold))
                    .foregroundStyle(BP.redText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Save") { save() }
                .buttonStyle(.slabPrimary(BP.accent(.settings)))
                .disabled(model.urlIsEmpty || model.urlIsInvalid)
            if !isUnconfigured {
                Button("Remove token and disconnect") {
                    model.connected = false
                    model.serverURL = ""
                    model.token = ""
                    model.testResult = nil
                }
                .buttonStyle(.slabDangerQuiet)
            }
        }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(testing ? "Testing…" : "Test connection") { runTest() }
                .buttonStyle(.slabPlain)
                .disabled(testing || model.urlIsEmpty || model.urlIsInvalid)
            switch model.testResult {
            case .ok(let text):
                result(icon: "checkmark.circle", text: text, fill: BP.green, ink: BP.onAccent)
            case .failed(let text):
                result(icon: "xmark.octagon", text: text, fill: BP.card, ink: BP.redText)
            case nil:
                EmptyView()
            }
        }
    }

    private func result(icon: String, text: String, fill: Color, ink: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
            Text(text)
                .font(BF.body(14, .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .slab(fill, border: BT.borderThin)
    }

    private var sync: some View {
        section("Sync", fill: BP.accent(.settings), footer: "Syncs when the app opens, shortly after edits, and when you pull the list down.") {
            value("Last sync", model.lastSync ?? "Never")
            value("Not sent yet", "\(model.unsent) change(s)")
            value("Refused by the server", "\(model.rejected) record(s)")
            if model.rejected > 0 {
                Text("Edit such a record again to send it again.")
                    .font(BF.body(13))
                    .foregroundStyle(BP.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.syncError {
                Text(error)
                    .font(BF.body(13, .semibold))
                    .foregroundStyle(BP.redText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(model.syncing ? "Syncing…" : "Sync now") { model.runSync() }
                .buttonStyle(.slabPlain)
                .disabled(model.syncing)
        }
    }

    private var photos: some View {
        section("Photos", fill: BP.accent(.settings), footer: "This phone keeps up to \(LabData.photoCacheLimit) of receipt photos, oldest dropped first. The permanent photo archive is on your laptop: this phone never archives photos or releases the server's copy.") {
            value("Cached photos", model.cachedPhotos)
            Button("Clear cached photos") { model.dialog = .clearCache }
                .buttonStyle(.slabDangerQuiet)
        }
    }

    private var about: some View {
        section("About", fill: BP.accent(.settings), footer: nil) {
            Text("Item categories (the dictionary) are edited on the Mac; changes sync here.")
                .font(BF.body(14))
                .foregroundStyle(BP.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Parts

    private func section<Content: View>(_ title: String, fill: Color, footer: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(.horizontal, 14)
                .padding(.top, 22)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .slab()
                .overlay(alignment: .topLeading) {
                    TagLabel(text: title, fill: fill)
                        .offset(x: 10, y: -12)
                }
            if let footer {
                Text(footer)
                    .font(BF.body(13))
                    .foregroundStyle(BP.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(BF.body(13, .semibold))
                .foregroundStyle(BP.text)
            content()
        }
    }

    private func value(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(BF.body(14, .medium))
                .foregroundStyle(BP.text)
            Spacer(minLength: 10)
            Text(value)
                .font(BF.mono(13))
                .foregroundStyle(BP.text)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Actions

    private func save() {
        KeyboardWatcher.dismiss()
        model.connected = true
        model.setupNeeded = false
        if model.receipts.isEmpty { model.receipts = LabData.receipts }
        model.testResult = .ok("Saved. Syncing…")
        model.runSync()
    }

    private func runTest() {
        KeyboardWatcher.dismiss()
        testing = true
        model.testResult = nil
        Task {
            try? await Task.sleep(for: .seconds(1))
            testing = false
            model.testResult = .ok(LabData.connectionOK)
        }
    }
}

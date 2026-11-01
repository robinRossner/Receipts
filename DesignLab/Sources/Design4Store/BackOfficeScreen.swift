import LabCore
import SwiftUI

// MARK: The back office: the Settings tab

struct BackOfficeScreen: View {
    @Bindable var model: StoreModel
    @State private var testing = false
    @State private var syncingNow = false
    @State private var saved = false

    private var saveDisabled: Bool { model.urlIsEmpty || model.urlIsInvalid }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    clipboard
                    timeCard
                    stockShelf
                    aboutNote
                }
                .padding(.horizontal, ST.gutter)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(SP.wall.ignoresSafeArea())
    }

    // MARK: Door

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(SF.form(30, bold: true))
                    .foregroundStyle(SP.formText)
                    .accessibilityAddTraits(.isHeader)
                Text("STAFF ONLY")
                    .font(SF.form(12))
                    .tracking(1.5)
                    .foregroundStyle(SP.formText2)
                    .accessibilityHidden(true)
            }
            Spacer()
            DoorSign(open: model.connected && !model.urlIsEmpty)
                .scaleEffect(0.85, anchor: .topTrailing)
                .frame(height: 50, alignment: .top)
        }
        .padding(.horizontal, ST.gutter)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { SP.formLine.frame(height: 1) }
    }

    // MARK: Server: a clipboard

    private var clipboard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Server")
                labelledField("Server URL", text: $model.serverURL, prompt: "https://receipts.example.com")
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Receipts token").font(SF.form(13)).foregroundStyle(SP.formText2)
                    SecureField("", text: $model.token, prompt: Text(model.connected ? "Saved in Keychain" : "Paste the token").foregroundStyle(SP.formText2))
                        .font(SF.print(14))
                        .foregroundStyle(SP.formText)
                        .tint(SP.formText)
                        .padding(.horizontal, 8)
                        .frame(height: 44)
                        .background(SP.field)
                        .overlay(alignment: .bottom) { SP.formText.frame(height: 1) }
                }
                if model.urlIsInvalid {
                    Text(LabData.invalidURLMessage)
                        .font(SF.form(13))
                        .foregroundStyle(SP.formRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    model.connected = true
                    model.testResult = .ok("Saved. Syncing…")
                } label: { WideLabel(text: "Save") }
                .buttonStyle(.keyTag)
                .disabled(saveDisabled)
                if model.connected && !model.urlIsEmpty {
                    Button {
                        model.connected = false
                        model.serverURL = ""
                        model.token = ""
                        model.testResult = nil
                    } label: { WideLabel(text: "Remove token and disconnect") }
                    .buttonStyle(.keyStop)
                }
                footnote("Your own receipts backend. Photos are sent there and read by it; this phone has no AI of its own. The token is stored in the iOS Keychain.")
                SP.formLine.frame(height: 1)
                fuse
            }
            .padding(14)
            .padding(.top, 14)
            .background(SP.form)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .padding(.top, 14)
            .background(SP.clipboard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .top) { MetalClip() }
        }
    }

    /// The test button with its lamp, like a fuse with a telltale.
    private var fuse: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(lampColor)
                    .frame(width: 14, height: 14)
                    .glow(lampColor, radius: lampLit ? 5 : 0)
                    .overlay(Circle().strokeBorder(SP.formLine, lineWidth: 1))
                    .accessibilityHidden(true)
                Button {
                    testing = true
                    model.testResult = nil
                    Task {
                        try? await Task.sleep(for: .seconds(0.8))
                        testing = false
                        model.testResult = .ok(LabData.connectionOK)
                    }
                } label: { WideLabel(text: testing ? "Testing…" : "Test connection") }
                .buttonStyle(.key)
                .disabled(testing || saveDisabled)
            }
            switch model.testResult {
            case .ok(let text): result("checkmark.circle", text, SP.formGreen)
            case .failed(let text): result("xmark.octagon", text, SP.formRed)
            case nil: EmptyView()
            }
        }
    }

    private var lampLit: Bool { model.testResult != nil }
    private var lampColor: Color {
        switch model.testResult {
        case .ok: return SP.formGreen
        case .failed: return SP.formRed
        case nil: return SP.formLine
        }
    }

    private func result(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(text).font(SF.form(14)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }

    // MARK: Sync: a time card

    @ViewBuilder private var timeCard: some View {
        if model.connected && !model.urlIsEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Sync")
                    .padding(.bottom, 6)
                punch("Last sync", model.lastSync ?? "Never")
                punch("Not sent yet", "\(model.unsent) change(s)")
                punch("Refused by the server", "\(model.rejected) record(s)")
                Text("Edit such a record again to send it again.")
                    .font(SF.form(13))
                    .foregroundStyle(SP.formText2)
                    .padding(.top, 6)
                if let error = model.syncError {
                    Text(error)
                        .font(SF.form(14, bold: true))
                        .foregroundStyle(SP.formRed)
                        .padding(.top, 6)
                }
                Button {
                    syncingNow = true
                    model.runSync()
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        syncingNow = false
                    }
                } label: { WideLabel(text: syncingNow ? "Syncing…" : "Sync now") }
                .buttonStyle(.key)
                .disabled(syncingNow)
                .padding(.top, 10)
                footnote("Syncs when the app opens, shortly after edits, and when you pull the list down.")
                    .padding(.top, 8)
            }
            .padding(14)
            .background(SP.timeCard)
            .overlay(alignment: .topTrailing) {
                // The clipped corner of a punch card
                Canvas { context, size in
                    var p = Path()
                    p.move(to: CGPoint(x: size.width, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                    context.fill(p, with: .color(SP.wall))
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            }
        }
    }

    private func punch(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(SF.form(14)).foregroundStyle(SP.formText)
            Spacer(minLength: 6)
            Text(value).font(SF.print(13, bold: true)).foregroundStyle(SP.formText)
        }
        .frame(minHeight: 34)
        .overlay(alignment: .bottom) { SP.timeCardLine.frame(height: 1) }
    }

    // MARK: Photos: stock on a shelf

    private var stockShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Photos")
            HStack(alignment: .firstTextBaseline) {
                Text("Cached photos").font(SF.form(14)).foregroundStyle(SP.formText)
                Spacer()
                Text(model.cachedPhotos).font(SF.print(13, bold: true)).foregroundStyle(SP.formText)
            }
            gauge
            Button { model.dialog = .clearCache } label: { WideLabel(text: "Clear cached photos") }
                .buttonStyle(.keyStop)
            footnote("This phone keeps up to 300 MB of receipt photos, oldest dropped first. The permanent photo archive is on your laptop: this phone never archives photos or releases the server's copy.")
        }
        .padding(14)
        .background(SP.form)
        .overlay(Rectangle().strokeBorder(SP.formLine, lineWidth: 1))
    }

    /// How full the stock shelf is: boxes out of 300 MB.
    private var gauge: some View {
        let used = (Double(model.cachedPhotos.split(separator: " ").first ?? "0") ?? 0) / 300
        let total = 20
        let filled = Int((used * Double(total)).rounded(.up))
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(0..<total, id: \.self) { i in
                    Rectangle()
                        .fill(i < filled ? SP.tag : SP.field)
                        .frame(height: 16)
                }
            }
            SP.rail.frame(height: 3)
        }
        .accessibilityLabel("\(Int(used * 100)) percent of \(LabData.photoCacheLimit)")
    }

    // MARK: About: a pinned note

    private var aboutNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("About")
            Text("Item categories (the dictionary) are edited on the Mac; changes sync here.")
                .font(SF.note(15))
                .foregroundStyle(SP.tagInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.colorScheme, .light)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SP.note)
        .overlay(alignment: .top) {
            Circle().fill(SP.closedSign).frame(width: 12, height: 12).offset(y: -4).accessibilityHidden(true)
        }
        .rotationEffect(.degrees(0.6))
        .shadow(color: SP.shadow.opacity(0.2), radius: 2, y: 1)
    }

    // MARK: Parts

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(SF.form(18, bold: true))
            .foregroundStyle(SP.formText)
            .accessibilityAddTraits(.isHeader)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(SF.form(13))
            .foregroundStyle(SP.formText2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labelledField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(SF.form(13)).foregroundStyle(SP.formText2)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(SP.formText2))
                .font(SF.print(14))
                .foregroundStyle(SP.formText)
                .tint(SP.formText)
                .padding(.horizontal, 8)
                .frame(height: 44)
                .background(SP.field)
                .overlay(alignment: .bottom) { SP.formText.frame(height: 1) }
        }
    }
}

/// The metal clip of the clipboard.
private struct MetalClip: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3).fill(SP.clip).frame(width: 34, height: 8).padding(.bottom, -2)
            RoundedRectangle(cornerRadius: 4)
                .fill(SP.clip)
                .frame(width: 112, height: 22)
                .overlay(Circle().fill(SP.clipboard).frame(width: 8, height: 8))
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

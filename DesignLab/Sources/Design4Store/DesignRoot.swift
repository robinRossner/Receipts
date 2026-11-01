import LabCore
import SwiftUI

public struct DesignRoot: View {
    @State private var model: StoreModel

    public init(initialScreen: LabScreen?) {
        _model = State(initialValue: StoreModel(initial: initialScreen ?? .list))
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                AnnouncementBanners(model: model)
                ZStack {
                    tabs
                    if model.route != nil {
                        ReceiptScreen(model: model)
                            .id(model.route?.receiptID)
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }
                }
            }
            .background(SP.counter.ignoresSafeArea())

            if let dialog = model.dialog {
                TillNotice(model: model, dialog: dialog)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.route?.receiptID)
        .animation(.easeOut(duration: 0.12), value: model.dialog)
        .tint(SP.ink)
        .labReportsScreen(model.screen)
    }

    private var tabs: some View {
        VStack(spacing: 0) {
            Group {
                switch model.tab {
                case .receipts: CheckoutScreen(model: model)
                case .overview: AisleScreen(model: model)
                case .settings: BackOfficeScreen(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StoreTabBar(selection: $model.tab)
        }
    }
}

// MARK: Tab bar

/// One flat surface with a single top rule. The selected label sits on a small yellow shelf tag.
struct StoreTabBar: View {
    @Binding var selection: LabScreen.Tab

    private let items: [(LabScreen.Tab, String, String)] = [
        (.receipts, "Receipts", "list.bullet.rectangle.portrait"),
        (.overview, "Overview", "chart.bar.xaxis"),
        (.settings, "Settings", "gearshape"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SP.barRule.frame(height: 1)
            HStack(spacing: 0) {
                ForEach(items, id: \.0) { item in tab(item) }
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)
        }
        .background(SP.bar.ignoresSafeArea(edges: .bottom))
    }

    private func tab(_ item: (LabScreen.Tab, String, String)) -> some View {
        let selected = selection == item.0
        return Button {
            KeyboardWatcher.dismiss()
            selection = item.0
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.2)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 22)
                Text(item.1)
                    .font(SF.shelf(12))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(selected ? SP.tag : Color.clear)
                    .foregroundStyle(selected ? SP.tagInk : SP.barText)
            }
            .foregroundStyle(selected ? SP.barTextOn : SP.barText)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Store announcements (banners)

struct AnnouncementBanners: View {
    let model: StoreModel

    var body: some View {
        if !model.syncBanners.isEmpty || model.errorBanner != nil {
            VStack(spacing: 0) {
                ForEach(model.syncBanners, id: \.self) { text in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(SP.listRed)
                        Text(text)
                            .font(SF.print(12, bold: true))
                            .foregroundStyle(SP.listRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Sync now") { model.syncBanners.removeAll() }
                            .buttonStyle(FlatKeyStyle(face: SP.tag, ink: SP.tagInk))
                            .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SP.listPaper, ignoresSafeAreaEdges: [])
                    .overlay(alignment: .bottom) { SP.listRule.frame(height: 1) }
                }
                if let error = model.errorBanner {
                    HStack(spacing: 8) {
                        Text("⚠ \(error)")
                            .font(SF.shelf(15))
                            .foregroundStyle(SP.alarmText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            model.errorBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(SP.alarmText)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 4)
                    .background(SP.alarm)
                }
            }
            .background(alignment: .top) {
                (model.syncBanners.isEmpty ? SP.alarm : SP.till).ignoresSafeArea(edges: .top)
            }
        }
    }
}

// MARK: Till notices (every alert and confirmation)

struct TillNotice: View {
    let model: StoreModel
    let dialog: StoreDialog
    @State private var fed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Spec {
        var title: String
        var message: String
        var confirm: String
        var destructive = false
        var cancel = true
    }

    private var spec: Spec {
        switch dialog {
        case .confirmAll(let n):
            return Spec(title: "Confirm \(n) receipts without flags?",
                        message: "Marks every unreviewed receipt that has no review reasons as reviewed. Receipts with warnings stay in “Needs review”.",
                        confirm: "Confirm all")
        case .permanentDelete:
            return Spec(title: "Permanently delete this receipt?",
                        message: "This removes the receipt, its items and the photo copy on this phone. It cannot be undone.",
                        confirm: "Delete permanently", destructive: true)
        case .scanUnavailable:
            return Spec(title: "Document camera not available",
                        message: "This device cannot scan documents. Use “Choose photos” instead.", confirm: "OK", cancel: false)
        case .scanNote:
            return Spec(title: "Scan",
                        message: "Only the first of 3 pages was added. A receipt is one photo; scan the other pages as separate receipts.",
                        confirm: "OK", cancel: false)
        case .delete:
            return Spec(title: "Delete this receipt?",
                        message: "It moves to \"Recently deleted\" and can be restored from there.",
                        confirm: "Delete", destructive: true)
        case .rerun:
            return Spec(title: "Re-run extraction?",
                        message: "The server reads the photo again and marks the receipt as not yet reviewed. If you already edited or confirmed this receipt, the server keeps your version.",
                        confirm: "Re-run extraction", destructive: true)
        case .clearCache:
            return Spec(title: "Clear cached photos?",
                        message: "Receipts keep their data. A photo the server still holds is downloaded again when you open it; one that is only on your laptop shows “This photo is on your laptop”.",
                        confirm: "Clear cached photos", destructive: true)
        }
    }

    var body: some View {
        let spec = spec
        ZStack {
            SP.scrim.opacity(0.55).ignoresSafeArea().accessibilityHidden(true)
            VStack(spacing: 0) {
                // The till's slot the notice is printed from
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SP.till)
                    SP.slot.frame(height: 4).clipShape(Capsule()).padding(.horizontal, 12)
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 4)
                }
                .frame(height: 20)
                .zIndex(1)

                paper(spec)
                    .padding(.horizontal, 10)
                    .offset(y: fed || reduceMotion ? 0 : -30)
                    .opacity(fed || reduceMotion ? 1 : 0)
            }
            .padding(.horizontal, 24)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.16)) { fed = true } }
    }

    private func paper(_ spec: Spec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(spec.title)
                .font(SF.print(17, bold: true))
                .foregroundStyle(SP.ink)
                .fixedSize(horizontal: false, vertical: true)
            DottedRule()
            Text(spec.message)
                .font(SF.print(14))
                .foregroundStyle(SP.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Button { model.confirmDialog() } label: { WideLabel(text: spec.confirm) }
                    .buttonStyle(spec.destructive ? KeycapStyle.keyStop : (spec.cancel ? KeycapStyle.keyGo : KeycapStyle.keyTag))
                if spec.cancel {
                    Button { model.dialog = nil } label: { WideLabel(text: "Cancel") }
                        .buttonStyle(KeycapStyle(face: SP.paperShade, lip: SP.rule, ink: SP.ink))
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .slip(shadow: 8)
    }
}

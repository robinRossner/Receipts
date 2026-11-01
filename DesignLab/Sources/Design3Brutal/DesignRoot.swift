import LabCore
import SwiftUI

public struct DesignRoot: View {
    @State private var model: BrutalModel

    public init(initialScreen: LabScreen?) {
        _model = State(initialValue: BrutalModel(initial: initialScreen ?? .list))
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                BrutalBanners(model: model)
                ZStack {
                    tabs
                    if model.route != nil {
                        BrutalDetailScreen(model: model)
                            .id(model.route?.receiptID)
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }
                }
            }
            .background(BP.page.ignoresSafeArea())

            if let dialog = model.dialog {
                BrutalDialogView(model: model, dialog: dialog)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.route?.receiptID)
        .animation(.easeOut(duration: 0.1), value: model.dialog)
        .tint(BP.text)
        .labReportsScreen(model.screen)
    }

    private var tabs: some View {
        VStack(spacing: 0) {
            Group {
                switch model.tab {
                case .receipts: BrutalListScreen(model: model)
                case .overview: BrutalOverviewScreen(model: model)
                case .settings: BrutalSettingsScreen(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            BrutalTabBar(selection: $model.tab)
        }
    }
}

// MARK: Tab bar

struct BrutalTabBar: View {
    @Binding var selection: LabScreen.Tab

    private let items: [(LabScreen.Tab, String, String)] = [
        (.receipts, "Receipts", "list.bullet.rectangle.portrait"),
        (.overview, "Overview", "chart.bar.xaxis"),
        (.settings, "Settings", "gearshape"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            BP.line.frame(height: BT.barRule)
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { item in
                    let selected = selection == item.0
                    Button {
                        KeyboardWatcher.dismiss()
                        selection = item.0
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: selected ? item.2 + ".fill" : item.2)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(height: 22)
                            Text(item.1)
                                .font(selected ? BF.label(11) : BF.body(11, .medium))
                        }
                        .foregroundStyle(selected ? BP.onAccent : BP.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(selected ? BP.accent(item.0) : Color.clear)
                        .overlay {
                            if selected { Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(BP.heroBg.ignoresSafeArea(edges: .bottom))
    }
}

// MARK: Banners

struct BrutalBanners: View {
    let model: BrutalModel

    var body: some View {
        if !model.syncBanners.isEmpty || model.errorBanner != nil {
            VStack(spacing: 0) {
                ForEach(model.syncBanners, id: \.self) { text in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(BP.redText)
                        Text(text)
                            .font(BF.body(13, .semibold))
                            .foregroundStyle(BP.redText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Sync now") { model.syncBanners.removeAll() }
                            .buttonStyle(.slabSmall(BP.yellow, ink: BP.onAccent))
                            .fixedSize()
                    }
                    .padding(12)
                    .background(BP.card)
                    .overlay(alignment: .bottom) { BP.line.frame(height: BT.rule) }
                }
                if let error = model.errorBanner {
                    HStack(spacing: 10) {
                        Text("⚠ \(error)")
                            .font(BF.body(14, .semibold))
                            .foregroundStyle(BP.onRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            model.errorBanner = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(BP.onRed)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    .padding(.leading, 14)
                    .padding(.vertical, 4)
                    .padding(.trailing, 4)
                    .background(BP.redFill)
                    .overlay(alignment: .bottom) { BP.line.frame(height: BT.rule) }
                }
            }
            .background(alignment: .top) {
                (model.errorBanner != nil && model.syncBanners.isEmpty ? BP.redFill : BP.card)
                    .ignoresSafeArea(edges: .top)
            }
        }
    }
}

// MARK: Dialogs

/// Replaces every system alert and confirmation dialog.
struct BrutalDialogView: View {
    let model: BrutalModel
    let dialog: BrutalDialog

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
            BP.scrim.opacity(BT.scrim).ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                Text(spec.title)
                    .font(BF.display(18))
                    .foregroundStyle(BP.onAccent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(spec.destructive ? BP.pink : BP.yellow)
                    .overlay(alignment: .bottom) { BP.line.frame(height: BT.rule) }
                VStack(spacing: 14) {
                    Text(spec.message)
                        .font(BF.body(15))
                        .foregroundStyle(BP.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(spec.confirm) { model.confirmDialog() }
                        .buttonStyle(spec.destructive ? SlabButtonStyle.slabDanger : SlabButtonStyle.slabPrimary)
                    if spec.cancel {
                        Button("Cancel") { model.dialog = nil }
                            .buttonStyle(.slabPlain)
                    }
                }
                .padding(14)
                .padding(.bottom, 4)
            }
            .slab(BP.card, border: BT.borderDialog, shadow: BT.shadowDialog)
            .padding(.horizontal, 28)
            .accessibilityAddTraits(.isModal)
        }
    }
}

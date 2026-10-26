import SwiftUI

/// Ports the sidebar's receipt list from dashboard.html: split into "Needs review" and
/// "Reviewed" sections, each sorted by date descending.
struct ReceiptListView: View {
    @EnvironmentObject var store: ReceiptStore
    @State private var showDeleted = false
    @State private var pendingPermanentDelete: ReceiptSummary?

    private var unreviewed: [ReceiptSummary] {
        store.receipts.filter { $0.reviewedAt == nil }.sorted { ($0.date ?? "") > ($1.date ?? "") }
    }
    private var reviewed: [ReceiptSummary] {
        store.receipts.filter { $0.reviewedAt != nil }.sorted { ($0.date ?? "") > ($1.date ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RECENT")
                    .font(AppTheme.body(11, weight: .medium))
                    .foregroundColor(AppTheme.inkSoft)
                Spacer()
                if !unreviewed.isEmpty {
                    Text("\(unreviewed.count) to review")
                        .font(AppTheme.body(11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(AppTheme.penRed)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }

            if store.receipts.isEmpty {
                Text("No receipts yet.")
                    .font(AppTheme.body(13))
                    .foregroundColor(AppTheme.inkSoft)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    section("Needs review", unreviewed)
                    section("Reviewed", reviewed)
                    recentlyDeleted
                }
            }
        }
        .confirmationDialog(
            "Permanently delete this receipt?",
            isPresented: Binding(get: { pendingPermanentDelete != nil }, set: { if !$0 { pendingPermanentDelete = nil } }),
            presenting: pendingPermanentDelete
        ) { receipt in
            Button("Delete permanently", role: .destructive) {
                Task { await store.permanentlyDeleteReceipt(id: receipt.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the receipt, its items and its image file. It cannot be undone.")
        }
    }

    @ViewBuilder
    private var recentlyDeleted: some View {
        if !store.deletedReceipts.isEmpty {
            DisclosureGroup(isExpanded: $showDeleted) {
                ForEach(store.deletedReceipts) { receipt in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(receipt.store ?? "Unknown")
                                .font(AppTheme.body(12, weight: .semibold))
                                .foregroundColor(AppTheme.ink)
                            Text("\(receipt.date ?? "") · \(fmtMoney(receipt.total))")
                                .font(AppTheme.mono(11))
                                .foregroundColor(AppTheme.inkSoft)
                        }
                        Spacer()
                        Button("Restore") { Task { await store.restoreReceipt(id: receipt.id) } }
                        Button("Delete permanently") { pendingPermanentDelete = receipt }
                            .foregroundColor(AppTheme.penRed)
                    }
                    .buttonStyle(.plain)
                    .font(AppTheme.body(11))
                    .padding(8)
                    .background(AppTheme.paper)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
                    .cornerRadius(4)
                }
            } label: {
                Text("RECENTLY DELETED (\(store.deletedReceipts.count))")
                    .font(AppTheme.body(11, weight: .medium))
                    .foregroundColor(AppTheme.inkSoft)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func section(_ label: String, _ items: [ReceiptSummary]) -> some View {
        if !items.isEmpty {
            Text(label.uppercased())
                .font(AppTheme.body(11, weight: .medium))
                .foregroundColor(AppTheme.inkSoft)
                .padding(.top, 4)
            ForEach(items) { receipt in
                ReceiptStubView(receipt: receipt)
            }
        }
    }
}

private struct ReceiptStubView: View {
    @EnvironmentObject var store: ReceiptStore
    let receipt: ReceiptSummary

    private var isUnreviewed: Bool { receipt.reviewedAt == nil }
    private var isSelected: Bool { store.selectedReceipt?.id == receipt.id }

    var body: some View {
        Button {
            Task { await store.loadReceiptDetail(id: receipt.id) }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(receipt.store ?? "Unknown")
                            .font(AppTheme.body(13, weight: .semibold))
                            .foregroundColor(AppTheme.ink)
                        Text(receipt.date ?? "")
                            .font(AppTheme.mono(12))
                            .foregroundColor(AppTheme.inkSoft)
                    }
                    Spacer()
                    Text(fmtMoney(receipt.total))
                        .font(AppTheme.mono(13))
                        .foregroundColor(AppTheme.ink)
                }
                .padding(10)

                if receipt.needsReview {
                    Text("⚠")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.penRed)
                        .padding(6)
                }
            }
            .background(isSelected ? Color(hex: 0xFBF8F1) : AppTheme.paper)
            .overlay(Rectangle().fill(AppTheme.penRed).frame(width: isUnreviewed ? 3 : 0), alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(AppTheme.rule, lineWidth: 1))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

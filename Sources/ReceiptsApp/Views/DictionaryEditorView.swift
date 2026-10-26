import SwiftUI

/// Settings tab for the shared item dictionary: search, rename, recategorize, merge duplicates.
struct DictionaryEditorView: View {
    @EnvironmentObject var store: ReceiptStore
    @State private var rows: [ReceiptStore.DictionaryRow] = []
    @State private var query = ""
    @State private var selection: Int?
    @State private var draft: ReceiptStore.DictionaryRow?
    @State private var mergeSource: ReceiptStore.DictionaryRow?
    @State private var mergeTarget: ReceiptStore.DictionaryRow?
    @State private var showMergePicker = false

    private var filtered: [ReceiptStore.DictionaryRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.displayNameDe.lowercased().contains(q) || $0.canonicalName.contains(q)
                || $0.translationEn.lowercased().contains(q) || $0.pathLabel.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search name, translation or category", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(filtered, selection: $selection) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayNameDe.isEmpty ? row.canonicalName : row.displayNameDe).font(.body)
                        Text(row.pathLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.isManual { Text("manual").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                    Text("\(row.timesSeen)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .tag(row.id)
            }
            .frame(minHeight: 180)
            Divider()
            editor
        }
        .task { await reload() }
        .onChange(of: selection) { draft = rows.first { $0.id == selection } }
        .sheet(isPresented: $showMergePicker) { mergePicker }
        .confirmationDialog(
            "Merge into \"\(mergeTarget?.displayNameDe ?? "")\"?", isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } })
        ) {
            Button("Merge", role: .destructive) {
                if let src = mergeSource, let dst = mergeTarget {
                    Task { await store.mergeDictionaryEntries(sourceId: src.id, targetId: dst.id); selection = nil; await reload() }
                }
                mergeTarget = nil
            }
            Button("Cancel", role: .cancel) { mergeTarget = nil }
        } message: {
            Text("All line items of \"\(mergeSource?.displayNameDe ?? "")\" move to the target, aliases are combined and the source entry is deleted.")
        }
    }

    @ViewBuilder
    private var editor: some View {
        if draft != nil {
            let d = Binding(get: { draft! }, set: { draft = $0 })
            let t = store.taxonomy
            Form {
                TextField("Name (de)", text: d.displayNameDe)
                TextField("Translation (en)", text: d.translationEn)
                Picker("Category", selection: d.category) {
                    ForEach(t.categoryNames(), id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: draft?.category) {
                    guard let c = draft?.category, !t.subcategoryNames(in: c).contains(draft?.subcategory ?? "") else { return }
                    draft?.subcategory = t.subcategoryNames(in: c).first ?? ""
                }
                Picker("Subcategory", selection: d.subcategory) {
                    ForEach(t.subcategoryNames(in: d.wrappedValue.category), id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: draft?.subcategory) {
                    guard let c = draft?.category, let s = draft?.subcategory,
                          !t.itemGroups(category: c, subcategory: s).contains(draft?.itemGroup ?? "") else { return }
                    draft?.itemGroup = t.itemGroups(category: c, subcategory: s).first ?? ""
                }
                Picker("Item group", selection: d.itemGroup) {
                    ForEach(t.itemGroups(category: d.wrappedValue.category, subcategory: d.wrappedValue.subcategory), id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Button("Save") {
                        if let draft { Task { await store.updateDictionaryEntry(draft); await reload() } }
                    }
                    Button("Merge into…") { mergeSource = draft; showMergePicker = true }
                    Spacer()
                    Text("Editing marks the entry as a manual override.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 250)
        } else {
            Text("Select an entry to edit it.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20)
        }
    }

    private var mergePicker: some View {
        MergeTargetPicker(rows: rows.filter { $0.id != mergeSource?.id }) { target in
            showMergePicker = false
            mergeTarget = target
        }
    }

    private func reload() async {
        rows = await store.dictionaryRows()
        draft = rows.first { $0.id == selection }
    }
}

private struct MergeTargetPicker: View {
    let rows: [ReceiptStore.DictionaryRow]
    let onPick: (ReceiptStore.DictionaryRow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [ReceiptStore.DictionaryRow] {
        let q = query.lowercased()
        return Array((q.isEmpty ? rows : rows.filter { $0.displayNameDe.lowercased().contains(q) || $0.canonicalName.contains(q) }).prefix(60))
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("Merge into which entry?").font(.headline)
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            List(matches) { row in
                Button { onPick(row) } label: {
                    VStack(alignment: .leading) {
                        Text(row.displayNameDe.isEmpty ? row.canonicalName : row.displayNameDe)
                        Text(row.pathLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Button("Cancel", role: .cancel) { dismiss() }
        }
        .padding(16)
        .frame(width: 420, height: 420)
    }
}

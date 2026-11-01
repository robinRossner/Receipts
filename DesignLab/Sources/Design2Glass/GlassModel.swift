import Foundation
import LabCore
import Observation

/// All navigation and fake-edit state of the design. `screen` is derived from it for the switcher.
@MainActor @Observable
final class GlassModel {
    // Root
    var tab: LabScreen.Tab = .receipts
    var banners: [String] = []
    var errorBanner: String?

    // Receipts tab
    var connected = true
    var receipts: [LabReceipt] = LabData.receipts
    var deleted: [LabReceipt] = LabData.deletedReceipts
    var uploads: [LabUploadJob] = []
    var deletedOpen = false
    var scrollToDeleted = false
    var search = ""
    var dateFilter = "All time"
    var storeFilter = "All stores"
    var showFilters = false
    var showUploads = false
    var dialogConfirmAll = false
    var pendingConfirmAll = false
    var permanentDelete: LabReceipt?
    var alertScanUnavailable = false
    var alertScanNote = false
    var syncing = false

    // Detail: one at a time, so the state lives here and `path` only drives the push.
    var path: [Int] = [] {
        didSet {
            if oldValue.isEmpty, let id = path.last { configureDetail(id) }
            if path.isEmpty { persistDetail() } else { showUploads = false }
        }
    }
    var detail: DetailState?

    // Overview tab
    var range: LabRange = .month
    var monthOffset = 0
    var yearOffset = 0
    var customFrom = LabFormat.date("2026-09-30") ?? .now
    var customTo = LabFormat.date("2026-10-31") ?? .now
    var openCategories: Set<String> = []
    var openSubcategories: Set<String> = []
    var openGroups: Set<String> = []
    var scrollToDrilldown = false

    // Settings tab
    enum TestResult: Equatable { case ok(String), failed(String) }
    var serverURL = LabData.serverURL
    var token = ""
    var testing = false
    var testResult: TestResult?
    var settingsSyncing = false
    var dialogClearCache = false
    /// Launch state: the dialog waits until its button has been scrolled into view.
    var pendingClearCache = false
    var cachedPhotos = LabData.cachedPhotos

    init(screen: LabScreen) {
        tab = screen.tab
        switch screen {
        case .list, .overview, .settings: break
        case .listProcessing:
            receipts = LabData.processingReceipts + LabData.receipts
            uploads = LabData.uploadQueue
            showUploads = true
        case .listDeletedOpen:
            deletedOpen = true
            scrollToDeleted = true
        case .listEmpty:
            receipts = []
            deleted = []
        case .listNoMatch:
            search = "Zalando"
            dateFilter = "This month"
        case .listSetup, .settingsUnconfigured:
            disconnect()
        case .listFilters: showFilters = true
        case .dialogConfirmAll: dialogConfirmAll = true
        case .dialogPermanentDelete:
            deletedOpen = true
            scrollToDeleted = true
            permanentDelete = deleted.first
        case .alertScanUnavailable: alertScanUnavailable = true
        case .alertScanNote: alertScanNote = true
        case .bannerSync: banners = LabData.banners
        case .bannerError: errorBanner = LabData.errorBanner
        case .overviewYear: range = .year
        case .overviewCustom: range = .custom
        case .overviewAll: range = .all
        case .overviewEmpty: monthOffset = 1
        case .overviewDrilldown:
            let p = LabData.drilldownPath
            openCategories = [p.category]
            openSubcategories = [p.category + "|" + p.subcategory]
            openGroups = [p.category + "|" + p.subcategory + "|" + p.itemGroup]
            scrollToDrilldown = true
        case .settingsInvalidURL: serverURL = "receipts.example.com"
        case .settingsTestOK: testResult = .ok(LabData.connectionOK)
        case .settingsTestFailed: testResult = .failed(LabData.connectionFailed)
        case .dialogClearCache: pendingClearCache = true
        default:
            if screen.isDetail, let receipt = screen.fixtureReceipt {
                let state = DetailState(receipt)
                state.apply(screen)
                path = [receipt.id]
                detail = state
            }
        }
    }

    // MARK: Derived screen

    var screen: LabScreen {
        switch tab {
        case .overview: return overviewScreen
        case .settings: return settingsScreen
        case .receipts:
            if !path.isEmpty, let detail { return detail.screen }
            return listScreen
        }
    }

    private var listScreen: LabScreen {
        if isSetup { return .listSetup }
        if dialogConfirmAll { return .dialogConfirmAll }
        if permanentDelete != nil { return .dialogPermanentDelete }
        if alertScanUnavailable { return .alertScanUnavailable }
        if alertScanNote { return .alertScanNote }
        if showFilters { return .listFilters }
        if !banners.isEmpty { return .bannerSync }
        if errorBanner != nil { return .bannerError }
        if receipts.isEmpty { return .listEmpty }
        if filtered.isEmpty { return .listNoMatch }
        if !uploads.isEmpty || receipts.contains(where: { $0.processing != nil }) { return .listProcessing }
        if deletedOpen { return .listDeletedOpen }
        return .list
    }

    private var overviewScreen: LabScreen {
        if summary.categories.isEmpty { return .overviewEmpty }
        if !openGroups.isEmpty { return .overviewDrilldown }
        switch range {
        case .month: return .overview
        case .year: return .overviewYear
        case .custom: return .overviewCustom
        case .all: return .overviewAll
        }
    }

    private var settingsScreen: LabScreen {
        if dialogClearCache || pendingClearCache { return .dialogClearCache }
        if serverURL.isEmpty { return .settingsUnconfigured }
        if !urlIsValid { return .settingsInvalidURL }
        switch testResult {
        case .ok: return .settingsTestOK
        case .failed: return .settingsTestFailed
        case nil: return .settings
        }
    }

    // MARK: List

    var isSetup: Bool { !connected && receipts.isEmpty }
    var isFiltering: Bool { dateFilter != "All time" || storeFilter != "All stores" }

    var filtered: [LabReceipt] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return receipts.filter { receipt in
            let date = receipt.date ?? ""
            switch dateFilter {
            case "This month": if !date.hasPrefix("2026-10") { return false }
            case "Last 3 months": if date < "2026-08-01" { return false }
            case "This year": if !date.hasPrefix("2026") { return false }
            default: break
            }
            if storeFilter != "All stores", receipt.store != storeFilter { return false }
            if query.isEmpty { return true }
            if receipt.store?.lowercased().contains(query) == true { return true }
            if let total = receipt.total, LabFormat.money(total).contains(query) { return true }
            return receipt.items.contains {
                $0.nameDe?.lowercased().contains(query) == true || $0.translationEn?.lowercased().contains(query) == true
            }
        }
    }

    var confirmableCount: Int {
        receipts.filter { $0.reviewedAt == nil && !$0.needsReview && $0.processing == nil }.count
    }

    func confirmAll() {
        for index in receipts.indices
        where receipts[index].reviewedAt == nil && !receipts[index].needsReview && receipts[index].processing == nil {
            receipts[index].reviewedAt = "2026-10-31T10:00:00Z"
        }
    }

    func moveToDeleted(_ receipt: LabReceipt) {
        receipts.removeAll { $0.id == receipt.id }
        if !deleted.contains(where: { $0.id == receipt.id }) { deleted.insert(receipt, at: 0) }
    }

    func restore(_ receipt: LabReceipt) {
        deleted.removeAll { $0.id == receipt.id }
        receipts.append(receipt)
        receipts.sort { ($0.date ?? "9") > ($1.date ?? "9") }
    }

    func runSync() async {
        syncing = true
        try? await Task.sleep(for: .seconds(1.2))
        syncing = false
    }

    // MARK: Detail

    func open(_ receiptID: Int, highlightItem: Int? = nil) {
        tab = .receipts
        path = [receiptID]
        if let highlightItem, let item = detail?.receipt.items.first(where: { $0.id == highlightItem }) {
            detail?.expanded.insert(item.itemDictionaryId)
            detail?.scrollTarget = "item-\(item.itemDictionaryId)"
        }
    }

    private func find(_ id: Int) -> LabReceipt? {
        receipts.first { $0.id == id } ?? LabData.receipt(id: id)
    }

    private func configureDetail(_ id: Int) {
        if let receipt = find(id) { detail = DetailState(receipt) }
    }

    func persistDetail() {
        guard let receipt = detail?.receipt, let index = receipts.firstIndex(where: { $0.id == receipt.id }) else { return }
        receipts[index] = receipt
    }

    /// `Looks good`: confirm, then the next receipt to review, in place.
    func confirmCurrent() {
        guard let detail else { return }
        detail.receipt.reviewedAt = "2026-10-31T10:00:00Z"
        persistDetail()
        if let next = receipts.first(where: { $0.reviewedAt == nil && $0.processing == nil }) {
            self.detail = DetailState(next)
        } else {
            path = []
        }
    }

    func deleteCurrent() {
        guard let receipt = detail?.receipt else { return }
        moveToDeleted(receipt)
        path = []
    }

    // MARK: Overview

    /// `LabStatsSummary` cannot be built from here, so an empty period is carried by this small wrapper.
    struct Summary {
        var total: Double = 0
        var categories: [LabCategoryStat] = []
        init(_ stats: LabStatsSummary? = nil) {
            total = stats?.total ?? 0
            categories = stats?.categories ?? []
        }
    }

    var summary: Summary {
        switch range {
        case .month:
            if monthOffset == 0 { return Summary(LabData.summary(.month)) }
            if monthOffset == -1 { return Summary(LabData.previousSummary(.month)) }
            return Summary()
        case .year: return yearOffset == 0 ? Summary(LabData.summary(.year)) : Summary()
        case .custom: return Summary(LabData.summary(.custom))
        case .all: return Summary(LabData.summary(.all))
        }
    }

    var previousSummary: LabStatsSummary? {
        switch range {
        case .month: return monthOffset == 0 ? LabData.previousSummary(.month) : nil
        case .year: return yearOffset == 0 ? LabData.previousSummary(.year) : nil
        case .custom, .all: return nil
        }
    }

    var selectedMonth: String {
        let base = LabFormat.date("2026-10-01") ?? .now
        let date = Calendar(identifier: .gregorian).date(byAdding: .month, value: monthOffset, to: base) ?? base
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    var rangeLabel: String {
        switch range {
        case .month:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: LabFormat.date(selectedMonth + "-01") ?? .now)
        case .year: return String(2026 + yearOffset)
        case .custom, .all: return LabData.rangeLabel(range)
        }
    }

    var chartMonths: [LabMonthCategoryTotal] {
        switch range {
        case .month: return LabData.monthly.filter { $0.month <= selectedMonth }
        case .year: return LabData.monthly.filter { $0.month.hasPrefix("2026") }
        case .custom: return LabData.monthly.filter { $0.month >= "2026-09" }
        case .all: return LabData.monthly
        }
    }

    /// Top 8 plus `Other`.
    var storeBars: [StoreBar] {
        var totals = LabData.storeTotals(range).map { StoreBar(store: $0.store, total: $0.total) }
        if range == .month, monthOffset == -1 {
            var byStore: [String: Double] = [:]
            for receipt in LabData.receipts where receipt.date?.hasPrefix(selectedMonth) == true {
                byStore[receipt.store ?? "Unknown", default: 0] += receipt.computedSum ?? 0
            }
            totals = byStore.map { StoreBar(store: $0.key, total: $0.value) }.sorted { $0.total > $1.total }
        }
        guard totals.count > 8 else { return totals }
        let rest = totals.dropFirst(8).reduce(0) { $0 + $1.total }
        return Array(totals.prefix(8)) + [StoreBar(store: "Other", total: rest)]
    }

    // MARK: Settings

    var urlIsValid: Bool {
        guard !serverURL.isEmpty, let url = URL(string: serverURL), let host = url.host, !host.isEmpty else { return false }
        return url.scheme == "https" || (url.scheme == "http" && host == "localhost")
    }

    func disconnect() {
        connected = false
        serverURL = ""
        token = ""
        testResult = nil
        receipts = []
        deleted = []
    }

    func saveSettings() {
        connected = true
        testResult = .ok("Saved. Syncing…")
    }

    func testConnection() async {
        testing = true
        testResult = nil
        try? await Task.sleep(for: .seconds(1))
        testing = false
        testResult = .ok(LabData.connectionOK)
    }

    func syncNow() async {
        settingsSyncing = true
        try? await Task.sleep(for: .seconds(1.2))
        settingsSyncing = false
    }
}

/// One open receipt.
@MainActor @Observable
final class DetailState {
    enum Page: String, CaseIterable, Identifiable { case items = "Items", photo = "Photo"; var id: String { rawValue } }

    var receipt: LabReceipt
    var loading = false
    var page: Page = .items
    var busy = false
    var confirmDelete = false
    var confirmRerun = false
    var date: Date?
    var time: Date?
    var printedTotal: String

    var addOpen: Bool
    var addOpenedByHand = false
    var addName = ""
    var addQty = "1"
    var addPrice = ""
    var addError = false
    var addBusy = false

    /// Dictionary ids of the product rows that are expanded.
    var expanded: Set<Int>
    var drafts: [Int: ItemDraft] = [:]
    var scrollTarget: String?

    init(_ receipt: LabReceipt) {
        self.receipt = receipt
        date = receipt.date.flatMap(LabFormat.date)
        time = receipt.time.flatMap(Self.parseTime)
        printedTotal = receipt.total.map { String(format: "%.2f", $0) } ?? ""
        addOpen = receipt.computedSum != nil && receipt.total != nil && receipt.computedSum != receipt.total
        expanded = Set(receipt.items.filter(\.needsReview).map(\.itemDictionaryId))
    }

    func apply(_ screen: LabScreen) {
        switch screen {
        case .detailLoading: loading = true
        case .detailPhoto, .detailPhotoMissing: page = .photo
        case .detailAddItem:
            addOpen = true
            addOpenedByHand = true
            addError = true
            scrollTarget = "add"
        case .detailItemEdited:
            guard let item = receipt.items.first else { return }
            expanded.insert(item.itemDictionaryId)
            var edited = ItemDraft(item)
            edited.subcategory = "Beverages"
            edited.itemGroup = "Juice"
            edited.category = "Food"
            drafts[item.id] = edited
            scrollTarget = "item-\(item.itemDictionaryId)"
        case .detailBusy: busy = true
        case .dialogDelete: confirmDelete = true
        case .dialogRerun: confirmRerun = true
        default: break
        }
    }

    var screen: LabScreen {
        if loading { return .detailLoading }
        if confirmDelete { return .dialogDelete }
        if confirmRerun { return .dialogRerun }
        if busy { return .detailBusy }
        if page == .photo {
            return receipt.photoLocation == "archived" ? .detailPhotoMissing : .detailPhoto
        }
        if let processing = receipt.processing {
            switch processing {
            case .waitingForUpload: return .detailWaiting
            case .processing: return .detailProcessing
            case .uploadFailed: return .detailUploadFailed
            case .failed: return .detailFailed
            }
        }
        if drafts.values.contains(where: \.pickersChanged) { return .detailItemEdited }
        if addOpen && addOpenedByHand { return .detailAddItem }
        return receipt.reviewedAt != nil ? .detailReviewed : .detail
    }

    func draft(_ item: LabLineItem) -> ItemDraft { drafts[item.id] ?? ItemDraft(item) }

    func save(_ item: LabLineItem) async {
        var draft = draft(item)
        guard let quantity = Self.number(draft.quantity), let price = Self.number(draft.price), quantity > 0 else {
            draft.status = .bad
            drafts[item.id] = draft
            return
        }
        draft.status = .saving
        drafts[item.id] = draft
        try? await Task.sleep(for: .seconds(0.5))
        if let index = receipt.items.firstIndex(where: { $0.id == item.id }) {
            receipt.items[index].quantity = quantity
            receipt.items[index].unitPrice = price
            receipt.items[index].translationEn = draft.translation.isEmpty ? nil : draft.translation
            receipt.items[index].category = draft.category
            receipt.items[index].subcategory = draft.subcategory
            receipt.items[index].itemGroup = draft.itemGroup
            var saved = ItemDraft(receipt.items[index])
            saved.status = .saved
            drafts[item.id] = saved
        }
    }

    func delete(_ item: LabLineItem) {
        receipt.items.removeAll { $0.id == item.id }
        drafts[item.id] = nil
    }

    func addItem() async {
        let name = addName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let price = Self.number(addPrice) else {
            addError = true
            return
        }
        addError = false
        addBusy = true
        try? await Task.sleep(for: .seconds(0.4))
        let id = (receipt.items.map(\.id).max() ?? receipt.id * 100) + 1
        receipt.items.append(LabLineItem(
            id: id, itemDictionaryId: 1000 + id, rawText: nil, nameDe: name, quantity: Self.number(addQty) ?? 1, unitPrice: price,
            translationEn: nil, category: "Other", subcategory: "Miscellaneous", itemGroup: "General"
        ))
        addBusy = false
        addName = ""
        addQty = "1"
        addPrice = ""
        addOpen = false
        addOpenedByHand = false
    }

    nonisolated static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    static func parseTime(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.date(from: text)
    }
}

struct StoreBar: Identifiable {
    var id: String { store }
    let store: String
    let total: Double
}

struct ItemDraft: Equatable {
    enum Status: Equatable { case idle, saving, saved, bad }

    var quantity: String
    var price: String
    var translation: String
    var category: String
    var subcategory: String
    var itemGroup: String
    var status: Status = .idle
    private let original: [String]

    init(_ item: LabLineItem) {
        quantity = LabFormat.quantity(item.quantity)
        price = String(format: "%.2f", item.unitPrice)
        translation = item.translationEn ?? ""
        category = item.category
        subcategory = item.subcategory
        itemGroup = item.itemGroup
        original = [item.category, item.subcategory, item.itemGroup]
    }

    var pickersChanged: Bool { [category, subcategory, itemGroup] != original }
    var total: Double? {
        guard let quantity = DetailState.number(quantity), let price = DetailState.number(price) else { return nil }
        return ((quantity * price) * 100).rounded() / 100
    }
}

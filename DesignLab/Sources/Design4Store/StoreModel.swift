import LabCore
import Observation
import SwiftUI

enum StoreDialog: Equatable {
    case confirmAll(Int)
    case permanentDelete(Int)
    case scanUnavailable
    case scanNote
    case delete
    case rerun
    case clearCache
}

/// What the detail route is showing. Fixture-only states (busy, loading, edited) live here so they can be launched.
struct DetailRoute: Equatable {
    var receiptID: Int
    var photoTab = false
    var loading = false
    var busy = false
    /// The launch asked for the add-item form; used for the scroll and for reporting.
    var addItemFixture = false
    var editedFixture = false
    /// Opens with this item expanded and scrolled to (Overview's `Edit`).
    var expandItemID: Int?
}

enum ListFixture { case normal, setup }
enum TestResult: Equatable { case ok(String), failed(String) }

/// All navigation and local edits. `screen` is derived from it, for the switcher.
@MainActor @Observable
final class StoreModel {
    // Navigation
    var tab: LabScreen.Tab = .receipts
    var route: DetailRoute?
    var dialog: StoreDialog?

    // Data
    var receipts: [LabReceipt] = LabData.receipts
    var processing: [LabReceipt] = []
    var deleted: [LabReceipt] = LabData.deletedReceipts
    var uploads: [LabUploadJob] = []
    /// Fixture-only receipts, reachable without being in a list (the processing detail screens).
    var extra: [LabReceipt] = []

    // Banners
    var syncBanners: [String] = []
    var errorBanner: String?

    // List
    var setupNeeded = false
    var deletedOpen = false
    var search = ""
    var dateFilter = LabData.dateRanges[0]
    var storeFilter: String?
    var filtersOpen = false
    var syncing = false

    // Overview
    var range: LabRange = .month
    var overviewEmpty = false
    var monthIndex = 11
    var openNodes: Set<String> = []
    var drilldownFixture = false

    // Settings
    var serverURL = LabData.serverURL
    var token = ""
    var connected = true
    var testResult: TestResult?
    var cachedPhotos = LabData.cachedPhotos
    var unsent = LabData.unsentChanges
    var rejected = LabData.rejectedRecords
    var syncError: String? = LabData.syncError
    var lastSync: String? = LabData.lastSync

    init(initial: LabScreen) {
        tab = initial.tab
        apply(initial)
    }

    private func apply(_ screen: LabScreen) {
        switch screen {
        case .listProcessing:
            processing = LabData.processingReceipts
            uploads = LabData.uploadQueue
        case .listDeletedOpen: deletedOpen = true
        case .listEmpty: receipts = []; deleted = []
        case .listNoMatch: search = "Kaffeemaschine"; dateFilter = "This month"
        case .listSetup: receipts = []; deleted = []; setupNeeded = true; connected = false; serverURL = ""
        case .listFilters: filtersOpen = true
        case .dialogConfirmAll: dialog = .confirmAll(LabData.unflaggedUnreviewedCount)
        case .dialogPermanentDelete: deletedOpen = true; dialog = .permanentDelete(LabData.deletedReceipts[0].id)
        case .alertScanUnavailable: dialog = .scanUnavailable
        case .alertScanNote: dialog = .scanNote
        case .bannerSync: syncBanners = LabData.banners
        case .bannerError: errorBanner = LabData.errorBanner
        case .detail, .detailReviewed, .detailWaiting, .detailProcessing, .detailUploadFailed, .detailFailed:
            openFixture(screen)
        case .detailLoading: openFixture(screen); route?.loading = true
        case .detailPhoto, .detailPhotoMissing: openFixture(screen); route?.photoTab = true
        case .detailAddItem: openFixture(screen); route?.addItemFixture = true
        case .detailItemEdited: openFixture(screen); route?.editedFixture = true
        case .detailBusy: openFixture(screen); route?.busy = true
        case .dialogDelete: openFixture(screen); dialog = .delete
        case .dialogRerun: openFixture(screen); dialog = .rerun
        case .overviewYear: range = .year
        case .overviewCustom: range = .custom
        case .overviewAll: range = .all
        case .overviewEmpty: overviewEmpty = true
        case .overviewDrilldown:
            let p = LabData.drilldownPath
            drilldownFixture = true
            openNodes = [p.category, p.category + "|" + p.subcategory, p.category + "|" + p.subcategory + "|" + p.itemGroup]
        case .settingsUnconfigured: connected = false; serverURL = ""
        case .settingsInvalidURL: serverURL = "receipts.example.com"
        case .settingsTestOK: testResult = .ok(LabData.connectionOK)
        case .settingsTestFailed: testResult = .failed(LabData.connectionFailed)
        case .dialogClearCache: dialog = .clearCache
        case .list, .overview, .settings: break
        }
    }

    private func openFixture(_ screen: LabScreen) {
        guard let fixture = screen.fixtureReceipt else { return }
        if receipt(id: fixture.id) == nil { extra.append(fixture) }
        route = DetailRoute(receiptID: fixture.id)
    }

    // MARK: Lookups

    func receipt(id: Int) -> LabReceipt? {
        (receipts + processing + deleted + extra).first { $0.id == id } ?? LabData.receipt(id: id)
    }

    func update(_ id: Int, _ change: (inout LabReceipt) -> Void) {
        if let i = receipts.firstIndex(where: { $0.id == id }) { change(&receipts[i]); return }
        if let i = processing.firstIndex(where: { $0.id == id }) { change(&processing[i]); return }
        if let i = extra.firstIndex(where: { $0.id == id }) { change(&extra[i]); return }
        if var other = LabData.receipt(id: id) {
            change(&other)
            extra.append(other)
        }
    }

    // MARK: List

    var isFiltering: Bool { dateFilter != LabData.dateRanges[0] || storeFilter != nil }
    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private func matches(_ receipt: LabReceipt) -> Bool {
        let date = receipt.date ?? ""
        switch dateFilter {
        case "This month": if !date.hasPrefix("2026-10") { return false }
        case "Last 3 months": if date < "2026-08-01" { return false }
        case "This year": if !date.hasPrefix("2026") { return false }
        default: break
        }
        if let storeFilter, receipt.store != storeFilter { return false }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        if (receipt.store ?? "").lowercased().contains(query) { return true }
        if LabFormat.money(receipt.total).contains(query) { return true }
        if let total = receipt.total, String(format: "%.2f", total).contains(query) { return true }
        return receipt.items.contains {
            ($0.nameDe ?? "").lowercased().contains(query) || ($0.translationEn ?? "").lowercased().contains(query)
        }
    }

    /// Processing rows first, as production has them in Needs review. Filters hide them while active.
    var needsReview: [LabReceipt] {
        let filtering = isFiltering || isSearching
        let active = filtering ? [] : processing
        return active + receipts.filter { $0.reviewedAt == nil && matches($0) }
    }

    var reviewedList: [LabReceipt] { receipts.filter { $0.reviewedAt != nil && matches($0) } }
    var unflaggedCount: Int { receipts.filter { $0.reviewedAt == nil && !$0.needsReview }.count }
    var hasNoReceipts: Bool { receipts.isEmpty && processing.isEmpty }
    var noMatch: Bool { !hasNoReceipts && needsReview.isEmpty && reviewedList.isEmpty }

    func softDelete(_ id: Int) {
        guard let i = receipts.firstIndex(where: { $0.id == id }) else {
            processing.removeAll { $0.id == id }
            extra.removeAll { $0.id == id }
            return
        }
        deleted.insert(receipts.remove(at: i), at: 0)
    }

    func restore(_ id: Int) {
        guard let i = deleted.firstIndex(where: { $0.id == id }) else { return }
        let receipt = deleted.remove(at: i)
        receipts.append(receipt)
        receipts.sort { ($0.date ?? "") > ($1.date ?? "") }
    }

    func confirmAllUnflagged() {
        for i in receipts.indices where receipts[i].reviewedAt == nil && !receipts[i].needsReview {
            receipts[i].reviewedAt = "2026-10-31T10:00:00Z"
        }
    }

    func runSync() {
        guard !syncing else { return }
        syncing = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            syncing = false
            syncError = nil
            unsent = 0
            lastSync = LabData.lastSync
        }
    }

    // MARK: Detail

    func open(_ id: Int, expanding item: Int? = nil) { route = DetailRoute(receiptID: id, expandItemID: item) }

    /// Confirms, then moves to the next receipt to review, in place.
    func looksGood(_ id: Int) {
        update(id) { $0.reviewedAt = "2026-10-31T10:00:00Z" }
        if let next = receipts.first(where: { $0.reviewedAt == nil && $0.id != id }) {
            route = DetailRoute(receiptID: next.id)
        } else {
            route = nil
        }
    }

    // MARK: Dialog actions

    func confirmDialog() {
        guard let dialog else { return }
        switch dialog {
        case .confirmAll: confirmAllUnflagged()
        case .permanentDelete(let id): deleted.removeAll { $0.id == id }
        case .delete:
            if let id = route?.receiptID { softDelete(id) }
            route = nil
        case .rerun:
            if let id = route?.receiptID {
                update(id) { $0.processing = .processing; $0.reviewedAt = nil }
            }
        case .clearCache: cachedPhotos = "0 MB"
        case .scanUnavailable, .scanNote: break
        }
        self.dialog = nil
    }

    // MARK: Settings

    var urlIsInvalid: Bool {
        let url = serverURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return false }
        return !(url.hasPrefix("https://") || url.hasPrefix("http://localhost"))
    }

    var urlIsEmpty: Bool { serverURL.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Reporting

    var screen: LabScreen {
        if let dialog {
            switch dialog {
            case .confirmAll: return .dialogConfirmAll
            case .permanentDelete: return .dialogPermanentDelete
            case .scanUnavailable: return .alertScanUnavailable
            case .scanNote: return .alertScanNote
            case .delete: return .dialogDelete
            case .rerun: return .dialogRerun
            case .clearCache: return .dialogClearCache
            }
        }
        if let route { return detailScreen(route) }
        switch tab {
        case .receipts:
            if !syncBanners.isEmpty { return .bannerSync }
            if errorBanner != nil { return .bannerError }
            if setupNeeded && hasNoReceipts { return .listSetup }
            if filtersOpen { return .listFilters }
            if hasNoReceipts { return .listEmpty }
            if noMatch { return .listNoMatch }
            if !uploads.isEmpty || !processing.isEmpty { return .listProcessing }
            if deletedOpen { return .listDeletedOpen }
            return .list
        case .overview:
            if overviewEmpty { return .overviewEmpty }
            if openNodes.contains(where: { $0.filter { $0 == "|" }.count == 2 }) { return .overviewDrilldown }
            switch range {
            case .month: return .overview
            case .year: return .overviewYear
            case .custom: return .overviewCustom
            case .all: return .overviewAll
            }
        case .settings:
            if !connected && urlIsEmpty { return .settingsUnconfigured }
            if urlIsInvalid { return .settingsInvalidURL }
            switch testResult {
            case .ok: return .settingsTestOK
            case .failed: return .settingsTestFailed
            case nil: return .settings
            }
        }
    }

    private func detailScreen(_ route: DetailRoute) -> LabScreen {
        if route.loading { return .detailLoading }
        if route.busy { return .detailBusy }
        let receipt = receipt(id: route.receiptID)
        if route.photoTab { return receipt?.photoNote != nil ? .detailPhotoMissing : .detailPhoto }
        switch receipt?.processing {
        case .waitingForUpload: return .detailWaiting
        case .processing: return .detailProcessing
        case .uploadFailed: return .detailUploadFailed
        case .failed: return .detailFailed
        case nil: break
        }
        if route.addItemFixture { return .detailAddItem }
        if route.editedFixture { return .detailItemEdited }
        return receipt?.reviewedAt != nil ? .detailReviewed : .detail
    }
}

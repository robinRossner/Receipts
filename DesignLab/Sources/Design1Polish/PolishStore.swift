import LabCore
import Observation
import SwiftUI

/// All local state of the design: navigation, fake data edits and the launch state.
@MainActor @Observable
final class PolishStore {
    enum SyncPhase { case synced, syncedNow, syncing, failedRetrying, failed, notYet }

    struct Snack: Identifiable {
        let id = UUID()
        let text: String
        let undo: () -> Void
    }

    // Navigation
    var tab: LabScreen.Tab
    var receiptsPath: [Int] = []
    var overviewPath: [Int] = []
    /// What a shown detail screen reports. nil when no detail is on screen.
    var detailReport: LabScreen?
    /// Consumed by the first detail screen that opens.
    var launchScreen: LabScreen
    var highlightItem: Int?

    // Data
    var receipts: [LabReceipt]
    var deleted: [LabReceipt] = LabData.deletedReceipts
    var uploads: [LabUploadJob] = []
    var connected = true
    var hasReceipts = true

    // List
    var searchText = ""
    var dateFilter = "All time"
    var storeFilter: String?
    var showFilters = false
    var showDeleted = false
    var confirmAll = false
    var pendingPermanentDelete: LabReceipt?
    var scanUnavailable = false
    var scanNote: String?
    var syncPhase = SyncPhase.synced
    var snack: Snack?
    /// Scrolls the list to Recently deleted at launch.
    var scrollToDeleted = false

    // Banners
    var banners: [String] = []
    var errorBanner: String?

    // Overview
    var range = LabRange.month
    var monthOffset = 0
    var yearOffset = 0
    var overviewForcedEmpty = false
    var expanded: Set<String> = []
    var scrollToDrilldown = false

    // Settings
    var serverURL = LabData.serverURL
    var token = ""
    var hasToken = true
    var testing = false
    var testResult: Bool?
    var savedNote = false
    var settingsSyncing = false
    var clearCacheDialog = false
    var cachedPhotos = LabData.cachedPhotos

    init(screen: LabScreen) {
        tab = screen.tab
        launchScreen = screen
        receipts = LabData.receipts

        if let receipt = screen.fixtureReceipt {
            receiptsPath = [receipt.id]
            if receipt.processing != nil { receipts.insert(contentsOf: LabData.processingReceipts, at: 0) }
        }

        switch screen {
        case .listProcessing:
            receipts.insert(contentsOf: LabData.processingReceipts, at: 0)
            uploads = LabData.uploadQueue
        case .listDeletedOpen:
            showDeleted = true
            scrollToDeleted = true
        case .listEmpty:
            receipts = []
            deleted = []
            hasReceipts = false
        case .listNoMatch:
            searchText = "Döner"
        case .listSetup:
            receipts = []
            deleted = []
            hasReceipts = false
            connected = false
            hasToken = false
            serverURL = ""
        case .listFilters:
            showFilters = true
        case .dialogConfirmAll:
            confirmAll = true
        case .dialogPermanentDelete:
            showDeleted = true
            scrollToDeleted = true
            pendingPermanentDelete = LabData.deletedReceipts.first
        case .alertScanUnavailable:
            scanUnavailable = true
        case .alertScanNote:
            scanNote = "Only the first of 3 pages was added. A receipt is one photo; scan the other pages as separate receipts."
        case .bannerSync:
            banners = LabData.banners
        case .bannerError:
            errorBanner = LabData.errorBanner
        case .overviewYear:
            range = .year
        case .overviewCustom:
            range = .custom
        case .overviewAll:
            range = .all
        case .overviewEmpty:
            overviewForcedEmpty = true
        case .overviewDrilldown:
            let path = LabData.drilldownPath
            expanded = [path.category, "\(path.category)>\(path.subcategory)",
                        "\(path.category)>\(path.subcategory)>\(path.itemGroup)"]
            scrollToDrilldown = true
        case .settingsUnconfigured:
            connected = false
            hasToken = false
            serverURL = ""
        case .settingsInvalidURL:
            connected = false
            hasToken = false
            serverURL = "receipts.example.com"
        case .settingsTestOK:
            testResult = true
        case .settingsTestFailed:
            testResult = false
        case .dialogClearCache:
            clearCacheDialog = true
        default:
            break
        }
    }

    // MARK: Reporting

    var currentScreen: LabScreen {
        switch tab {
        case .settings:
            if clearCacheDialog { return .dialogClearCache }
            if testResult == true { return .settingsTestOK }
            if testResult == false { return .settingsTestFailed }
            if urlIsInvalid { return .settingsInvalidURL }
            return hasToken ? .settings : .settingsUnconfigured
        case .overview:
            if let detailReport, !overviewPath.isEmpty { return detailReport }
            let path = LabData.drilldownPath
            if range == .month, expanded.contains("\(path.category)>\(path.subcategory)>\(path.itemGroup)") { return .overviewDrilldown }
            if overviewIsEmpty { return .overviewEmpty }
            switch range {
            case .month: return .overview
            case .year: return .overviewYear
            case .custom: return .overviewCustom
            case .all: return .overviewAll
            }
        case .receipts:
            if let detailReport, !receiptsPath.isEmpty { return detailReport }
            if confirmAll { return .dialogConfirmAll }
            if pendingPermanentDelete != nil { return .dialogPermanentDelete }
            if scanUnavailable { return .alertScanUnavailable }
            if scanNote != nil { return .alertScanNote }
            if showFilters { return .listFilters }
            if errorBanner != nil { return .bannerError }
            if !banners.isEmpty { return .bannerSync }
            if !connected && !hasReceipts { return .listSetup }
            if !hasReceipts { return .listEmpty }
            if filtered.isEmpty { return .listNoMatch }
            if showDeleted { return .listDeletedOpen }
            if !uploads.isEmpty || receipts.contains(where: { $0.processing != nil }) { return .listProcessing }
            return .list
        }
    }

    // MARK: List

    var isFiltering: Bool { !searchText.isEmpty || dateFilter != "All time" || storeFilter != nil }

    var filtered: [LabReceipt] {
        receipts.filter { receipt in
            if let storeFilter, receipt.store != storeFilter { return false }
            if !matchesDate(receipt) { return false }
            let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
            guard !query.isEmpty else { return true }
            if (receipt.store ?? "").lowercased().contains(query) { return true }
            if LabFormat.money(receipt.total).contains(query) { return true }
            return receipt.items.contains {
                ($0.nameDe ?? "").lowercased().contains(query) || ($0.translationEn ?? "").lowercased().contains(query)
            }
        }
    }

    private func matchesDate(_ receipt: LabReceipt) -> Bool {
        // "Today" in the data is 2026-10-31.
        guard let date = receipt.date else { return dateFilter == "All time" }
        switch dateFilter {
        case "This month": return date.hasPrefix("2026-10")
        case "Last 3 months": return date >= "2026-08-01"
        case "This year": return date.hasPrefix("2026")
        default: return true
        }
    }

    var needsReview: [LabReceipt] { filtered.filter { $0.reviewedAt == nil } }
    var reviewed: [LabReceipt] { filtered.filter { $0.reviewedAt != nil } }
    var reviewCount: Int { receipts.filter { $0.reviewedAt == nil }.count }
    var unflaggedCount: Int { receipts.filter { $0.reviewedAt == nil && !$0.needsReview && $0.processing == nil }.count }
    var storesInUse: [String] { Array(Set(receipts.compactMap(\.store))).sorted() }

    func clearFilters() {
        searchText = ""
        dateFilter = "All time"
        storeFilter = nil
    }

    func receipt(_ id: Int) -> LabReceipt? {
        receipts.first { $0.id == id } ?? LabData.receipt(id: id)
    }

    func update(_ id: Int, _ change: (inout LabReceipt) -> Void) {
        guard let index = receipts.firstIndex(where: { $0.id == id }) else { return }
        change(&receipts[index])
    }

    /// Marks a receipt reviewed. Returns the next one to review.
    @discardableResult
    func confirm(_ id: Int) -> LabReceipt? {
        update(id) { $0.reviewedAt = ($0.date ?? "2026-10-31") + "T20:15:00Z"; $0.needsReview = false; $0.reviewReasons = [] }
        return nextToReview(after: id)
    }

    func nextToReview(after id: Int) -> LabReceipt? {
        let queue = receipts.filter { $0.reviewedAt == nil && $0.processing == nil && $0.id != id }
        if let index = receipts.firstIndex(where: { $0.id == id }),
           let later = queue.first(where: { candidate in (receipts.firstIndex { $0.id == candidate.id } ?? 0) > index }) {
            return later
        }
        return queue.first
    }

    func confirmAllWithoutFlags() {
        for receipt in receipts where receipt.reviewedAt == nil && !receipt.needsReview && receipt.processing == nil {
            confirm(receipt.id)
        }
    }

    func confirmFromList(_ receipt: LabReceipt) {
        let before = receipt
        confirm(receipt.id)
        show(snack: "\(receipt.store ?? "Receipt") reviewed") { [weak self] in
            self?.update(before.id) { $0 = before }
        }
    }

    func delete(_ receipt: LabReceipt) {
        guard let index = receipts.firstIndex(where: { $0.id == receipt.id }) else { return }
        receipts.remove(at: index)
        deleted.insert(receipt, at: 0)
        show(snack: "Moved to Recently deleted") { [weak self] in
            guard let self else { return }
            self.deleted.removeAll { $0.id == receipt.id }
            self.receipts.insert(receipt, at: min(index, self.receipts.count))
        }
    }

    func restore(_ receipt: LabReceipt) {
        deleted.removeAll { $0.id == receipt.id }
        let index = receipts.firstIndex { ($0.date ?? "9999") < (receipt.date ?? "") } ?? receipts.count
        receipts.insert(receipt, at: index)
    }

    func show(snack text: String, undo: @escaping @MainActor () -> Void) {
        let new = Snack(text: text, undo: { undo() })
        withAnimation(.easeOut(duration: 0.2)) { snack = new }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if snack?.id == new.id { withAnimation(.easeOut(duration: 0.2)) { snack = nil } }
        }
    }

    func syncNow() async {
        syncPhase = .syncing
        try? await Task.sleep(for: .seconds(1.2))
        syncPhase = .syncedNow
    }

    // MARK: Uploads

    func cancelUpload(_ id: Int) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[index].state = .cancelled
    }

    func cancelAllUploads() {
        for index in uploads.indices where !uploads[index].state.isFinished { uploads[index].state = .cancelled }
    }

    func retryFailedUploads() {
        for index in uploads.indices where uploads[index].state.isFailure { uploads[index].state = .queued }
    }

    func clearFinishedUploads() { uploads.removeAll { $0.state.isFinished } }

    // MARK: Settings

    var urlIsInvalid: Bool {
        guard !serverURL.isEmpty else { return false }
        let url = serverURL.lowercased()
        return !(url.hasPrefix("https://") && url.count > 8) && !url.hasPrefix("http://localhost")
    }

    // MARK: Overview

    var overviewIsEmpty: Bool { overviewForcedEmpty || OverviewData.summary(store: self).total == 0 }
}

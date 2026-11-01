import Foundation

/// Every screen and state of the iOS app, with stable ids. docs/screens.md describes each one. The raw value is the
/// `-screen` launch argument.
public enum LabScreen: String, CaseIterable, Identifiable, Sendable {
    // Receipts tab
    case list, listProcessing, listDeletedOpen, listEmpty, listNoMatch, listSetup, listFilters
    case dialogConfirmAll, dialogPermanentDelete, alertScanUnavailable, alertScanNote
    // Root banners (above the tabs)
    case bannerSync, bannerError
    // Receipt detail
    case detail, detailLoading, detailReviewed, detailPhoto, detailPhotoMissing, detailAddItem, detailItemEdited
    case detailBusy, detailWaiting, detailProcessing, detailUploadFailed, detailFailed
    case dialogDelete, dialogRerun
    // Overview tab
    case overview, overviewYear, overviewCustom, overviewAll, overviewEmpty, overviewDrilldown
    // Settings tab
    case settings, settingsUnconfigured, settingsInvalidURL, settingsTestOK, settingsTestFailed, dialogClearCache

    public var id: String { rawValue }

    public enum Tab: String, Sendable { case receipts, overview, settings }

    /// Which tab this screen lives on (`bannerSync` / `bannerError` show the receipts tab under the banner).
    public var tab: Tab {
        switch self {
        case .overview, .overviewYear, .overviewCustom, .overviewAll, .overviewEmpty, .overviewDrilldown: return .overview
        case .settings, .settingsUnconfigured, .settingsInvalidURL, .settingsTestOK, .settingsTestFailed, .dialogClearCache: return .settings
        default: return .receipts
        }
    }

    /// True for screens pushed on top of the receipt list (tab bar hidden in production).
    public var isDetail: Bool { rawValue.hasPrefix("detail") || self == .dialogDelete || self == .dialogRerun }

    /// The receipt a detail screen shows.
    public var fixtureReceipt: LabReceipt? {
        switch self {
        case .detail, .detailLoading, .detailPhoto, .detailAddItem, .detailItemEdited, .detailBusy, .dialogDelete, .dialogRerun:
            return LabData.flagged
        case .detailReviewed: return LabData.reviewed
        case .detailPhotoMissing: return LabData.photoOnLaptop
        case .detailWaiting: return LabData.waitingForUpload
        case .detailProcessing: return LabData.processing
        case .detailUploadFailed: return LabData.uploadFailed
        case .detailFailed: return LabData.extractionFailed
        default: return nil
        }
    }
}

/// Launch arguments: `-screen <id>` (all targets) and `-design <1|2|3|4>` (DesignLab).
public enum LabLaunch {
    public static var screen: LabScreen? {
        guard let raw = value(after: "-screen") else { return nil }
        guard let screen = LabScreen(rawValue: raw) else {
            print("DesignLab: unknown -screen \(raw). Known: \(LabScreen.allCases.map(\.rawValue).joined(separator: " "))")
            return nil
        }
        return screen
    }

    public static var design: Int? {
        value(after: "-design").flatMap(Int.init).flatMap { (1...4).contains($0) ? $0 : nil }
    }

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

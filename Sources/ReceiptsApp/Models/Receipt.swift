import Foundation

/// Where a receipt that cloud sync handles stands: waiting for its photo to reach the server, being read there,
/// or failed. nil = an ordinary finished receipt (all receipts when sync is off).
enum ReceiptProcessing: Equatable, Hashable {
    case waitingForUpload(String?)
    case uploadFailed(String?)
    case processing
    case failed(String?)

    /// From the receipt's job status (`extraction_status` / `extraction_error`).
    init?(status: String?, error: String?) {
        switch status {
        case "pending_upload": self = .waitingForUpload(error)
        case "upload_failed": self = .uploadFailed(error)
        case "queued", "processing": self = .processing
        case "failed": self = .failed(error)
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .waitingForUpload: return "Waiting to upload"
        case .uploadFailed: return "Upload failed"
        case .processing: return "Reading receipt on the server…"
        case .failed: return "Could not read this receipt"
        }
    }

    var isActive: Bool {
        switch self {
        case .waitingForUpload, .processing: return true
        case .uploadFailed, .failed: return false
        }
    }
}

/// Row shape for the sidebar list (GET /receipts in the old API).
struct ReceiptSummary: Identifiable, Hashable {
    let id: Int
    var store: String?
    var date: String?
    var time: String?
    var total: Double?
    var needsReview: Bool
    var reviewedAt: String?
    var processing: ReceiptProcessing?
}

/// Full receipt + its line items (GET /receipts/{id} in the old API).
struct ReceiptDetail: Identifiable {
    let id: Int
    var store: String?
    var date: String?
    var time: String?
    var total: Double?
    var computedSum: Double?
    var needsReview: Bool
    var reviewReasons: [String]
    var sourceImage: String?
    var reviewedAt: String?
    var items: [LineItemDetail]
    /// Cloud sync: the receipt's wire id, its job status, and why there may be no photo to show.
    var uuid: String?
    var processing: ReceiptProcessing?
    var photoLocation: String?
    /// Shown instead of the photo when there is none to display (still on the server, missing here, no photo).
    var photoNote: String?

    var hasSumMismatch: Bool {
        reviewReasons.contains { $0.contains("sum to") }
    }
}

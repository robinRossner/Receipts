import SwiftUI

/// Compact batch-upload panel for the review sidebar: overall progress, bulk actions, and one
/// row per queued file with its live stage.
struct UploadQueueView: View {
    @EnvironmentObject var store: ReceiptStore

    private var finishedCount: Int { store.uploadQueue.filter { $0.state.isFinished }.count }
    private var hasFailed: Bool { store.uploadQueue.contains { isFailure($0.state) } }
    private var hasPending: Bool { store.uploadQueue.contains { !$0.state.isFinished } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("UPLOADS - \(finishedCount) of \(store.uploadQueue.count)")
                    .font(AppTheme.body(11, weight: .medium))
                    .foregroundColor(AppTheme.inkSoft)
                Spacer()
                if hasPending { actionButton("Cancel all") { store.cancelAllUploads() } }
                if hasFailed { actionButton("Retry failed") { store.retryFailedUploads() } }
                actionButton("Clear finished") { store.clearFinishedUploads() }
            }
            ProgressView(value: Double(finishedCount), total: Double(max(store.uploadQueue.count, 1)))
                .progressViewStyle(.linear)
                .tint(AppTheme.ink)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.uploadQueue) { job in
                        row(job)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(AppTheme.body(11))
            .foregroundColor(AppTheme.inkSoft)
    }

    private func receiptId(of job: UploadJob) -> Int? {
        switch job.state {
        case .done(let id), .uploaded(let id), .duplicate(let id): return id
        default: return nil
        }
    }

    private func row(_ job: UploadJob) -> some View {
        HStack(alignment: .top, spacing: 6) {
            thumbnail(job)
            statusIcon(job.state)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(AppTheme.ink)
                Text(statusText(job.state))
                    .font(AppTheme.body(11))
                    .foregroundColor(isFailure(job.state) ? AppTheme.penRed : AppTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !job.state.isFinished {
                Button { store.cancelUpload(id: job.id) } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.inkSoft)
                .help("Cancel")
            }
        }
        .font(AppTheme.body(12))
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = receiptId(of: job) { store.flaggedPaneOpen = false; Task { await store.loadReceiptDetail(id: id) } }
        }
    }

    @ViewBuilder private func thumbnail(_ job: UploadJob) -> some View {
        if let image = job.thumbnail {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else {
            RoundedRectangle(cornerRadius: 2).fill(AppTheme.rule).frame(width: 22, height: 22)
        }
    }

    @ViewBuilder private func statusIcon(_ state: UploadJob.State) -> some View {
        switch state {
        case .queued: Image(systemName: "clock").foregroundColor(AppTheme.inkSoft)
        case .scanning, .extracting, .categorizing, .saving, .uploading: ProgressView().controlSize(.mini)
        case .done, .uploaded: Image(systemName: "checkmark.circle.fill").foregroundColor(AppTheme.greenText)
        case .duplicate: Image(systemName: "equal.circle").foregroundColor(AppTheme.inkSoft)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(AppTheme.penRed)
        case .cancelled: Image(systemName: "slash.circle").foregroundColor(AppTheme.inkSoft)
        }
    }

    private func isFailure(_ state: UploadJob.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func statusText(_ state: UploadJob.State) -> String {
        switch state {
        case .queued: return "Waiting"
        case .scanning: return "Scanning…"
        case .extracting: return "Reading receipt…"
        case .categorizing: return "Categorizing…"
        case .saving: return "Saving…"
        case .uploading: return "Uploading…"
        case .done(let id): return "Imported as receipt #\(id)"
        case .uploaded(let id): return "Uploaded (receipt #\(id)); the server is reading it"
        case .duplicate(let id): return "Already imported (receipt #\(id))"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

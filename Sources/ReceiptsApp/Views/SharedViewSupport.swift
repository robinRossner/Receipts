import SwiftUI

// View helpers both apps use.

/// Wraps children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (points, widest, y + rowHeight)
    }
}

/// The transient "something happened, Undo" bar. Lives above the tabs' screens so it survives popping back to the list.
@MainActor
final class SnackCenter: ObservableObject {
    struct Snack: Identifiable {
        let id = UUID()
        let text: String
        let undo: @MainActor () async -> Void
    }

    @Published private(set) var current: Snack?
    static let visibleSeconds: UInt64 = 5

    func show(_ text: String, undo: @escaping @MainActor () async -> Void) {
        let new = Snack(text: text, undo: undo)
        withAnimation(.easeOut(duration: 0.2)) { current = new }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.visibleSeconds * 1_000_000_000)
            guard let self, self.current?.id == new.id else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.current = nil }
        }
    }

    func performUndo() {
        guard let snack = current else { return }
        withAnimation(.easeOut(duration: 0.2)) { current = nil }
        Task { await snack.undo() }
    }
}

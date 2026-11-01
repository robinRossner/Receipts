import SwiftUI

/// Stands in for a receipt photo: a slightly tilted till slip drawn from the receipt's data, on a dark surface.
/// Fixed colours on purpose, because a photo looks the same in light and dark mode. Designs choose the size and framing.
public struct ReceiptPhotoPlaceholder: View {
    let receipt: LabReceipt

    public init(receipt: LabReceipt) { self.receipt = receipt }

    public var body: some View {
        ZStack {
            Color(white: 0.2)
            slip
                .rotationEffect(.degrees(-1.2))
                .padding(20)
        }
        .accessibilityLabel("Receipt photo")
    }

    private var slip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((receipt.store ?? "Kassenbon").uppercased())
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
            Text("Hauptstr. 12 · 60313 Frankfurt")
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            ForEach(receipt.items.prefix(14)) { item in
                HStack {
                    Text(item.rawText ?? "").lineLimit(1)
                    Spacer()
                    Text(String(format: "%.2f", item.totalPrice).replacingOccurrences(of: ".", with: ","))
                }
            }
            Rectangle().frame(height: 1).padding(.vertical, 6)
            HStack {
                Text("SUMME EUR").bold()
                Spacer()
                Text(String(format: "%.2f", receipt.total ?? 0).replacingOccurrences(of: ".", with: ",")).bold()
            }
            Text("\(receipt.date ?? "") \(receipt.time ?? "")")
                .padding(.top, 8)
            HStack(spacing: 1.5) {
                ForEach(0..<46, id: \.self) { i in
                    Rectangle().frame(width: [1, 2, 1, 3, 1][i % 5], height: 28)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(Color(white: 0.16))
        .padding(14)
        .frame(maxWidth: 270)
        .background(Color(red: 0.97, green: 0.96, blue: 0.92))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }
}

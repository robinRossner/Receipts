// Draws two synthetic receipt photos (a paper receipt on a desk) for the iPhone simulator e2e run:
//   swift Tests/e2e/make_sample_receipts.swift <out_dir>
// Writes receipt-1.jpg and receipt-2.jpg (distinct bytes, so the server does not see a duplicate). The fake extraction
// of the e2e run ignores the content; the pictures are for the photo view and the screenshots.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ name: String, store: String, lines: [(String, String)], tilt: CGFloat) throws {
    let w = 2400, h = 3200
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.36, green: 0.29, blue: 0.23, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.saveGState()
    ctx.translateBy(x: 1200, y: 1600)
    ctx.rotate(by: tilt * .pi / 180)
    ctx.setFillColor(CGColor(red: 0.98, green: 0.976, blue: 0.957, alpha: 1))
    ctx.fill(CGRect(x: -750, y: -1200, width: 1500, height: 2400))
    func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1)])
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    }
    text(store, x: -630, y: 1000, size: 90)
    text("Musterstrasse 1, 1010 Wien", x: -630, y: 880, size: 58)
    var y: CGFloat = 700
    for (item, price) in lines {
        text(item, x: -630, y: y, size: 60)
        text(price, x: 330, y: y, size: 60)
        y -= 100
    }
    ctx.setStrokeColor(CGColor(gray: 0.08, alpha: 1)); ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: -630, y: y + 40)); ctx.addLine(to: CGPoint(x: 630, y: y + 40)); ctx.strokePath()
    text("SUMME", x: -630, y: y - 60, size: 90)
    ctx.restoreGState()
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
}

try draw("receipt-1.jpg", store: "EDEKA", lines: [("Bio Eier 10er", "2,49"), ("Milch 1l x2", "2,38")], tilt: 2.5)
try draw("receipt-2.jpg", store: "REWE", lines: [("Brot", "2,19"), ("Butter", "1,99")], tilt: -3)
print(out.path)

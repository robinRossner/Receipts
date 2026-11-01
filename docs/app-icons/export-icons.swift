// Renders docs/app-icons/1-the-slip.svg into the app icons of both apps. Run from the repo root after changing the SVG:
//   swift docs/app-icons/export-icons.swift
// iPhone: the opaque full-bleed square (iOS rounds the corners itself). Mac: a rounded tile with margin and a shadow,
// because macOS draws the icon as it is.
import AppKit
import Foundation

let source = "docs/app-icons/1-the-slip.svg"
let iPhoneCatalog = "Sources/ReceiptsiOS/Resources/Assets.xcassets/AppIcon.appiconset"
let macCatalog = "Sources/ReceiptsMacAssets/Assets.xcassets/AppIcon.appiconset"

func renderSVG() -> CGImage {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let ql = Process()
    ql.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    ql.arguments = ["-t", "-s", "1024", "-o", tmp.path, source]
    ql.standardOutput = FileHandle.nullDevice
    try! ql.run()
    ql.waitUntilExit()
    let png = tmp.appendingPathComponent((source as NSString).lastPathComponent + ".png")
    return NSBitmapImageRep(data: try! Data(contentsOf: png))!.cgImage!
}

func context(_ size: Int, opaque: Bool) -> CGContext {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

func write(_ ctx: CGContext, to path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let data = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

/// Apple's macOS icon grid: an 824 px tile on the 1024 px canvas, corner radius 185.
func macTile(_ art: CGImage) -> CGImage {
    let ctx = context(1024, opaque: false)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(art, in: tile)
    return ctx.makeImage()!
}

let art = renderSVG()

let phone = context(1024, opaque: true)
phone.draw(art, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
write(phone, to: "\(iPhoneCatalog)/icon-1024.png")

let contents: (String) -> Void = { json in
    try! json.write(toFile: "\(iPhoneCatalog)/Contents.json", atomically: true, encoding: .utf8)
}
contents("""
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

""")

let tile = macTile(art)
var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let file = "icon-\(points)@\(scale)x.png"
        let ctx = context(pixels, opaque: false)
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        write(ctx, to: "\(macCatalog)/\(file)")
        images.append("    { \"filename\" : \"\(file)\", \"idiom\" : \"mac\", \"scale\" : \"\(scale)x\", \"size\" : \"\(points)x\(points)\" }")
    }
}
try! """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

""".write(toFile: "\(macCatalog)/Contents.json", atomically: true, encoding: .utf8)

let root = "{\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
for catalog in [iPhoneCatalog, macCatalog] {
    try! root.write(toFile: ((catalog as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

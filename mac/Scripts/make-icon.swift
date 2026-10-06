#!/usr/bin/env swift
// Renders the app icon (the "译" badge used in the window header) and packs it into an .icns file.
// Usage: swift Scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    // The macOS icon grid: the rounded square fills about 80% of the canvas.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0x60 / 255.0, green: 0x6C / 255.0, blue: 0xE6 / 255.0, alpha: 1),
                              ending: NSColor(srgbRed: 0x44 / 255.0, green: 0x4F / 255.0, blue: 0xC4 / 255.0, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    let glyphSize = rect.height * 0.64
    var font = NSFont(name: "PingFang SC", size: glyphSize) ?? NSFont.systemFont(ofSize: glyphSize)
    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = NSAttributedString(string: "译", attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
    let textSize = text.size()
    text.draw(in: NSRect(x: rect.minX, y: rect.midY - textSize.height / 2 + rect.height * 0.01, width: rect.width, height: textSize.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("QingYi-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try! process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
if process.terminationStatus != 0 {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(output)")

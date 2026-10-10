import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "/tmp/netlink-icon.png"
let pixels = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("无法创建图标画布\n", stderr)
    exit(1)
}
rep.size = NSSize(width: pixels, height: pixels)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
NSColor(srgbRed: 0.09, green: 0.12, blue: 0.15, alpha: 1).setFill()
NSBezierPath(roundedRect: bounds.insetBy(dx: 40, dy: 40), xRadius: 190, yRadius: 190).fill()

let symbolName = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil) != nil
    ? "lock.shield.fill"
    : "shield.fill"
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium)
let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let tinted = NSImage(size: base.size, flipped: false) { rect in
    NSColor(srgbRed: 0.55, green: 0.82, blue: 0.72, alpha: 1).set()
    rect.fill()
    base.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
    return true
}
let side = CGFloat(pixels) * 0.62
let origin = (CGFloat(pixels) - side) / 2
tinted.draw(in: NSRect(x: origin, y: origin - 20, width: side, height: side))
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("无法编码 PNG\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: output))
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}

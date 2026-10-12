import AppKit
import Foundation

// 应用图标「链路」：蓝色底，三个白色节点连成一条线，最后一个是绿色（已连通）。
// 坐标和设计稿一致：1024×1024 画布，y 向下，图标主体 824×824 留出阴影的边。

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
),
    let graphics = NSGraphicsContext(bitmapImageRep: rep)
else {
    fputs("无法创建图标画布\n", stderr)
    exit(1)
}
rep.size = NSSize(width: pixels, height: pixels)

let context = graphics.cgContext
// 翻成 y 向下，和设计稿的 SVG 坐标一样。
context.translateBy(x: 0, y: CGFloat(pixels))
context.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 底板：投影 + 上浅下深的蓝色渐变。
context.saveGState()
// setShadow 的偏移不跟坐标变换走，按原始的 y 向上算：负数才是往下。
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0x000000, 0.28))
context.addPath(shape)
context.setFillColor(rgb(0x0B5FD9))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shape)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [rgb(0x4FA3FF), rgb(0x0B5FD9)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
context.restoreGState()

// 一圈很淡的高光描边。
context.addPath(shape)
context.setStrokeColor(rgb(0xFFFFFF, 0.18))
context.setLineWidth(4)
context.strokePath()

// 链路。
let line = CGMutablePath()
line.move(to: CGPoint(x: 262, y: 628))
line.addCurve(to: CGPoint(x: 512, y: 400), control1: CGPoint(x: 392, y: 628), control2: CGPoint(x: 392, y: 400))
line.addCurve(to: CGPoint(x: 762, y: 584), control1: CGPoint(x: 632, y: 400), control2: CGPoint(x: 640, y: 584))
context.addPath(line)
context.setStrokeColor(rgb(0xFFFFFF))
context.setLineWidth(46)
context.setLineCap(.round)
context.strokePath()

func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ color: CGColor) {
    context.setFillColor(color)
    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}
dot(262, 628, 62, rgb(0xFFFFFF))
dot(512, 400, 62, rgb(0xFFFFFF))
dot(762, 584, 76, rgb(0xFFFFFF))
dot(762, 584, 52, rgb(0x34C759))

graphics.flushGraphics()

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

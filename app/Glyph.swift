import AppKit
import SwiftUI

/// 整体连接状态：菜单栏图标和菜单面板头部用。
enum LinkState {
    case checking
    case up
    case partial
    case down
}

extension AppModel {
    var linkState: LinkState {
        if vpn.phase == .checking || tunnel.phase == .checking { return .checking }
        if vpn.phase == .up && tunnel.phase == .up { return .up }
        if vpn.phase == .down && tunnel.phase == .down { return .down }
        return .partial
    }
}

/// 应用图标「链路」的单色版：三个节点连成一条线。模板图，菜单栏深浅色下自动变色。
/// 状态靠形状区分，不靠颜色：全通是实心，部分通最后一个节点空心，没连是虚线加空心。
enum PathGlyph {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(_ state: LinkState, size: CGFloat = 18) -> NSImage {
        let key = "\(state)-\(size)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(state, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = tr("内网连接", "NetLink")
        cache[key] = image
        return image
    }

    /// 按 24×24 的网格画，和设计稿里的菜单栏图标一致。
    private static func draw(_ state: LinkState, in rect: NSRect) {
        let unit = rect.width / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        // 检查中整体半透明：先在透明层里画实心，再整体淡出，线和节点重叠处不会叠深。
        let context = NSGraphicsContext.current?.cgContext
        if state == .checking {
            context?.setAlpha(0.5)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer {
            if state == .checking { context?.endTransparencyLayer() }
        }
        let color = NSColor.black
        color.set()

        let line = NSBezierPath()
        line.move(to: point(5, 16))
        line.curve(to: point(12, 8), controlPoint1: point(9, 16), controlPoint2: point(9, 8))
        line.curve(to: point(19, 14), controlPoint1: point(15, 8), controlPoint2: point(15, 14))
        line.lineWidth = 2 * unit
        line.lineCapStyle = .round
        if state == .down {
            line.setLineDash([1.6 * unit, 2.6 * unit], count: 2, phase: 0)
        }
        line.stroke()

        let nodes: [(CGFloat, CGFloat, CGFloat, Bool)] = [
            (5, 16, 2.4, state != .down),
            (12, 8, 2.4, state != .down),
            (19, 14, 2.8, state == .up || state == .checking),
        ]
        for (x, y, radius, filled) in nodes {
            let center = point(x, y)
            let r = radius * unit
            let circle = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            if filled {
                circle.fill()
            } else {
                // 空心节点：先挖掉线，再描一圈。
                NSGraphicsContext.current?.compositingOperation = .clear
                circle.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                color.set()
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r + 0.8 * unit, y: center.y - r + 0.8 * unit, width: r * 2 - 1.6 * unit, height: r * 2 - 1.6 * unit))
                ring.lineWidth = 1.6 * unit
                ring.stroke()
            }
        }
    }
}

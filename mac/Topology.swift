import AppKit
import SwiftUI

private enum TopologyWireStyle {
    case curve
    /// 跳板 → 多条转发：先到竖向总线，再水平接入，避免扇形贝塞尔缠在一起。
    case rail(railX: CGFloat)
}

private struct TopologyEdge: Identifiable {
    var id: String
    var from: CGPoint
    var to: CGPoint
    var fromSide: TopologySide
    var toSide: TopologySide
    var on: Bool
    var style: TopologyWireStyle = .curve
}

@MainActor
struct TopologyCanvas: View {
    @Bindable var model: AppModel
    @Binding var selection: Selection?
    var pathEdit: Binding<PathEdit?>
    @Environment(\.netlinkTheme) private var theme

    @State private var dragKey: String?
    @State private var dragOrigin: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var didDrag = false
    /// 拖动时冻结缩放比例，免得节点拖出边界、画布变大时比例跟着跳。
    @State private var dragScale: CGFloat = 1

    private let nodeSize = TopologyMetrics.nodeSize

    var body: some View {
        GeometryReader { proxy in
            let placed = livePositions()
            let edges = buildEdges(placed)
            let content = contentSize(placed)
            let scale = dragKey == nil ? fitScale(content, viewport: proxy.size) : dragScale
            let canvas = CGSize(
                width: max(content.width, proxy.size.width / scale),
                height: max(content.height, proxy.size.height / scale)
            )
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    DotGrid()
                        .frame(width: canvas.width, height: canvas.height)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = nil }
                    TopologyWires(edges: edges, theme: theme)
                        .frame(width: canvas.width, height: canvas.height)
                        .allowsHitTesting(false)
                    ForEach(Array(nodes(placed)), id: \.key) { item in
                        nodeView(item, scale: scale)
                            .position(
                                x: item.origin.x + nodeSize.width / 2,
                                y: item.origin.y + nodeSize.height / 2
                            )
                            .zIndex(dragKey == item.key ? 10 : 1)
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
            }
        }
        .background(Theme.canvas)
    }

    fileprivate struct NodeItem {
        var key: String
        var origin: CGPoint
        var kind: Kind
        enum Kind {
            case machine
            case vpn(VPNProfile)
            case jump(Jump)
            case forward(Forward)
        }

        var selection: Selection {
            switch kind {
            case .machine: return .machine
            case .vpn(let profile): return .vpn(profile.id)
            case .jump(let jump): return .jump(jump.id)
            case .forward(let forward): return .forward(forward.id)
            }
        }
    }

    private func nodes(_ placed: [String: CGPoint]) -> [NodeItem] {
        var items: [NodeItem] = [
            NodeItem(key: TopologyKey.machine, origin: placed[TopologyKey.machine] ?? TopologyMetrics.origin, kind: .machine),
        ]
        for vpn in model.config.vpns {
            let key = TopologyKey.vpn(vpn.id)
            items.append(NodeItem(key: key, origin: placed[key] ?? .zero, kind: .vpn(vpn)))
        }
        for jump in model.config.jumps {
            let key = TopologyKey.jump(jump.id)
            items.append(NodeItem(key: key, origin: placed[key] ?? .zero, kind: .jump(jump)))
        }
        for forward in model.config.forwards {
            let key = TopologyKey.forward(forward.id)
            items.append(NodeItem(key: key, origin: placed[key] ?? .zero, kind: .forward(forward)))
        }
        return items
    }

    private func livePositions() -> [String: CGPoint] {
        var placed = model.config.resolvedLayout()
        if let dragKey, let base = placed[dragKey] {
            placed[dragKey] = CGPoint(x: base.x + dragTranslation.width, y: base.y + dragTranslation.height)
        }
        return placed
    }

    private func contentSize(_ placed: [String: CGPoint]) -> CGSize {
        let maxX = placed.values.map { $0.x }.max() ?? 0
        let maxY = placed.values.map { $0.y }.max() ?? 0
        return CGSize(width: maxX + nodeSize.width + 28, height: maxY + nodeSize.height + 28)
    }

    /// 内容比可见区域大时整体缩小，最小 0.65；再放不下就滚动。
    private func fitScale(_ content: CGSize, viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let fit = min(viewport.width / content.width, viewport.height / content.height)
        return min(1, max(0.65, fit))
    }

    private func buildEdges(_ placed: [String: CGPoint]) -> [TopologyEdge] {
        var edges: [TopologyEdge] = []
        let machine = placed[TopologyKey.machine] ?? TopologyMetrics.origin
        let all = model.config.vpns
        let ids = Set(all.map(\.id))
        let roots = all.filter { vpn in
            guard let via = vpn.viaID else { return true }
            return !ids.contains(via)
        }
        var visited = Set<UUID>()

        func add(
            _ id: String,
            _ link: (from: CGPoint, to: CGPoint, fromSide: TopologySide, toSide: TopologySide),
            on: Bool,
            style: TopologyWireStyle = .curve
        ) {
            edges.append(TopologyEdge(id: id, from: link.from, to: link.to, fromSide: link.fromSide, toSide: link.toSide, on: on, style: style))
        }

        func emit(_ vpn: VPNProfile) {
            guard !visited.contains(vpn.id) else { return }
            visited.insert(vpn.id)
            guard let origin = placed[TopologyKey.vpn(vpn.id)] else { return }

            let children = model.config.vpns(via: vpn.id).filter { !visited.contains($0.id) }
            let childBiases = sideBiases(for: children.map { placed[TopologyKey.vpn($0.id)] ?? .zero }, parent: origin)
            for (index, child) in children.enumerated() {
                guard let childOrigin = placed[TopologyKey.vpn(child.id)] else { continue }
                let link = TopologyMetrics.link(from: origin, to: childOrigin, fromBias: childBiases[index], toBias: 0)
                add("w-\(vpn.id.uuidString)-\(child.id.uuidString)", link, on: model.isOn(vpn) && model.isOn(child))
                emit(child)
            }

            let jumps = model.config.jumps(on: vpn.id)
            let jumpBiases = sideBiases(for: jumps.map { placed[TopologyKey.jump($0.id)] ?? .zero }, parent: origin)
            for (jumpIndex, jump) in jumps.enumerated() {
                guard let jumpOrigin = placed[TopologyKey.jump(jump.id)] else { continue }
                let jumpLink = TopologyMetrics.link(from: origin, to: jumpOrigin, fromBias: jumpBiases[jumpIndex], toBias: 0)
                add("v-\(vpn.id.uuidString)-\(jump.id.uuidString)", jumpLink, on: model.isOn(jump))
                let forwards = model.config.forwards(on: jump.id)
                let hub = TopologyMetrics.rightPort(of: jumpOrigin)
                let railX = hub.x + TopologyMetrics.forwardRailInset
                for forward in forwards {
                    guard let tunnelOrigin = placed[TopologyKey.forward(forward.id)] else { continue }
                    let leaf = TopologyMetrics.leftPort(of: tunnelOrigin)
                    let style: TopologyWireStyle = forwards.count > 1 ? .rail(railX: railX) : .curve
                    let link = (
                        from: hub,
                        to: leaf,
                        fromSide: TopologySide.right,
                        toSide: TopologySide.left
                    )
                    add("j-\(jump.id.uuidString)-\(forward.id.uuidString)", link, on: model.status(of: forward).httpOK, style: style)
                }
            }
        }

        let rootBiases = sideBiases(for: roots.map { placed[TopologyKey.vpn($0.id)] ?? .zero }, parent: machine)
        for (index, vpn) in roots.enumerated() {
            guard let origin = placed[TopologyKey.vpn(vpn.id)] else { continue }
            let link = TopologyMetrics.link(from: machine, to: origin, fromBias: rootBiases[index], toBias: 0)
            add("m-\(vpn.id.uuidString)", link, on: model.isOn(vpn))
            emit(vpn)
        }
        return edges
    }

    /// 同一侧多个子节点时，沿边错开附着点，避免线叠在一起。
    private func sideBiases(for children: [CGPoint], parent: CGPoint) -> [CGFloat] {
        guard children.count > 1 else { return Array(repeating: 0, count: children.count) }
        let parentCenter = TopologyMetrics.center(of: parent)
        let ranked = children.enumerated().sorted { left, right in
            let a = TopologyMetrics.center(of: left.element)
            let b = TopologyMetrics.center(of: right.element)
            let dxA = abs(a.x - parentCenter.x)
            let dyA = abs(a.y - parentCenter.y)
            let dxB = abs(b.x - parentCenter.x)
            let dyB = abs(b.y - parentCenter.y)
            if dxA >= dyA, dxB >= dyB {
                return a.y < b.y
            }
            if dyA > dxA, dyB > dxB {
                return a.x < b.x
            }
            return a.y < b.y
        }
        var biases = Array(repeating: CGFloat(0), count: children.count)
        let step: CGFloat = 28
        let start = -step * CGFloat(children.count - 1) / 2
        for (rank, item) in ranked.enumerated() {
            biases[item.offset] = start + step * CGFloat(rank)
        }
        return biases
    }

    @ViewBuilder
    private func nodeView(_ item: NodeItem, scale: CGFloat) -> some View {
        let dragging = dragKey == item.key
        let look = NodeLook.make(item.kind, model: model, theme: theme)
        TopologyNode(look: look, selected: selection == item.selection)
            .opacity(dragging ? 0.9 : 1)
            .scaleEffect(dragging ? 1.03 : 1)
            .shadow(color: dragging ? Color.black.opacity(0.18) : .clear, radius: 10, y: 4)
            .gesture(dragGesture(for: item, scale: scale))
            .contextMenu {
                NodeMenu(model: model, selection: item.selection, pathEdit: pathEdit)
            }
            .help(look.title)
            .animation(.easeOut(duration: 0.12), value: dragging)
    }

    /// 手势的位移是屏幕上的点，画布缩放过，要除回画布坐标。
    private func dragGesture(for item: NodeItem, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("topology"))
            .onChanged { value in
                if dragKey == nil {
                    dragKey = item.key
                    dragOrigin = model.config.resolvedLayout()[item.key] ?? item.origin
                    dragScale = scale
                    didDrag = false
                }
                guard dragKey == item.key else { return }
                if hypot(value.translation.width, value.translation.height) > 6 {
                    didDrag = true
                    dragTranslation = CGSize(width: value.translation.width / dragScale, height: value.translation.height / dragScale)
                    NSCursor.closedHand.set()
                }
            }
            .onEnded { _ in
                defer {
                    dragKey = nil
                    dragTranslation = .zero
                    NSCursor.arrow.set()
                }
                guard dragKey == item.key else { return }
                if didDrag {
                    let next = CGPoint(
                        x: dragOrigin.x + dragTranslation.width,
                        y: dragOrigin.y + dragTranslation.height
                    )
                    commitDrag(item, to: next)
                }
                selection = item.selection
            }
    }

    private func commitDrag(_ item: NodeItem, to origin: CGPoint) {
        model.updateLayout(item.key, origin: origin)
        switch item.kind {
        case .forward(let forward):
            if let jump = nearestJump(to: TopologyMetrics.center(of: origin)) {
                model.reparentForward(forward.id, to: jump.id)
            }
        case .jump(let jump):
            if let vpn = nearestVPN(to: TopologyMetrics.center(of: origin)) {
                model.reparentJump(jump.id, to: vpn.id)
            }
        default:
            break
        }
    }

    private func nearestJump(to point: CGPoint) -> Jump? {
        let placed = model.config.resolvedLayout()
        return model.config.jumps
            .compactMap { jump -> (Jump, CGFloat)? in
                guard let origin = placed[TopologyKey.jump(jump.id)] else { return nil }
                let center = TopologyMetrics.center(of: origin)
                let distance = hypot(center.x - point.x, center.y - point.y)
                return distance < 120 ? (jump, distance) : nil
            }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

    private func nearestVPN(to point: CGPoint) -> VPNProfile? {
        let placed = model.config.resolvedLayout()
        return model.config.vpns
            .compactMap { vpn -> (VPNProfile, CGFloat)? in
                guard let origin = placed[TopologyKey.vpn(vpn.id)] else { return nil }
                let center = TopologyMetrics.center(of: origin)
                let distance = hypot(center.x - point.x, center.y - point.y)
                return distance < 140 ? (vpn, distance) : nil
            }
            .min(by: { $0.1 < $1.1 })?
            .0
    }
}

/// 节点长什么样：图标、名字、状态文字和颜色。图上、侧边栏和检查器共用。
struct NodeLook {
    var symbol: String
    var iconFile: String? = nil
    var pageURL: String? = nil
    var title: String
    var detail: String
    /// 图标/品牌色：通了也不一律用绿，按服务类型区分。
    var tint: Color
    /// 连通状态色：绿 / 橙 / 灰，只给状态点和说明文字。
    var status: Color
    var on: Bool

    @MainActor
    static func of(_ selection: Selection, model: AppModel, theme: Theme) -> NodeLook? {
        switch selection {
        case .machine:
            return make(.machine, model: model, theme: theme)
        case .vpn(let id):
            return model.config.vpns.first { $0.id == id }.map { make(.vpn($0), model: model, theme: theme) }
        case .jump(let id):
            return model.config.jumps.first { $0.id == id }.map { make(.jump($0), model: model, theme: theme) }
        case .forward(let id):
            return model.config.forwards.first { $0.id == id }.map { make(.forward($0), model: model, theme: theme) }
        }
    }

    @MainActor
    fileprivate static func make(_ kind: TopologyCanvas.NodeItem.Kind, model: AppModel, theme: Theme) -> NodeLook {
        switch kind {
        case .machine:
            return NodeLook(symbol: "laptopcomputer", title: model.config.machineName, detail: tr("这台 Mac", "This Mac"), tint: theme.text, status: theme.ok, on: true)
        case .vpn(let profile):
            let on = model.isOn(profile)
            let detail: String
            if profile.isSystemVPN {
                detail = on ? tr("已连接", "Connected") : tr("未连接", "Disconnected")
            } else if on {
                detail = model.vpn.phase.title
            } else {
                let host = model.vpnHost(profile)
                detail = host.isEmpty ? tr("未设置", "Not set") : host
            }
            let brand = vpnBrand(profile)
            let status: Color = !on ? theme.muted : (profile.isSystemVPN || model.vpn.phase == .up ? theme.ok : theme.warn)
            return NodeLook(symbol: vpnSymbol(profile), iconFile: Engine.systemVPNAppPath(kind: profile.kind), title: profile.name, detail: detail, tint: on ? brand : theme.muted, status: status, on: on)
        case .jump(let jump):
            let on = model.isOn(jump)
            return NodeLook(symbol: "server.rack", title: jump.name, detail: hostOnly(jump.host), tint: on ? Color(nsColor: .systemBrown) : theme.muted, status: on ? theme.ok : theme.muted, on: on)
        case .forward(let forward):
            let port = model.status(of: forward)
            // 已连通只显示端口，状态靠角标；多条转发时卡片更干净。
            let state: String
            if port.httpOK {
                state = ":\(forward.localPort)"
            } else if port.listening {
                state = ":\(forward.localPort) \(tr("无响应", "no response"))"
            } else {
                state = ":\(forward.localPort) \(tr("未连接", "off"))"
            }
            let brand = serviceBrand(forward, theme: theme)
            let status = port.httpOK ? theme.ok : (port.listening ? theme.warn : theme.muted)
            // TCP 目标（数据库等）没有网页图标；HTTP 才去抓 favicon。
            let pageURL = forward.check == .http ? port.browseURL : nil
            return NodeLook(
                symbol: serviceSymbol(forward),
                pageURL: pageURL,
                title: forward.name,
                detail: state,
                tint: port.httpOK || port.listening ? brand : theme.muted,
                status: status,
                on: port.httpOK
            )
        }
    }

    static func vpnSymbol(_ profile: VPNProfile) -> String {
        if profile.isShadowrocket { return "paperplane" }
        if profile.isForticlient { return "shield.lefthalf.filled" }
        return "lock.shield"
    }

    static func vpnBrand(_ profile: VPNProfile) -> Color {
        if profile.isShadowrocket { return Color(nsColor: .systemOrange) }
        if profile.isForticlient { return Color(nsColor: .systemRed) }
        return Color(nsColor: .systemBlue)
    }

    static func hostOnly(_ raw: String) -> String {
        if let host = raw.split(separator: "@").last, !host.isEmpty {
            return String(host)
        }
        return raw.isEmpty ? tr("未设置", "Not set") : raw
    }

    static func serviceSymbol(_ forward: Forward) -> String {
        serviceSymbol(name: forward.name, targetPort: forward.targetPort)
    }

    static func serviceSymbol(name: String, targetPort: Int = 0) -> String {
        let lower = name.lowercased()
        if lower.contains("git") { return "chevron.left.forwardslash.chevron.right" }
        if lower.contains("jump") { return "key.horizontal" }
        if lower.contains("gateway") || lower.contains("gw") || lower.contains("api") {
            return "network"
        }
        if lower.contains("db") || lower.contains("mysql") || lower.contains("postgres") || lower.contains("sql")
            || lower.contains("redis") || lower.contains("mongo")
            || [3306, 5432, 6379, 27017, 1433].contains(targetPort) {
            return "cylinder.split.1x2"
        }
        if targetPort == 443 || targetPort == 8443 { return "globe" }
        return "arrow.left.arrow.right"
    }

    static func serviceBrand(_ forward: Forward, theme: Theme) -> Color {
        serviceBrand(name: forward.name, targetPort: forward.targetPort, theme: theme)
    }

    static func serviceBrand(name: String, targetPort: Int = 0, theme: Theme) -> Color {
        let lower = name.lowercased()
        if lower.contains("git") { return Color(nsColor: .systemOrange) }
        if lower.contains("jump") { return Color(nsColor: .systemBrown) }
        if lower.contains("gateway") || lower.contains("gw") || lower.contains("api") || targetPort == 443 || targetPort == 8443 {
            return Color(nsColor: .systemIndigo)
        }
        if lower.contains("db") || lower.contains("mysql") || lower.contains("postgres") || lower.contains("sql")
            || lower.contains("redis") || lower.contains("mongo")
            || [3306, 5432, 6379, 27017, 1433].contains(targetPort) {
            return Color(nsColor: .systemTeal)
        }
        return theme.accent
    }
}

/// 图上的一个节点：横向小卡片，左边图标，右边名字和状态。
@MainActor
struct TopologyNode: View {
    var look: NodeLook
    var selected: Bool
    @Environment(\.netlinkTheme) private var theme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ServiceBadge(pageURL: look.pageURL, iconFile: look.iconFile, symbol: look.symbol, tint: look.tint, side: 28, ring: false)
                StatusDot(color: look.status)
                    .offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(look.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(look.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(look.status == theme.muted ? theme.muted : look.tint.opacity(0.9))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: TopologyMetrics.nodeSize.width, height: TopologyMetrics.nodeSize.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: Color.black.opacity(hovered ? 0.12 : 0.06), radius: hovered ? 4 : 1.5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? theme.accent : theme.line, lineWidth: selected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// 状态小圆点，外面一圈底色描边，压在图标角上也看得清。
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 1.5))
    }
}

/// 画布的点阵底。
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 18
            let color = Color(nsColor: .tertiaryLabelColor).opacity(0.35)
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)), with: .color(color))
                    x += step
                }
                y += step
            }
        }
    }
}

@MainActor
private struct TopologyWires: View {
    var edges: [TopologyEdge]
    var theme: Theme

    var body: some View {
        ZStack {
            ForEach(edges) { edge in
                TopologyWire(
                    from: edge.from,
                    to: edge.to,
                    fromSide: edge.fromSide,
                    toSide: edge.toSide,
                    on: edge.on,
                    style: edge.style,
                    theme: theme
                )
            }
        }
    }
}

@MainActor
private struct TopologyWire: View {
    var from: CGPoint
    var to: CGPoint
    var fromSide: TopologySide
    var toSide: TopologySide
    var on: Bool
    var style: TopologyWireStyle
    var theme: Theme

    var body: some View {
        let color = on ? theme.ok : theme.line
        switch style {
        case .curve:
            curve(color: color)
        case .rail(let railX):
            rail(railX: railX, color: color)
        }
    }

    @ViewBuilder
    private func curve(color: Color) -> some View {
        let span = hypot(to.x - from.x, to.y - from.y)
        let pull = max(28, min(72, span * 0.4))
        let c1 = TopologyMetrics.pull(from, side: fromSide, distance: pull)
        let c2 = TopologyMetrics.pull(to, side: toSide, distance: pull)
        let tipAngle = atan2(to.y - c2.y, to.x - c2.x)
        let tip = CGPoint(x: to.x - cos(tipAngle) * 1.5, y: to.y - sin(tipAngle) * 1.5)
        ZStack {
            Path { path in
                path.move(to: from)
                path.addCurve(to: tip, control1: c1, control2: c2)
            }
            .stroke(color, style: StrokeStyle(lineWidth: on ? 2 : 1.5, lineCap: .round, lineJoin: .round, dash: on ? [] : [4, 4]))
            ArrowHead(at: to, angle: tipAngle, color: color)
        }
    }

    @ViewBuilder
    private func rail(railX: CGFloat, color: Color) -> some View {
        let elbow = CGPoint(x: railX, y: from.y)
        let branch = CGPoint(x: railX, y: to.y)
        let tip = CGPoint(x: to.x - 1.5, y: to.y)
        ZStack {
            Path { path in
                path.move(to: from)
                path.addLine(to: elbow)
                path.addLine(to: branch)
                path.addLine(to: tip)
            }
            .stroke(color, style: StrokeStyle(lineWidth: on ? 2 : 1.5, lineCap: .round, lineJoin: .round, dash: on ? [] : [4, 4]))
            ArrowHead(at: to, angle: 0, color: color)
        }
    }
}

@MainActor
private struct ArrowHead: View {
    var at: CGPoint
    var angle: CGFloat
    var color: Color

    var body: some View {
        let length: CGFloat = 9
        let half: CGFloat = 4.5
        let cosA = cos(angle)
        let sinA = sin(angle)
        let base = CGPoint(x: at.x - cosA * length, y: at.y - sinA * length)
        let left = CGPoint(x: base.x + sinA * half, y: base.y - cosA * half)
        let right = CGPoint(x: base.x - sinA * half, y: base.y + cosA * half)
        Path { path in
            path.move(to: at)
            path.addLine(to: left)
            path.addLine(to: right)
            path.closeSubpath()
        }
        .fill(color)
    }
}

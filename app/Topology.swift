import AppKit
import SwiftUI

private struct TopologyEdge: Identifiable {
    var id: String
    var from: CGPoint
    var to: CGPoint
    var fromSide: TopologySide
    var toSide: TopologySide
    var on: Bool
}

struct TopologyCanvas: View {
    @Bindable var model: AppModel
    var pathEdit: Binding<PathEdit?>
    @Environment(\.netlinkTheme) private var theme

    @State private var dragKey: String?
    @State private var dragOrigin: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var didDrag = false
    @State private var menuKey: String?

    private let nodeSize = TopologyMetrics.nodeSize

    var body: some View {
        GeometryReader { proxy in
            let placed = livePositions()
            let edges = buildEdges(placed)
            let canvas = canvasSize(placed, viewport: proxy.size)
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: canvas.width, height: canvas.height)
                    TopologyWires(edges: edges, theme: theme)
                        .frame(width: canvas.width, height: canvas.height)
                        .allowsHitTesting(false)
                    ForEach(Array(nodes(placed)), id: \.key) { item in
                        nodeView(item)
                            .position(
                                x: item.origin.x + nodeSize.width / 2,
                                y: item.origin.y + nodeSize.height / 2
                            )
                            .zIndex(dragKey == item.key ? 10 : 1)
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
    }

    private struct NodeItem {
        var key: String
        var origin: CGPoint
        var kind: Kind
        enum Kind {
            case machine
            case vpn(VPNProfile)
            case jump(Jump)
            case forward(Forward)
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

    private func canvasSize(_ placed: [String: CGPoint], viewport: CGSize) -> CGSize {
        let maxX = placed.values.map { $0.x }.max() ?? 0
        let maxY = placed.values.map { $0.y }.max() ?? 0
        return CGSize(
            width: max(viewport.width, maxX + nodeSize.width + 48),
            height: max(viewport.height, maxY + nodeSize.height + 48)
        )
    }

    private func buildEdges(_ placed: [String: CGPoint]) -> [TopologyEdge] {
        var edges: [TopologyEdge] = []
        let machine = placed[TopologyKey.machine] ?? TopologyMetrics.origin
        let vpns = model.config.vpns
        let vpnBiases = sideBiases(for: vpns.map { placed[TopologyKey.vpn($0.id)] ?? .zero }, parent: machine)
        for (vpnIndex, vpn) in vpns.enumerated() {
            guard let origin = placed[TopologyKey.vpn(vpn.id)] else { continue }
            let link = TopologyMetrics.link(from: machine, to: origin, fromBias: vpnBiases[vpnIndex], toBias: 0)
            edges.append(TopologyEdge(
                id: "m-\(vpn.id.uuidString)",
                from: link.from,
                to: link.to,
                fromSide: link.fromSide,
                toSide: link.toSide,
                on: vpnOn(vpn)
            ))
            let jumps = model.config.jumps(on: vpn.id)
            let jumpBiases = sideBiases(for: jumps.map { placed[TopologyKey.jump($0.id)] ?? .zero }, parent: origin)
            for (jumpIndex, jump) in jumps.enumerated() {
                guard let jumpOrigin = placed[TopologyKey.jump(jump.id)] else { continue }
                let jumpLink = TopologyMetrics.link(from: origin, to: jumpOrigin, fromBias: jumpBiases[jumpIndex], toBias: 0)
                edges.append(TopologyEdge(
                    id: "v-\(vpn.id.uuidString)-\(jump.id.uuidString)",
                    from: jumpLink.from,
                    to: jumpLink.to,
                    fromSide: jumpLink.fromSide,
                    toSide: jumpLink.toSide,
                    on: jumpOn(jump)
                ))
                let forwards = model.config.forwards(on: jump.id)
                let tunnelBiases = sideBiases(for: forwards.map { placed[TopologyKey.forward($0.id)] ?? .zero }, parent: jumpOrigin)
                for (forwardIndex, forward) in forwards.enumerated() {
                    guard let tunnelOrigin = placed[TopologyKey.forward(forward.id)] else { continue }
                    let port = portStatus(forward)
                    let tunnelLink = TopologyMetrics.link(
                        from: jumpOrigin,
                        to: tunnelOrigin,
                        fromBias: tunnelBiases[forwardIndex],
                        toBias: 0
                    )
                    edges.append(TopologyEdge(
                        id: "j-\(jump.id.uuidString)-\(forward.id.uuidString)",
                        from: tunnelLink.from,
                        to: tunnelLink.to,
                        fromSide: tunnelLink.fromSide,
                        toSide: tunnelLink.toSide,
                        on: port.httpOK
                    ))
                }
            }
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
    private func nodeView(_ item: NodeItem) -> some View {
        let dragging = dragKey == item.key
        Group {
            switch item.kind {
            case .machine:
                PathNode(
                    symbol: "macbook",
                    title: model.config.machineName,
                    detail: "这台 Mac",
                    tint: theme.accent,
                    on: true,
                    externalHover: menuKey == item.key
                )
            case .vpn(let profile):
                let on = vpnOn(profile)
                PathNode(
                    symbol: vpnSymbol(profile, on: on),
                    iconFile: Engine.systemVPNAppPath(kind: profile.kind),
                    title: profile.name,
                    detail: vpnDetail(profile, on: on),
                    tint: on ? (profile.isSystemVPN ? theme.ok : phaseColor(model.vpn.phase)) : theme.muted,
                    on: on,
                    externalHover: menuKey == item.key
                )
            case .jump(let jump):
                PathNode(
                    symbol: "server.rack",
                    title: jump.name,
                    detail: hostOnly(jump.host),
                    tint: jumpOn(jump) ? theme.ok : phaseColor(model.tunnel.phase),
                    on: jumpOn(jump),
                    externalHover: menuKey == item.key
                )
            case .forward(let forward):
                let port = portStatus(forward)
                PathNode(
                    symbol: serviceSymbol(port.name),
                    pageURL: port.browseURL,
                    title: port.name,
                    detail: port.httpOK ? "已连接" : (port.listening ? "无响应" : "未连接"),
                    tint: port.httpOK ? theme.ok : (port.listening ? theme.warn : theme.bad),
                    on: port.httpOK,
                    externalHover: menuKey == item.key
                )
            }
        }
        .opacity(dragging ? 0.92 : 1)
        .scaleEffect(dragging ? 1.03 : 1)
        .shadow(color: dragging ? theme.accent.opacity(0.25) : .clear, radius: 10, y: 4)
        .gesture(dragGesture(for: item))
        .popover(isPresented: menuBinding(for: item.key), arrowEdge: .bottom) {
            menuContent(for: item)
                .themed()
        }
        .help(help(for: item))
        .animation(.easeOut(duration: 0.12), value: dragging)
    }

    private func menuBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { menuKey == key },
            set: { menuKey = $0 ? key : nil }
        )
    }

    private func dragGesture(for item: NodeItem) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("topology"))
            .onChanged { value in
                if dragKey == nil {
                    dragKey = item.key
                    dragOrigin = model.config.resolvedLayout()[item.key] ?? item.origin
                    didDrag = false
                }
                guard dragKey == item.key else { return }
                if hypot(value.translation.width, value.translation.height) > 6 {
                    didDrag = true
                    dragTranslation = value.translation
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
                } else {
                    menuKey = item.key
                }
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
                return distance < 150 ? (jump, distance) : nil
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
                // Prefer left-side / overlapping VPN by also checking x proximity
                return distance < 180 ? (vpn, distance) : nil
            }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

    @ViewBuilder
    private func menuContent(for item: NodeItem) -> some View {
        let dismiss = { menuKey = nil }
        switch item.kind {
        case .machine:
            machineMenu(dismiss: dismiss)
        case .vpn(let profile):
            vpnMenu(profile, dismiss: dismiss)
        case .jump(let jump):
            jumpMenu(jump, dismiss: dismiss)
        case .forward(let forward):
            TunnelActionList(port: portStatus(forward), model: model, dismiss: dismiss) {
                pathEdit.wrappedValue = .renameForward(forward.id)
            }
        }
    }

    private func help(for item: NodeItem) -> String {
        switch item.kind {
        case .machine: return model.config.machineName
        case .vpn(let profile): return profile.name
        case .jump(let jump): return jump.name
        case .forward(let forward): return "\(forward.name) 的操作"
        }
    }

    private func machineMenu(dismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TunnelActionRow(title: "改名", symbol: "pencil", tint: theme.text, spinning: false) {
                dismiss()
                pathEdit.wrappedValue = .renameMachine
            }
            TunnelActionRow(title: "添加 VPN", symbol: "plus", tint: theme.accent, spinning: false) {
                dismiss()
                pathEdit.wrappedValue = .addVPN
            }
        }
        .padding(6)
        .frame(width: 168)
        .background(theme.bg)
    }

    private func vpnMenu(_ profile: VPNProfile, dismiss: @escaping () -> Void) -> some View {
        if profile.isSystemVPN {
            return AnyView(systemVPNMenu(profile, dismiss: dismiss))
        }
        let alive = vpnOn(profile) && model.vpn.processAlive ? "在跑" : "没在跑"
        let route = model.vpn.routePresent ? "已有" : "没有"
        let gateway = model.vpn.gatewayReachable ? "通" : "不通"
        let host = Credentials.load(file: profile.credentialFile)?.host ?? ""
        return AnyView(VStack(alignment: .leading, spacing: 2) {
            menuNote(host.isEmpty ? "还没有主机" : host)
            menuNote("进程 \(alive) · 路由 \(route) · 网关 \(gateway)")
            menuRule()
            TunnelActionRow(title: "连接", symbol: "link", tint: theme.accent, spinning: model.job == .vpnConnect) {
                dismiss()
                model.connectVPNProfile(profile.id)
            }
            TunnelActionRow(title: "断开", symbol: "minus.circle", tint: theme.bad, spinning: model.job == .vpnDisconnect) {
                dismiss()
                model.disconnectVPNProfile(profile.id)
            }
            TunnelActionRow(title: "重启", symbol: "arrow.clockwise", tint: theme.text, spinning: model.job == .vpnRestart) {
                dismiss()
                model.restartVPNProfile(profile.id)
            }
            watchRows(
                owner: model.vpn.watch,
                takeoverSpinning: model.job == .vpnTakeover,
                enableSpinning: model.job == .vpnWatchOn,
                disableSpinning: model.job == .vpnWatchOff,
                dismiss: dismiss,
                takeover: { model.takeOverVPN() },
                enable: { model.setVPNWatch(true) },
                disable: { model.setVPNWatch(false) }
            )
            menuRule()
            TunnelActionRow(title: "改名", symbol: "pencil", tint: theme.text, spinning: false) {
                dismiss()
                pathEdit.wrappedValue = .renameVPN(profile.id)
            }
            TunnelActionRow(title: "修改账号", symbol: "person", tint: theme.accent, spinning: false) {
                dismiss()
                pathEdit.wrappedValue = .vpn(profile.id)
            }
            TunnelActionRow(title: "添加跳板", symbol: "plus", tint: theme.accent, spinning: false) {
                dismiss()
                pathEdit.wrappedValue = .addJump(profile.id)
            }
            if model.config.vpns.count > 1, profile.id != VPNProfile.primary, !profile.isSystemVPN {
                TunnelActionRow(title: "删除", symbol: "trash", tint: theme.bad, spinning: false) {
                    dismiss()
                    model.removeVPN(profile.id)
                }
            }
        }
        .padding(6)
        .frame(width: 228)
        .background(theme.bg))
    }

    private func systemVPNMenu(_ profile: VPNProfile, dismiss: @escaping () -> Void) -> some View {
        let on = vpnOn(profile)
        let whereFrom = profile.isForticlient ? "系统里的 FortiClient" : "系统里的 Shadowrocket"
        return VStack(alignment: .leading, spacing: 2) {
            menuNote(on ? "已连接" : "未连接")
            menuNote(whereFrom)
            if profile.isForticlient, !FortiClient.hasLogin() {
                menuNote("还没有密码")
            }
            menuRule()
            TunnelActionRow(title: "连接", symbol: "link", tint: theme.accent, spinning: model.job == .vpnConnect) {
                dismiss()
                model.connectVPNProfile(profile.id)
            }
            TunnelActionRow(title: "断开", symbol: "minus.circle", tint: theme.bad, spinning: model.job == .vpnDisconnect) {
                dismiss()
                model.disconnectVPNProfile(profile.id)
            }
            TunnelActionRow(title: "重启", symbol: "arrow.clockwise", tint: theme.text, spinning: model.job == .vpnRestart) {
                dismiss()
                model.restartVPNProfile(profile.id)
            }
            TunnelActionRow(title: "打开应用", symbol: "arrow.up.forward.app", tint: theme.accent, spinning: model.job == .vpnOpenApp) {
                dismiss()
                model.openSystemVPNApp(profile.id)
            }
            TunnelActionRow(title: "退出", symbol: "power", tint: theme.bad, spinning: model.job == .vpnQuitApp) {
                dismiss()
                model.quitSystemVPNApp(profile.id)
            }
            menuRule()
            if profile.isForticlient {
                TunnelActionRow(title: "修改账号", symbol: "person", tint: theme.accent, spinning: false) {
                    dismiss()
                    model.askFortiAccount(thenConnect: false)
                }
            }
            TunnelActionRow(title: "改名", symbol: "pencil", tint: theme.text, spinning: false) {
                dismiss()
                pathEdit.wrappedValue = .renameVPN(profile.id)
            }
        }
        .padding(6)
        .frame(width: 228)
        .background(theme.bg)
    }

    private func jumpMenu(_ jump: Jump, dismiss: @escaping () -> Void) -> some View {
        let keyOK = FileManager.default.isReadableFile(atPath: PathExpander.expand(jump.identityFile))
        let running = jumpOn(jump)
        return VStack(alignment: .leading, spacing: 2) {
            menuNote(jump.host.isEmpty ? "还没有跳板" : jump.host)
            menuNote("密钥 \(keyOK ? "可读" : "没有") · autossh \(running ? "在跑" : "没在跑")")
            menuRule()
            TunnelActionRow(title: "连接", symbol: "link", tint: theme.accent, spinning: model.job == .tunnelConnect) {
                dismiss()
                model.connectJump(jump.id)
            }
            TunnelActionRow(title: "断开", symbol: "minus.circle", tint: theme.bad, spinning: model.job == .tunnelDisconnect) {
                dismiss()
                model.disconnectJump(jump.id)
            }
            TunnelActionRow(title: "重启", symbol: "arrow.clockwise", tint: theme.text, spinning: model.job == .tunnelRestart) {
                dismiss()
                model.restartJump(jump.id)
            }
            watchRows(
                owner: model.tunnel.watch,
                takeoverSpinning: model.job == .tunnelTakeover,
                enableSpinning: model.job == .tunnelWatchOn,
                disableSpinning: model.job == .tunnelWatchOff,
                dismiss: dismiss,
                takeover: { model.takeOverTunnel() },
                enable: { model.setTunnelWatch(true) },
                disable: { model.setTunnelWatch(false) }
            )
            menuRule()
            TunnelActionRow(title: "改名", symbol: "pencil", tint: theme.text, spinning: false) {
                dismiss()
                pathEdit.wrappedValue = .renameJump(jump.id)
            }
            TunnelActionRow(title: "修改跳板", symbol: "server.rack", tint: theme.accent, spinning: false) {
                dismiss()
                pathEdit.wrappedValue = .jump(jump.id)
            }
            TunnelActionRow(title: "添加隧道", symbol: "plus", tint: theme.accent, spinning: false) {
                dismiss()
                pathEdit.wrappedValue = .addTunnel(jump.id)
            }
            if model.config.jumps.count > 1, model.config.forwards(on: jump.id).isEmpty {
                TunnelActionRow(title: "删除", symbol: "trash", tint: theme.bad, spinning: false) {
                    dismiss()
                    model.removeJump(jump.id)
                }
            }
        }
        .padding(6)
        .frame(width: 228)
        .background(theme.bg)
    }

    private func menuNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
    }

    private func menuRule() -> some View {
        Rectangle().fill(theme.line).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 8)
    }

    @ViewBuilder
    private func watchRows(
        owner: WatchdogOwner,
        takeoverSpinning: Bool,
        enableSpinning: Bool,
        disableSpinning: Bool,
        dismiss: @escaping () -> Void,
        takeover: @escaping () -> Void,
        enable: @escaping () -> Void,
        disable: @escaping () -> Void
    ) -> some View {
        switch owner {
        case .shell, .both:
            TunnelActionRow(title: "改由本应用守护", symbol: "arrow.triangle.2.circlepath", tint: theme.accent, spinning: takeoverSpinning) {
                dismiss()
                takeover()
            }
            TunnelActionRow(title: "停止自动重连", symbol: "pause.circle", tint: theme.bad, spinning: disableSpinning) {
                dismiss()
                disable()
            }
        case .app, .stale:
            TunnelActionRow(title: "停止自动重连", symbol: "pause.circle", tint: theme.bad, spinning: disableSpinning) {
                dismiss()
                disable()
            }
            if owner == .stale {
                TunnelActionRow(title: "重新拉起守护", symbol: "arrow.clockwise", tint: theme.accent, spinning: enableSpinning) {
                    dismiss()
                    enable()
                }
            }
        case .off:
            TunnelActionRow(title: "开启自动重连", symbol: "arrow.triangle.2.circlepath", tint: theme.accent, spinning: enableSpinning) {
                dismiss()
                enable()
            }
        }
    }

    private func vpnSymbol(_ profile: VPNProfile, on: Bool) -> String {
        if profile.isShadowrocket { return on ? "paperplane.fill" : "paperplane" }
        if profile.isForticlient { return on ? "shield.lefthalf.filled" : "shield" }
        return on ? "lock.shield.fill" : "lock.shield"
    }

    private func vpnOn(_ profile: VPNProfile) -> Bool {
        if profile.isSystemVPN { return model.vpn.systemUp.contains(profile.serviceName) }
        let host = Credentials.load(file: profile.credentialFile)?.host ?? ""
        let live = model.vpn.connectedHost
        if live.isEmpty {
            return model.config.vpns.filter { !$0.isSystemVPN }.count == 1 && model.vpn.phase == .up
        }
        return !host.isEmpty && (live == host || live.contains(host) || host.contains(live))
    }

    private func vpnDetail(_ profile: VPNProfile, on: Bool) -> String {
        if profile.isSystemVPN { return on ? "已连接" : "未连接" }
        if on { return model.vpn.phase.title }
        let host = Credentials.load(file: profile.credentialFile)?.host ?? ""
        return host.isEmpty ? "未设置" : host
    }

    private func jumpOn(_ jump: Jump) -> Bool {
        if model.tunnel.runningJumpHosts.contains(jump.host) { return true }
        return model.config.jumps.count == 1 && model.tunnel.autosshRunning
    }

    private func hostOnly(_ raw: String) -> String {
        if let host = raw.split(separator: "@").last, !host.isEmpty {
            return String(host)
        }
        return raw.isEmpty ? "未设置" : raw
    }

    private func portStatus(_ forward: Forward) -> PortStatus {
        if let found = model.tunnel.ports.first(where: { $0.localPort == forward.localPort }) {
            return found
        }
        return PortStatus(
            name: forward.name,
            localPort: forward.localPort,
            target: forward.target,
            browseLabel: forward.browseLabel,
            browseURL: forward.browseURL?.absoluteString ?? "",
            enabled: forward.enabled,
            listening: false,
            httpOK: false
        )
    }

    private func serviceSymbol(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("git") { return "chevron.left.forwardslash.chevron.right" }
        if lower.contains("jump") { return "key.horizontal" }
        return "rectangle.connected.to.line.below"
    }

    private func phaseColor(_ phase: LinkPhase) -> Color {
        switch phase {
        case .up: return theme.ok
        case .degraded, .checking: return theme.warn
        case .down: return theme.bad
        }
    }
}

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
                    theme: theme
                )
            }
        }
    }
}

private struct TopologyWire: View {
    var from: CGPoint
    var to: CGPoint
    var fromSide: TopologySide
    var toSide: TopologySide
    var on: Bool
    var theme: Theme

    var body: some View {
        let color = on ? theme.ok : theme.line
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
            .stroke(color, style: StrokeStyle(lineWidth: on ? 2 : 1.5, lineCap: .round, lineJoin: .round))
            ArrowHead(at: to, angle: tipAngle, color: color)
        }
    }
}

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

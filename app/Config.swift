import CoreGraphics
import Foundation

struct Forward: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var localPort: Int
    var targetHost: String
    var targetPort: Int
    /// 浏览器打开时用的主机名。空则用 127.0.0.1。GitLab 默认走内网域名。
    var openHost: String
    /// 为 false 时这条转发保持断开，自动重连也不会把它拉起来。
    var enabled: Bool
    /// 空则走主跳板。
    var jumpID: UUID?

    init(id: UUID = UUID(), name: String, localPort: Int, targetHost: String, targetPort: Int, openHost: String = "", enabled: Bool = true, jumpID: UUID? = nil) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.openHost = Self.resolvedOpenHost(name: name, openHost: openHost)
        self.enabled = enabled
        self.jumpID = jumpID
    }

    var target: String { "\(targetHost):\(targetPort)" }
    /// autossh -L 的参数，和 ~/.zsh/conf.d/06-ssh-tunnel.zsh 里的写法一致。
    var spec: String { "\(localPort):\(targetHost):\(targetPort)" }

    var browseHost: String {
        openHost.isEmpty ? "127.0.0.1" : openHost
    }

    var browseLabel: String {
        localPort == 80 ? browseHost : "\(browseHost):\(localPort)"
    }

    var browseURL: URL? {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = browseHost
        if localPort != 80 {
            parts.port = localPort
        }
        parts.path = "/"
        return parts.url
    }

    static let bundled: [Forward] = [
        Forward(name: "GitLab", localPort: 80, targetHost: "10.62.1.101", targetPort: 80, openHost: "git.techtanium.internal"),
        Forward(name: "JumpServer", localPort: 8080, targetHost: "10.62.1.10", targetPort: 80),
    ]

    private static func resolvedOpenHost(name: String, openHost: String) -> String {
        let trimmed = openHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if name == "GitLab" { return "git.techtanium.internal" }
        return ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, localPort, targetHost, targetPort, openHost, enabled, jumpID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "转发"
        localPort = try container.decodeIfPresent(Int.self, forKey: .localPort) ?? 0
        targetHost = try container.decodeIfPresent(String.self, forKey: .targetHost) ?? ""
        targetPort = try container.decodeIfPresent(Int.self, forKey: .targetPort) ?? 0
        let storedHost = try container.decodeIfPresent(String.self, forKey: .openHost) ?? ""
        openHost = Self.resolvedOpenHost(name: name, openHost: storedHost)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        jumpID = try container.decodeIfPresent(UUID.self, forKey: .jumpID)
    }
}

struct Jump: Codable, Equatable, Identifiable {
    static let primary = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!

    var id: UUID
    var name: String
    var host: String
    var identityFile: String
    /// 空则挂在主 VPN 下。
    var vpnID: UUID?

    init(id: UUID = UUID(), name: String, host: String, identityFile: String, vpnID: UUID? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.identityFile = identityFile
        self.vpnID = vpnID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, identityFile, vpnID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "跳板"
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        vpnID = try container.decodeIfPresent(UUID.self, forKey: .vpnID)
    }
}

struct LayoutPoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct VPNProfile: Codable, Equatable, Identifiable {
    static let primary = UUID(uuidString: "B1000000-0000-4000-8000-000000000001")!
    static let shadowrocket = UUID(uuidString: "C1000000-0000-4000-8000-000000000001")!
    static let forticlient = UUID(uuidString: "D1000000-0000-4000-8000-000000000001")!

    var id: UUID
    var name: String
    var credentialFile: String
    /// openconnect：公司 VPN。shadowrocket / forticlient：系统网络里的 VPN。
    var kind: String
    /// 系统 VPN 在 scutil 里的服务名。
    var serviceName: String
    /// 流量先经过的另一个 VPN（例如 Shadowrocket）。空则直接从本机出去。只用来画图和显示状态，不影响连接。
    var viaID: UUID?

    var isShadowrocket: Bool { kind == "shadowrocket" }
    var isForticlient: Bool { kind == "forticlient" }
    var isSystemVPN: Bool { isShadowrocket || isForticlient }

    init(id: UUID = UUID(), name: String, credentialFile: String, kind: String = "openconnect", serviceName: String = "", viaID: UUID? = nil) {
        self.id = id
        self.name = name
        self.credentialFile = credentialFile
        self.kind = kind
        self.serviceName = serviceName
        self.viaID = viaID
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, credentialFile, kind, serviceName, viaID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "VPN"
        credentialFile = try container.decodeIfPresent(String.self, forKey: .credentialFile) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "openconnect"
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName) ?? ""
        viaID = try container.decodeIfPresent(UUID.self, forKey: .viaID)
    }
}

struct AppConfig: Codable, Equatable {
    var credentialFile: String = "~/.internalvpn"
    var vpnPidFile: String = "~/.openconnect.pid"
    var vpnLogFile: String = "~/.vpn.log"
    var vpnWatchdogFile: String = "~/.openconnect.watchdog"
    var routeMarker: String = "172.16.88"
    var pingHost: String = "172.16.88.238"
    var reconnectTimeout: Int = 30
    var vpnWatchdogInterval: Int = 15
    var vpnFailThreshold: Int = 2

    var jumpHost: String = "appdev@10.62.11.31"
    var identityFile: String = "~/.ssh/appdev"
    var tunnelLogFile: String = "~/.tunnel.log"
    var tunnelWatchdogFile: String = "~/.tunnel.watchdog"
    var tunnelWatchdogInterval: Int = 20
    var forwards: [Forward] = Forward.bundled
    var jumps: [Jump] = [
        Jump(id: Jump.primary, name: "跳板", host: "appdev@10.62.11.31", identityFile: "~/.ssh/appdev"),
    ]
    var vpns: [VPNProfile] = [
        VPNProfile(id: VPNProfile.primary, name: "VPN", credentialFile: "~/.internalvpn"),
    ]

    var machineName: String = "本机"
    /// 拓扑图节点左上角坐标。键是 machine / vpn:<uuid> / jump:<uuid> / forward:<uuid>。
    var layout: [String: LayoutPoint] = [:]
    /// 默认布局的版本。旧配置是 0，打开应用时会排一次并记成当前版本。
    var layoutVersion: Int = AppConfig.layoutRevision
    var openconnectPath: String = "/opt/homebrew/bin/openconnect"
    var autosshPath: String = "/opt/homebrew/bin/autossh"

    static let layoutRevision = 1

    private enum CodingKeys: String, CodingKey {
        case credentialFile, vpnPidFile, vpnLogFile, vpnWatchdogFile
        case routeMarker, pingHost, reconnectTimeout, vpnWatchdogInterval, vpnFailThreshold
        case jumpHost, identityFile, tunnelLogFile, tunnelWatchdogFile, tunnelWatchdogInterval
        case forwards, jumps, vpns, machineName, layout, layoutVersion, openconnectPath, autosshPath
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        credentialFile = try container.decodeIfPresent(String.self, forKey: .credentialFile) ?? defaults.credentialFile
        vpnPidFile = try container.decodeIfPresent(String.self, forKey: .vpnPidFile) ?? defaults.vpnPidFile
        vpnLogFile = try container.decodeIfPresent(String.self, forKey: .vpnLogFile) ?? defaults.vpnLogFile
        vpnWatchdogFile = try container.decodeIfPresent(String.self, forKey: .vpnWatchdogFile) ?? defaults.vpnWatchdogFile
        routeMarker = try container.decodeIfPresent(String.self, forKey: .routeMarker) ?? defaults.routeMarker
        pingHost = try container.decodeIfPresent(String.self, forKey: .pingHost) ?? defaults.pingHost
        reconnectTimeout = try container.decodeIfPresent(Int.self, forKey: .reconnectTimeout) ?? defaults.reconnectTimeout
        vpnWatchdogInterval = try container.decodeIfPresent(Int.self, forKey: .vpnWatchdogInterval) ?? defaults.vpnWatchdogInterval
        vpnFailThreshold = try container.decodeIfPresent(Int.self, forKey: .vpnFailThreshold) ?? defaults.vpnFailThreshold
        jumpHost = try container.decodeIfPresent(String.self, forKey: .jumpHost) ?? defaults.jumpHost
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile) ?? defaults.identityFile
        tunnelLogFile = try container.decodeIfPresent(String.self, forKey: .tunnelLogFile) ?? defaults.tunnelLogFile
        tunnelWatchdogFile = try container.decodeIfPresent(String.self, forKey: .tunnelWatchdogFile) ?? defaults.tunnelWatchdogFile
        tunnelWatchdogInterval = try container.decodeIfPresent(Int.self, forKey: .tunnelWatchdogInterval) ?? defaults.tunnelWatchdogInterval
        forwards = try container.decodeIfPresent([Forward].self, forKey: .forwards) ?? defaults.forwards
        jumps = try container.decodeIfPresent([Jump].self, forKey: .jumps) ?? []
        vpns = try container.decodeIfPresent([VPNProfile].self, forKey: .vpns) ?? []
        machineName = try container.decodeIfPresent(String.self, forKey: .machineName) ?? defaults.machineName
        layout = try container.decodeIfPresent([String: LayoutPoint].self, forKey: .layout) ?? [:]
        layoutVersion = try container.decodeIfPresent(Int.self, forKey: .layoutVersion) ?? 0
        openconnectPath = try container.decodeIfPresent(String.self, forKey: .openconnectPath) ?? defaults.openconnectPath
        normalize()
        autosshPath = try container.decodeIfPresent(String.self, forKey: .autosshPath) ?? defaults.autosshPath
    }
}

enum TopologyKey {
    static let machine = "machine"
    static func vpn(_ id: UUID) -> String { "vpn:\(id.uuidString)" }
    static func jump(_ id: UUID) -> String { "jump:\(id.uuidString)" }
    static func forward(_ id: UUID) -> String { "forward:\(id.uuidString)" }
}

enum TopologySide {
    case left, right, top, bottom
}

enum TopologyMetrics {
    static let nodeSize = CGSize(width: 140, height: 112)
    static let columnGap: CGFloat = 76
    static let rowGap: CGFloat = 18
    static let origin = CGPoint(x: 32, y: 20)
    static let inset: CGFloat = 16

    static func center(of origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + nodeSize.width / 2, y: origin.y + nodeSize.height / 2)
    }

    static func rightPort(of origin: CGPoint) -> CGPoint {
        port(of: origin, side: .right)
    }

    static func leftPort(of origin: CGPoint) -> CGPoint {
        port(of: origin, side: .left)
    }

    /// 按两个节点中心的相对位置选出口和入口，上下左右都会用到。
    static func link(from originA: CGPoint, to originB: CGPoint, fromBias: CGFloat = 0, toBias: CGFloat = 0) -> (from: CGPoint, to: CGPoint, fromSide: TopologySide, toSide: TopologySide) {
        let a = center(of: originA)
        let b = center(of: originB)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let fromSide: TopologySide
        let toSide: TopologySide
        if abs(dx) >= abs(dy) {
            fromSide = dx >= 0 ? .right : .left
            toSide = dx >= 0 ? .left : .right
        } else {
            fromSide = dy >= 0 ? .bottom : .top
            toSide = dy >= 0 ? .top : .bottom
        }
        return (
            port(of: originA, side: fromSide, bias: fromBias),
            port(of: originB, side: toSide, bias: toBias),
            fromSide,
            toSide
        )
    }

    static func port(of origin: CGPoint, side: TopologySide, bias: CGFloat = 0) -> CGPoint {
        let midX = origin.x + nodeSize.width / 2
        let midY = origin.y + nodeSize.height / 2
        let minX = origin.x + inset
        let maxX = origin.x + nodeSize.width - inset
        let minY = origin.y + inset
        let maxY = origin.y + nodeSize.height - inset
        switch side {
        case .left:
            return CGPoint(x: origin.x, y: min(max(midY + bias, minY), maxY))
        case .right:
            return CGPoint(x: origin.x + nodeSize.width, y: min(max(midY + bias, minY), maxY))
        case .top:
            return CGPoint(x: min(max(midX + bias, minX), maxX), y: origin.y)
        case .bottom:
            return CGPoint(x: min(max(midX + bias, minX), maxX), y: origin.y + nodeSize.height)
        }
    }

    static func pull(_ point: CGPoint, side: TopologySide, distance: CGFloat) -> CGPoint {
        switch side {
        case .left: return CGPoint(x: point.x - distance, y: point.y)
        case .right: return CGPoint(x: point.x + distance, y: point.y)
        case .top: return CGPoint(x: point.x, y: point.y - distance)
        case .bottom: return CGPoint(x: point.x, y: point.y + distance)
        }
    }
}

enum ConfigCheck {
    static func issues(_ config: AppConfig) -> [String] {
        var found: [String] = []
        if config.jumps.isEmpty {
            found.append("至少保留一台跳板")
        }
        if config.vpns.isEmpty {
            found.append("至少保留一个 VPN")
        }
        for jump in config.jumps {
            if !jump.host.contains("@") || jump.host.hasPrefix("@") || jump.host.hasSuffix("@") {
                found.append("\(jump.name) 要写成 user@host")
            }
            if jump.identityFile.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append("\(jump.name) 缺少私钥")
            }
        }
        if config.machineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append("本机名称不能为空")
        }
        for vpn in config.vpns {
            if vpn.name.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append("VPN 名称不能为空")
            }
            if vpn.isSystemVPN {
                if vpn.serviceName.trimmingCharacters(in: .whitespaces).isEmpty {
                    found.append("\(vpn.name) 缺少系统 VPN 服务名")
                }
            } else if vpn.credentialFile.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append("\(vpn.name) 缺少凭据文件")
            }
        }
        for jump in config.jumps where jump.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append("跳板名称不能为空")
        }
        for forward in config.forwards where forward.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append("隧道名称不能为空")
        }
        if config.forwards.isEmpty {
            found.append("至少保留一条端口转发")
        }
        let ports = config.forwards.map(\.localPort)
        if Set(ports).count != ports.count {
            found.append("本地端口有重复")
        }
        for forward in config.forwards {
            if !(1...65535).contains(forward.localPort) || !(1...65535).contains(forward.targetPort) {
                found.append("\(forward.name) 的端口不在 1–65535")
            }
            if forward.targetHost.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append("\(forward.name) 缺少目标主机")
            }
        }
        if config.routeMarker.trimmingCharacters(in: .whitespaces).isEmpty || config.pingHost.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("VPN 路由标记和网关地址不能为空")
        }
        if config.vpnFailThreshold < 1 {
            found.append("VPN 连续失败次数至少为 1")
        }
        if config.vpnWatchdogInterval < 5 || config.tunnelWatchdogInterval < 5 {
            found.append("检查间隔至少 5 秒")
        }
        if config.reconnectTimeout < 0 {
            found.append("重连超时不能为负")
        }
        return found
    }
}

extension AppConfig {
    mutating func normalize() {
        if jumps.isEmpty {
            jumps = [Jump(id: Jump.primary, name: "跳板", host: jumpHost, identityFile: identityFile)]
        }
        if vpns.isEmpty {
            vpns = [VPNProfile(id: VPNProfile.primary, name: "VPN", credentialFile: credentialFile)]
        }
        if let primary = jumps.first(where: { $0.id == Jump.primary }) ?? jumps.first {
            jumpHost = primary.host
            identityFile = primary.identityFile
        }
        if let primary = vpns.first(where: { $0.id == VPNProfile.primary }) ?? vpns.first {
            credentialFile = primary.credentialFile
        }
        let ids = Set(vpns.map(\.id))
        for index in vpns.indices {
            if let via = vpns[index].viaID, via == vpns[index].id || !ids.contains(via) {
                vpns[index].viaID = nil
            }
        }
        for index in vpns.indices {
            var seen: Set<UUID> = [vpns[index].id]
            var cursor = vpns[index].viaID
            while let id = cursor {
                if seen.contains(id) {
                    vpns[index].viaID = nil
                    break
                }
                seen.insert(id)
                cursor = vpns.first { $0.id == id }?.viaID
            }
        }
    }

    /// 从这个 VPN 往上走，经过的所有上游 VPN。
    func upstreamIDs(of id: UUID) -> Set<UUID> {
        var found: Set<UUID> = []
        var cursor = vpns.first { $0.id == id }?.viaID
        while let next = cursor, !found.contains(next), next != id {
            found.insert(next)
            cursor = vpns.first { $0.id == next }?.viaID
        }
        return found
    }

    func vpns(via id: UUID) -> [VPNProfile] {
        vpns.filter { $0.viaID == id }
    }

    func jump(for forward: Forward) -> Jump {
        let id = forward.jumpID ?? Jump.primary
        return jumps.first { $0.id == id } ?? jumps[0]
    }

    func vpn(for jump: Jump) -> VPNProfile {
        let id = jump.vpnID ?? VPNProfile.primary
        return vpns.first { $0.id == id } ?? vpns[0]
    }

    func forwards(on jumpID: UUID) -> [Forward] {
        forwards.filter { ($0.jumpID ?? Jump.primary) == jumpID }
    }

    func jumps(on vpnID: UUID) -> [Jump] {
        jumps.filter { ($0.vpnID ?? VPNProfile.primary) == vpnID }
    }

    func layoutPoint(for key: String) -> CGPoint? {
        layout[key]?.point
    }

    mutating func setLayout(_ point: CGPoint, for key: String) {
        layout[key] = LayoutPoint(point)
    }

    /// 从左到右：本机、（上游 VPN）、VPN、跳板、隧道。有隧道的 VPN 放在中间，父节点相对子节点垂直居中。
    /// 每多一层上游，后面的列整体右移一列。
    func defaultLayout() -> [String: CGPoint] {
        let metrics = TopologyMetrics.self
        let nodeH = metrics.nodeSize.height
        let rowGap = metrics.rowGap
        let step = metrics.nodeSize.width + metrics.columnGap
        func column(_ index: Int) -> CGFloat { metrics.origin.x + CGFloat(index) * step }
        var placed: [String: CGPoint] = [:]

        func stackHeight(_ count: Int) -> CGFloat {
            guard count > 0 else { return 0 }
            return CGFloat(count) * nodeH + CGFloat(count - 1) * rowGap
        }

        struct JumpBlock {
            var id: UUID
            var height: CGFloat
            var forwards: [UUID]
        }
        struct VPNBlock {
            var id: UUID
            var height: CGFloat
            var span: CGFloat
            var hasJumps: Bool
            var children: [VPNBlock]
            var jumps: [JumpBlock]
        }

        var seen = Set<UUID>()
        func build(_ vpn: VPNProfile) -> VPNBlock {
            seen.insert(vpn.id)
            var children: [VPNBlock] = []
            for child in vpns where child.viaID == vpn.id && !seen.contains(child.id) {
                children.append(build(child))
            }
            var jumpBlocks: [JumpBlock] = []
            for jump in jumps(on: vpn.id) {
                let list = forwards(on: jump.id)
                let height = list.isEmpty ? nodeH : max(nodeH, stackHeight(list.count))
                jumpBlocks.append(JumpBlock(id: jump.id, height: height, forwards: list.map(\.id)))
            }
            let heights = children.map(\.height) + jumpBlocks.map(\.height)
            let span = heights.isEmpty ? 0 : heights.reduce(0, +) + CGFloat(heights.count - 1) * rowGap
            return VPNBlock(
                id: vpn.id,
                height: max(nodeH, span),
                span: span,
                hasJumps: !jumpBlocks.isEmpty || children.contains { $0.hasJumps },
                children: children,
                jumps: jumpBlocks
            )
        }

        let ids = Set(vpns.map(\.id))
        let roots = vpns.filter { vpn in
            guard let via = vpn.viaID else { return true }
            return !ids.contains(via)
        }
        var built = roots.map(build)
        for vpn in vpns where !seen.contains(vpn.id) {
            built.append(build(vpn))
        }
        let linked = built.filter(\.hasJumps)
        let alone = built.filter { !$0.hasJumps }
        let head = alone.count / 2
        let blocks = Array(alone.prefix(head)) + linked + Array(alone.dropFirst(head))

        func place(_ block: VPNBlock, depth: Int, top: CGFloat) {
            placed[TopologyKey.vpn(block.id)] = CGPoint(x: column(depth + 1), y: top + (block.height - nodeH) / 2)
            var cursor = top + (block.height - block.span) / 2
            for child in block.children {
                place(child, depth: depth + 1, top: cursor)
                cursor += child.height + rowGap
            }
            for jump in block.jumps {
                placed[TopologyKey.jump(jump.id)] = CGPoint(x: column(depth + 2), y: cursor + (jump.height - nodeH) / 2)
                var forwardCursor = cursor + (jump.height - stackHeight(jump.forwards.count)) / 2
                for id in jump.forwards {
                    placed[TopologyKey.forward(id)] = CGPoint(x: column(depth + 3), y: forwardCursor)
                    forwardCursor += nodeH + rowGap
                }
                cursor += jump.height + rowGap
            }
        }

        let total = blocks.isEmpty
            ? nodeH
            : blocks.map(\.height).reduce(0, +) + CGFloat(max(blocks.count - 1, 0)) * rowGap
        var cursor = metrics.origin.y
        for block in blocks {
            place(block, depth: 0, top: cursor)
            cursor += block.height + rowGap
        }

        placed[TopologyKey.machine] = CGPoint(x: column(0), y: metrics.origin.y + max(0, (total - nodeH) / 2))

        var spill = cursor
        for jump in jumps where placed[TopologyKey.jump(jump.id)] == nil {
            placed[TopologyKey.jump(jump.id)] = CGPoint(x: column(2), y: spill)
            spill += nodeH + rowGap
        }
        for forward in forwards where placed[TopologyKey.forward(forward.id)] == nil {
            placed[TopologyKey.forward(forward.id)] = CGPoint(x: column(3), y: spill)
            spill += nodeH + rowGap
        }
        return placed
    }

    func resolvedLayout() -> [String: CGPoint] {
        var placed = defaultLayout()
        for (key, point) in layout {
            placed[key] = point.point
        }
        return placed
    }
}

struct VPNCredential {
    var host: String
    var user: String
    var password: String
}

enum Credentials {
    static func parse(_ text: String) -> VPNCredential? {
        var host = ""
        var user = ""
        var password: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let index = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<index])
            let value = String(line[line.index(after: index)...])
            switch key {
            case "host": host = value.trimmingCharacters(in: .whitespaces)
            case "user": user = value.trimmingCharacters(in: .whitespaces)
            case "password": password = value
            default: break
            }
        }
        guard !host.isEmpty, !user.isEmpty, let password, !password.isEmpty else { return nil }
        return VPNCredential(host: host, user: user, password: password)
    }

    static func load(file: String) -> VPNCredential? {
        let path = PathExpander.expand(file)
        guard let text = Shell.readSmall(path) else { return nil }
        return parse(text)
    }

    /// 只在用户点了「更新账号」时写文件。密码留空则保留原密码。写完把权限收成 600。
    static func update(file: String, host: String, user: String, newPassword: String?) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else {
            throw CredentialError.emptyAccount
        }
        let existing = load(file: file)
        let password: String
        if let newPassword, !newPassword.isEmpty {
            password = newPassword
        } else if let existing {
            password = existing.password
        } else {
            throw CredentialError.missingPassword
        }
        let path = PathExpander.expand(file)
        let text = "host=\(trimmedHost)\nuser=\(trimmedUser)\npassword=\(password)\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

enum CredentialError: LocalizedError {
    case emptyAccount
    case missingPassword

    var errorDescription: String? {
        switch self {
        case .emptyAccount: return "主机和用户名不能为空"
        case .missingPassword: return "凭据文件里还没有密码，需要填写一次"
        }
    }
}

enum AppearanceChoice: String {
    case system
    case dark
    case light

    static func parse(_ raw: String?) -> AppearanceChoice {
        guard let raw, let choice = AppearanceChoice(rawValue: raw) else { return .system }
        return choice
    }

    static var current: AppearanceChoice {
        parse(UserDefaults.standard.string(forKey: Prefs.appearanceKey))
    }
}

enum Prefs {
    static let appearanceKey = "netlink.appearance"
    private static let vpnKey = "netlink.vpnAutoReconnect"
    private static let tunnelKey = "netlink.tunnelAutoReconnect"

    static var vpnAutoReconnect: Bool {
        get {
            if UserDefaults.standard.object(forKey: vpnKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: vpnKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: vpnKey) }
    }

    static var tunnelAutoReconnect: Bool {
        get {
            if UserDefaults.standard.object(forKey: tunnelKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: tunnelKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: tunnelKey) }
    }
}

enum ConfigStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NetLink", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("config.json") }
    static var wantedPath: String { directory.appendingPathComponent("service.wanted").path }
    static var servicePIDPath: String { directory.appendingPathComponent("service.pid").path }
    static var serviceLogPath: String { directory.appendingPathComponent("service.log").path }
    static var lockPath: String { directory.appendingPathComponent("operation.lock").path }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func load() -> AppConfig {
        ensureDir()
        guard FileManager.default.fileExists(atPath: file.path) else {
            let config = AppConfig()
            try? save(config)
            return config
        }
        return loadIfValid() ?? AppConfig()
    }

    static func loadIfValid() -> AppConfig? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    static func save(_ config: AppConfig) throws {
        ensureDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func setWanted(_ on: Bool) {
        ensureDir()
        if on {
            FileManager.default.createFile(atPath: wantedPath, contents: Data("1\n".utf8))
        } else {
            try? FileManager.default.removeItem(atPath: wantedPath)
        }
    }

    static var wanted: Bool {
        FileManager.default.fileExists(atPath: wantedPath)
    }
}

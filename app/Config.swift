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
    /// 怎么判断这条转发是通的。http：请求一次 HTTP，端到端；tcp：只看本地端口能不能连上，
    /// 给不是 HTTP 的目标（数据库、SSH 等）用。tcp 只能说明 autossh 在听，不代表远端可达。
    var check: ForwardCheck

    init(id: UUID = UUID(), name: String, localPort: Int, targetHost: String, targetPort: Int, openHost: String = "", enabled: Bool = true, jumpID: UUID? = nil, check: ForwardCheck = .http) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.openHost = Self.resolvedOpenHost(name: name, openHost: openHost)
        self.enabled = enabled
        self.jumpID = jumpID
        self.check = check
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

    /// 首次启动时的示例，换成自己的目标即可。
    static var example: [Forward] {
        [Forward(name: tr("示例网站", "Example site"), localPort: 8080, targetHost: "10.0.0.10", targetPort: 80)]
    }

    private static func resolvedOpenHost(name: String, openHost: String) -> String {
        openHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, localPort, targetHost, targetPort, openHost, enabled, jumpID, check
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = L10n.localizedDefault(try container.decodeIfPresent(String.self, forKey: .name) ?? tr("转发", "Forward"))
        localPort = try container.decodeIfPresent(Int.self, forKey: .localPort) ?? 0
        targetHost = try container.decodeIfPresent(String.self, forKey: .targetHost) ?? ""
        targetPort = try container.decodeIfPresent(Int.self, forKey: .targetPort) ?? 0
        let storedHost = try container.decodeIfPresent(String.self, forKey: .openHost) ?? ""
        openHost = Self.resolvedOpenHost(name: name, openHost: storedHost)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        jumpID = try container.decodeIfPresent(UUID.self, forKey: .jumpID)
        check = try container.decodeIfPresent(ForwardCheck.self, forKey: .check) ?? .http
    }
}

enum ForwardCheck: String, Codable {
    case http
    case tcp
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
        name = L10n.localizedDefault(try container.decodeIfPresent(String.self, forKey: .name) ?? tr("跳板", "Jump host"))
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
    /// 连上 VPN 后 netstat -rn 里应该出现的网段片段。
    var routeMarker: String = "10.0.0"
    /// VPN 连通性探测。写 `主机:端口` 用 TCP 连接，不带端口则 ping（很多内网主机不回 ICMP）。
    var pingHost: String = "10.0.0.1:22"
    var reconnectTimeout: Int = 30
    var vpnWatchdogInterval: Int = 15
    var vpnFailThreshold: Int = 2

    var jumpHost: String = "user@jump.example.com"
    var identityFile: String = "~/.ssh/id_ed25519"
    var tunnelLogFile: String = "~/.tunnel.log"
    var tunnelWatchdogFile: String = "~/.tunnel.watchdog"
    var tunnelWatchdogInterval: Int = 20
    /// 隧道连续几次检查不通才重启。一次偶发超时不应该把全部转发拆掉重连。
    var tunnelFailThreshold: Int = 2
    var forwards: [Forward] = Forward.example
    var jumps: [Jump] = [
        Jump(id: Jump.primary, name: tr("跳板", "Jump host"), host: "user@jump.example.com", identityFile: "~/.ssh/id_ed25519"),
    ]
    var vpns: [VPNProfile] = [
        VPNProfile(id: VPNProfile.primary, name: "VPN", credentialFile: "~/.internalvpn"),
    ]

    var machineName: String = tr("本机", "Local")
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
        case jumpHost, identityFile, tunnelLogFile, tunnelWatchdogFile, tunnelWatchdogInterval, tunnelFailThreshold
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
        tunnelFailThreshold = try container.decodeIfPresent(Int.self, forKey: .tunnelFailThreshold) ?? defaults.tunnelFailThreshold
        forwards = try container.decodeIfPresent([Forward].self, forKey: .forwards) ?? defaults.forwards
        jumps = try container.decodeIfPresent([Jump].self, forKey: .jumps) ?? []
        vpns = try container.decodeIfPresent([VPNProfile].self, forKey: .vpns) ?? []
        machineName = L10n.localizedDefault(try container.decodeIfPresent(String.self, forKey: .machineName) ?? defaults.machineName)
        layout = try container.decodeIfPresent([String: LayoutPoint].self, forKey: .layout) ?? [:]
        layoutVersion = try container.decodeIfPresent(Int.self, forKey: .layoutVersion) ?? 0
        openconnectPath = try container.decodeIfPresent(String.self, forKey: .openconnectPath) ?? defaults.openconnectPath
        autosshPath = try container.decodeIfPresent(String.self, forKey: .autosshPath) ?? defaults.autosshPath
        normalize()
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
            found.append(tr("至少保留一台跳板", "Keep at least one jump host"))
        }
        if config.vpns.isEmpty {
            found.append(tr("至少保留一个 VPN", "Keep at least one VPN"))
        }
        for jump in config.jumps {
            if !jump.host.contains("@") || jump.host.hasPrefix("@") || jump.host.hasSuffix("@") {
                found.append(tr("\(jump.name) 要写成 user@host", "\(jump.name) must be written as user@host"))
            }
            if jump.host.hasPrefix("-") || jump.host.contains(where: \.isWhitespace) || jump.identityFile.hasPrefix("-") {
                found.append(tr("\(jump.name) 的主机或密钥不能以 - 开头，也不能含空白", "The host or key of \(jump.name) can't start with - or contain whitespace"))
            }
            if jump.identityFile.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append(tr("\(jump.name) 缺少私钥", "\(jump.name) has no private key"))
            }
        }
        if config.machineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(tr("本机名称不能为空", "The name of this Mac can't be empty"))
        }
        for vpn in config.vpns {
            if vpn.name.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append(tr("VPN 名称不能为空", "VPN name can't be empty"))
            }
            if vpn.isSystemVPN {
                if vpn.serviceName.trimmingCharacters(in: .whitespaces).isEmpty {
                    found.append(tr("\(vpn.name) 缺少系统 VPN 服务名", "\(vpn.name) has no system VPN service name"))
                }
            } else if vpn.credentialFile.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append(tr("\(vpn.name) 缺少凭据文件", "\(vpn.name) has no credential file"))
            }
        }
        for jump in config.jumps where jump.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(tr("跳板名称不能为空", "Jump host name can't be empty"))
        }
        for forward in config.forwards where forward.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append(tr("隧道名称不能为空", "Tunnel name can't be empty"))
        }
        if config.forwards.isEmpty {
            found.append(tr("至少保留一条端口转发", "Keep at least one port forward"))
        }
        let ports = config.forwards.map(\.localPort)
        if Set(ports).count != ports.count {
            found.append(tr("本地端口有重复", "Local ports must be unique"))
        }
        for forward in config.forwards {
            if !(1...65535).contains(forward.localPort) || !(1...65535).contains(forward.targetPort) {
                found.append(tr("\(forward.name) 的端口不在 1–65535", "The port of \(forward.name) must be within 1–65535"))
            }
            if forward.targetHost.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append(tr("\(forward.name) 缺少目标主机", "\(forward.name) has no target host"))
            } else if forward.targetHost.hasPrefix("-") || !forward.targetHost.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) {
                found.append(tr("\(forward.name) 的目标主机只能含字母、数字、点和横线", "The target host of \(forward.name) may only contain letters, digits, dots and hyphens"))
            }
        }
        if config.routeMarker.trimmingCharacters(in: .whitespaces).isEmpty || config.pingHost.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append(tr("VPN 路由标记和网关地址不能为空", "VPN route marker and gateway address can't be empty"))
        }
        for (label, path, suffix) in [
            (tr("VPN 进程文件", "VPN pid file"), config.vpnPidFile, ".pid"),
            (tr("VPN 日志", "VPN log"), config.vpnLogFile, ".log"),
            (tr("隧道日志", "Tunnel log"), config.tunnelLogFile, ".log"),
        ] where !SudoPath.allowed(PathExpander.expand(path)) {
            found.append(tr("\(label) 必须在家目录下，以 \(suffix) 结尾，且不是符号链接", "\(label) must be inside your home folder, end with \(suffix), and not be a symlink"))
        }
        if config.vpnFailThreshold < 1 || config.tunnelFailThreshold < 1 {
            found.append(tr("连续失败次数至少为 1", "Failure threshold must be at least 1"))
        }
        if config.vpnWatchdogInterval < 5 || config.tunnelWatchdogInterval < 5 {
            found.append(tr("检查间隔至少 5 秒", "Check interval must be at least 5 seconds"))
        }
        if config.reconnectTimeout < 0 {
            found.append(tr("重连超时不能为负", "Reconnect timeout can't be negative"))
        }
        return found
    }
}

extension AppConfig {
    mutating func normalize() {
        if jumps.isEmpty {
            jumps = [Jump(id: Jump.primary, name: tr("跳板", "Jump host"), host: jumpHost, identityFile: identityFile)]
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

    var primaryJump: Jump {
        jumps.first { $0.id == Jump.primary } ?? jumps.first
            ?? Jump(id: Jump.primary, name: tr("跳板", "Jump host"), host: jumpHost, identityFile: identityFile)
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
            let key = String(line[..<index]).trimmingCharacters(in: .whitespaces)
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
        for value in [trimmedHost, trimmedUser, password] where value.contains(where: \.isNewline) {
            throw CredentialError.invalidCharacter
        }
        let path = PathExpander.expand(file)
        let text = "host=\(trimmedHost)\nuser=\(trimmedUser)\npassword=\(password)\n"
        try writePrivate(Data(text.utf8), to: path)
    }

    /// 先在同一目录里以 0600 建临时文件再改名，密码不会有哪怕一瞬间是别人可读的。
    static func writePrivate(_ data: Data, to path: String) throws {
        let temp = "\(path).tmp.\(getpid())"
        _ = unlink(temp)
        let fd = Darwin.open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CredentialError.writeFailed(String(cString: strerror(errno))) }
        var written = 0
        let ok = data.withUnsafeBytes { buffer -> Bool in
            while written < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += n
            }
            return true
        }
        let synced = ok && fsync(fd) == 0
        Darwin.close(fd)
        guard synced, rename(temp, path) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = unlink(temp)
            throw CredentialError.writeFailed(reason)
        }
    }
}

enum CredentialError: LocalizedError {
    case emptyAccount
    case missingPassword
    case invalidCharacter
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyAccount: return tr("主机和用户名不能为空", "Host and user name can't be empty")
        case .missingPassword: return tr("凭据文件里还没有密码，需要填写一次", "The credential file has no password yet. Enter it once")
        case .invalidCharacter: return tr("主机、用户名和密码里不能有换行", "Host, user name and password can't contain line breaks")
        case .writeFailed(let reason): return tr("写不进凭据文件：\(reason)", "Can't write the credential file: \(reason)")
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

enum ConfigError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        tr("配置文件读不了，已保留原文件。先修好它，或在应用里点保存覆盖（会先备份成 config.json.bak）", "Can't read the config file; the original is kept. Fix it, or click Save in the app to overwrite it (a backup is saved as config.json.bak first)")
    }
}

enum ConfigStore {
    /// 后台操作和界面都会读改写配置。递归锁：mutate 里面还会调 save。
    private static let writeLock = NSRecursiveLock()

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NetLink", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("config.json") }
    static var wantedPath: String { directory.appendingPathComponent("service.wanted").path }
    static var servicePIDPath: String { directory.appendingPathComponent("service.pid").path }
    static var serviceLogPath: String { directory.appendingPathComponent("service.log").path }
    static var lockPath: String { directory.appendingPathComponent("operation.lock").path }
    /// 守护重启 VPN 时用哪份凭据：最近一次连上的那个。
    static var activeCredentialPath: String { directory.appendingPathComponent("vpn.credential").path }

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 文件在，但解不出来。这时 load() 给的是默认值，不能拿它去覆盖原文件，也不该拿它去连接。
    static var isCorrupt: Bool {
        FileManager.default.fileExists(atPath: file.path) && loadIfValid() == nil
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

    /// 原文件解不出来时默认拒绝写入。用户在界面里明确点保存才允许覆盖，并先留一份备份。
    static func save(_ config: AppConfig, overwriteCorrupt: Bool = false) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        ensureDir()
        if isCorrupt {
            guard overwriteCorrupt else { throw ConfigError.unreadable }
            let backup = directory.appendingPathComponent("config.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: file, to: backup)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// 读最新的、改、写，整个过程互斥。后台操作改配置都走这里，不要自己 load 再 save。
    @discardableResult
    static func mutate(_ body: (inout AppConfig) -> Void) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isCorrupt else { return false }
        var config = load()
        body(&config)
        return (try? save(config)) != nil
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

// MARK: - 配置导入导出

/// 随配置一起带走的机密：VPN 账号（按 VPN 的 id）和 SSH 私钥内容（按跳板的 id）。
struct ImportedSecrets {
    var credentials: [UUID: VPNCredential] = [:]
    var keys: [UUID: String] = [:]
    var isEmpty: Bool { credentials.isEmpty && keys.isEmpty }
}

struct ImportPreview {
    var config: AppConfig
    var issues: [String]
    var secrets: ImportedSecrets
    /// 配置里指向的凭据文件在这台机器上不存在，而文件里也没带账号：导入后要重新填。
    var missingCredentials: [String]

    var summary: String {
        var text = tr("\(config.vpns.count) 个 VPN · \(config.jumps.count) 台跳板 · \(config.forwards.count) 条转发", "\(config.vpns.count) VPN · \(config.jumps.count) jump hosts · \(config.forwards.count) forwards")
        if !secrets.isEmpty {
            text += tr(" · 含 \(secrets.credentials.count) 个账号、\(secrets.keys.count) 把私钥", " · includes \(secrets.credentials.count) accounts, \(secrets.keys.count) private keys")
        }
        return text
    }
}

enum ConfigTransferError: LocalizedError {
    case notNetLinkConfig
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notNetLinkConfig: return tr("这不是 NetLink 的配置文件", "This isn't a NetLink config file")
        case .unreadable(let reason): return tr("读不了这个文件：\(reason)", "Can't read this file: \(reason)")
        }
    }
}

/// 配置的导出和导入。
///
/// 导出时可以把 VPN 账号的内容和 SSH 私钥的内容直接写进文件，换一台机器导入就能用，
/// 不用再去拷凭据文件和密钥。这样的文件里是明文密码和私钥，要当密码一样保管。
///
/// 导入时机密不会写回文件里写的路径（那是任意路径，等于让别人的文件往你的家目录里写东西），
/// 而是存进应用自己的数据目录，再把配置里的路径指过去。
enum ConfigTransfer {
    private static let knownKeys: Set<String> = ["forwards", "jumps", "vpns", "jumpHost", "credentialFile", "routeMarker", "pingHost"]
    private static let maxKeyBytes = 64 * 1024

    /// 家目录下的路径写成 `~/...`，换一台机器、换一个用户名也指得对。
    static func portable(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let expanded = PathExpander.expand(path)
        if expanded == home { return "~" }
        if expanded.hasPrefix(home + "/") { return "~" + expanded.dropFirst(home.count) }
        return path
    }

    static func export(_ config: AppConfig, includeSecrets: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(config)
        guard var root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw ConfigTransferError.notNetLinkConfig
        }

        var vpns = (root["vpns"] as? [[String: Any]]) ?? []
        for index in vpns.indices {
            guard let path = vpns[index]["credentialFile"] as? String else { continue }
            if includeSecrets, !path.isEmpty,
               let credential = Credentials.load(file: path) {
                vpns[index]["credential"] = [
                    "host": credential.host,
                    "user": credential.user,
                    "password": credential.password,
                ]
                vpns[index].removeValue(forKey: "credentialFile")
            } else {
                vpns[index]["credentialFile"] = portable(path)
            }
        }
        root["vpns"] = vpns

        var jumps = (root["jumps"] as? [[String: Any]]) ?? []
        for index in jumps.indices {
            guard let path = jumps[index]["identityFile"] as? String else { continue }
            if includeSecrets, !path.isEmpty,
               let key = try? String(contentsOfFile: PathExpander.expand(path), encoding: .utf8),
               key.utf8.count <= maxKeyBytes, key.contains("PRIVATE KEY") {
                jumps[index]["identity"] = key
                jumps[index].removeValue(forKey: "identityFile")
            } else {
                jumps[index]["identityFile"] = portable(path)
            }
        }
        root["jumps"] = jumps

        // 顶层这两项只是主 VPN / 主跳板的镜像，导入时会从它们那里重新算出来。
        if includeSecrets {
            root.removeValue(forKey: "credentialFile")
            root.removeValue(forKey: "identityFile")
        } else {
            for key in ["credentialFile", "identityFile"] {
                if let value = root[key] as? String { root[key] = portable(value) }
            }
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func write(_ config: AppConfig, to url: URL, includeSecrets: Bool = false) throws {
        try export(config, includeSecrets: includeSecrets).write(to: url, options: .atomic)
        // 里面有主机名和路径，带机密的更不能让别的用户读到。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 配置的解码对缺字段很宽容（`{}` 也能解出一份默认值），所以先确认它确实像 NetLink 的配置，
    /// 免得随便一个 JSON 文件就把当前配置换成默认值。
    static func parse(_ data: Data) throws -> ImportPreview {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !knownKeys.isDisjoint(with: root.keys) else {
            throw ConfigTransferError.notNetLinkConfig
        }

        var secrets = ImportedSecrets()
        var problems: [String] = []
        var vpns = (root["vpns"] as? [[String: Any]]) ?? []
        for index in vpns.indices {
            guard let embedded = vpns[index]["credential"] as? [String: Any] else { continue }
            vpns[index].removeValue(forKey: "credential")
            let name = vpns[index]["name"] as? String ?? "VPN"
            guard let idText = vpns[index]["id"] as? String, let id = UUID(uuidString: idText) else {
                problems.append(tr("\(name) 的账号没有有效的 id", "The account of \(name) has no valid id"))
                continue
            }
            let host = (embedded["host"] as? String) ?? ""
            let user = (embedded["user"] as? String) ?? ""
            let password = (embedded["password"] as? String) ?? ""
            if host.isEmpty || user.isEmpty || password.isEmpty {
                problems.append(tr("\(name) 的账号不完整", "The account of \(name) is incomplete"))
            } else if [host, user, password].contains(where: { $0.contains(where: \.isNewline) }) {
                problems.append(tr("\(name) 的账号里有换行", "The account of \(name) contains a line break"))
            } else {
                secrets.credentials[id] = VPNCredential(host: host, user: user, password: password)
            }
        }
        root["vpns"] = vpns

        var jumps = (root["jumps"] as? [[String: Any]]) ?? []
        for index in jumps.indices {
            guard let key = jumps[index]["identity"] as? String else { continue }
            jumps[index].removeValue(forKey: "identity")
            let name = jumps[index]["name"] as? String ?? tr("跳板", "Jump host")
            guard let idText = jumps[index]["id"] as? String, let id = UUID(uuidString: idText) else {
                problems.append(tr("\(name) 的私钥没有有效的 id", "The private key of \(name) has no valid id"))
                continue
            }
            if !key.contains("PRIVATE KEY") || key.utf8.count > maxKeyBytes {
                problems.append(tr("\(name) 的私钥格式不对", "The private key of \(name) is malformed"))
            } else {
                secrets.keys[id] = key
            }
        }
        root["jumps"] = jumps

        let stripped = (try? JSONSerialization.data(withJSONObject: root)) ?? data
        let decoded: AppConfig
        do {
            decoded = try JSONDecoder().decode(AppConfig.self, from: stripped)
        } catch {
            throw ConfigTransferError.unreadable(error.localizedDescription)
        }
        var config = decoded
        config.normalize()

        let missing = config.vpns.compactMap { vpn -> String? in
            guard !vpn.isSystemVPN, secrets.credentials[vpn.id] == nil else { return nil }
            guard !vpn.credentialFile.isEmpty else { return vpn.name }
            let path = PathExpander.expand(vpn.credentialFile)
            return FileManager.default.fileExists(atPath: path) ? nil : vpn.name
        }

        // 带了机密的条目，路径会在导入时指到应用的数据目录，这里只校验其他部分。
        var checked = config
        for index in checked.vpns.indices where secrets.credentials[checked.vpns[index].id] != nil {
            checked.vpns[index].credentialFile = "~/.netlink-imported"
        }
        for index in checked.jumps.indices where secrets.keys[checked.jumps[index].id] != nil {
            checked.jumps[index].identityFile = "~/.netlink-imported"
        }
        checked.normalize()
        return ImportPreview(
            config: config,
            issues: problems + ConfigCheck.issues(checked),
            secrets: secrets,
            missingCredentials: missing
        )
    }

    /// 把带来的机密落到 `directory/imported/` 下，并把配置里的路径指过去。返回可以保存的配置。
    static func materialize(_ preview: ImportPreview, into directory: URL = ConfigStore.directory) throws -> AppConfig {
        var config = preview.config
        let credentials = directory.appendingPathComponent("imported/credentials", isDirectory: true)
        let keys = directory.appendingPathComponent("imported/keys", isDirectory: true)
        let private700: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        if !preview.secrets.credentials.isEmpty {
            try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true, attributes: private700)
        }
        if !preview.secrets.keys.isEmpty {
            try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true, attributes: private700)
        }
        for index in config.vpns.indices {
            guard let credential = preview.secrets.credentials[config.vpns[index].id] else { continue }
            let path = credentials.appendingPathComponent(config.vpns[index].id.uuidString).path
            try Credentials.update(file: path, host: credential.host, user: credential.user, newPassword: credential.password)
            config.vpns[index].credentialFile = path
        }
        for index in config.jumps.indices {
            guard let key = preview.secrets.keys[config.jumps[index].id] else { continue }
            let path = keys.appendingPathComponent(config.jumps[index].id.uuidString).path
            let text = key.hasSuffix("\n") ? key : key + "\n"
            try Credentials.writePrivate(Data(text.utf8), to: path)
            config.jumps[index].identityFile = path
        }
        config.normalize()
        return config
    }

    /// 导入前把当前配置留一份。
    static func backupCurrent() {
        let backup = ConfigStore.directory.appendingPathComponent("config.json.bak")
        guard FileManager.default.fileExists(atPath: ConfigStore.file.path) else { return }
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: ConfigStore.file, to: backup)
    }
}

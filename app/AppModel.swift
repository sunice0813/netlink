import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var vpn = VPNSnapshot()
    var tunnel = TunnelSnapshot()
    var journal: [String] = []
    var vpnLog = ""
    var tunnelLog = ""
    var busy = false
    var busyLabel: String?
    var job: Job?
    var refreshingVisible = false
    var statusLine: String?
    var statusNonce = 0
    var checkedAt: Date?
    var config: AppConfig
    var configWarning: String?
    var loginMessage = ""
    var fortiPrompt = false
    var fortiConnectAfterSave = false

    private var started = false
    private var refreshing = false
    private var journalTimer: Timer?

    init() {
        ConfigStore.ensureDir()
        if !FileManager.default.fileExists(atPath: ConfigStore.file.path) {
            config = AppConfig()
            try? ConfigStore.save(config)
        } else if var loaded = ConfigStore.loadIfValid() {
            if loaded.layoutVersion < AppConfig.layoutRevision {
                loaded.layout = loaded.defaultLayout().mapValues(LayoutPoint.init)
                loaded.layoutVersion = AppConfig.layoutRevision
                try? ConfigStore.save(loaded)
            }
            config = loaded
        } else {
            config = AppConfig()
            configWarning = "配置文件读不了，先按默认值显示。点保存才会覆盖原文件。"
        }
        AppLocator.model = self
    }

    var menuSymbol: String {
        if vpn.phase == .checking || tunnel.phase == .checking { return "shield" }
        if vpn.phase == .up && tunnel.phase == .up { return "checkmark.shield.fill" }
        if vpn.phase == .down && tunnel.phase == .down { return "shield.slash" }
        return "shield.lefthalf.filled"
    }

    var banner: String? {
        if let configWarning { return configWarning }
        if vpn.phase == .checking { return nil }
        if !vpn.sudoOK { return "sudo 不能免密执行，连接和断开都会失败。" }
        if !vpn.openconnectInstalled { return "找不到 \(config.openconnectPath)" }
        if !tunnel.autosshInstalled { return "找不到 \(config.autosshPath)" }
        if vpn.credentialOK == false && vpn.phase != .checking {
            return "读不到 \(config.credentialFile) 里的 host / user / password"
        }
        return nil
    }

    func start() {
        guard !started else { return }
        started = true
        AppLocator.model = self
        let timer = Timer(timeInterval: 0.4, repeats: true) { _ in
            let lines = JournalStore.shared.snapshot()
            Task { @MainActor in
                AppLocator.model?.applyJournal(lines)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        journalTimer = timer
        adoptSystemVPNs()
        Task { await refreshLoop() }
    }

    /// 系统里已经有的 Shadowrocket 和 FortiClient，补到图上。不改它们现在的连接。
    func adoptSystemVPNs() {
        var next = config
        var changed = false
        if Engine.systemVPNInstalled("Shadowrocket"), !next.vpns.contains(where: \.isShadowrocket) {
            next.vpns.append(VPNProfile(
                id: VPNProfile.shadowrocket,
                name: "Shadowrocket",
                credentialFile: "",
                kind: "shadowrocket",
                serviceName: "Shadowrocket"
            ))
            changed = true
        }
        if Engine.systemVPNInstalled("VPN", bundleHint: "com.fortinet.forticlient.macos.vpn"), !next.vpns.contains(where: \.isForticlient) {
            next.vpns.append(VPNProfile(
                id: VPNProfile.forticlient,
                name: "FortiClient",
                credentialFile: "",
                kind: "forticlient",
                serviceName: "VPN"
            ))
            changed = true
        }
        if changed {
            try? save(config: next)
        }
    }

    func applyJournal(_ lines: [String]) {
        guard lines != journal else { return }
        journal = lines
    }

    func refresh(manual: Bool = false) async {
        if refreshing {
            if manual { post("正在刷新，这一步还没结束") }
            return
        }
        if busy {
            if manual { post("\(busyLabel ?? "上一步")，这一步还没结束") }
            return
        }
        refreshing = true
        if manual {
            refreshingVisible = true
            post("正在刷新")
            await Task.yield()
        }
        defer {
            refreshing = false
            refreshingVisible = false
        }
        let config = self.config
        let update: (VPNSnapshot, TunnelSnapshot, String, String) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let probed = Engine.probe()
                let vpnText = Redact.text(Shell.tail(path: PathExpander.expand(config.vpnLogFile), lines: 40))
                let tunnelText = Redact.text(Shell.tail(path: PathExpander.expand(config.tunnelLogFile), lines: 40))
                continuation.resume(returning: (probed.0, probed.1, vpnText, tunnelText))
            }
        }
        vpn = update.0
        tunnel = update.1
        vpnLog = update.2
        tunnelLog = update.3
        let now = Date()
        checkedAt = now
        if let loaded = ConfigStore.loadIfValid() {
            self.config = loaded
        }
        if manual {
            post("已刷新 \(Self.clock.string(from: now))")
        }
    }

    func askFortiAccount(thenConnect: Bool) {
        fortiConnectAfterSave = thenConnect
        fortiPrompt = true
        if thenConnect {
            post("先填写 FortiClient 的密码")
        }
    }

    func connectVPN() { connectVPNProfile(VPNProfile.primary) }

    func connectVPNProfile(_ id: UUID) {
        let profile = config.vpns.first { $0.id == id }
        let name = profile?.name ?? "VPN"
        if profile?.isSystemVPN == true {
            let service = profile?.serviceName ?? name
            let kind = profile?.kind ?? ""
            if kind == "forticlient", !FortiClient.hasLogin() {
                askFortiAccount(thenConnect: true)
                return
            }
            run(.vpnConnect, "正在连接 \(name)") {
                Engine.connectSystemVPN(service, label: name, kind: kind)
            }
            return
        }
        let file = profile?.credentialFile ?? config.credentialFile
        run(.vpnConnect, "正在连接 \(name)") {
            let target = Credentials.load(file: file)?.host ?? ""
            let running = Engine.runningVPNHost()
            if !running.isEmpty, !target.isEmpty, !running.contains(target), !target.contains(running) {
                Engine.disconnectVPN()
                Thread.sleep(forTimeInterval: 2)
            }
            Engine.connectVPN(enableWatch: Prefs.vpnAutoReconnect, takeOverWatch: false, credentialFile: file)
        }
    }
    func disconnectVPN() { disconnectVPNProfile(VPNProfile.primary) }

    func disconnectVPNProfile(_ id: UUID) {
        if let profile = config.vpns.first(where: { $0.id == id }), profile.isSystemVPN {
            let service = profile.serviceName
            run(.vpnDisconnect, "正在断开 \(profile.name)") {
                Engine.disconnectSystemVPN(service, label: profile.name, kind: profile.kind)
            }
            return
        }
        let file = config.vpns.first { $0.id == id }?.credentialFile ?? config.credentialFile
        let host = Credentials.load(file: file)?.host ?? ""
        let only = config.vpns.filter { !$0.isSystemVPN }.count <= 1
        run(.vpnDisconnect, "正在断开 VPN") {
            let running = Engine.runningVPNHost()
            let matches = running.isEmpty || only || host.isEmpty || running.contains(host) || host.contains(running)
            if matches {
                Engine.disconnectVPN()
            } else {
                Engine.emit("这个 VPN 没在连接")
            }
        }
    }

    func restartVPN() { restartVPNProfile(VPNProfile.primary) }

    func openSystemVPNApp(_ id: UUID) {
        guard let profile = config.vpns.first(where: { $0.id == id }), profile.isSystemVPN else { return }
        run(.vpnOpenApp, "正在打开 \(profile.name)") {
            Engine.openSystemVPNApp(kind: profile.kind, label: profile.name)
        }
    }

    func quitSystemVPNApp(_ id: UUID) {
        guard let profile = config.vpns.first(where: { $0.id == id }), profile.isSystemVPN else { return }
        run(.vpnQuitApp, "正在退出 \(profile.name)") {
            Engine.quitSystemVPNApp(service: profile.serviceName, kind: profile.kind, label: profile.name)
        }
    }

    func restartVPNProfile(_ id: UUID) {
        let profile = config.vpns.first { $0.id == id }
        let name = profile?.name ?? "VPN"
        if profile?.isSystemVPN == true {
            let service = profile?.serviceName ?? name
            let kind = profile?.kind ?? ""
            if kind == "forticlient", !FortiClient.hasLogin() {
                askFortiAccount(thenConnect: true)
                return
            }
            run(.vpnRestart, "正在重启 \(name)") {
                Engine.restartSystemVPN(service, label: name, kind: kind)
            }
            return
        }
        let file = profile?.credentialFile ?? config.credentialFile
        run(.vpnRestart, "正在重启 \(name)") {
            Engine.restartVPN(enableWatch: Prefs.vpnAutoReconnect, credentialFile: file)
        }
    }
    func connectTunnel() { run(.tunnelConnect, "正在连接隧道") { Engine.connectTunnel(enableWatch: Prefs.tunnelAutoReconnect, takeOverWatch: false, startVPNIfNeeded: true) } }
    func disconnectTunnel() { run(.tunnelDisconnect, "正在断开隧道") { Engine.disconnectTunnel() } }

    func connectJump(_ id: UUID) {
        if config.jumps.count <= 1 {
            connectTunnel()
            return
        }
        let ports = config.forwards(on: id).map(\.localPort)
        run(.tunnelConnect, "正在连接跳板") {
            for port in ports {
                Engine.connectForward(localPort: port, enableWatch: Prefs.tunnelAutoReconnect, startVPNIfNeeded: true)
            }
        }
    }

    func disconnectJump(_ id: UUID) {
        if config.jumps.count <= 1 {
            disconnectTunnel()
            return
        }
        let ports = config.forwards(on: id).map(\.localPort)
        run(.tunnelDisconnect, "正在断开跳板") {
            for port in ports {
                Engine.disconnectForward(localPort: port)
            }
        }
    }

    func restartJump(_ id: UUID) {
        if config.jumps.count <= 1 {
            restartTunnel()
            return
        }
        let ports = config.forwards(on: id).map(\.localPort)
        run(.tunnelRestart, "正在重启跳板") {
            for port in ports {
                Engine.disconnectForward(localPort: port)
            }
            for port in ports {
                Engine.connectForward(localPort: port, enableWatch: Prefs.tunnelAutoReconnect, startVPNIfNeeded: true)
            }
        }
    }
    func connectForward(_ port: Int) {
        let name = config.forwards.first { $0.localPort == port }?.name ?? "转发"
        run(.forwardConnect(port), "正在连接 \(name)") {
            Engine.connectForward(localPort: port, enableWatch: Prefs.tunnelAutoReconnect, startVPNIfNeeded: true)
        }
    }
    func disconnectForward(_ port: Int) {
        let name = config.forwards.first { $0.localPort == port }?.name ?? "转发"
        run(.forwardDisconnect(port), "正在断开 \(name)") {
            Engine.disconnectForward(localPort: port)
        }
    }
    func restartTunnel() { run(.tunnelRestart, "正在重启隧道") { Engine.restartTunnel(enableWatch: Prefs.tunnelAutoReconnect) } }
    func takeOverVPN() { run(.vpnTakeover, "正在接管 VPN 守护") { Engine.takeOverVPN() } }
    func takeOverTunnel() { run(.tunnelTakeover, "正在接管隧道守护") { Engine.takeOverTunnel() } }
    func setVPNWatch(_ on: Bool) {
        Prefs.vpnAutoReconnect = on
        run(on ? .vpnWatchOn : .vpnWatchOff, on ? "正在开启 VPN 自动重连" : "正在关闭 VPN 自动重连") { Engine.setVPNWatch(on: on) }
    }
    func setTunnelWatch(_ on: Bool) {
        Prefs.tunnelAutoReconnect = on
        run(on ? .tunnelWatchOn : .tunnelWatchOff, on ? "正在开启隧道自动重连" : "正在关闭隧道自动重连") { Engine.setTunnelWatch(on: on) }
    }

    func save(config newConfig: AppConfig) throws {
        var next = newConfig
        next.normalize()
        let problems = ConfigCheck.issues(next)
        if !problems.isEmpty {
            throw SaveError.message(problems.joined(separator: "\n"))
        }
        mergeRuntimeState(into: &next)
        try ConfigStore.save(next, overwriteCorrupt: true)
        config = next
        configWarning = nil
    }

    /// 后台操作会在磁盘上改 enabled、删转发和 VPN，内存里的 `config` 最多晚 6 秒才跟上。
    /// 界面保存时不能把这些改动写回旧值：enabled 以磁盘为准，已被后台删掉的不再复活。
    private func mergeRuntimeState(into next: inout AppConfig) {
        guard let disk = ConfigStore.loadIfValid() else { return }
        let diskForwards = Dictionary(uniqueKeysWithValues: disk.forwards.map { ($0.id, $0) })
        let knownForwards = Set(config.forwards.map(\.id))
        next.forwards = next.forwards.compactMap { forward in
            if let onDisk = diskForwards[forward.id] {
                var merged = forward
                merged.enabled = onDisk.enabled
                return merged
            }
            return knownForwards.contains(forward.id) ? nil : forward
        }
        let diskVPNs = Set(disk.vpns.map(\.id))
        let knownVPNs = Set(config.vpns.map(\.id))
        next.vpns.removeAll { knownVPNs.contains($0.id) && !diskVPNs.contains($0.id) }
    }

    func saveCredential(file: String? = nil, host: String, user: String, password: String) throws {
        try Credentials.update(file: file ?? config.credentialFile, host: host, user: user, newPassword: password)
    }

    func addVPN(name: String, host: String, user: String, password: String) throws {
        let id = UUID()
        let folder = ConfigStore.directory.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(id.uuidString).path
        try Credentials.update(file: file, host: host, user: user, newPassword: password)
        var next = config
        next.vpns.append(VPNProfile(id: id, name: name, credentialFile: file))
        placeNew(TopologyKey.vpn(id), near: TopologyKey.machine, in: &next, column: 1)
        try save(config: next)
    }

    func addJump(name: String, host: String, identityFile: String, vpnID: UUID = VPNProfile.primary) throws {
        let id = UUID()
        var next = config
        next.jumps.append(Jump(
            id: id,
            name: name,
            host: host,
            identityFile: identityFile,
            vpnID: vpnID == VPNProfile.primary ? nil : vpnID
        ))
        placeNew(TopologyKey.jump(id), near: TopologyKey.vpn(vpnID), in: &next, column: 2)
        try save(config: next)
    }

    func addTunnel(name: String, localPort: Int, targetHost: String, targetPort: Int, openHost: String, jumpID: UUID) throws {
        let id = UUID()
        var next = config
        next.forwards.append(Forward(
            id: id,
            name: name,
            localPort: localPort,
            targetHost: targetHost,
            targetPort: targetPort,
            openHost: openHost,
            enabled: false,
            jumpID: jumpID == Jump.primary ? nil : jumpID
        ))
        placeNew(TopologyKey.forward(id), near: TopologyKey.jump(jumpID), in: &next, column: 3)
        try save(config: next)
    }

    func updateLayout(_ key: String, origin: CGPoint) {
        var next = config
        next.setLayout(clamped(origin), for: key)
        do {
            try save(config: next)
        } catch {
            post(error.localizedDescription)
        }
    }

    func reparentForward(_ id: UUID, to jumpID: UUID) {
        var next = config
        guard let index = next.forwards.firstIndex(where: { $0.id == id }) else { return }
        let current = next.forwards[index].jumpID ?? Jump.primary
        guard current != jumpID else { return }
        next.forwards[index].jumpID = jumpID == Jump.primary ? nil : jumpID
        do {
            try save(config: next)
            post("隧道已挂到新跳板，重新连接后生效")
        } catch {
            post(error.localizedDescription)
        }
    }

    /// 设置流量先经过哪个 VPN。只改图和状态显示，不动任何连接。
    func setVPNVia(_ id: UUID, via: UUID?) {
        guard let index = config.vpns.firstIndex(where: { $0.id == id }) else { return }
        if let via {
            guard via != id, config.vpns.contains(where: { $0.id == via }) else { return }
            guard !config.upstreamIDs(of: via).contains(id) else {
                post("不能绕成一圈")
                return
            }
        }
        guard config.vpns[index].viaID != via else { return }
        var next = config
        next.vpns[index].viaID = via
        next.layout = next.defaultLayout().mapValues(LayoutPoint.init)
        do {
            try save(config: next)
            if let via, let name = next.vpns.first(where: { $0.id == via })?.name {
                post("\(next.vpns[index].name) 的流量经过 \(name)")
            } else {
                post("\(next.vpns[index].name) 直接从本机出去")
            }
        } catch {
            post(error.localizedDescription)
        }
    }

    func reparentJump(_ id: UUID, to vpnID: UUID) {
        var next = config
        guard let index = next.jumps.firstIndex(where: { $0.id == id }) else { return }
        let current = next.jumps[index].vpnID ?? VPNProfile.primary
        guard current != vpnID else { return }
        next.jumps[index].vpnID = vpnID == VPNProfile.primary ? nil : vpnID
        do {
            try save(config: next)
            post("跳板已挂到新 VPN")
        } catch {
            post(error.localizedDescription)
        }
    }

    private func placeNew(_ key: String, near parent: String, in config: inout AppConfig, column: Int) {
        let placed = config.resolvedLayout()
        let parentOrigin = placed[parent] ?? TopologyMetrics.origin
        let step = TopologyMetrics.nodeSize.width + TopologyMetrics.columnGap
        // 上游 VPN 会让后面的列右移，新节点跟着父节点走，不按固定列号。
        let x = placed[parent] != nil
            ? parentOrigin.x + step
            : TopologyMetrics.origin.x + CGFloat(column) * step
        var y = parentOrigin.y
        let occupied = placed.values.filter { abs($0.x - x) < 40 }.map(\.y)
        while occupied.contains(where: { abs($0 - y) < TopologyMetrics.nodeSize.height }) {
            y += TopologyMetrics.nodeSize.height + TopologyMetrics.rowGap
        }
        config.setLayout(CGPoint(x: x, y: y), for: key)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: max(8, point.x), y: max(8, point.y))
    }

    func removeForward(_ port: Int) {
        guard config.forwards.count > 1 else { return }
        let name = config.forwards.first { $0.localPort == port }?.name ?? "转发"
        run(.forwardDisconnect(port), "正在移除 \(name)") {
            Engine.disconnectForward(localPort: port)
            ConfigStore.mutate { config in
                config.forwards.removeAll { $0.localPort == port }
                config.normalize()
            }
        }
    }

    func removeJump(_ id: UUID) {
        guard config.jumps.count > 1 else { return }
        if !config.forwards(on: id).isEmpty {
            post("先删掉这台跳板上的隧道")
            return
        }
        var next = config
        next.jumps.removeAll { $0.id == id }
        do {
            try save(config: next)
        } catch {
            post(error.localizedDescription)
        }
    }

    func removeVPN(_ id: UUID) {
        guard config.vpns.count > 1, let profile = config.vpns.first(where: { $0.id == id }) else { return }
        if id == VPNProfile.primary {
            post("主 VPN 不能删，可以改账号")
            return
        }
        let file = profile.credentialFile
        let host = Credentials.load(file: file)?.host ?? ""
        run(.vpnDisconnect, "正在移除 \(profile.name)") {
            let running = Engine.runningVPNHost()
            if !running.isEmpty, !host.isEmpty, running.contains(host) || host.contains(running) {
                Engine.disconnectVPN()
            }
            ConfigStore.mutate { config in
                config.vpns.removeAll { $0.id == id }
                config.normalize()
            }
            let path = PathExpander.expand(file)
            if !path.hasSuffix("/.internalvpn") {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private func run(_ job: Job, _ label: String, _ work: @escaping () -> Void) {
        guard !busy else {
            post(busyLabel.map { "\($0)，这一步还没结束" } ?? "上一步还没结束")
            return
        }
        busy = true
        self.job = job
        busyLabel = label
        post(label)
        JournalStore.shared.clear()
        journal = []
        Engine.operationQueue.async {
            work()
            let lines = JournalStore.shared.snapshot()
            Task { @MainActor in
                self.journal = lines
                let result = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.post((result?.isEmpty == false ? result! : "完成"))
                self.busy = false
                self.busyLabel = nil
                self.job = nil
                Task { await self.refresh() }
            }
        }
    }

    private func post(_ text: String) {
        statusLine = String(text.prefix(180))
        statusNonce += 1
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func refreshLoop() async {
        while !Task.isCancelled {
            if !busy {
                await refresh()
            }
            try? await Task.sleep(for: .seconds(6))
        }
    }
}

enum Job: Equatable {
    case vpnConnect, vpnDisconnect, vpnRestart
    case vpnOpenApp, vpnQuitApp
    case tunnelConnect, tunnelDisconnect, tunnelRestart
    case forwardConnect(Int), forwardDisconnect(Int)
    case vpnTakeover, tunnelTakeover
    case vpnWatchOn, vpnWatchOff
    case tunnelWatchOn, tunnelWatchOff
}

enum AppLocator {
    nonisolated(unsafe) static weak var model: AppModel?
}

enum SaveError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

extension WatchdogOwner {
    var label: String {
        switch self {
        case .off: return "自动重连：关"
        case .shell: return "自动重连：终端守护"
        case .app: return "自动重连：本应用"
        case .both: return "自动重连：终端和本应用都在跑"
        case .stale: return "自动重连：标记还在，进程不在"
        }
    }
}

extension LinkPhase {
    var title: String {
        switch self {
        case .checking: return "检查中"
        case .up: return "已连接"
        case .degraded: return "不完整"
        case .down: return "未连接"
        }
    }
}

import AppKit
import Darwin
import Foundation

// 行为对齐 ~/.zsh/conf.d/05-vpn.zsh 和 06-ssh-tunnel.zsh。
// 改连接状态的函数都在 FileLock 里跑，和后台守护互斥。
// 密码只放进 openconnect 的标准输入，不进参数，也不进日志。

enum LinkPhase: String {
    case checking
    case up
    case degraded
    case down
}

enum WatchdogOwner: String {
    case off
    case shell
    case app
    case both
    case stale
}

struct PortStatus: Identifiable, Equatable {
    var id: Int { localPort }
    var name: String
    var localPort: Int
    var target: String
    var browseLabel: String
    var browseURL: String
    var enabled: Bool
    var listening: Bool
    var httpOK: Bool
}

struct VPNSnapshot: Equatable {
    var phase: LinkPhase = .checking
    var host = ""
    var user = ""
    /// 当前 openconnect 命令行里的主机。用来区分图上的哪一个 VPN 正在连。
    var connectedHost = ""
    var credentialOK = false
    var pid: Int32?
    var processAlive = false
    var routePresent = false
    var gatewayReachable = false
    var watch = WatchdogOwner.off
    var watchFlag = false
    var openconnectInstalled = true
    var sudoOK = true
    /// 还不能免密 sudo 执行的命令。
    var sudoMissing: [String] = []
    /// 当前已连接的系统 VPN 服务名，例如 Shadowrocket、FortiClient 对应的 "VPN"。
    var systemUp: Set<String> = []
}

struct TunnelSnapshot: Equatable {
    var phase: LinkPhase = .checking
    var jump = ""
    var identityExists = false
    var autosshRunning = false
    var runningJumpHosts: [String] = []
    var ports: [PortStatus] = []
    var watch = WatchdogOwner.off
    var watchFlag = false
    var autosshInstalled = true

    var okCount: Int { ports.filter(\.httpOK).count }
}

enum Engine {
    static let operationQueue = DispatchQueue(label: "netlink.operation")
    /// Shadowrocket / FortiClient 单独排队，不被公司 VPN、隧道的操作锁拖住。
    static let systemVPNQueue = DispatchQueue(label: "netlink.system-vpn")

    /// 只认终端里 `source ~/.zshrc; _vpn_watchdog` 这种进程。
    /// 别的命令行如果刚好带上这个字符串（比如搜索），不算守护进程。
    static func isShellWatchdog(_ command: String, marker: String) -> Bool {
        command.contains("source ~/.zshrc") && command.contains(marker)
    }

    static func classifyWatch(flag: Bool, shell: Bool, serviceAlive: Bool) -> WatchdogOwner {
        if shell && serviceAlive && flag { return .both }
        if shell { return .shell }
        if flag && serviceAlive { return .app }
        if flag { return .stale }
        return .off
    }

    /// 守护进程只有在「标记还在、终端守护不在、当前也不健康、失败次数够了」时才重连。
    static func shouldRestart(flag: Bool, shell: Bool, healthy: Bool, fails: Int, threshold: Int) -> Bool {
        flag && !shell && !healthy && fails >= threshold
    }

    static func openConnectArguments(host: String, user: String, pidFile: String, timeout: Int) -> [String] {
        [
            "--protocol=anyconnect", host,
            "--background",
            "--pid-file=\(pidFile)",
            "--user=\(user)",
            "--passwd-on-stdin",
            "--reconnect-timeout=\(timeout)",
        ]
    }

    static func autosshArguments(config: AppConfig, forwards: [Forward]? = nil) -> [String] {
        let chosen = forwards ?? config.forwards.filter { ($0.jumpID ?? Jump.primary) == Jump.primary }
        let jump = chosen.first.map { config.jump(for: $0) }
        var arguments = [
            "-M", "0", "-f", "-N",
            "-E", PathExpander.expand(config.tunnelLogFile),
            "-i", PathExpander.expand(jump?.identityFile ?? config.identityFile),
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        for forward in chosen {
            arguments.append("-L")
            arguments.append(forward.spec)
        }
        arguments.append(jump?.host ?? config.jumpHost)
        return arguments
    }

    static func probe(heal: Bool = true) -> (VPNSnapshot, TunnelSnapshot) {
        let config = ConfigStore.load()
        let procs = Shell.processes()
        var vpn = vpnSnapshot(config: config, procs: procs, ping: true)
        let tunnel = tunnelSnapshot(config: config, procs: procs)
        vpn.sudoMissing = Setup.sudoMissing(config: config)
        vpn.sudoOK = vpn.sudoMissing.isEmpty
        if heal {
            healIfNeeded(vpn: vpn, tunnel: tunnel)
        }
        return (vpn, tunnel)
    }

    /// 配置文件坏了的时候 load() 给的是默认值，拿它去连接只会连错地方。
    private static func configUsable() -> Bool {
        if ConfigStore.isCorrupt {
            emit("配置文件读不了，先在应用里修好或重新保存，再连接")
            return false
        }
        return true
    }

    static func connectVPN(enableWatch: Bool, takeOverWatch: Bool, credentialFile: String? = nil) {
        FileLock.with {
            guard configUsable() else { return }
            let config = ConfigStore.load()
            var procs = Shell.processes()
            if processAlive(config: config, procs: procs) {
                let pid = readPID(config.vpnPidFile) ?? 0
                emit("VPN 已在运行（PID \(pid)）")
                arrangeVPNWatch(config: config, procs: procs, enable: enableWatch, takeOver: takeOverWatch)
                return
            }
            stopShellWatchdog("_vpn_watchdog")
            switch startOpenConnect(config, credentialFile: credentialFile) {
            case .connected(let pid, let seconds):
                emit("VPN 已连接（PID \(pid)，\(seconds) 秒）")
                procs = Shell.processes()
                arrangeVPNWatch(config: config, procs: procs, enable: enableWatch, takeOver: true)
            case .degraded:
                emit("VPN 进程在运行，但路由还没出现")
                emit(logTail(config.vpnLogFile))
            case .failed:
                emit("VPN 启动失败")
                emit(logTail(config.vpnLogFile))
            }
        }
    }

    static func disconnectVPN() {
        FileLock.with {
            let config = ConfigStore.load()
            writeFlag(config.vpnWatchdogFile, false)
            stopShellWatchdog("_vpn_watchdog")
            stopOpenConnect(config)
            syncWanted(config: config)
            sleep(1)
            if openConnectProcesses().isEmpty {
                emit("VPN 已断开")
            } else {
                emit("还有 openconnect 进程没退出")
            }
        }
    }

    /// Shadowrocket 是 iOS 应用在 Mac 上跑的，`scutil --nc` 里看不到它。
    /// 装没装看应用目录，开没开看它的 PacketTunnel 扩展进程。
    static let shadowrocketApp = "/Applications/Shadowrocket.app"

    static func shadowrocketInstalled() -> Bool {
        FileManager.default.fileExists(atPath: shadowrocketApp)
    }

    static func shadowrocketRunning(in procs: [Proc]? = nil) -> Bool {
        (procs ?? Shell.processes()).contains {
            $0.command.contains("/Shadowrocket.app/PlugIns/PacketTunnel.appex/")
        }
    }

    /// Shadowrocket 没有可调用的开关，只能打开应用让人点。状态会在下一次检查里自己更新。
    private static func handOffShadowrocket(_ title: String, wantOn: Bool) {
        emit("\(title) 没有命令行开关，已打开应用，请在里面\(wantOn ? "打开" : "关闭")开关")
        _ = Shell.run("/usr/bin/open", [shadowrocketApp], timeout: 8)
    }

    static func systemVPNInstalled(_ name: String, bundleHint: String = "") -> Bool {
        if name == "Shadowrocket" { return shadowrocketInstalled() }
        let listed = Shell.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 5).stdout
        return listed.split(whereSeparator: \.isNewline).contains { line in
            line.contains("\"\(name)\"") && (bundleHint.isEmpty || line.contains(bundleHint))
        }
    }

    static func systemVPNStatus(_ name: String) -> String {
        if name == "Shadowrocket" { return shadowrocketRunning() ? "Connected" : "Disconnected" }
        let text = Shell.run("/usr/sbin/scutil", ["--nc", "status", name], timeout: 5).stdout
        return text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// 系统 VPN 不走公司 VPN/隧道那把操作锁，避免后台守护卡住时连断开都点不动。
    static func connectSystemVPN(_ name: String, label: String = "", kind: String = "") {
        let title = label.isEmpty ? name : label
        if systemVPNStatus(name) == "Connected" {
            emit("\(title) 已在运行")
            return
        }
        if kind == "forticlient" {
            connectFortiClient(service: name, title: title)
            return
        }
        if kind == "shadowrocket" {
            handOffShadowrocket(title, wantOn: true)
            return
        }
        emit("正在连接 \(title)")
        _ = Shell.run("/usr/sbin/scutil", ["--nc", "start", name], timeout: 8)
        if waitSystemVPN(name, until: "Connected", seconds: 20) {
            emit("\(title) 已连接")
        } else {
            emit("\(title) 还没连上")
        }
    }

    static func disconnectSystemVPN(_ name: String, label: String = "", kind: String = "") {
        let title = label.isEmpty ? name : label
        if kind == "forticlient" {
            disconnectFortiClient(service: name, title: title)
            return
        }
        if kind == "shadowrocket" {
            handOffShadowrocket(title, wantOn: false)
            return
        }
        emit("正在断开 \(title)")
        _ = Shell.run("/usr/sbin/scutil", ["--nc", "stop", name], timeout: 8)
        if waitSystemVPN(name, until: "Disconnected", seconds: 8) {
            emit("\(title) 已断开")
        } else {
            emit("\(title) 还在连接")
        }
    }

    static func restartSystemVPN(_ name: String, label: String = "", kind: String = "") {
        disconnectSystemVPN(name, label: label, kind: kind)
        Thread.sleep(forTimeInterval: 1)
        connectSystemVPN(name, label: label, kind: kind)
    }

    /// Shadowrocket / FortiClient 的图形界面。守护进程不在这里。
    static func systemVPNAppPath(kind: String) -> String? {
        switch kind {
        case "shadowrocket": return "/Applications/Shadowrocket.app"
        case "forticlient": return "/Applications/FortiClient.app"
        default: return nil
        }
    }

    static func systemVPNBundleID(kind: String) -> String? {
        systemVPNBundleIDs(kind: kind).first
    }

    /// 主程序和它带起来的界面进程。系统守护和网络扩展不在这里。
    static func systemVPNBundleIDs(kind: String) -> [String] {
        switch kind {
        case "shadowrocket":
            return ["com.liguangming.Shadowrocket"]
        case "forticlient":
            return [
                "com.fortinet.FortiClient",
                "com.fortinet.forticlient.FortiClientAgent",
                "com.fortinet.FctMiscAgent",
                "com.fortinet.forticlient.macos.vpn",
            ]
        default:
            return []
        }
    }

    /// 用进程命令行判断是不是这个应用自己的进程。系统目录里的守护进程不算。
    static func isSystemVPNAppProcess(kind: String, command: String) -> Bool {
        switch kind {
        case "shadowrocket":
            return command.contains("/Shadowrocket.app/")
        case "forticlient":
            if command.contains("/Library/Application Support/Fortinet/") { return false }
            if command.contains("/Library/SystemExtensions/") { return false }
            return command.contains("/FortiClient.app/")
                || command.contains("/FortiTray.app/")
                || command.contains("/FortiClientAgent.app/")
                || command.contains("/FctMiscAgent.app/")
        default:
            return false
        }
    }

    static func openSystemVPNApp(kind: String, label: String) {
        guard let path = systemVPNAppPath(kind: kind) else {
            emit("\(label) 不是可打开的系统 VPN")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            emit("找不到 \(label)")
            return
        }
        emit("正在打开 \(label)")
        let result = Shell.run("/usr/bin/open", [path], timeout: 8)
        if result.ok {
            emit("已打开 \(label)")
        } else {
            emit("\(label) 打开失败")
        }
    }

    /// 先断开这个系统 VPN，再结束它的界面进程。系统目录里的守护进程保留。
    static func quitSystemVPNApp(service: String, kind: String, label: String) {
        if systemVPNStatus(service) == "Connected", kind != "shadowrocket" {
            if kind == "forticlient" {
                disconnectFortiClient(service: service, title: label)
            } else {
                disconnectSystemVPN(service, label: label, kind: kind)
            }
        }
        endSystemVPNApp(kind: kind, label: label)
    }

    private static func endSystemVPNApp(kind: String, label: String) {
        let ids = systemVPNBundleIDs(kind: kind)
        guard !ids.isEmpty else {
            emit("\(label) 不是可退出的系统 VPN")
            return
        }
        let before = systemVPNAppProcesses(kind: kind)
        let apps = ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        if before.isEmpty && apps.isEmpty {
            emit("\(label) 没在运行")
            return
        }
        emit("正在退出 \(label)")
        for app in apps {
            _ = app.terminate()
        }
        if waitUntilAppGone(kind: kind, seconds: 2) {
            emit("\(label) 已退出")
            return
        }
        for app in ids.flatMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0) }) {
            app.forceTerminate()
        }
        signalSystemVPNApp(kind: kind, signal: SIGTERM)
        if waitUntilAppGone(kind: kind, seconds: 2) {
            emit("\(label) 已退出")
            return
        }
        signalSystemVPNApp(kind: kind, signal: SIGKILL)
        if waitUntilAppGone(kind: kind, seconds: 2) {
            emit("\(label) 已退出")
        } else {
            emit("\(label) 还没退出")
        }
    }

    private static func systemVPNAppProcesses(kind: String) -> [Proc] {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        return Shell.processes().filter { proc in
            proc.pid != selfPid && isSystemVPNAppProcess(kind: kind, command: proc.command)
        }
    }

    private static func signalSystemVPNApp(kind: String, signal: Int32) {
        for proc in systemVPNAppProcesses(kind: kind) {
            _ = Darwin.kill(proc.pid, signal)
        }
    }

    private static func waitUntilAppGone(kind: String, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if systemVPNAppProcesses(kind: kind).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return systemVPNAppProcesses(kind: kind).isEmpty
    }

    private static func connectFortiClient(service: String, title: String) {
        guard let login = FortiClient.savedLogin() else {
            emit("\(title) 还没有密码")
            return
        }
        emit("正在连接 \(title)")
        switch FortiClient.send(action: "connect", user: login.user, password: login.password) {
        case .accepted:
            break
        case .noNode:
            emit("这台 Mac 上没有可用的 node，\(title) 连不上")
            return
        case .noAddon:
            emit("找不到 \(title) 的连接组件")
            return
        case .rejected, .failed:
            emit("\(title) 没有接受连接")
            return
        }
        if waitSystemVPN(service, until: "Connected", seconds: 25) {
            emit("\(title) 已连接")
        } else if FortiClient.recentLoginRejected() {
            emit("\(title) 登录被拒绝，请核对密码")
        } else {
            emit("\(title) 还没连上")
        }
    }

    private static func disconnectFortiClient(service: String, title: String) {
        emit("正在断开 \(title)")
        switch FortiClient.send(action: "disconnect", user: "", password: "") {
        case .accepted:
            break
        case .noNode:
            emit("这台 Mac 上没有可用的 node，\(title) 断不开")
            return
        case .noAddon:
            emit("找不到 \(title) 的连接组件")
            return
        case .rejected, .failed:
            emit("\(title) 没有接受断开")
            return
        }
        if waitSystemVPN(service, until: "Disconnected", seconds: 12) {
            emit("\(title) 已断开")
        } else {
            emit("\(title) 还在连接")
        }
    }

    private static func waitSystemVPN(_ name: String, until wanted: String, seconds: TimeInterval) -> Bool {
        if systemVPNStatus(name) == wanted || (wanted == "Disconnected" && systemVPNStatus(name).isEmpty) {
            return true
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let status = systemVPNStatus(name)
            if status == wanted || (wanted == "Disconnected" && status.isEmpty) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return systemVPNStatus(name) == wanted
    }

    static func restartVPN(enableWatch: Bool, credentialFile: String? = nil) {
        disconnectVPN()
        sleep(2)
        connectVPN(enableWatch: enableWatch, takeOverWatch: true, credentialFile: credentialFile)
    }

    static func connectTunnel(enableWatch: Bool, takeOverWatch: Bool, startVPNIfNeeded: Bool) {
        FileLock.with {
            guard configUsable() else { return }
            ConfigStore.mutate { config in
                for index in config.forwards.indices {
                    config.forwards[index].enabled = true
                }
            }
            let config = ConfigStore.load()
            let pending = config.forwards.filter { !forwardUp($0) }
            if pending.isEmpty {
                emit("隧道已在运行")
                arrangeTunnelWatch(config: config, procs: Shell.processes(), enable: enableWatch, takeOver: takeOverWatch)
                return
            }
            stopShellWatchdog("_tunnel_watchdog")
            var started = false
            for forward in pending {
                guard ensureJump(config, jump: config.jump(for: forward), startVPNIfNeeded: startVPNIfNeeded) else { return }
                if let pid = listeners(forward.localPort).first {
                    emit("\(forward.name) 的端口 \(forward.localPort) 已被占用（PID \(pid)）")
                    continue
                }
                emit("启动 \(forward.name)")
                if startAutossh(config, forwards: [forward]) {
                    started = true
                }
            }
            guard started else {
                emit("autossh 启动失败")
                emit(logTail(config.tunnelLogFile))
                return
            }
            if waitForPorts(config, seconds: 12) {
                emit("隧道已就绪")
                arrangeTunnelWatch(config: config, procs: Shell.processes(), enable: enableWatch, takeOver: true)
            } else {
                emit("隧道还没完全就绪")
                emit(logTail(config.tunnelLogFile))
            }
        }
    }

    static func connectForward(localPort: Int, enableWatch: Bool, startVPNIfNeeded: Bool) {
        FileLock.with {
            guard configUsable() else { return }
            ConfigStore.mutate { config in
                if let index = config.forwards.firstIndex(where: { $0.localPort == localPort }) {
                    config.forwards[index].enabled = true
                }
            }
            let config = ConfigStore.load()
            guard let forward = config.forwards.first(where: { $0.localPort == localPort }) else {
                emit("没有本地端口 \(localPort) 的转发")
                return
            }
            if forwardUp(forward) {
                emit("\(forward.name) 已在运行")
                arrangeTunnelWatch(config: config, procs: Shell.processes(), enable: enableWatch, takeOver: false)
                return
            }
            guard ensureJump(config, jump: config.jump(for: forward), startVPNIfNeeded: startVPNIfNeeded) else { return }
            if let pid = listeners(forward.localPort).first {
                emit("\(forward.name) 的端口 \(forward.localPort) 已被占用（PID \(pid)）")
                return
            }
            emit("启动 \(forward.name)")
            guard startAutossh(config, forwards: [forward]) else {
                emit("\(forward.name) 启动失败")
                emit(logTail(config.tunnelLogFile))
                return
            }
            if waitForForward(forward, seconds: 12) {
                emit("\(forward.name) 已就绪")
                arrangeTunnelWatch(config: config, procs: Shell.processes(), enable: enableWatch, takeOver: false)
            } else {
                emit("\(forward.name) 还没就绪")
                emit(logTail(config.tunnelLogFile))
            }
        }
    }

    static func disconnectForward(localPort: Int) {
        FileLock.with {
            guard configUsable() else { return }
            ConfigStore.mutate { config in
                if let index = config.forwards.firstIndex(where: { $0.localPort == localPort }) {
                    config.forwards[index].enabled = false
                }
            }
            let config = ConfigStore.load()
            guard let forward = config.forwards.first(where: { $0.localPort == localPort }) else {
                emit("没有本地端口 \(localPort) 的转发")
                return
            }
            if shellWatchdogAlive("_tunnel_watchdog") {
                stopShellWatchdog("_tunnel_watchdog")
                emit("已停掉终端里的隧道守护，避免它把这条转发重新拉起来")
            }
            let shared = Shell.processes().contains { proc in
                carries(proc, spec: forward.spec, config: config)
                    && config.forwards.contains { $0.localPort != forward.localPort && proc.command.contains($0.spec) }
            }
            if shared {
                emit("\(forward.name) 和其他转发在同一个进程里，其余的会重新连上")
            }
            stopForward(config, forward, restoreOthers: true)
            sleep(1)
            if listeners(forward.localPort).isEmpty {
                emit("\(forward.name) 已断开")
            } else {
                emit("\(forward.name) 的端口还没释放")
            }
        }
    }

    static func disconnectTunnel() {
        FileLock.with {
            ConfigStore.mutate { config in
                for index in config.forwards.indices {
                    config.forwards[index].enabled = false
                }
            }
            let config = ConfigStore.load()
            writeFlag(config.tunnelWatchdogFile, false)
            stopShellWatchdog("_tunnel_watchdog")
            stopTunnelProcesses(config)
            syncWanted(config: config)
            sleep(1)
            if occupiedPort(config) == nil {
                emit("隧道已断开")
            } else {
                emit("还有转发端口没释放")
            }
        }
    }

    static func restartTunnel(enableWatch: Bool) {
        disconnectTunnel()
        sleep(2)
        connectTunnel(enableWatch: enableWatch, takeOverWatch: true, startVPNIfNeeded: true)
    }

    static func disconnectAll() {
        disconnectTunnel()
        disconnectVPN()
        stopAppService()
    }

    static func takeOverVPN() {
        FileLock.with {
            let config = ConfigStore.load()
            stopShellWatchdog("_vpn_watchdog")
            writeFlag(config.vpnWatchdogFile, true)
            startServiceIfNeeded()
            emit("VPN 自动重连已改由本应用负责")
        }
    }

    static func takeOverTunnel() {
        FileLock.with {
            let config = ConfigStore.load()
            stopShellWatchdog("_tunnel_watchdog")
            writeFlag(config.tunnelWatchdogFile, true)
            startServiceIfNeeded()
            emit("隧道自动重连已改由本应用负责")
        }
    }

    static func setVPNWatch(on: Bool) {
        FileLock.with {
            let config = ConfigStore.load()
            if on {
                stopShellWatchdog("_vpn_watchdog")
                writeFlag(config.vpnWatchdogFile, true)
                startServiceIfNeeded()
                emit("已开启 VPN 自动重连")
            } else {
                writeFlag(config.vpnWatchdogFile, false)
                stopShellWatchdog("_vpn_watchdog")
                syncWanted(config: config)
                emit("已关闭 VPN 自动重连，当前连接保持不变")
            }
        }
    }

    static func setTunnelWatch(on: Bool) {
        FileLock.with {
            let config = ConfigStore.load()
            if on {
                stopShellWatchdog("_tunnel_watchdog")
                writeFlag(config.tunnelWatchdogFile, true)
                startServiceIfNeeded()
                emit("已开启隧道自动重连")
            } else {
                writeFlag(config.tunnelWatchdogFile, false)
                stopShellWatchdog("_tunnel_watchdog")
                syncWanted(config: config)
                emit("已关闭隧道自动重连，当前连接保持不变")
            }
        }
    }

    static func vpnHealthy(config: AppConfig, procs: [Proc]) -> Bool {
        guard processAlive(config: config, procs: procs) else { return false }
        guard routePresent(config.routeMarker) else { return false }
        return ping(config.pingHost)
    }

    static func tunnelHealthy(config: AppConfig) -> Bool {
        let wanted = config.forwards.filter(\.enabled)
        guard !wanted.isEmpty else { return true }
        for forward in wanted where !forwardUp(forward) {
            return false
        }
        return true
    }

    /// 失败时不会清掉守护标记。锁只包住真正改进程的步骤，睡眠时放开。
    static func restartVPNPreservingFlag(config: AppConfig) {
        guard flag(config.vpnWatchdogFile) else { return }
        guard !shellWatchdogAlive("_vpn_watchdog") else { return }
        emitLog(config.vpnLogFile, "强制重启 VPN")
        FileLock.with { stopOpenConnect(config) }
        sleep(3)
        guard flag(config.vpnWatchdogFile) else { return }
        // 重连最近一次连上的那个账号，而不是永远回到主 VPN。
        let last = (try? String(contentsOfFile: ConfigStore.activeCredentialPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = startOpenConnect(config, credentialFile: (last?.isEmpty == false) ? last : nil)
    }

    static func restartTunnelPreservingFlag(config: AppConfig) {
        guard flag(config.tunnelWatchdogFile) else { return }
        guard !shellWatchdogAlive("_tunnel_watchdog") else { return }
        let down = config.forwards.filter { $0.enabled && !forwardUp($0) }
        guard !down.isEmpty else { return }
        emitLog(config.tunnelLogFile, "隧道异常，重连 \(down.map(\.name).joined(separator: "、"))")
        FileLock.with {
            for forward in down {
                stopForward(config, forward, restoreOthers: false)
            }
        }
        sleep(2)
        guard flag(config.tunnelWatchdogFile) else { return }
        FileLock.with {
            for forward in down {
                _ = startAutossh(config, forwards: [forward])
            }
            restoreEnabled(config, except: nil)
        }
    }

    static func flag(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: PathExpander.expand(path))
    }

    static func serviceAlive() -> Bool {
        let path = ConfigStore.servicePIDPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, pid != getpid() else { return false }
        return Shell.processes().contains { $0.pid == pid && $0.command.contains("--service") }
    }

    /// 清掉守护标记并停掉本应用拉起的 `--service`。不嵌套 FileLock。
    static func stopAppService() {
        ConfigStore.setWanted(false)
        let path = ConfigStore.servicePIDPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              pid != getpid() else { return }
        let procs = Shell.processes()
        guard procs.contains(where: { $0.pid == pid && $0.command.contains("NetLink") && $0.command.contains("--service") }) else {
            return
        }
        signal(pid, sudo: false)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !Shell.processes().contains(where: { $0.pid == pid }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if Shell.processes().contains(where: { $0.pid == pid }) {
            signal(pid, sudo: false, force: true)
            Thread.sleep(forTimeInterval: 0.2)
        }
        try? FileManager.default.removeItem(atPath: path)
        emit("后台守护已停")
    }

    static func ensureService() {
        FileLock.with {
            startServiceIfNeeded()
        }
    }

    // MARK: - Snapshots

    private static func vpnSnapshot(config: AppConfig, procs: [Proc], ping: Bool) -> VPNSnapshot {
        var snap = VPNSnapshot()
        snap.openconnectInstalled = FileManager.default.isExecutableFile(atPath: config.openconnectPath)
        snap.watchFlag = flag(config.vpnWatchdogFile)
        let shell = procs.contains { isShellWatchdog($0.command, marker: "_vpn_watchdog") }
        snap.watch = classifyWatch(flag: snap.watchFlag, shell: shell, serviceAlive: serviceAlive())
        if let credential = Credentials.load(file: config.credentialFile) {
            snap.credentialOK = true
            snap.host = credential.host
            snap.user = credential.user
        }
        snap.connectedHost = openConnectProcesses(in: procs).first.flatMap { hostInOpenConnect($0.command) } ?? ""
        snap.pid = readPID(config.vpnPidFile)
        if let pid = snap.pid {
            snap.processAlive = procs.contains { $0.pid == pid }
        }
        if !snap.processAlive {
            snap.processAlive = !openConnectProcesses(in: procs).isEmpty
        }
        snap.systemUp = Set(config.vpns.filter(\.isSystemVPN).compactMap { profile -> String? in
            guard systemVPNStatus(profile.serviceName) == "Connected" else { return nil }
            return profile.serviceName
        })
        snap.routePresent = routePresent(config.routeMarker)
        snap.gatewayReachable = ping ? self.ping(config.pingHost) : false
        if snap.processAlive && snap.routePresent && snap.gatewayReachable {
            snap.phase = .up
        } else if snap.processAlive {
            snap.phase = .degraded
        } else {
            snap.phase = .down
        }
        return snap
    }

    private static func tunnelSnapshot(config: AppConfig, procs: [Proc]) -> TunnelSnapshot {
        var snap = TunnelSnapshot()
        snap.jump = config.jumpHost
        snap.autosshInstalled = FileManager.default.isExecutableFile(atPath: config.autosshPath)
        snap.identityExists = FileManager.default.isReadableFile(atPath: PathExpander.expand(config.identityFile))
        snap.autosshRunning = autosshAlive(config: config, procs: procs)
        snap.runningJumpHosts = config.jumps.map(\.host).filter { host in
            procs.contains { $0.command.contains("autossh") && $0.command.contains(host) }
        }
        snap.watchFlag = flag(config.tunnelWatchdogFile)
        let shell = procs.contains { isShellWatchdog($0.command, marker: "_tunnel_watchdog") }
        snap.watch = classifyWatch(flag: snap.watchFlag, shell: shell, serviceAlive: serviceAlive())

        snap.ports = config.forwards.map { forward in
            PortStatus(
                name: forward.name,
                localPort: forward.localPort,
                target: forward.target,
                browseLabel: forward.browseLabel,
                browseURL: forward.browseURL?.absoluteString ?? "http://127.0.0.1:\(forward.localPort)/",
                enabled: forward.enabled,
                listening: !listeners(forward.localPort).isEmpty,
                httpOK: forwardUp(forward)
            )
        }.sorted { $0.localPort < $1.localPort }
        let wanted = snap.ports.filter(\.enabled)
        let ok = wanted.filter(\.httpOK).count
        if wanted.isEmpty {
            snap.phase = .down
        } else if ok == wanted.count {
            snap.phase = .up
        } else if ok > 0 || snap.autosshRunning {
            snap.phase = .degraded
        } else {
            snap.phase = .down
        }
        return snap
    }

    // MARK: - VPN process

    private enum VPNStart {
        case connected(pid: Int32, seconds: Int)
        case degraded
        case failed
    }

    private static func startOpenConnect(_ config: AppConfig, credentialFile: String? = nil) -> VPNStart {
        guard FileManager.default.isExecutableFile(atPath: config.openconnectPath) else {
            emit("找不到 \(config.openconnectPath)")
            return .failed
        }
        let file = credentialFile ?? config.credentialFile
        guard let credential = Credentials.load(file: file) else {
            emit("\(file) 缺少 host、user 或 password")
            return .failed
        }
        let pidPath = PathExpander.expand(config.vpnPidFile)
        let logPath = PathExpander.expand(config.vpnLogFile)
        try? FileManager.default.removeItem(atPath: pidPath)
        try? PathExpander.expand(file).write(toFile: ConfigStore.activeCredentialPath, atomically: true, encoding: .utf8)
        let payload = Data("\(credential.user)\n\(credential.password)\n".utf8)
        emitLog(config.vpnLogFile, "开始连接 VPN")
        let result = Shell.run(
            config.openconnectPath,
            openConnectArguments(host: credential.host, user: credential.user, pidFile: pidPath, timeout: config.reconnectTimeout),
            stdin: payload,
            sudo: true,
            timeout: 25,
            appendLog: logPath
        )
        if result.code != 0 && !processAlive(config: config, procs: Shell.processes()) {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { emit(Redact.line(detail)) }
            return .failed
        }
        let deadline = Date().addingTimeInterval(20)
        var seconds = 0
        while Date() < deadline {
            sleep(1)
            seconds += 1
            let procs = Shell.processes()
            if processAlive(config: config, procs: procs) && routePresent(config.routeMarker) {
                let pid = readPID(config.vpnPidFile) ?? 0
                return .connected(pid: pid, seconds: seconds)
            }
        }
        if processAlive(config: config, procs: Shell.processes()) {
            return .degraded
        }
        return .failed
    }

    private static func stopOpenConnect(_ config: AppConfig) {
        if let pid = readPID(config.vpnPidFile) {
            signal(pid, sudo: true)
        }
        for proc in openConnectProcesses() where proc.pid != getpid() {
            signal(proc.pid, sudo: true)
        }
        sleep(1)
        for proc in openConnectProcesses() {
            signal(proc.pid, sudo: true, force: true)
        }
        let pidPath = PathExpander.expand(config.vpnPidFile)
        try? FileManager.default.removeItem(atPath: pidPath)
        if FileManager.default.fileExists(atPath: pidPath), SudoPath.allowed(pidPath) {
            _ = Shell.run("/bin/rm", ["-f", pidPath], sudo: true, timeout: 8)
        }
    }

    private static func processAlive(config: AppConfig, procs: [Proc]) -> Bool {
        if let pid = readPID(config.vpnPidFile), procs.contains(where: { $0.pid == pid }) {
            return true
        }
        return !openConnectProcesses(in: procs).isEmpty
    }

    static func runningVPNHost() -> String {
        openConnectProcesses().first.flatMap { hostInOpenConnect($0.command) } ?? ""
    }

    private static func hostInOpenConnect(_ command: String) -> String? {
        for token in command.split(separator: " ") {
            let text = String(token)
            guard text.hasPrefix("http://") || text.hasPrefix("https://"), let url = URL(string: text), let host = url.host else { continue }
            return host
        }
        return nil
    }

    /// 命令行第一个词的文件名。用它判断「是不是这个程序」，不看参数里碰巧出现的字符串。
    static func executableName(_ command: String) -> String {
        let first = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return (first as NSString).lastPathComponent
    }

    static func isOpenConnect(_ command: String) -> Bool {
        executableName(command) == "openconnect" && command.contains("--protocol=anyconnect")
    }

    /// 凭据里可能是完整 URL，进程里只有主机名，比较时两边都收成 host。
    static func vpnHostKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, trimmed.contains("://") {
            return host.lowercased()
        }
        return trimmed.lowercased()
    }

    private static func openConnectProcesses(in procs: [Proc]? = nil) -> [Proc] {
        let list = procs ?? Shell.processes()
        return list.filter { isOpenConnect($0.command) }
    }

    // MARK: - Tunnel process

    private static func startAutossh(_ config: AppConfig, forwards: [Forward]? = nil) -> Bool {
        let chosen = forwards ?? config.forwards.filter(\.enabled)
        guard !chosen.isEmpty else {
            emit("没有要连接的转发")
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: config.autosshPath) else {
            emit("找不到 \(config.autosshPath)")
            return false
        }
        let identity = chosen.first.map { config.jump(for: $0).identityFile } ?? config.identityFile
        let key = PathExpander.expand(identity)
        guard FileManager.default.isReadableFile(atPath: key) else {
            emit("读不到密钥 \(identity)")
            return false
        }
        emitLog(config.tunnelLogFile, "开始连接 \(chosen.map(\.name).joined(separator: "、"))")
        let result = Shell.run(
            config.autosshPath,
            autosshArguments(config: config, forwards: chosen),
            sudo: true,
            timeout: 20
        )
        if result.ok { return true }
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { emit(detail) }
        return autosshAlive(config: config, procs: Shell.processes())
    }

    private static func stopTunnelProcesses(_ config: AppConfig) {
        let procs = Shell.processes()
        for proc in procs where isOurAutossh(proc, config: config) || isOurForwardingSSH(proc, config: config) {
            signal(proc.pid, sudo: true)
        }
        sleep(1)
        let rest = Shell.processes()
        for forward in config.forwards {
            let owned = ownedListeners(forward.localPort, config: config, procs: rest)
            for pid in owned.ours {
                signal(pid, sudo: true, force: true)
            }
            if let pid = owned.foreign.first {
                emit("\(forward.name) 的端口 \(forward.localPort) 被别的程序占着（PID \(pid)），没有动它")
            }
        }
    }

    private static func stopForward(_ config: AppConfig, _ forward: Forward, restoreOthers: Bool) {
        let procs = Shell.processes().filter { carries($0, spec: forward.spec, config: config) }
        for proc in procs {
            signal(proc.pid, sudo: true)
        }
        sleep(1)
        let owned = ownedListeners(forward.localPort, config: config, procs: Shell.processes())
        for pid in owned.ours {
            signal(pid, sudo: true, force: true)
        }
        if let pid = owned.foreign.first {
            emit("\(forward.name) 的端口 \(forward.localPort) 被别的程序占着（PID \(pid)），没有动它")
        }
        if restoreOthers {
            restoreEnabled(config, except: forward.localPort)
        }
    }

    private static func restoreEnabled(_ config: AppConfig, except: Int?) {
        for forward in config.forwards where forward.enabled && forward.localPort != except {
            if listeners(forward.localPort).isEmpty {
                emit("重新连接 \(forward.name)")
                _ = startAutossh(config, forwards: [forward])
            }
        }
    }

    private static func carries(_ proc: Proc, spec: String, config: AppConfig) -> Bool {
        let ours = isOurAutossh(proc, config: config) || isOurForwardingSSH(proc, config: config)
        return ours && proc.command.contains(spec)
    }

    private static func ensureJump(_ config: AppConfig, jump: Jump? = nil, startVPNIfNeeded: Bool) -> Bool {
        let target = jump ?? config.primaryJump
        emit("检查跳板机连通性")
        if jumpReachable(config, jump: target, timeout: 5) {
            emit("跳板机可达")
            return true
        }
        emit("跳板机不可达，先连接 VPN")
        guard startVPNIfNeeded else {
            emit("已取消连接隧道")
            return false
        }
        if !processAlive(config: config, procs: Shell.processes()) {
            stopShellWatchdog("_vpn_watchdog")
            // 跳板挂在哪个 VPN 下就用哪个账号；挂的是系统 VPN（没法在这里启动）就退回主 VPN。
            let owner = config.vpn(for: target)
            let credential = owner.isSystemVPN ? nil : owner.credentialFile
            switch startOpenConnect(config, credentialFile: credential) {
            case .connected(let pid, let seconds):
                emit("VPN 已连接（PID \(pid)，\(seconds) 秒）")
                arrangeVPNWatch(config: config, procs: Shell.processes(), enable: Prefs.vpnAutoReconnect, takeOver: true)
            case .degraded:
                emit("VPN 进程在，但路由未确认，继续等跳板机")
            case .failed:
                emit("VPN 没连上，隧道中止")
                emit(logTail(config.vpnLogFile))
                return false
            }
        }
        emit("等待跳板机，最多 30 秒")
        guard waitForJump(config, jump: target, seconds: 30) else {
            emit("30 秒内跳板机仍不可达")
            return false
        }
        emit("跳板机已可达")
        return true
    }

    /// 本应用起的 autossh / ssh 都带 `-E <隧道日志>`，用它认「自己的」进程，
    /// 手动开的 ssh -L 或别的程序不会被误杀。
    private static func hasOurLogMarker(_ command: String, config: AppConfig) -> Bool {
        command.contains("-E \(PathExpander.expand(config.tunnelLogFile))")
    }

    static func isOurAutossh(_ proc: Proc, config: AppConfig) -> Bool {
        executableName(proc.command) == "autossh" && hasOurLogMarker(proc.command, config: config)
    }

    /// autossh 拉起的 ssh 子进程。
    static func isOurForwardingSSH(_ proc: Proc, config: AppConfig) -> Bool {
        executableName(proc.command) == "ssh" && proc.command.contains("-L") && hasOurLogMarker(proc.command, config: config)
    }

    /// 端口上的监听者里，只有我们自己的隧道进程才会被结束。别的程序占着端口，只提示不动手。
    private static func ownedListeners(_ port: Int, config: AppConfig, procs: [Proc]) -> (ours: [Int32], foreign: [Int32]) {
        var ours: [Int32] = []
        var foreign: [Int32] = []
        for pid in listeners(port) {
            if let proc = procs.first(where: { $0.pid == pid }), isOurAutossh(proc, config: config) || isOurForwardingSSH(proc, config: config) {
                ours.append(pid)
            } else {
                foreign.append(pid)
            }
        }
        return (ours, foreign)
    }

    private static func autosshAlive(config: AppConfig, procs: [Proc]) -> Bool {
        procs.contains { isOurAutossh($0, config: config) }
    }

    private static func jumpReachable(_ config: AppConfig, jump: Jump? = nil, timeout: Int) -> Bool {
        let target = jump ?? config.primaryJump
        let result = Shell.run(
            "/usr/bin/ssh",
            [
                "-i", PathExpander.expand(target.identityFile),
                "-o", "ConnectTimeout=\(timeout)",
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                target.host,
                "true",
            ],
            timeout: Double(timeout) + 2
        )
        return result.ok
    }

    private static func waitForJump(_ config: AppConfig, jump: Jump? = nil, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if jumpReachable(config, jump: jump, timeout: 3) { return true }
            let remain = deadline.timeIntervalSinceNow
            if remain <= 0 { break }
            sleep(min(3, remain))
        }
        return false
    }

    private static func waitForPorts(_ config: AppConfig, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if tunnelHealthy(config: config) { return true }
            sleep(1)
        }
        return tunnelHealthy(config: config)
    }

    private static func waitForForward(_ forward: Forward, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if forwardUp(forward) { return true }
            sleep(1)
        }
        return forwardUp(forward)
    }

    private static func occupiedPort(_ config: AppConfig) -> (port: Int, pid: Int32)? {
        for forward in config.forwards {
            if let pid = listeners(forward.localPort).first {
                return (forward.localPort, pid)
            }
        }
        return nil
    }

    // MARK: - Probes

    private static func routePresent(_ marker: String) -> Bool {
        let result = Shell.run("/usr/sbin/netstat", ["-rn"], timeout: 8)
        return result.stdout.contains(marker)
    }

    /// 写成 `主机:端口` 就测 TCP 连得上，否则 ping。公司网关常常不回 ICMP，
    /// 测跳板机的 22 端口（和原来的脚本一致）更可靠。
    static func tcpTarget(_ raw: String) -> (host: String, port: Int)? {
        guard let colon = raw.lastIndex(of: ":"), !raw.contains("]") else { return nil }
        let host = String(raw[..<colon])
        guard !host.isEmpty, let port = Int(raw[raw.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    private static func ping(_ host: String) -> Bool {
        if let target = tcpTarget(host) {
            return Shell.run("/usr/bin/nc", ["-z", "-w", "3", target.host, String(target.port)], timeout: 6).ok
        }
        let result = Shell.run("/sbin/ping", ["-c", "1", "-W", "3000", "-t", "4", host], timeout: 6)
        return result.ok
    }

    private static func forwardUp(_ forward: Forward) -> Bool {
        switch forward.check {
        case .http: return httpUp(forward.localPort)
        case .tcp: return tcpUp(forward.localPort)
        }
    }

    private static func tcpUp(_ port: Int) -> Bool {
        Shell.run("/usr/bin/nc", ["-z", "-w", "3", "127.0.0.1", String(port)], timeout: 5).ok
    }

    private static func httpUp(_ port: Int) -> Bool {
        let result = Shell.run(
            "/usr/bin/curl",
            ["-s", "-o", "/dev/null", "--max-time", "3", "http://127.0.0.1:\(port)/"],
            timeout: 5
        )
        return result.ok
    }

    static func listeners(_ port: Int) -> [Int32] {
        let result = Shell.run(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
            sudo: true,
            timeout: 8
        )
        return result.stdout.split(whereSeparator: \.isNewline).compactMap {
            Int32($0.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Watchdogs

    private static func arrangeVPNWatch(config: AppConfig, procs: [Proc], enable: Bool, takeOver: Bool) {
        guard enable else { return }
        let shell = procs.contains { isShellWatchdog($0.command, marker: "_vpn_watchdog") } || shellWatchdogAlive("_vpn_watchdog")
        if shell && !takeOver {
            emit("自动重连仍由终端守护负责")
            return
        }
        if shell { stopShellWatchdog("_vpn_watchdog") }
        writeFlag(config.vpnWatchdogFile, true)
        startServiceIfNeeded()
        emit("VPN 自动重连由本应用负责")
    }

    private static func arrangeTunnelWatch(config: AppConfig, procs: [Proc], enable: Bool, takeOver: Bool) {
        guard enable else { return }
        let shell = procs.contains { isShellWatchdog($0.command, marker: "_tunnel_watchdog") } || shellWatchdogAlive("_tunnel_watchdog")
        if shell && !takeOver {
            emit("隧道自动重连仍由终端守护负责")
            return
        }
        if shell { stopShellWatchdog("_tunnel_watchdog") }
        writeFlag(config.tunnelWatchdogFile, true)
        startServiceIfNeeded()
        emit("隧道自动重连由本应用负责")
    }

    private static func healIfNeeded(vpn: VPNSnapshot, tunnel: TunnelSnapshot) {
        guard ConfigStore.wanted else { return }
        let vpnNeeds = vpn.watchFlag && vpn.watch != .shell && vpn.watch != .both
        let tunnelNeeds = tunnel.watchFlag && tunnel.watch != .shell && tunnel.watch != .both
        guard vpnNeeds || tunnelNeeds else { return }
        guard !serviceAlive() else { return }
        ensureService()
    }

    private static func startServiceIfNeeded() {
        ConfigStore.setWanted(true)
        guard !serviceAlive() else { return }
        guard let executable = Bundle.main.executableURL else {
            emit("找不到应用自己的可执行文件，没能拉起后台守护")
            return
        }
        do {
            _ = try Spawn.launch(
                executable: executable,
                arguments: ["--service"],
                logPath: ConfigStore.serviceLogPath,
                environment: ProcessInfo.processInfo.environment
            )
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline && !serviceAlive() {
                Thread.sleep(forTimeInterval: 0.1)
            }
            emit(serviceAlive() ? "后台守护已启动" : "后台守护已拉起，但还没确认 pid")
        } catch {
            emit("后台守护启动失败：\(error.localizedDescription)")
        }
    }

    static func stopShellWatchdog(_ marker: String) {
        func matching() -> [Proc] {
            Shell.processes().filter { isShellWatchdog($0.command, marker: marker) }
        }
        for proc in matching() {
            signal(proc.pid, sudo: false)
        }
        sleep(0.4)
        for proc in matching() {
            signal(proc.pid, sudo: true, force: true)
        }
    }

    private static func shellWatchdogAlive(_ marker: String) -> Bool {
        Shell.processes().contains { isShellWatchdog($0.command, marker: marker) }
    }

    private static func syncWanted(config: AppConfig) {
        if !flag(config.vpnWatchdogFile) && !flag(config.tunnelWatchdogFile) {
            ConfigStore.setWanted(false)
        }
    }

    static func writeFlag(_ path: String, _ on: Bool) {
        let expanded = PathExpander.expand(path)
        if on {
            FileManager.default.createFile(atPath: expanded, contents: Data())
        } else {
            try? FileManager.default.removeItem(atPath: expanded)
        }
    }

    private static func readPID(_ path: String) -> Int32? {
        let expanded = PathExpander.expand(path)
        guard let text = Shell.readSmall(expanded) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func signal(_ pid: Int32, sudo: Bool, force: Bool = false) {
        guard pid > 0, pid != getpid() else { return }
        let args = force ? ["-9", String(pid)] : [String(pid)]
        _ = Shell.run("/bin/kill", args, sudo: sudo, timeout: 8)
    }

    private static func logTail(_ path: String) -> String {
        let text = Shell.tail(path: PathExpander.expand(path), lines: 8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "日志是空的" : text
    }

    static func emit(_ message: String) {
        let safe = Redact.line(message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return }
        for line in safe.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = Redact.line(String(line))
            JournalStore.shared.add(text)
            if AppRuntime.isService {
                print(text)
                fflush(stdout)
            }
        }
    }

    static func emitLog(_ file: String, _ message: String) {
        emit(message)
        let line = "[\(Timestamp.now())] \(Redact.line(message))\n"
        Shell.append(path: PathExpander.expand(file), text: line)
    }

    private static func sleep(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }
}

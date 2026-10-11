import Darwin
import Foundation

enum AppRuntime {
    nonisolated(unsafe) static var isService = false
}

enum SpawnError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

enum Spawn {
    static func launch(executable: URL, arguments: [String], logPath: String, environment: [String: String]) throws -> pid_t {
        ConfigStore.ensureDir()
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { throw SpawnError.message(tr("无法初始化进程属性", "Couldn't initialize process attributes")) }
        defer { posix_spawnattr_destroy(&attr) }
        let flagResult = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        if flagResult != 0 {
            throw SpawnError.message(tr("无法脱离会话：\(String(cString: strerror(flagResult)))", "Couldn't detach from the session: \(String(cString: strerror(flagResult)))"))
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SpawnError.message(tr("无法初始化文件动作", "Couldn't initialize file actions")) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let logfd = Darwin.open(logPath, Darwin.O_CREAT | Darwin.O_WRONLY | Darwin.O_APPEND, 0o644)
        if logfd >= 0 {
            _ = posix_spawn_file_actions_adddup2(&actions, logfd, STDOUT_FILENO)
            _ = posix_spawn_file_actions_adddup2(&actions, logfd, STDERR_FILENO)
        }
        _ = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", Darwin.O_RDONLY, 0)

        let argvStrings = [executable.path] + arguments
        let argvPointers = argvStrings.map { strdup($0) }
        defer { argvPointers.forEach { free($0) } }
        var argv = argvPointers.map { UnsafeMutablePointer($0) } + [nil]

        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        let envPointers = envStrings.map { strdup($0) }
        defer { envPointers.forEach { free($0) } }
        var envp = envPointers.map { UnsafeMutablePointer($0) } + [nil]

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &actions, &attr, &argv, &envp)
        if logfd >= 0 { Darwin.close(logfd) }
        guard rc == 0 else {
            throw SpawnError.message(String(cString: strerror(rc)))
        }
        return pid
    }
}

final class ServiceControl: @unchecked Sendable {
    static let shared = ServiceControl()
    private let lock = NSLock()
    private var flag = false

    /// 信号处理在另一个队列里写，主循环里读。
    var stop: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

enum Service {
    static func run() {
        AppRuntime.isService = true
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { ServiceControl.shared.stop = true }
        term.resume()
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { ServiceControl.shared.stop = true }
        interrupt.resume()

        ConfigStore.ensureDir()
        let pidPath = ConfigStore.servicePIDPath
        try? String(getpid()).write(toFile: pidPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        Engine.emit(tr("后台守护开始 pid=\(getpid())", "Background service started pid=\(getpid())"))

        var lastVPN = Date.distantPast
        var lastTunnel = Date.distantPast
        var vpnFails = 0
        var tunnelFails = 0
        var idleSince: Date?

        while !ServiceControl.shared.stop {
            Thread.sleep(forTimeInterval: 1)
            if ServiceControl.shared.stop { break }
            // 配置读不了就什么都不做：用默认值去「修复」只会把连接弄坏。
            if ConfigStore.isCorrupt { continue }
            let config = ConfigStore.load()
            let now = Date()
            let vpnFlag = Engine.flag(config.vpnWatchdogFile)
            let tunnelFlag = Engine.flag(config.tunnelWatchdogFile)
            let vpnDue = vpnFlag && now.timeIntervalSince(lastVPN) >= Double(max(config.vpnWatchdogInterval, 5))
            let tunnelDue = tunnelFlag && now.timeIntervalSince(lastTunnel) >= Double(max(config.tunnelWatchdogInterval, 5))

            if !vpnFlag && !tunnelFlag {
                if idleSince == nil { idleSince = now }
                if let idleSince, now.timeIntervalSince(idleSince) > 3 {
                    Engine.emit(tr("守护标记已清除，后台服务退出", "Watchdog flags cleared, background service exiting"))
                    break
                }
                continue
            }
            idleSince = nil
            // 每秒起一次 ps 太浪费，只在真要检查的时候才看进程。
            guard vpnDue || tunnelDue else { continue }
            let procs = Shell.processes()
            let shellVPN = procs.contains { Engine.isShellWatchdog($0.command, marker: "_vpn_watchdog") }
            let shellTunnel = procs.contains { Engine.isShellWatchdog($0.command, marker: "_tunnel_watchdog") }

            if vpnDue && !shellVPN {
                lastVPN = now
                let healthy = Engine.vpnHealthy(config: config, procs: procs)
                if healthy {
                    vpnFails = 0
                } else {
                    vpnFails += 1
                    Engine.emitLog(config.vpnLogFile, tr("VPN 健康检查失败（\(vpnFails)/\(config.vpnFailThreshold)）", "VPN health check failed (\(vpnFails)/\(config.vpnFailThreshold))"))
                    if Engine.shouldRestart(flag: true, shell: false, healthy: false, fails: vpnFails, threshold: config.vpnFailThreshold) {
                        Engine.restartVPNPreservingFlag(config: config)
                        vpnFails = 0
                        Thread.sleep(forTimeInterval: 10)
                    }
                }
            }

            if tunnelDue && !shellTunnel {
                lastTunnel = now
                let healthy = Engine.tunnelHealthy(config: config)
                if healthy {
                    tunnelFails = 0
                } else {
                    tunnelFails += 1
                    Engine.emitLog(config.tunnelLogFile, tr("隧道健康检查失败（\(tunnelFails)/\(config.tunnelFailThreshold)）", "Tunnel health check failed (\(tunnelFails)/\(config.tunnelFailThreshold))"))
                    if Engine.shouldRestart(flag: true, shell: false, healthy: false, fails: tunnelFails, threshold: config.tunnelFailThreshold) {
                        Engine.restartTunnelPreservingFlag(config: config)
                        tunnelFails = 0
                        Thread.sleep(forTimeInterval: 8)
                    }
                }
            }
        }
    }
}

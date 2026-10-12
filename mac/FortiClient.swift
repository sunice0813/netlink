import Darwin
import Foundation

/// FortiClient 的系统开关不会把账号交给它的隧道。真正的连接在菜单栏 FortiTray
/// 的本地套接字上，由官方的 guimessenger 组件发送。密码只从本机凭据文件读，不进参数、日志或配置。
enum FortiClient {
    static let addonPath = "/Applications/FortiClient.app/Contents/Resources/app.asar.unpacked/assets/js/guimessenger_jyp.node"
    static let trayApp = "/Applications/FortiClient.app/Contents/Resources/runtime.helper/FortiClientAgent.app/Contents/Resources/FortiTray/FortiTray.app"
    static let profilePlist = "/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"

    enum Result {
        case accepted
        case rejected
        case failed
        case noNode
        case noAddon
    }

    static var credentialPath: String {
        ConfigStore.directory.appendingPathComponent("credentials/forticlient").path
    }

    static let script = """
    const fs = require("fs");
    const addon = process.env.FCT_ADDON;
    if (!addon) { process.stdout.write("NOADDON"); process.exit(0); }
    const m = require(addon);
    const input = JSON.parse(fs.readFileSync(0, "utf8"));
    function asList(value) {
      if (Array.isArray(value)) return value;
      if (typeof value === "string") return JSON.parse(value);
      return [];
    }
    (async () => {
      try { await m.SetGuiHandle(process.pid); } catch (_) {}
      const listed = asList(await m.GetVPNConnectionList());
      const profile = listed.find((item) => item && item.type === "ssl") || listed[0];
      const name = (profile && profile.connection_name) || input.name || "";
      const type = (profile && profile.type) || "ssl";
      if (input.action === "disconnect") {
        const result = await m.DisconnectTunnel(JSON.stringify({
          name: name,
          connection_name: name,
          connection_type: type
        }));
        process.stdout.write(String(result));
        return;
      }
      if (!name || !input.username || !input.password) {
        process.stdout.write("NEEDLOGIN");
        return;
      }
      const result = await m.ConnectTunnel(JSON.stringify({
        name: name,
        connection_name: name,
        connection_type: type,
        username: input.username,
        password: input.password,
        save_password: "0",
        save_user_name: "0",
        always_up: "0",
        auto_connect: "0",
        certificate: ""
      }));
      process.stdout.write(String(result));
    })().catch(() => {
      process.stdout.write("FAIL");
    });
    """

    static func nodeBinary() -> String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func nodeArguments(binary: String) -> [String] {
        [binary, "-e", script]
    }

    static func hasLogin() -> Bool { savedLogin() != nil }

    static func savedLogin() -> VPNCredential? {
        Credentials.load(file: credentialPath)
    }

    /// 图上预先填的用户名。密码不从 FortiClient 的配置里读。
    static func suggestedAccount() -> (name: String, user: String) {
        if let saved = savedLogin() {
            return (saved.host, saved.user)
        }
        return profileAccount()
    }

    static func save(user: String, password: String?) throws {
        let profile = profileAccount()
        let host = profile.name.isEmpty ? "FortiClient" : profile.name
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? (savedLogin()?.user ?? profile.user) : trimmed
        let directory = URL(fileURLWithPath: credentialPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Credentials.update(file: credentialPath, host: host, user: resolved, newPassword: password)
    }

    static func send(action: String, user: String, password: String) -> Result {
        guard FileManager.default.fileExists(atPath: addonPath) else { return .noAddon }
        guard let binary = nodeBinary() else { return .noNode }
        if action == "connect", user.isEmpty || password.isEmpty { return .failed }
        // ConnectTunnel 必须在 FortiClient 主程序已注册时才回 ["1"]；只开 FortiTray 会得到 ["0"]。
        ensureMessenger(forceRestart: false)
        let first = invoke(binary: binary, action: action, user: user, password: password)
        if first == .accepted { return .accepted }
        if first == .rejected || first == .failed {
            ensureMessenger(forceRestart: true)
            return invoke(binary: binary, action: action, user: user, password: password)
        }
        return first
    }

    private static func invoke(binary: String, action: String, user: String, password: String) -> Result {
        let body: [String: String] = [
            "action": action,
            "username": user,
            "password": password,
            "name": profileAccount().name,
        ]
        guard let stdin = try? JSONSerialization.data(withJSONObject: body) else { return .failed }
        let result = Shell.run(
            binary,
            Array(nodeArguments(binary: binary).dropFirst()),
            stdin: stdin,
            timeout: 20,
            environment: ["FCT_ADDON": addonPath]
        )
        let text = result.stdout + result.stderr
        if text.contains("[\"1\"]") { return .accepted }
        if text.contains("NEEDLOGIN") || text.contains("[\"0\"]") { return .rejected }
        return .failed
    }

    static func recentLoginRejected() -> Bool {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Fortinet/FortiClient/Logs/fortitray.log")
        let text = Shell.tail(path: path, lines: 40)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd HH:mm:ss"
        let cutoff = Date().addingTimeInterval(-40)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.contains("Permission denied") || line.contains("Login failed") else { continue }
            let stamp = String(line.prefix(17))
            if let date = formatter.date(from: stamp), date >= cutoff { return true }
        }
        return false
    }

    private static func ensureMessenger(forceRestart: Bool = false) {
        ensureTray(forceRestart: forceRestart)
        ensureMainApp()
    }

    private static func ensureTray(forceRestart: Bool = false) {
        let socket = "/tmp/fctvpnctl.sock_\(getuid())"
        if !forceRestart, socketAccepts(socket) { return }
        for proc in Shell.processes() {
            let cmd = proc.command
            guard cmd.contains("/FortiTray.app/") || cmd.hasSuffix("/FortiTray") || cmd.contains("FortiTray.app/Contents/MacOS/FortiTray") else {
                continue
            }
            _ = Darwin.kill(proc.pid, SIGTERM)
        }
        Thread.sleep(forTimeInterval: 0.4)
        try? FileManager.default.removeItem(atPath: socket)
        guard FileManager.default.fileExists(atPath: trayApp) else { return }
        _ = Shell.run("/usr/bin/open", ["-g", trayApp], timeout: 8)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if socketAccepts(socket) { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private static func ensureMainApp() {
        let isGUI: (Proc) -> Bool = { proc in
            proc.command.contains("/FortiClient.app/Contents/MacOS/FortiClient")
                && !proc.command.contains("FortiClientAgent")
                && !proc.command.contains("FortiTray")
        }
        if !Shell.processes().contains(where: isGUI) {
            _ = Shell.run("/usr/bin/open", ["-g", "-a", "FortiClient"], timeout: 8)
        }
        // 主程序向 servctl 注册需要一点时间；注册前 ConnectTunnel 只会回 ["0"]。
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if Shell.processes().contains(where: isGUI) {
                Thread.sleep(forTimeInterval: 1.5)
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private static func socketAccepts(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { buf in
                    strncpy(buf, src, maxLen)
                }
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        return ok
    }

    private static func profileAccount() -> (name: String, user: String) {
        let url = URL(fileURLWithPath: profilePlist)
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let profiles = root["Profiles"] as? [String: Any],
              !profiles.isEmpty else {
            return ("FortiClient", "")
        }
        let name = profiles.first { integer((($0.value as? [String: Any])?["VpnType"])) == 0 }?.key
            ?? profiles.keys.sorted().first
            ?? "FortiClient"
        let user = (profiles[name] as? [String: Any])?["User"] as? String ?? ""
        return (name, user)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

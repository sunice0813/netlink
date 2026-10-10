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
        auto_connect: "0"
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
        ensureTray()
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
        let text = result.stdout
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

    private static func ensureTray() {
        let socket = "/tmp/fctvpnctl.sock_\(getuid())"
        if FileManager.default.fileExists(atPath: socket) { return }
        guard FileManager.default.fileExists(atPath: trayApp) else { return }
        _ = Shell.run("/usr/bin/open", ["-g", trayApp], timeout: 8)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socket) { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
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

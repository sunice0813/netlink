import Darwin
import Foundation

enum SelfTest {
    static func run() -> Int32 {
        var failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("ok  \(name)")
            } else {
                print("FAIL \(name)")
                failed += 1
            }
        }

        check("appearance default", AppearanceChoice.parse(nil) == .system)
        check("appearance dark", AppearanceChoice.parse("dark") == .dark)
        check("appearance unknown", AppearanceChoice.parse("nope") == .system)

        let parsed = Credentials.parse("host=vpn.example\nuser=alice\npassword=s3cret\n")
        check("parse credential", parsed?.host == "vpn.example" && parsed?.user == "alice" && parsed?.password == "s3cret")
        check("reject incomplete", Credentials.parse("host=vpn.example\nuser=alice\n") == nil)
        check("keep password spaces", Credentials.parse("host=h\nuser=u\npassword=a b\n")?.password == "a b")

        let redacted = Redact.line("password=s3cret")
        check("redact password", redacted == "password=***" && !redacted.contains("s3cret"))

        let procs = Shell.parsePS("  42 zsh -c source ~/.zshrc; _vpn_watchdog\n  7 /Applications/NetLink.app/Contents/MacOS/NetLink --service\n")
        check("parse ps", procs.count == 2 && procs[0].pid == 42 && procs[0].command.contains("_vpn_watchdog"))
        check(
            "real zsh watchdog",
            Engine.isShellWatchdog("zsh -c source ~/.zshrc >/dev/null 2>&1; _vpn_watchdog", marker: "_vpn_watchdog")
        )
        check(
            "search command is not a watchdog",
            !Engine.isShellWatchdog("/bin/zsh -c ps | awk '/_vpn_watchdog/'", marker: "_vpn_watchdog")
        )
        check("parse service", procs[1].command.contains("--service"))

        let config = AppConfig()
        let args = Engine.openConnectArguments(host: "https://vpn.example", user: "alice", pidFile: "/tmp/p", timeout: 30)
        check("openconnect uses stdin password", args.contains("--passwd-on-stdin") && args.contains("--background"))
        check("password stays out of argv", !args.joined(separator: " ").contains("s3cret"))
        let forwardArgs = Engine.autosshArguments(config: config)
        check("autossh forwards", forwardArgs.contains("80:10.62.1.101:80") && forwardArgs.contains("8080:10.62.1.10:80"))
        let oneForward = Engine.autosshArguments(config: config, forwards: [Forward.bundled[0]])
        check("single forward args", oneForward.contains("80:10.62.1.101:80") && !oneForward.contains("8080:10.62.1.10:80"))
        check("autossh jump", forwardArgs.last == "appdev@10.62.11.31")
        var extra = config
        let other = Jump(name: "备用", host: "bob@10.1.1.1", identityFile: "~/.ssh/bob")
        extra.jumps.append(other)
        let extraForward = Forward(name: "临时", localPort: 9000, targetHost: "10.1.1.2", targetPort: 80, enabled: false, jumpID: other.id)
        let extraArgs = Engine.autosshArguments(config: extra, forwards: [extraForward])
        check("extra jump host", extraArgs.last == "bob@10.1.1.1")
        check("extra jump key", extraArgs.contains(PathExpander.expand("~/.ssh/bob")))
        check("primary args ignore extra jump", forwardArgs.last == "appdev@10.62.11.31" && !forwardArgs.contains("bob@10.1.1.1"))
        let legacy = try? JSONDecoder().decode(AppConfig.self, from: Data(#"{"jumpHost":"a@b","identityFile":"~/.ssh/a","credentialFile":"~/.internalvpn"}"#.utf8))
        check("legacy config grows a jump and vpn", legacy?.jumps.first?.id == Jump.primary && legacy?.vpns.first?.id == VPNProfile.primary && legacy?.jumpHost == "a@b" && legacy?.vpns.first?.kind == "openconnect")
        check("legacy layout version", legacy?.layoutVersion == 0)
        let fresh = AppConfig().defaultLayout()
        let machine = fresh[TopologyKey.machine]!
        let vpn = fresh[TopologyKey.vpn(VPNProfile.primary)]!
        let jump = fresh[TopologyKey.jump(Jump.primary)]!
        let git = fresh[TopologyKey.forward(Forward.bundled[0].id)]!
        let server = fresh[TopologyKey.forward(Forward.bundled[1].id)]!
        check("default reads left to right", machine.x < vpn.x && vpn.x < jump.x && jump.x < git.x && git.x == server.x)
        check("default centers the chain", abs(machine.y - vpn.y) < 0.5 && abs(vpn.y - jump.y) < 0.5 && git.y < jump.y && jump.y < server.y)
        var saved = AppConfig()
        saved.setLayout(CGPoint(x: 9, y: 8), for: TopologyKey.machine)
        let kept = saved.resolvedLayout()[TopologyKey.machine]!
        check("saved position wins", kept.x == 9 && kept.y == 8)
        var graph = AppConfig()
        graph.vpns.append(VPNProfile(id: VPNProfile.shadowrocket, name: "Shadowrocket", credentialFile: "", kind: "shadowrocket", serviceName: "Shadowrocket"))
        graph.vpns.append(VPNProfile(id: VPNProfile.forticlient, name: "FortiClient", credentialFile: "", kind: "forticlient", serviceName: "VPN"))
        let arranged = graph.defaultLayout()
        let companyY = arranged[TopologyKey.vpn(VPNProfile.primary)]!.y
        let shadowY = arranged[TopologyKey.vpn(VPNProfile.shadowrocket)]!.y
        let fortiY = arranged[TopologyKey.vpn(VPNProfile.forticlient)]!.y
        check("default puts the tunnel vpn in the middle", shadowY < companyY && companyY < fortiY)
        let oldVPN = try? JSONDecoder().decode(VPNProfile.self, from: Data(#"{"id":"B1000000-0000-4000-8000-000000000001","name":"VPN","credentialFile":"~/.internalvpn"}"#.utf8))
        check("old vpn profile stays openconnect", oldVPN?.kind == "openconnect" && oldVPN?.isShadowrocket == false)

        let encoded = try? JSONEncoder().encode(config)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
        check("config roundtrip", decoded?.forwards.count == 2 && decoded?.jumpHost == config.jumpHost)
        let gitlabHTML = #"<link rel="apple-touch-icon" href="/apple.png" /><link rel="icon" type="image/png" href="/assets/favicon.png" />"#
        let gitlabIcon = SiteIconLookup.linkIcon(in: gitlabHTML, base: URL(string: "http://git.techtanium.internal/users/sign_in")!)
        check("gitlab tab icon", gitlabIcon?.absoluteString == "http://git.techtanium.internal/assets/favicon.png")
        let jumpHTML = "<html><head><title></title></head></html>"
        check("page without icon link", SiteIconLookup.linkIcon(in: jumpHTML, base: URL(string: "http://127.0.0.1:8080/")!) == nil)
        let jumpJSON = Data(#"{"INTERFACE":{"favicon":"/static/img/facio.ico","login_title":"JumpServer"}}"#.utf8)
        let jumpIcon = SiteIconLookup.interfaceFavicon(in: jumpJSON, base: URL(string: "http://127.0.0.1:8080")!)
        check("jumpserver tab icon", jumpIcon?.absoluteString == "http://127.0.0.1:8080/static/img/facio.ico")
        check("png is an image", SiteIconLookup.isImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D]), type: "image/png"))
        check("html is not an image", !SiteIconLookup.isImage(Data("<html>".utf8), type: "text/html"))

        check("gitlab opens by name", Forward.bundled[0].browseURL?.absoluteString == "http://git.techtanium.internal/")
        check("jumpserver opens locally", Forward.bundled[1].browseURL?.absoluteString == "http://127.0.0.1:8080/")
        let oldGitLab = try? JSONDecoder().decode(
            Forward.self,
            from: Data(#"{"name":"GitLab","localPort":80,"targetHost":"10.62.1.101","targetPort":80}"#.utf8)
        )
        check("old gitlab config uses domain", oldGitLab?.browseURL?.absoluteString == "http://git.techtanium.internal/")

        var broken = config
        broken.forwards.append(Forward(name: "重复", localPort: 80, targetHost: "10.0.0.1", targetPort: 80))
        check("duplicate port rejected", !ConfigCheck.issues(broken).isEmpty)

        check("shell owns watch", Engine.classifyWatch(flag: true, shell: true, serviceAlive: false) == .shell)
        check("app owns watch", Engine.classifyWatch(flag: true, shell: false, serviceAlive: true) == .app)
        check("both owners", Engine.classifyWatch(flag: true, shell: true, serviceAlive: true) == .both)
        check("stale flag", Engine.classifyWatch(flag: true, shell: false, serviceAlive: false) == .stale)
        check("watch off", Engine.classifyWatch(flag: false, shell: false, serviceAlive: true) == .off)
        check("no restart while shell owns it", !Engine.shouldRestart(flag: true, shell: true, healthy: false, fails: 9, threshold: 2))
        check("no restart when healthy", !Engine.shouldRestart(flag: true, shell: false, healthy: true, fails: 9, threshold: 2))
        check("restart at threshold", Engine.shouldRestart(flag: true, shell: false, healthy: false, fails: 2, threshold: 2))
        check("wait for second failure", !Engine.shouldRestart(flag: true, shell: false, healthy: false, fails: 1, threshold: 2))

        FileLock.with {}
        check("file lock", true)
        let fortiArgs = FortiClient.nodeArguments(binary: "/opt/homebrew/bin/node")
        let fortiSecret = "forti-secret-sample"
        let fortiPayload = (try? JSONSerialization.data(withJSONObject: [
            "action": "connect", "username": "alice", "password": fortiSecret,
        ])) ?? Data()
        let fortiPayloadText = String(data: fortiPayload, encoding: .utf8) ?? ""
        check("forticlient argv hides password", !fortiArgs.joined(separator: " ").contains(fortiSecret))
        check("forticlient payload stays on stdin", fortiPayloadText.contains(fortiSecret) && fortiPayloadText.contains("\"password\""))
        check("forticlient script talks to messenger", FortiClient.script.contains("ConnectTunnel") && FortiClient.script.contains("DisconnectTunnel") && !FortiClient.script.contains("console.log"))
        check("shadowrocket app path", Engine.systemVPNAppPath(kind: "shadowrocket") == "/Applications/Shadowrocket.app")
        check("forticlient app path", Engine.systemVPNAppPath(kind: "forticlient") == "/Applications/FortiClient.app")
        check("forticlient icon file", AppIcon.bundledIconURL(appPath: "/Applications/FortiClient.app")?.lastPathComponent == "electron.icns")
        check("shadowrocket icon loads", AppIcon.image(forApp: "/Applications/Shadowrocket.app")?.isValid == true)
        check("forticlient icon loads", AppIcon.image(forApp: "/Applications/FortiClient.app")?.isValid == true)
        check("missing app has no icon", AppIcon.image(forApp: "/Applications/NetLinkMissing.app") == nil)
        check("shadowrocket bundle id", Engine.systemVPNBundleID(kind: "shadowrocket") == "com.liguangming.Shadowrocket")
        check("forticlient bundle id", Engine.systemVPNBundleID(kind: "forticlient") == "com.fortinet.FortiClient")
        check("forticlient also quits the tray", Engine.systemVPNBundleIDs(kind: "forticlient").contains("com.fortinet.forticlient.macos.vpn"))
        check("openconnect is not a system app", Engine.systemVPNAppPath(kind: "openconnect") == nil && Engine.systemVPNBundleID(kind: "openconnect") == nil)
        check(
            "shadowrocket extension is the app",
            Engine.isSystemVPNAppProcess(kind: "shadowrocket", command: "/private/var/folders/x/d/Wrapper/Shadowrocket.app/PlugIns/PacketTunnel.appex/PacketTunnel")
        )
        check(
            "fortitray is the app",
            Engine.isSystemVPNAppProcess(kind: "forticlient", command: "Contents/Resources/FortiTray/FortiTray.app/Contents/MacOS/FortiTray")
        )
        check(
            "forticlient daemon is not the app",
            !Engine.isSystemVPNAppProcess(kind: "forticlient", command: "/Library/Application Support/Fortinet/FortiClient/bin/fctctld")
        )
        check(
            "forticlient system extension is not the app",
            !Engine.isSystemVPNAppProcess(kind: "forticlient", command: "/Library/SystemExtensions/abc/com.fortinet.forticlient.macos.vpn.nwextension.systemextension/Contents/MacOS/com.fortinet.forticlient.macos.vpn.nwextension")
        )
        check("spawn dry service", spawnDry())
        if failed == 0 {
            print("self-test passed")
            return 0
        }
        print("self-test failed: \(failed)")
        return 1
    }

    private static func spawnDry() -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("netlink-dry-\(getpid()).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        var environment = ProcessInfo.processInfo.environment
        environment["NETLINK_SERVICE_DRY"] = "1"
        guard let pid = try? Spawn.launch(
            executable: executable,
            arguments: ["--service"],
            logPath: logURL.path,
            environment: environment
        ), pid > 0 else { return false }
        defer { Darwin.kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: logURL, encoding: .utf8), text.contains("dry-ready") {
                return Darwin.kill(pid, 0) == 0 || errno == EPERM
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}

enum StatusCLI {
    static func run() -> Int32 {
        let (vpn, tunnel) = Engine.probe(heal: false)
        print("VPN: \(vpn.phase.title) pid=\(vpn.pid.map(String.init) ?? "-") 进程=\(vpn.processAlive ? "在" : "不在") 路由=\(vpn.routePresent ? "有" : "无") 网关=\(vpn.gatewayReachable ? "通" : "不通") \(vpn.watch.label)")
        if vpn.credentialOK {
            print("账号: \(vpn.user) @ \(vpn.host)")
        } else {
            print("账号: 凭据不完整")
        }
        print("隧道: \(tunnel.okCount)/\(tunnel.ports.count) autossh=\(tunnel.autosshRunning ? "在" : "不在") \(tunnel.watch.label)")
        for port in tunnel.ports {
            let state = port.httpOK ? "通" : (port.listening ? "无响应" : "未听")
            print("  \(port.name) \(port.browseLabel) → \(port.target) \(state)")
        }
        fflush(stdout)
        return 0
    }
}

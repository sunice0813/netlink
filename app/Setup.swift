import Foundation

// 首次打开时补齐运行环境：缺 openconnect / autossh 就用 Homebrew 装，
// sudo 不能免密就弹系统密码框，写 /etc/sudoers.d/netlink。

enum Setup {
    static let sudoersFile = "/private/etc/sudoers.d/netlink"
    static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static var logPath: String { ConfigStore.directory.appendingPathComponent("setup.log").path }

    static let passwordPrompt = "NetLink 要把免密 sudo 规则写进 /etc/sudoers.d/netlink。连接 VPN 要建虚拟网卡、改路由，openconnect 和 autossh 必须以 root 运行。只需输入这一次，之后连接和断开不再要密码。"

    enum SudoResult: Equatable {
        case done
        case cancelled
        case failed(String)
    }

    /// 免密 sudo 要放行的命令，顺序和 README 一致。
    static func sudoCommands(config: AppConfig) -> [String] {
        [config.openconnectPath, config.autosshPath, "/bin/kill", "/usr/sbin/lsof", "/usr/bin/true"]
    }

    /// 还不能免密执行的命令。程序不存在的不算在内：那是缺依赖，另有提示，
    /// 而且 `sudo -l` 对不存在的路径总是失败，算进来会一直弹密码框。
    static func sudoMissing(config: AppConfig) -> [String] {
        sudoCommands(config: config).filter { command in
            FileManager.default.isExecutableFile(atPath: command)
                && !Shell.run("/usr/bin/sudo", ["-n", "-l", command], timeout: 8).ok
        }
    }

    static func brewPath() -> String? {
        brewCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 缺哪些 Homebrew 包。配置里改成了别处的路径时 brew 装了也没用，不算。
    static func missingFormulas(config: AppConfig, brew: String) -> [String] {
        let bin = (brew as NSString).deletingLastPathComponent
        return [(config.openconnectPath, "openconnect"), (config.autosshPath, "autossh")].compactMap { path, formula in
            guard !FileManager.default.isExecutableFile(atPath: path), path == bin + "/" + formula else { return nil }
            return formula
        }
    }

    /// 以当前用户身份在后台装依赖，输出写进 setup.log。brew 不允许用 root 跑。
    @discardableResult
    static func installDependencies() -> Bool {
        let config = ConfigStore.load()
        guard let brew = brewPath() else {
            Engine.emit("没有找到 Homebrew，先到 https://brew.sh 安装")
            return false
        }
        let formulas = missingFormulas(config: config, brew: brew)
        guard !formulas.isEmpty else { return true }
        ConfigStore.ensureDir()
        Shell.append(path: logPath, text: "[\(Timestamp.now())] brew install \(formulas.joined(separator: " "))\n")
        let bin = (brew as NSString).deletingLastPathComponent
        let result = Shell.run(
            brew,
            ["install", "--formula"] + formulas,
            timeout: 1800,
            appendLog: logPath,
            environment: [
                "PATH": "\(bin):/usr/bin:/bin:/usr/sbin:/sbin",
                "NONINTERACTIVE": "1",
                "HOMEBREW_NO_ENV_HINTS": "1",
            ]
        )
        if result.ok && missingFormulas(config: config, brew: brew).isEmpty {
            Shell.append(path: logPath, text: "[\(Timestamp.now())] 完成\n")
            Engine.emit("已安装 \(formulas.joined(separator: "、"))")
            return true
        }
        let reason = result.timedOut ? "超时" : "退出码 \(result.code)"
        Shell.append(path: logPath, text: "[\(Timestamp.now())] 失败（\(reason)）\n")
        Engine.emit("安装 \(formulas.joined(separator: "、")) 失败（\(reason)），详情见 日志 → 安装")
        return false
    }

    // MARK: - sudoers

    /// macOS 短用户名的字符集。这些值会拼进 sudoers，不能带空格、逗号、冒号、等号、反斜杠。
    static func safeUser(_ user: String) -> Bool {
        user.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil
    }

    static func safeCommand(_ path: String) -> Bool {
        path.range(of: "^(/[A-Za-z0-9_.+-]+)+$", options: .regularExpression) != nil
            && !path.split(separator: "/").contains("..")
    }

    static func sudoersRule(user: String, commands: [String]) -> String? {
        guard safeUser(user), !commands.isEmpty, commands.allSatisfy(safeCommand) else { return nil }
        return """
        # 由 NetLink 生成：免密执行连接 VPN 和隧道要用的命令。
        # 删除本文件即可撤销：sudo rm /etc/sudoers.d/netlink
        \(user) ALL=(root) NOPASSWD: \(commands.joined(separator: ", "))

        """
    }

    /// 以 root 运行的脚本。规则先在临时文件里用 visudo 校验，装好后再校验这个文件（含属主和权限），
    /// 原来整体校验能过、装完不能过也算失败。失败就还原，免得把 sudo 弄坏。
    /// 整体校验不要求本来就能过：别的文件权限不对之类的老问题，不该拦住这一步。
    /// 规则用 base64 传进来，不用处理引号。
    static func installScript(rule: String) -> String {
        let encoded = Data(rule.utf8).base64EncodedString()
        return """
        set -e
        umask 077
        tmp=$(/usr/bin/mktemp /private/tmp/netlink-sudoers.XXXXXX)
        trap '/bin/rm -f "$tmp" "$tmp.bak"' EXIT
        /bin/echo '\(encoded)' | /usr/bin/base64 -D > "$tmp"
        /usr/sbin/visudo -cqf "$tmp"
        target='\(sudoersFile)'
        /bin/mkdir -p /private/etc/sudoers.d
        if [ -f "$target" ]; then /bin/cp -p "$target" "$tmp.bak"; fi
        before=ok
        /usr/sbin/visudo -cq >/dev/null 2>&1 || before=bad
        /usr/bin/install -m 0440 -o root -g wheel "$tmp" "$target"
        if ! /usr/sbin/visudo -cqf "$target" || { [ "$before" = ok ] && ! /usr/sbin/visudo -cq; }; then
          if [ -f "$tmp.bak" ]; then /bin/cp -p "$tmp.bak" "$target"; else /bin/rm -f "$target"; fi
          exit 1
        fi
        """
    }

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func installSudoers() -> SudoResult {
        let config = ConfigStore.load()
        guard let rule = sudoersRule(user: NSUserName(), commands: sudoCommands(config: config)) else {
            return .failed("用户名或 openconnect / autossh 路径里有 sudoers 不允许的字符，请手动配置")
        }
        let script = "do shell script \(appleScriptString(installScript(rule: rule))) "
            + "with prompt \(appleScriptString(passwordPrompt)) with administrator privileges"
        let result = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 900)
        if result.ok {
            let missing = sudoMissing(config: config)
            return missing.isEmpty ? .done : .failed("规则已写入，但仍不能免密执行：\(missing.joined(separator: "、"))")
        }
        if result.stderr.contains("-128") {
            return .cancelled
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail.isEmpty ? "写入免密 sudo 规则失败" : "写入免密 sudo 规则失败：\(detail)")
    }
}

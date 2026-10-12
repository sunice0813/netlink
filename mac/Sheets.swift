import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LogsView: View {
    var model: AppModel
    @Environment(\.netlinkTheme) private var theme
    @State private var logSource = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker(tr("日志", "Logs"), selection: $logSource) {
                    Text("VPN").tag(0)
                    Text(tr("隧道", "Tunnel")).tag(1)
                    Text(tr("安装", "Install")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(tr("密码不会出现在日志里", "Passwords never appear in logs"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if !model.journal.isEmpty {
                Text(model.journal.suffix(8).joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Rectangle().fill(theme.line).frame(height: 1)
            ScrollView {
                Text(logText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.log)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
            .background(Theme.canvas)
        }
        .foregroundStyle(theme.text)
        .frame(minWidth: 560, minHeight: 360)
    }

    private var logText: String {
        let raw = [model.vpnLog, model.tunnelLog, model.setupLog][logSource]
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? tr("还没有日志", "No logs yet") : trimmed
    }
}

@MainActor
struct ConfigTransferView: View {
    var model: AppModel
    @Environment(\.netlinkTheme) private var theme
    @State private var preview: ImportPreview?
    @State private var previewName = ""
    @State private var message = ""
    @State private var failed = false
    @State private var includeSecrets = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                section(
                    title: tr("导出", "Export"),
                    detail: tr("把当前的 VPN、跳板、转发和图上的位置存成一个 JSON 文件。勾选下面的选项后，VPN 账号和 SSH 私钥的内容也一起带上，换一台机器导入就能直接用。", "Saves the current VPNs, jump hosts, forwards and their positions on the map as a JSON file. With the option below checked, the VPN accounts and SSH private keys are included too, so importing it on another Mac just works.")
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(tr("包含 VPN 密码和 SSH 私钥", "Include VPN passwords and SSH private keys"), isOn: $includeSecrets)
                            .toggleStyle(.checkbox)
                        if includeSecrets {
                            Text(tr("导出的文件里是明文密码和私钥，请当成密码一样保管，只交给自己信任的人。", "The exported file contains plain-text passwords and private keys. Keep it as safe as a password and only give it to people you trust."))
                                .font(.system(size: 12))
                                .foregroundStyle(theme.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            exportConfig()
                        } label: {
                            Label(tr("导出到文件…", "Export to File…"), systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Rectangle().fill(theme.line).frame(height: 1)
                section(
                    title: tr("导入", "Import"),
                    detail: tr("选择之前导出的文件，确认内容后替换当前配置。替换前会把现在的配置备份为 config.json.bak。文件里带的账号和私钥会存进应用自己的数据目录。", "Choose a previously exported file, review it, then replace the current config. The current config is backed up as config.json.bak first. Accounts and keys in the file are stored in the app's own data folder.")
                ) {
                    Button {
                        chooseFile()
                    } label: {
                        Label(tr("选择文件…", "Choose File…"), systemImage: "square.and.arrow.down")
                    }
                    if let preview {
                        previewCard(preview)
                    }
                }
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(failed ? theme.bad : theme.ok)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            Spacer(minLength: 0)
        }
        .background(theme.bg)
        .foregroundStyle(theme.text)
        .frame(width: 540)
        .frame(minHeight: 420)
    }

    private func section<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) { content() }
        }
    }

    private func previewCard(_ preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(previewName)
                .font(.system(size: 12, weight: .semibold))
            Text(preview.summary)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
            if !preview.missingCredentials.isEmpty {
                Text(tr("\(preview.missingCredentials.joined(separator: "、")) 的账号文件在这台机器上不存在，文件里也没带账号，导入后要在对应节点里重新填。", "The account files for \(preview.missingCredentials.joined(separator: ", ")) don't exist on this Mac and aren't in the file. Enter them again on those nodes after importing."))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preview.issues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("不能导入：", "Can't import:"))
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(preview.issues, id: \.self) { issue in
                        Text("· \(issue)").font(.system(size: 12))
                    }
                }
                .foregroundStyle(theme.bad)
            }
            HStack(spacing: 8) {
                if preview.issues.isEmpty {
                    Button(tr("导入并替换当前配置", "Import and Replace Current Config")) {
                        apply(preview)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(tr("取消", "Cancel")) {
                    self.preview = nil
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.line, lineWidth: 1))
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.title = tr("导出配置", "Export Config")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "netlink-config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let current = ConfigStore.loadIfValid() ?? model.config
            try ConfigTransfer.write(current, to: url, includeSecrets: includeSecrets)
            show(
                includeSecrets
                    ? tr("已导出到 \(url.path)（含密码和私钥，请妥善保管）", "Exported to \(url.path) (includes passwords and private keys, keep it safe)")
                    : tr("已导出到 \(url.path)", "Exported to \(url.path)"),
                failed: false
            )
        } catch {
            show(tr("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)"), failed: true)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = tr("选择要导入的配置", "Choose a Config to Import")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            preview = try ConfigTransfer.parse(data)
            previewName = url.lastPathComponent
            message = ""
        } catch {
            preview = nil
            show(error.localizedDescription, failed: true)
        }
    }

    private func apply(_ preview: ImportPreview) {
        ConfigTransfer.backupCurrent()
        do {
            let ready = try ConfigTransfer.materialize(preview)
            try model.save(config: ready)
            self.preview = nil
            show(tr("已导入。原配置备份为 config.json.bak，转发和 VPN 的改动重新连接后生效。", "Imported. The previous config was backed up as config.json.bak. Reconnect for forward and VPN changes to take effect."), failed: false)
            Task { await model.refresh() }
        } catch {
            show(tr("导入失败：\(error.localizedDescription)", "Import failed: \(error.localizedDescription)"), failed: true)
        }
    }

    private func show(_ text: String, failed: Bool) {
        message = text
        self.failed = failed
    }
}

@MainActor
struct FortiAccountSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.netlinkTheme) private var theme
    @State private var user = ""
    @State private var password = ""
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("FortiClient 账号", "FortiClient Account"))
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("用户", "User"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                TextField(tr("用户名", "User name"), text: $user)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("密码", "Password"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                SecureField(FortiClient.hasLogin() ? tr("留空则不改", "Leave empty to keep") : tr("必填", "Required"), text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            Text(tr("密码只写在本机的凭据文件里，不进配置，也不进日志。FortiClient 自己没有记住密码。", "The password is only written to the credential file on this Mac, never to the config or logs. FortiClient itself doesn't remember it."))
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.bad)
            }
            HStack {
                Button(tr("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.fortiConnectAfterSave ? tr("保存并连接", "Save and Connect") : tr("保存", "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(theme.bg)
        .foregroundStyle(theme.text)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            user = FortiClient.suggestedAccount().user
        }
    }

    private func save() {
        let connectAfter = model.fortiConnectAfterSave
        do {
            try FortiClient.save(user: user, password: password.isEmpty ? nil : password)
        } catch {
            note = error.localizedDescription
            return
        }
        password = ""
        model.fortiConnectAfterSave = false
        model.fortiPrompt = false
        if connectAfter {
            model.connectVPNProfile(VPNProfile.forticlient)
        }
    }
}

enum PathEdit: Identifiable {
    case vpn(UUID)
    case jump(UUID)
    case addVPN
    case addJump(UUID)
    case addTunnel(UUID)
    case renameMachine
    case renameVPN(UUID)
    case renameJump(UUID)
    case renameForward(UUID)
    case forward(UUID)

    var id: String {
        switch self {
        case .vpn(let id): return "vpn-\(id.uuidString)"
        case .jump(let id): return "jump-\(id.uuidString)"
        case .addVPN: return "add-vpn"
        case .addJump(let id): return "add-jump-\(id.uuidString)"
        case .addTunnel(let id): return "add-tunnel-\(id.uuidString)"
        case .renameMachine: return "rename-machine"
        case .renameVPN(let id): return "rename-vpn-\(id.uuidString)"
        case .renameJump(let id): return "rename-jump-\(id.uuidString)"
        case .renameForward(let id): return "rename-forward-\(id.uuidString)"
        case .forward(let id): return "forward-\(id.uuidString)"
        }
    }
}

@MainActor
struct PathConfigSheet: View {
    var model: AppModel
    var kind: PathEdit
    @Environment(\.dismiss) private var dismiss
    @Environment(\.netlinkTheme) private var theme
    @State private var name = ""
    @State private var host = ""
    @State private var user = ""
    @State private var password = ""
    @State private var jump = ""
    @State private var identity = ""
    @State private var localPort = 9000
    @State private var targetHost = ""
    @State private var targetPort = 80
    @State private var openHost = ""
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            switch kind {
            case .vpn, .addVPN:
                field(tr("名称", "Name"), text: $name, prompt: "VPN")
                field(tr("主机", "Host"), text: $host, prompt: "vpn.example.com")
                field(tr("用户", "User"), text: $user, prompt: tr("用户名", "User name"))
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("密码", "Password"))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.muted)
                    SecureField(isAddingVPN ? tr("必填", "Required") : tr("留空则不改", "Leave empty to keep"), text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                Text(isAddingVPN ? tr("密码只写在本机的凭据文件里，不会进配置。", "The password is only written to the credential file on this Mac, never to the config.") : tr("正在使用的连接不会马上切换。同一时间只连一个 VPN。", "The connection in use won't switch right away. Only one VPN is connected at a time."))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .jump, .addJump:
                field(tr("名称", "Name"), text: $name, prompt: tr("跳板", "Jump host"))
                field(tr("跳板", "Jump host"), text: $jump, prompt: "user@host")
                field(tr("私钥", "Private key"), text: $identity, prompt: "~/.ssh/id_ed25519")
                if !identity.trimmingCharacters(in: .whitespaces).isEmpty, !keyExists {
                    Text(tr("找不到这个私钥", "Can't find this private key"))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.warn)
                }
                Text(tr("写成 user@host。改完要重新连接，正在用的隧道不会马上切换。", "Write it as user@host. Reconnect after changing it; tunnels in use won't switch right away."))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .addTunnel, .forward:
                field(tr("名称", "Name"), text: $name, prompt: "GitLab")
                field(tr("本地端口", "Local port"), text: Binding(
                    get: { String(localPort) },
                    set: { localPort = Int($0.filter(\.isNumber)) ?? localPort }
                ), prompt: "9000")
                field(tr("目标主机", "Target host"), text: $targetHost, prompt: "10.0.0.10")
                field(tr("目标端口", "Target port"), text: Binding(
                    get: { String(targetPort) },
                    set: { targetPort = Int($0.filter(\.isNumber)) ?? targetPort }
                ), prompt: "80")
                field(tr("打开时的域名，可空", "Host name to open (optional)"), text: $openHost, prompt: tr("留空则用 127.0.0.1", "Empty means 127.0.0.1"))
                Text(isEditingForward
                    ? tr("正在用的转发要断开重连才按新的端口和目标走。", "A forward in use follows the new port and target after you reconnect it.")
                    : tr("先出现在图上，点连接才会建隧道。", "It appears on the map first; the tunnel is only created when you click Connect."))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .renameMachine, .renameVPN, .renameJump, .renameForward:
                field(tr("名称", "Name"), text: $name, prompt: tr("显示名称", "Display name"))
                Text(tr("只改图上和菜单里的名字，不会动正在用的连接。", "Only changes the name on the map and in the menu; connections in use aren't touched."))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(tr("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("保存", "Save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(theme.bg)
        .foregroundStyle(theme.text)
        .onAppear(perform: load)
    }

    private var isAddingVPN: Bool {
        if case .addVPN = kind { return true }
        return false
    }

    private var isEditingForward: Bool {
        if case .forward = kind { return true }
        return false
    }

    private var title: String {
        switch kind {
        case .vpn: return tr("修改 VPN", "Edit VPN")
        case .jump: return tr("修改跳板", "Edit Jump Host")
        case .addVPN: return tr("添加 VPN", "Add VPN")
        case .addJump: return tr("添加跳板", "Add Jump Host")
        case .addTunnel: return tr("添加转发", "Add Forward")
        case .forward: return tr("编辑转发", "Edit Forward")
        case .renameMachine, .renameVPN, .renameJump, .renameForward: return tr("改名", "Rename")
        }
    }

    private var keyExists: Bool {
        FileManager.default.fileExists(atPath: PathExpander.expand(identity))
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch kind {
        case .vpn(let id):
            let profile = model.config.vpns.first { $0.id == id }
            name = profile?.name ?? "VPN"
            if let file = profile?.credentialFile, let cred = Credentials.load(file: file) {
                host = cred.host
                user = cred.user
            }
        case .jump(let id):
            let item = model.config.jumps.first { $0.id == id }
            name = item?.name ?? tr("跳板", "Jump host")
            jump = item?.host ?? ""
            identity = item?.identityFile ?? ""
        case .addVPN:
            name = "VPN"
        case .addJump:
            name = tr("跳板", "Jump host")
            identity = "~/.ssh/"
        case .addTunnel:
            name = tr("新隧道", "New tunnel")
            localPort = suggestedPort()
            targetPort = 80
        case .renameMachine:
            name = model.config.machineName
        case .renameVPN(let id):
            name = model.config.vpns.first { $0.id == id }?.name ?? "VPN"
        case .renameJump(let id):
            name = model.config.jumps.first { $0.id == id }?.name ?? tr("跳板", "Jump host")
        case .renameForward(let id):
            name = model.config.forwards.first { $0.id == id }?.name ?? tr("隧道", "Tunnel")
        case .forward(let id):
            if let item = model.config.forwards.first(where: { $0.id == id }) {
                name = item.name
                localPort = item.localPort
                targetHost = item.targetHost
                targetPort = item.targetPort
                openHost = item.openHost
            }
        }
    }

    private func suggestedPort() -> Int {
        let used = Set(model.config.forwards.map(\.localPort))
        var port = 9000
        while used.contains(port) { port += 1 }
        return port
    }

    private func save() {
        do {
            switch kind {
            case .vpn(let id):
                let file = model.config.vpns.first { $0.id == id }?.credentialFile ?? model.config.credentialFile
                try model.saveCredential(file: file, host: host, user: user, password: password)
                var next = model.config
                if let index = next.vpns.firstIndex(where: { $0.id == id }) {
                    next.vpns[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                try model.save(config: next)
                Task { await model.refresh() }
            case .addVPN:
                try model.addVPN(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    host: host,
                    user: user,
                    password: password
                )
            case .jump(let id):
                var next = model.config
                if let index = next.jumps.firstIndex(where: { $0.id == id }) {
                    next.jumps[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    next.jumps[index].host = jump.trimmingCharacters(in: .whitespacesAndNewlines)
                    next.jumps[index].identityFile = identity.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                try model.save(config: next)
                Task { await model.refresh() }
            case .addJump(let vpnID):
                try model.addJump(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    host: jump,
                    identityFile: identity,
                    vpnID: vpnID
                )
            case .addTunnel(let jumpID):
                try model.addTunnel(
                    name: name,
                    localPort: localPort,
                    targetHost: targetHost,
                    targetPort: targetPort,
                    openHost: openHost,
                    jumpID: jumpID
                )
            case .renameMachine:
                var next = model.config
                next.machineName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                try model.save(config: next)
            case .renameVPN(let id):
                var next = model.config
                guard let index = next.vpns.firstIndex(where: { $0.id == id }) else { return }
                next.vpns[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                try model.save(config: next)
            case .renameJump(let id):
                var next = model.config
                guard let index = next.jumps.firstIndex(where: { $0.id == id }) else { return }
                next.jumps[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                try model.save(config: next)
            case .renameForward(let id):
                var next = model.config
                guard let index = next.forwards.firstIndex(where: { $0.id == id }) else { return }
                next.forwards[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                try model.save(config: next)
            case .forward(let id):
                try model.updateForward(id, name: name, localPort: localPort, targetHost: targetHost, targetPort: targetPort, openHost: openHost)
            }
            dismiss()
        } catch {
            note = error.localizedDescription
        }
    }
}

@MainActor
struct NetLinkCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandMenu(tr("连接", "Connection")) {
            Button(tr("刷新状态", "Refresh Status")) { Task { await model.refresh(manual: true) } }
                .keyboardShortcut("r")
            Button(tr("连接隧道", "Connect Tunnel")) { model.connectTunnel() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button(tr("连接 VPN", "Connect VPN")) { model.connectVPN() }
            Button(tr("断开 VPN", "Disconnect VPN")) { model.disconnectVPN() }
            Button(tr("断开隧道", "Disconnect Tunnel")) { model.disconnectTunnel() }
        }
    }
}

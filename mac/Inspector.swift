import AppKit
import SwiftUI

/// 侧边栏、拓扑图和检查器共用的选中项。
enum Selection: Hashable {
    case machine
    case vpn(UUID)
    case jump(UUID)
    case forward(UUID)
}

/// 右侧检查器：选中节点的状态、开关、详情和操作。原来藏在节点弹出菜单和设置页里的都在这里。
@MainActor
struct InspectorView: View {
    @Bindable var model: AppModel
    var selection: Selection?
    var pathEdit: Binding<PathEdit?>
    @Environment(\.netlinkTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selection {
                case .machine:
                    machine
                case .vpn(let id):
                    if let profile = model.config.vpns.first(where: { $0.id == id }) {
                        if profile.isSystemVPN { systemVPN(profile) } else { vpn(profile) }
                    } else {
                        empty
                    }
                case .jump(let id):
                    if let jump = model.config.jumps.first(where: { $0.id == id }) { self.jump(jump) } else { empty }
                case .forward(let id):
                    if let forward = model.config.forwards.first(where: { $0.id == id }) { self.forward(forward) } else { empty }
                case nil:
                    empty
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(theme.text)
    }

    // MARK: - 各类节点

    private var empty: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.muted)
                Text(tr("选择一个节点", "Select a node"))
                    .font(.system(size: 15, weight: .semibold))
                Text(tr("在左侧列表或图上点一个节点，这里显示它的状态和操作。右键节点也能直接操作。", "Click a node in the list or on the map to see its status and actions here. You can also right-click a node."))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InspectorSection(tr("概览", "Overview")) {
                InfoRow(tr("VPN", "VPN"), "\(model.config.vpns.filter { model.isOn($0) }.count)/\(model.config.vpns.count) " + tr("已连接", "connected"))
                InfoRow(tr("转发", "Forwards"), "\(model.tunnel.okCount)/\(model.config.forwards.count) " + tr("通", "up"))
                InfoRow(tr("自动重连", "Auto-reconnect"), model.autoReconnectOn ? tr("开", "On") : tr("关", "Off"))
            }
        }
    }

    private var machine: some View {
        Group {
            header(.machine, toggle: nil, busy: false)
            InspectorSection(tr("概览", "Overview")) {
                InfoRow(tr("VPN", "VPN"), "\(model.config.vpns.count)")
                InfoRow(tr("跳板", "Jump hosts"), "\(model.config.jumps.count)")
                InfoRow(tr("转发", "Forwards"), "\(model.config.forwards.count)")
            }
            InspectorSection(tr("自动重连", "Auto-reconnect")) {
                Toggle(tr("断线后自动重连 VPN 和隧道", "Reconnect the VPN and tunnels when they drop"), isOn: Binding(
                    get: { model.autoReconnectOn },
                    set: { model.setAutoReconnect($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            }
            actions {
                ActionTile(tr("改名", "Rename"), "pencil") { pathEdit.wrappedValue = .renameMachine }
                ActionTile(tr("添加 VPN", "Add VPN"), "plus") { pathEdit.wrappedValue = .addVPN }
            }
        }
    }

    private func vpn(_ profile: VPNProfile) -> some View {
        let on = model.isOn(profile)
        let credential = Credentials.load(file: profile.credentialFile)
        let busy = isBusy([.vpnConnect, .vpnDisconnect, .vpnRestart])
        return Group {
            header(.vpn(profile.id), toggle: Binding(
                get: { on },
                set: { $0 ? model.connectVPNProfile(profile.id) : model.disconnectVPNProfile(profile.id) }
            ), busy: busy)
            InspectorSection(tr("详情", "Details")) {
                InfoRow(tr("主机", "Host"), credential?.host ?? tr("未设置", "Not set"), mono: true)
                InfoRow(tr("用户", "User"), credential?.user ?? "—")
                if on {
                    InfoRow(tr("路由", "Route"), model.vpn.routePresent ? tr("已出现", "Present") : tr("没有", "Missing"), tint: model.vpn.routePresent ? theme.ok : theme.warn)
                    InfoRow(tr("网关", "Gateway"), model.vpn.gatewayReachable ? tr("可达", "Reachable") : tr("不可达", "Unreachable"), tint: model.vpn.gatewayReachable ? theme.ok : theme.warn)
                }
            }
            viaPicker(profile)
            watchSection(owner: model.vpn.watch, isVPN: true)
            actions {
                ActionTile(tr("修改账号", "Edit Account"), "person") { pathEdit.wrappedValue = .vpn(profile.id) }
                ActionTile(tr("重启", "Restart"), "arrow.clockwise") { model.restartVPNProfile(profile.id) }
                ActionTile(tr("改名", "Rename"), "pencil") { pathEdit.wrappedValue = .renameVPN(profile.id) }
                ActionTile(tr("添加跳板", "Add Jump Host"), "plus") { pathEdit.wrappedValue = .addJump(profile.id) }
            }
            if model.config.vpns.count > 1, profile.id != VPNProfile.primary {
                destructive(tr("删除这个 VPN…", "Delete This VPN…")) { model.removeVPN(profile.id) }
            }
        }
    }

    private func systemVPN(_ profile: VPNProfile) -> some View {
        let on = model.isOn(profile)
        let busy = isBusy([.vpnConnect, .vpnDisconnect, .vpnRestart, .vpnOpenApp, .vpnQuitApp])
        return Group {
            header(.vpn(profile.id), toggle: Binding(
                get: { on },
                set: { $0 ? model.connectVPNProfile(profile.id) : model.disconnectVPNProfile(profile.id) }
            ), busy: busy)
            InspectorSection(tr("详情", "Details")) {
                InfoRow(tr("类型", "Type"), tr("系统 VPN", "System VPN"))
                if profile.isForticlient {
                    InfoRow(tr("账号", "Account"), FortiClient.hasLogin() ? tr("已保存", "Saved") : tr("还没有密码", "No password yet"))
                }
                if profile.isShadowrocket {
                    Note(tr("Shadowrocket 没有命令行开关，打开或关闭会切到它的应用里。", "Shadowrocket has no command-line switch; turning it on or off switches to its app."))
                }
            }
            viaPicker(profile)
            actions {
                ActionTile(tr("打开应用", "Open App"), "arrow.up.forward.app") { model.openSystemVPNApp(profile.id) }
                ActionTile(tr("退出应用", "Quit App"), "power") { model.quitSystemVPNApp(profile.id) }
                ActionTile(tr("改名", "Rename"), "pencil") { pathEdit.wrappedValue = .renameVPN(profile.id) }
                if profile.isForticlient {
                    ActionTile(tr("修改账号", "Edit Account"), "person") { model.askFortiAccount(thenConnect: false) }
                }
            }
        }
    }

    private func jump(_ jump: Jump) -> some View {
        let on = model.isOn(jump)
        let keyOK = FileManager.default.isReadableFile(atPath: PathExpander.expand(jump.identityFile))
        let busy = isBusy([.tunnelConnect, .tunnelDisconnect, .tunnelRestart])
        return Group {
            header(.jump(jump.id), toggle: Binding(
                get: { on },
                set: { $0 ? model.connectJump(jump.id) : model.disconnectJump(jump.id) }
            ), busy: busy)
            InspectorSection(tr("详情", "Details")) {
                InfoRow(tr("地址", "Address"), jump.host.isEmpty ? tr("未设置", "Not set") : jump.host, mono: true)
                InfoRow(tr("私钥", "Key"), keyOK ? tr("可读", "Readable") : tr("找不到", "Missing"), tint: keyOK ? nil : theme.bad)
                InfoRow("autossh", on ? tr("在跑", "Running") : tr("没在跑", "Not running"))
            }
            InspectorSection(tr("挂在", "Behind")) {
                Picker(tr("VPN", "VPN"), selection: Binding(
                    get: { jump.vpnID ?? VPNProfile.primary },
                    set: { model.reparentJump(jump.id, to: $0) }
                )) {
                    ForEach(model.config.vpns) { vpn in
                        Text(vpn.name).tag(vpn.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Note(tr("跳板不通时，连接隧道会先连这个 VPN。", "If the jump host is unreachable, this VPN is connected first."))
            }
            watchSection(owner: model.tunnel.watch, isVPN: false)
            actions {
                ActionTile(tr("修改跳板", "Edit Jump Host"), "server.rack") { pathEdit.wrappedValue = .jump(jump.id) }
                ActionTile(tr("重启", "Restart"), "arrow.clockwise") { model.restartJump(jump.id) }
                ActionTile(tr("改名", "Rename"), "pencil") { pathEdit.wrappedValue = .renameJump(jump.id) }
                ActionTile(tr("添加转发", "Add Forward"), "plus") { pathEdit.wrappedValue = .addTunnel(jump.id) }
            }
            if model.config.jumps.count > 1 {
                if model.config.forwards(on: jump.id).isEmpty {
                    destructive(tr("删除这台跳板…", "Delete This Jump Host…")) { model.removeJump(jump.id) }
                } else {
                    Note(tr("要删除这台跳板，先删掉或移走它上面的转发。", "To delete this jump host, remove or move its forwards first."))
                }
            }
        }
    }

    private func forward(_ forward: Forward) -> some View {
        let port = model.status(of: forward)
        let on = port.httpOK || port.listening
        let busy = model.job == .forwardConnect(forward.localPort) || model.job == .forwardDisconnect(forward.localPort)
        return Group {
            header(.forward(forward.id), toggle: Binding(
                get: { on },
                set: { $0 ? model.connectForward(forward.localPort) : model.disconnectForward(forward.localPort) }
            ), busy: busy)
            InspectorSection(tr("详情", "Details")) {
                InfoRow(tr("本地", "Local"), "127.0.0.1:\(forward.localPort)", mono: true)
                InfoRow(tr("目标", "Target"), forward.target, mono: true)
                InfoRow(tr("打开地址", "Opens"), forward.browseLabel, mono: true)
                InfoRow(tr("检查方式", "Check"), forward.check == .http ? "HTTP" : "TCP")
            }
            if model.config.jumps.count > 1 {
                InspectorSection(tr("经由", "Via")) {
                    Picker(tr("跳板", "Jump host"), selection: Binding(
                        get: { forward.jumpID ?? Jump.primary },
                        set: { model.reparentForward(forward.id, to: $0) }
                    )) {
                        ForEach(model.config.jumps) { jump in
                            Text(jump.name).tag(jump.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
            actions {
                if on, let url = URL(string: port.browseURL) {
                    ActionTile(tr("在浏览器打开", "Open in Browser"), "safari") { NSWorkspace.shared.open(url) }
                }
                ActionTile(tr("编辑", "Edit"), "pencil") { pathEdit.wrappedValue = .forward(forward.id) }
            }
            if model.config.forwards.count > 1 {
                destructive(tr("删除这条转发…", "Delete This Forward…")) { model.removeForward(forward.localPort) }
            }
        }
    }

    // MARK: - 组件

    @ViewBuilder
    private func header(_ selection: Selection, toggle: Binding<Bool>?, busy: Bool) -> some View {
        if let look = NodeLook.of(selection, model: model, theme: theme) {
            HStack(spacing: 12) {
                ServiceBadge(pageURL: look.pageURL, iconFile: look.iconFile, symbol: look.symbol, tint: look.tint, side: 38, ring: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(look.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(look.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(look.status == theme.muted ? theme.muted : look.tint.opacity(0.9))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().controlSize(.small)
                } else if let toggle {
                    Toggle(tr("连接", "Connect"), isOn: toggle)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(toggle.wrappedValue ? tr("断开", "Disconnect") : tr("连接", "Connect"))
                }
            }
        }
    }

    @ViewBuilder
    private func viaPicker(_ profile: VPNProfile) -> some View {
        let blocked = Set(model.config.vpns.filter { other in
            other.id == profile.id || model.config.upstreamIDs(of: other.id).contains(profile.id)
        }.map(\.id))
        let options = model.config.vpns.filter { !blocked.contains($0.id) }
        if !options.isEmpty {
            InspectorSection(tr("流量经过", "Traffic goes through")) {
                Picker(tr("上游", "Upstream"), selection: Binding<UUID?>(
                    get: { profile.viaID },
                    set: { model.setVPNVia(profile.id, via: $0) }
                )) {
                    Text(tr("本机直接出去", "Directly from this Mac")).tag(UUID?.none)
                    ForEach(options) { option in
                        Text(option.name).tag(UUID?.some(option.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                Note(tr("只影响图和状态显示，不改连接。", "Only affects the map and status, not the connection."))
            }
        }
    }

    @ViewBuilder
    private func watchSection(owner: WatchdogOwner, isVPN: Bool) -> some View {
        InspectorSection(tr("自动重连", "Auto-reconnect")) {
            Toggle(tr("断线后自动重连", "Reconnect when it drops"), isOn: Binding(
                get: { owner != .off },
                set: { isVPN ? model.setVPNWatch($0) : model.setTunnelWatch($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            switch owner {
            case .shell, .both:
                Note(tr("终端里的守护脚本也在跑。", "A watchdog script is also running in Terminal."))
                Button(tr("改由本应用守护", "Let This App Watch It")) { isVPN ? model.takeOverVPN() : model.takeOverTunnel() }
                    .controlSize(.small)
            case .stale:
                Note(tr("开关是开的，但守护进程不在。", "The switch is on, but the watchdog isn't running."))
                Button(tr("重新拉起守护", "Restart the Watchdog")) { isVPN ? model.setVPNWatch(true) : model.setTunnelWatch(true) }
                    .controlSize(.small)
            case .app, .off:
                EmptyView()
            }
        }
    }

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            content()
        }
    }

    private func destructive(_ title: String, action: @escaping () -> Void) -> some View {
        DestructiveButton(title: title, action: action)
    }

    private func isBusy(_ jobs: [Job]) -> Bool {
        guard let job = model.job else { return false }
        return jobs.contains(job)
    }
}

/// 删除类操作：先确认一次。
struct DestructiveButton: View {
    var title: String
    var action: () -> Void
    @State private var confirming = false
    @Environment(\.netlinkTheme) private var theme

    var body: some View {
        Button {
            confirming = true
        } label: {
            Text(title).font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.bad)
        .confirmationDialog(title, isPresented: $confirming) {
            Button(tr("删除", "Delete"), role: .destructive, action: action)
            Button(tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("删除后要重新添加才能恢复。", "You'll need to add it again to restore it."))
        }
    }
}

/// 检查器里的一组：小标题加内容。
struct InspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @Environment(\.netlinkTheme) private var theme

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.muted)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
    }
}

/// 一行「名称 —— 值」。
struct InfoRow: View {
    var label: String
    var value: String
    var mono = false
    var tint: Color?
    @Environment(\.netlinkTheme) private var theme

    init(_ label: String, _ value: String, mono: Bool = false, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.mono = mono
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(theme.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(tint ?? theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line.opacity(0.6)).frame(height: 1).offset(y: 4)
        }
    }
}

/// 灰色小字说明。
struct Note: View {
    var text: String
    @Environment(\.netlinkTheme) private var theme

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 检查器里的操作按钮，两列排。
struct ActionTile: View {
    var title: String
    var symbol: String
    var action: () -> Void

    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

/// 右键菜单：图上的节点和侧边栏的行共用。
@MainActor
struct NodeMenu: View {
    var model: AppModel
    var selection: Selection
    var pathEdit: Binding<PathEdit?>

    var body: some View {
        switch selection {
        case .machine:
            Button(tr("改名…", "Rename…")) { pathEdit.wrappedValue = .renameMachine }
            Button(tr("添加 VPN…", "Add VPN…")) { pathEdit.wrappedValue = .addVPN }
        case .vpn(let id):
            if let profile = model.config.vpns.first(where: { $0.id == id }) {
                if model.isOn(profile) {
                    Button(tr("断开", "Disconnect")) { model.disconnectVPNProfile(id) }
                } else {
                    Button(tr("连接", "Connect")) { model.connectVPNProfile(id) }
                }
                Button(tr("重启", "Restart")) { model.restartVPNProfile(id) }
                Divider()
                if profile.isSystemVPN {
                    Button(tr("打开应用", "Open App")) { model.openSystemVPNApp(id) }
                } else {
                    Button(tr("修改账号…", "Edit Account…")) { pathEdit.wrappedValue = .vpn(id) }
                    Button(tr("添加跳板…", "Add Jump Host…")) { pathEdit.wrappedValue = .addJump(id) }
                }
                Button(tr("改名…", "Rename…")) { pathEdit.wrappedValue = .renameVPN(id) }
            }
        case .jump(let id):
            if let jump = model.config.jumps.first(where: { $0.id == id }) {
                if model.isOn(jump) {
                    Button(tr("断开", "Disconnect")) { model.disconnectJump(id) }
                } else {
                    Button(tr("连接", "Connect")) { model.connectJump(id) }
                }
                Button(tr("重启", "Restart")) { model.restartJump(id) }
                Divider()
                Button(tr("修改跳板…", "Edit Jump Host…")) { pathEdit.wrappedValue = .jump(id) }
                Button(tr("添加转发…", "Add Forward…")) { pathEdit.wrappedValue = .addTunnel(id) }
                Button(tr("改名…", "Rename…")) { pathEdit.wrappedValue = .renameJump(id) }
            }
        case .forward(let id):
            if let forward = model.config.forwards.first(where: { $0.id == id }) {
                let port = model.status(of: forward)
                if port.httpOK || port.listening {
                    Button(tr("断开", "Disconnect")) { model.disconnectForward(forward.localPort) }
                    if let url = URL(string: port.browseURL) {
                        Button(tr("在浏览器打开", "Open in Browser")) { NSWorkspace.shared.open(url) }
                    }
                } else {
                    Button(tr("连接", "Connect")) { model.connectForward(forward.localPort) }
                }
                Divider()
                Button(tr("编辑…", "Edit…")) { pathEdit.wrappedValue = .forward(id) }
            }
        }
    }
}

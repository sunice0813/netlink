import AppKit
import SwiftUI

/// 主窗口：左侧边栏、中间拓扑图、右侧检查器，工具栏在标题栏里。
@MainActor
struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.netlinkTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Selection?
    @State private var pathEdit: PathEdit?
    @State private var showInspector = true
    @State private var statusDismiss: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $selection, pathEdit: $pathEdit)
                .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    NoticeBar(banner: banner, model: model)
                }
                TopologyCanvas(model: model, selection: $selection, pathEdit: $pathEdit)
                    .coordinateSpace(name: "topology")
                StatusBar(model: model)
            }
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model, selection: selection, pathEdit: $pathEdit)
                    .inspectorColumnWidth(min: 250, ideal: 280, max: 380)
                    .toolbar {
                        ToolbarItem {
                            Button {
                                showInspector.toggle()
                            } label: {
                                Label(tr("检查器", "Inspector"), systemImage: "sidebar.right")
                            }
                            .help(tr("显示或隐藏右侧详情", "Show or hide the details panel"))
                        }
                    }
            }
        }
        .navigationTitle(tr("内网连接", "NetLink"))
        .navigationSubtitle(summary)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.refresh(manual: true) }
                } label: {
                    Label(tr("刷新", "Refresh"), systemImage: "arrow.clockwise")
                }
                .help(tr("刷新状态（⌘R）", "Refresh status (⌘R)"))
                .disabled(model.refreshingVisible)
                Button {
                    openWindow(id: "logs")
                } label: {
                    Label(tr("日志", "Logs"), systemImage: "doc.text")
                }
                .help(tr("日志", "Logs"))
                Button {
                    openWindow(id: "transfer")
                } label: {
                    Label(tr("导入导出", "Import / Export"), systemImage: "square.and.arrow.up.on.square")
                }
                .help(tr("导入或导出配置", "Import or export the config"))
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .task { model.start() }
        .onChange(of: model.statusNonce) { _, _ in scheduleStatusDismiss() }
        .onChange(of: model.busy) { _, _ in scheduleStatusDismiss() }
        .sheet(item: $pathEdit) { kind in
            PathConfigSheet(model: model, kind: kind).themed()
        }
        .sheet(isPresented: $model.fortiPrompt, onDismiss: {
            model.fortiConnectAfterSave = false
        }) {
            FortiAccountSheet(model: model).themed()
        }
    }

    private var summary: String {
        let when = model.checkedAt.map { Self.clock.string(from: $0) } ?? tr("尚未检查", "not checked yet")
        if model.vpn.phase == .checking { return tr("检查中…", "Checking…") }
        if model.vpn.phase == .up && model.tunnel.phase == .up {
            return tr("全部正常 · \(when)", "All good · \(when)")
        }
        let tunnel = model.tunnel.ports.isEmpty ? tr("没有转发", "no forwards") : "\(model.tunnel.okCount)/\(model.tunnel.ports.count)"
        return tr("VPN \(model.vpn.phase.title) · 转发 \(tunnel) · \(when)", "VPN \(model.vpn.phase.title) · forwards \(tunnel) · \(when)")
    }

    private func scheduleStatusDismiss() {
        statusDismiss?.cancel()
        guard model.statusLine != nil, !model.busy, !model.refreshingVisible else { return }
        statusDismiss = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if !model.busy, !model.refreshingVisible {
                model.statusLine = nil
            }
        }
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// 左侧边栏：链路（本机、VPN、跳板）和转发两组，选中后右侧显示详情。
@MainActor
struct SidebarView: View {
    var model: AppModel
    @Binding var selection: Selection?
    @Binding var pathEdit: PathEdit?
    @Environment(\.netlinkTheme) private var theme

    var body: some View {
        List(selection: $selection) {
            Section(tr("链路", "Path")) {
                row(.machine)
                ForEach(model.config.vpns) { vpn in
                    row(.vpn(vpn.id))
                }
                ForEach(model.config.jumps) { jump in
                    row(.jump(jump.id), trailing: NodeLook.hostOnly(jump.host))
                }
            }
            Section(tr("转发", "Forwards")) {
                ForEach(model.config.forwards) { forward in
                    row(.forward(forward.id), trailing: ":\(forward.localPort)")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button(tr("添加 VPN…", "Add VPN…")) { pathEdit = .addVPN }
                    Button(tr("添加跳板…", "Add Jump Host…")) { pathEdit = .addJump(targetVPN) }
                    Button(tr("添加转发…", "Add Forward…")) { pathEdit = .addTunnel(targetJump) }
                } label: {
                    Label(tr("添加", "Add"), systemImage: "plus")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("添加 VPN、跳板或转发", "Add a VPN, jump host or forward"))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func row(_ item: Selection, trailing: String? = nil) -> some View {
        if let look = NodeLook.of(item, model: model, theme: theme) {
            HStack(spacing: 8) {
                StatusDot(color: look.on ? look.tint : theme.muted.opacity(0.45), size: 8)
                Text(look.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .tag(item)
            .contextMenu {
                NodeMenu(model: model, selection: item, pathEdit: $pathEdit)
            }
        }
    }

    /// 新跳板挂在选中的 VPN 下，没选就挂主 VPN。
    private var targetVPN: UUID {
        if case .vpn(let id) = selection { return id }
        if case .jump(let id) = selection, let jump = model.config.jumps.first(where: { $0.id == id }) {
            return jump.vpnID ?? VPNProfile.primary
        }
        return VPNProfile.primary
    }

    /// 新转发走选中的跳板（或选中转发所在的跳板），没选就走主跳板。
    private var targetJump: UUID {
        if case .jump(let id) = selection { return id }
        if case .forward(let id) = selection, let forward = model.config.forwards.first(where: { $0.id == id }) {
            return forward.jumpID ?? Jump.primary
        }
        return Jump.primary
    }
}

/// 画布上方的提示条：缺依赖、sudo 不能免密、配置读不了这类要处理的事。
@MainActor
struct NoticeBar: View {
    var banner: Banner
    var model: AppModel
    @Environment(\.netlinkTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warn)
            Text(banner.text)
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action = banner.action {
                Button(action.title) { model.perform(action) }
                    .controlSize(.small)
                    .disabled(model.busy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.warn.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }
}

/// 窗口底部状态栏：左边是正在做的事或最近一条结果，右边是自动重连和检查时间。
@MainActor
struct StatusBar: View {
    var model: AppModel
    @Environment(\.netlinkTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if model.busy || model.refreshingVisible {
                ProgressView().controlSize(.mini)
            }
            if let line = model.statusLine {
                Text(line)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            Text(model.autoReconnectOn ? tr("自动重连：开", "Auto-reconnect: on") : tr("自动重连：关", "Auto-reconnect: off"))
                .help(tr("关掉窗口不会断开；菜单栏里的「退出并断开」才会断开 VPN 和隧道。", "Closing the window doesn't disconnect; use Quit and Disconnect in the menu bar to stop the VPN and tunnels."))
            if let checked = model.checkedAt {
                Text("·")
                Text(tr("检查于 \(ContentView.clock.string(from: checked))", "Checked \(ContentView.clock.string(from: checked))"))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.muted)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(theme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }
}

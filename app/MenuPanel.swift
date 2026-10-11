import AppKit
import SwiftUI

/// 菜单栏面板：每个 VPN 和转发一行开关，状态和操作是同一个控件。
@MainActor
struct MenuPanel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.netlinkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            section("VPN")
            ForEach(model.config.vpns) { profile in
                let busy = model.job == .vpnConnect || model.job == .vpnDisconnect
                MenuToggleRow(
                    title: profile.name,
                    detail: vpnDetail(profile),
                    tint: model.isOn(profile) ? theme.ok : theme.muted,
                    isOn: model.isOn(profile),
                    busy: busy
                ) { on in
                    on ? model.connectVPNProfile(profile.id) : model.disconnectVPNProfile(profile.id)
                }
            }
            if !model.config.forwards.isEmpty {
                section(tr("转发", "Forwards"))
                ForEach(model.config.forwards) { forward in
                    let port = model.status(of: forward)
                    let busy = model.job == .forwardConnect(forward.localPort) || model.job == .forwardDisconnect(forward.localPort)
                    MenuToggleRow(
                        title: forward.name,
                        trailing: ":\(forward.localPort)",
                        detail: port.httpOK ? tr("已连接", "Connected") : (port.listening ? tr("无响应", "No response") : tr("未连接", "Off")),
                        tint: port.httpOK ? theme.ok : (port.listening ? theme.warn : theme.muted),
                        isOn: port.httpOK || port.listening,
                        busy: busy,
                        open: port.httpOK ? URL(string: port.browseURL) : nil
                    ) { on in
                        on ? model.connectForward(forward.localPort) : model.disconnectForward(forward.localPort)
                    }
                }
            }
            divider
            MenuToggleRow(
                title: tr("自动重连", "Auto-reconnect"),
                detail: nil,
                tint: theme.muted,
                isOn: model.autoReconnectOn,
                busy: model.job == .vpnWatchOn || model.job == .vpnWatchOff
            ) { on in
                model.setAutoReconnect(on)
            }
            divider
            MenuButtonRow(title: tr("打开内网连接", "Open NetLink")) { showMain() }
            MenuButtonRow(title: tr("设置…", "Settings…")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            MenuButtonRow(title: tr("退出并断开", "Quit and Disconnect")) { NSApp.terminate(nil) }
        }
        .padding(6)
        .frame(width: 300)
        .foregroundStyle(theme.text)
        .onChange(of: model.fortiPrompt) { _, show in
            if show { showMain() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: PathGlyph.image(model.linkState, size: 20))
                .renderingMode(.template)
                .foregroundStyle(overallTint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(overallTint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(overallTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(overallDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 8)
            Button {
                Task { await model.refresh(manual: true) }
            } label: {
                if model.refreshingVisible {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.muted)
            .help(tr("刷新", "Refresh"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Rectangle().fill(theme.line).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private var overallTint: Color {
        if model.vpn.phase == .up && model.tunnel.phase == .up { return theme.ok }
        if model.vpn.phase == .checking { return theme.muted }
        if model.vpn.phase == .down && model.tunnel.phase == .down { return theme.muted }
        return theme.warn
    }

    private var overallTitle: String {
        if model.vpn.phase == .checking { return tr("检查中", "Checking") }
        if model.vpn.phase == .up && model.tunnel.phase == .up { return tr("全部正常", "All good") }
        if model.vpn.phase == .down && model.tunnel.phase == .down { return tr("未连接", "Disconnected") }
        return tr("部分连接", "Partly connected")
    }

    private var overallDetail: String {
        let vpns = model.config.vpns.filter { model.isOn($0) }.count
        return tr(
            "\(vpns)/\(model.config.vpns.count) 个 VPN · \(model.tunnel.okCount)/\(model.config.forwards.count) 条转发",
            "\(vpns)/\(model.config.vpns.count) VPN · \(model.tunnel.okCount)/\(model.config.forwards.count) forwards"
        )
    }

    private func vpnDetail(_ profile: VPNProfile) -> String {
        if model.isOn(profile) {
            return profile.isSystemVPN ? tr("已连接", "Connected") : model.vpn.phase.title
        }
        return tr("未连接", "Off")
    }

    private func showMain() {
        let windows = NSApp.windows.filter { window in
            window.identifier?.rawValue.hasPrefix("main") == true
                || (window.styleMask.contains(.titled) && window.level == .normal && !(window is NSPanel) && window.title == tr("内网连接", "NetLink"))
        }
        if let window = windows.first {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 菜单面板里带开关的一行。
@MainActor
struct MenuToggleRow: View {
    var title: String
    var trailing: String? = nil
    var detail: String?
    var tint: Color
    var isOn: Bool
    var busy: Bool
    var open: URL? = nil
    var toggle: (Bool) -> Void
    @Environment(\.netlinkTheme) private var theme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 6)
            if let open {
                Button(tr("打开", "Open")) { NSWorkspace.shared.open(open) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            if busy {
                ProgressView().controlSize(.mini).frame(width: 32)
            } else {
                Toggle(title, isOn: Binding(get: { isOn }, set: { toggle($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered ? theme.hoverFill : Color.clear))
        .onHover { hovered = $0 }
    }
}

/// 菜单面板底部的普通命令行。
@MainActor
struct MenuButtonRow: View {
    var title: String
    var action: () -> Void
    @Environment(\.netlinkTheme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered ? Color.accentColor : Color.clear))
                .foregroundStyle(hovered ? Color.white : theme.text)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

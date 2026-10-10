import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct Theme: Equatable {
    var bg: Color
    var line: Color
    var text: Color
    var muted: Color
    var ok: Color
    var warn: Color
    var bad: Color
    var accent: Color
    var accentHover: Color
    var onAccent: Color
    var hoverFill: Color
    var hoverLine: Color
    var log: Color

    static let dark = Theme(
        bg: Color(red: 0.12, green: 0.125, blue: 0.135),
        line: Color.white.opacity(0.10),
        text: Color(red: 0.93, green: 0.94, blue: 0.95),
        muted: Color(red: 0.62, green: 0.66, blue: 0.70),
        ok: Color(red: 0.45, green: 0.73, blue: 0.55),
        warn: Color(red: 0.86, green: 0.70, blue: 0.38),
        bad: Color(red: 0.86, green: 0.45, blue: 0.42),
        accent: Color(red: 0.62, green: 0.78, blue: 0.74),
        accentHover: Color(red: 0.70, green: 0.84, blue: 0.80),
        onAccent: Color(red: 0.08, green: 0.12, blue: 0.12),
        hoverFill: Color.white.opacity(0.06),
        hoverLine: Color.white.opacity(0.28),
        log: Color(red: 0.78, green: 0.81, blue: 0.84)
    )

    static let light = Theme(
        bg: Color(red: 0.96, green: 0.96, blue: 0.955),
        line: Color.black.opacity(0.12),
        text: Color(red: 0.13, green: 0.14, blue: 0.15),
        muted: Color(red: 0.40, green: 0.43, blue: 0.46),
        ok: Color(red: 0.16, green: 0.50, blue: 0.32),
        warn: Color(red: 0.68, green: 0.44, blue: 0.08),
        bad: Color(red: 0.72, green: 0.24, blue: 0.20),
        accent: Color(red: 0.16, green: 0.46, blue: 0.42),
        accentHover: Color(red: 0.22, green: 0.54, blue: 0.50),
        onAccent: Color.white,
        hoverFill: Color.black.opacity(0.05),
        hoverLine: Color.black.opacity(0.22),
        log: Color(red: 0.20, green: 0.22, blue: 0.24)
    )

    static func resolve(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }
}

private struct ThemeKey: EnvironmentKey {
    static var defaultValue: Theme {
        switch AppearanceChoice.current {
        case .light: return .light
        case .dark: return .dark
        case .system:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? .dark : .light
        }
    }
}

extension EnvironmentValues {
    var netlinkTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

private struct Themed: ViewModifier {
    @AppStorage(Prefs.appearanceKey) private var appearanceRaw = AppearanceChoice.system.rawValue
    @Environment(\.colorScheme) private var systemScheme

    private var choice: AppearanceChoice { AppearanceChoice.parse(appearanceRaw) }

    private var scheme: ColorScheme {
        switch choice {
        case .system: return systemScheme
        case .dark: return .dark
        case .light: return .light
        }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.netlinkTheme, Theme.resolve(scheme))
            .preferredColorScheme(choice.colorScheme)
            .onAppear { AppearanceWindows.apply() }
            .onChange(of: appearanceRaw) { _, _ in AppearanceWindows.apply() }
    }
}

extension AppearanceChoice {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

extension View {
    func themed() -> some View { modifier(Themed()) }
}

@MainActor
struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.netlinkTheme) private var theme
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var showTransfer = false
    @State private var pathEdit: PathEdit?
    @State private var statusDismiss: Task<Void, Never>?

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(theme.line).frame(height: 1)
                pathMap
                footer
            }
            noticeOverlay
        }
        .foregroundStyle(theme.text)
        .frame(minWidth: 880, minHeight: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .task { model.start() }
        .onChange(of: model.statusNonce) { _, _ in
            scheduleStatusDismiss()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model).themed()
        }
        .sheet(isPresented: $showLogs) {
            LogsView(model: model).themed()
        }
        .sheet(isPresented: $showTransfer) {
            ConfigTransferView(model: model).themed()
        }
        .sheet(item: $pathEdit) { kind in
            PathConfigSheet(model: model, kind: kind).themed()
        }
        .sheet(isPresented: $model.fortiPrompt, onDismiss: {
            model.fortiConnectAfterSave = false
        }) {
            FortiAccountSheet(model: model).themed()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: model.menuSymbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(summaryTint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("内网连接")
                        .font(.system(size: 18, weight: .semibold))
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.muted)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ActionButton(title: "刷新", symbol: "arrow.clockwise", kind: .secondary, spinning: model.refreshingVisible) {
                    Task { await model.refresh(manual: true) }
                }
                ActionButton(title: "日志", symbol: "doc.text", kind: .secondary) {
                    showLogs = true
                }
                ActionButton(title: "导入导出", symbol: "square.and.arrow.up.on.square", kind: .secondary) {
                    showTransfer = true
                }
                ActionButton(title: "设置", symbol: "gearshape", kind: .secondary) {
                    showSettings = true
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var summaryTint: Color {
        if model.vpn.phase == .up && model.tunnel.phase == .up { return theme.ok }
        if model.vpn.phase == .down && model.tunnel.phase == .down { return theme.bad }
        if model.vpn.phase == .checking || model.tunnel.phase == .checking { return theme.muted }
        return theme.warn
    }

    private var pathMap: some View {
        TopologyCanvas(model: model, pathEdit: $pathEdit)
            .coordinateSpace(name: "topology")
    }

    private var footer: some View {
        Text("退出应用会断开 VPN 和隧道，并停掉自动重连。关掉窗口不会退出。")
            .font(.system(size: 11))
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private var summary: String {
        let when = model.checkedAt.map { time($0) } ?? "尚未检查"
        if model.vpn.phase == .up && model.tunnel.phase == .up {
            return "VPN 和隧道都正常 · \(when)"
        }
        return "VPN \(model.vpn.phase.title) · 隧道 \(tunnelHeadline) · \(when)"
    }

    private var tunnelHeadline: String {
        if model.tunnel.phase == .checking { return "检查中" }
        if model.tunnel.ports.isEmpty { return "未连接" }
        return "\(model.tunnel.okCount)/\(model.tunnel.ports.count) 通"
    }

    private var noticeOverlay: some View {
        VStack(spacing: 8) {
            if let banner = model.banner {
                notice(banner, symbol: "exclamationmark.circle.fill", tint: theme.warn, spinning: false)
            }
            if let line = model.statusLine {
                notice(
                    line,
                    symbol: "checkmark.circle.fill",
                    tint: model.busy || model.refreshingVisible ? theme.accent : theme.ok,
                    spinning: model.busy || model.refreshingVisible
                )
            }
        }
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func notice(_ text: String, symbol: String, tint: Color, spinning: Bool) -> some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView().controlSize(.small).tint(tint)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.bg)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
    }

    private func scheduleStatusDismiss() {
        statusDismiss?.cancel()
        guard model.statusLine != nil, !model.busy, !model.refreshingVisible else { return }
        statusDismiss = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            if !model.busy, !model.refreshingVisible {
                model.statusLine = nil
            }
        }
    }

    private func phaseColor(_ phase: LinkPhase) -> Color {
        switch phase {
        case .checking: return theme.muted
        case .up: return theme.ok
        case .degraded: return theme.warn
        case .down: return theme.bad
        }
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

@MainActor
struct ServiceBadge: View {
    var pageURL: String?
    var iconFile: String? = nil
    var symbol: String
    var tint: Color
    var side: CGFloat
    var ring: Bool = true
    var chrome: Bool = true
    @Environment(\.netlinkTheme) private var theme
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if iconFile != nil, let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                if chrome {
                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                        .fill(image == nil ? tint.opacity(0.14) : theme.bg)
                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                        .stroke(ring ? tint.opacity(0.9) : theme.line, lineWidth: 1)
                }
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(chrome ? side * 0.14 : 0)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: side * (chrome ? 0.4 : 0.72), weight: .medium))
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: side, height: side)
        .task(id: "\(iconFile ?? "")|\(pageURL ?? "")") {
            image = nil
            if let iconFile {
                image = AppIcon.image(forApp: iconFile)
                return
            }
            guard let pageURL else { return }
            guard let data = await SiteIcons.shared.data(for: pageURL) else { return }
            image = NSImage(data: data)
        }
    }
}

@MainActor
struct PathNode: View {
    var symbol: String
    var pageURL: String? = nil
    var iconFile: String? = nil
    var title: String
    var detail: String
    var tint: Color
    var on: Bool
    var open: (() -> Void)?
    var help: String? = nil
    var externalHover: Bool = false
    @Environment(\.netlinkTheme) private var theme
    @State private var hovered = false

    private var hot: Bool { hovered || externalHover }

    var body: some View {
        let content = VStack(spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                ServiceBadge(
                    pageURL: pageURL,
                    iconFile: iconFile,
                    symbol: symbol,
                    tint: on ? tint : theme.muted,
                    side: 34,
                    ring: on
                )
                Circle()
                    .fill(on ? tint : theme.muted.opacity(0.55))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(theme.bg, lineWidth: 1.5))
                    .offset(x: 1, y: 1)
            }
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(on ? tint : theme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: TopologyMetrics.nodeSize.width, height: TopologyMetrics.nodeSize.height)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on ? tint.opacity(hot ? 0.16 : 0.09) : (hot ? tint.opacity(0.08) : theme.hoverFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hot ? tint.opacity(0.85) : (on ? tint.opacity(0.32) : theme.line), lineWidth: 1)
        )

        if let open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hovered = hovering
                    if hovering {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
                .help(help ?? "打开 \(title)")
                .animation(.easeOut(duration: 0.12), value: hovered)
        } else {
            content
        }
    }
}

@MainActor
private struct ClickMenu<Label: View, Menu: View>: View {
    var help: String
    @ViewBuilder var label: (Bool) -> Label
    var menu: (@escaping () -> Void) -> Menu
    @State private var shown = false
    @State private var hovered = false

    var body: some View {
        Button {
            shown = true
        } label: {
            label(hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            menu { shown = false }
                .themed()
        }
    }
}

@MainActor
struct TunnelActionList: View {
    var port: PortStatus
    var model: AppModel
    var dismiss: () -> Void
    var onRename: () -> Void
    @Environment(\.netlinkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if port.httpOK || port.listening {
                row("打开", symbol: "arrow.up.right", tint: theme.accent, spinning: false) {
                    dismiss()
                    if let url = URL(string: port.browseURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            row(
                "连接",
                symbol: "link",
                tint: theme.accent,
                spinning: model.job == .forwardConnect(port.localPort)
            ) {
                dismiss()
                model.connectForward(port.localPort)
            }
            row(
                "断开",
                symbol: "minus.circle",
                tint: theme.bad,
                spinning: model.job == .forwardDisconnect(port.localPort)
            ) {
                dismiss()
                model.disconnectForward(port.localPort)
            }
            row("改名", symbol: "pencil", tint: theme.text, spinning: false) {
                dismiss()
                onRename()
            }
            if model.config.forwards.count > 1 {
                row("删除", symbol: "trash", tint: theme.bad, spinning: model.job == .forwardDisconnect(port.localPort)) {
                    dismiss()
                    model.removeForward(port.localPort)
                }
            }
        }
        .padding(6)
        .frame(width: 148)
        .background(theme.bg)
    }

    private func row(_ title: String, symbol: String, tint: Color, spinning: Bool, action: @escaping () -> Void) -> some View {
        TunnelActionRow(title: title, symbol: symbol, tint: tint, spinning: spinning, action: action)
    }
}

@MainActor
struct TunnelActionRow: View {
    var title: String
    var symbol: String
    var tint: Color
    var spinning: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if spinning {
                    ProgressView().controlSize(.small).tint(tint)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 14)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered && !spinning ? tint.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
            .background(HoverProbe { inside in
                hovered = inside && !spinning
                if inside && !spinning {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            })
        }
        .buttonStyle(.plain)
        .disabled(spinning)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct HoverProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverView {
        let view = HoverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: HoverView, context: Context) {
        nsView.onChange = onChange
    }

    final class HoverView: NSView {
        var onChange: ((Bool) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}

@MainActor
struct ActionButton: View {
    enum Kind { case primary, secondary, danger }
    var title: String
    var symbol: String? = nil
    var kind: Kind = .secondary
    var spinning = false
    var action: () -> Void
    @Environment(\.netlinkTheme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if spinning {
                    ProgressView().controlSize(.small).tint(foreground)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(shown)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(ActionButtonStyle(kind: kind, hovered: hovered, theme: theme))
        .onHover { hovering in
            hovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .disabled(spinning)
    }

    private var shown: String {
        guard spinning, title.count <= 4 else { return title }
        return "\(title)中"
    }

    private var foreground: Color {
        switch kind {
        case .primary: return theme.onAccent
        case .secondary: return theme.text
        case .danger: return theme.bad
        }
    }
}

private struct ActionButtonStyle: ButtonStyle {
    var kind: ActionButton.Kind
    var hovered: Bool
    var theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .foregroundStyle(foreground)
            .background(fill(pressed: configuration.isPressed))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.1), value: hovered)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return theme.onAccent
        case .secondary: return theme.text
        case .danger: return theme.bad
        }
    }

    private func fill(pressed: Bool) -> Color {
        switch kind {
        case .primary:
            return hovered && !pressed ? theme.accentHover : theme.accent
        case .secondary:
            return hovered ? theme.hoverFill : Color.clear
        case .danger:
            return hovered ? theme.bad.opacity(0.10) : Color.clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return Color.clear
        case .secondary: return hovered ? theme.hoverLine : theme.line
        case .danger: return theme.bad.opacity(hovered ? 0.9 : 0.55)
        }
    }
}

@MainActor
struct LogsView: View {
    var model: AppModel
    @Environment(\.netlinkTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var logSource = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("日志")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("密码不会出现在这里")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Rectangle().fill(theme.line).frame(height: 1)
            HStack(spacing: 0) {
                logTab("VPN", tag: 0)
                logTab("隧道", tag: 1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            if !model.journal.isEmpty {
                Text(model.journal.suffix(8).joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            ScrollView {
                Text(logText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.log)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
            }
        }
        .background(theme.bg)
        .foregroundStyle(theme.text)
        .frame(width: 720, height: 480)
    }

    private var logText: String {
        let raw = logSource == 0 ? model.vpnLog : model.tunnelLog
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "还没有日志" : trimmed
    }

    private func logTab(_ title: String, tag: Int) -> some View {
        Button {
            logSource = tag
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: logSource == tag ? .semibold : .regular))
                    .foregroundStyle(logSource == tag ? theme.text : theme.muted)
                Rectangle()
                    .fill(logSource == tag ? theme.accent : Color.clear)
                    .frame(height: 2)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct ConfigTransferView: View {
    var model: AppModel
    @Environment(\.netlinkTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ImportPreview?
    @State private var previewName = ""
    @State private var message = ""
    @State private var failed = false
    @State private var includeSecrets = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("配置导入导出")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Rectangle().fill(theme.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 18) {
                section(
                    title: "导出",
                    detail: "把当前的 VPN、跳板、转发和图上的位置存成一个 JSON 文件。勾选下面的选项后，VPN 账号和 SSH 私钥的内容也一起带上，换一台机器导入就能直接用。"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("包含 VPN 密码和 SSH 私钥", isOn: $includeSecrets)
                            .toggleStyle(.checkbox)
                        if includeSecrets {
                            Text("导出的文件里是明文密码和私钥，请当成密码一样保管，只交给自己信任的人。")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ActionButton(title: "导出到文件…", symbol: "square.and.arrow.up", kind: .secondary) {
                            exportConfig()
                        }
                    }
                }
                Rectangle().fill(theme.line).frame(height: 1)
                section(
                    title: "导入",
                    detail: "选择之前导出的文件，确认内容后替换当前配置。替换前会把现在的配置备份为 config.json.bak。文件里带的账号和私钥会存进应用自己的数据目录。"
                ) {
                    ActionButton(title: "选择文件…", symbol: "square.and.arrow.down", kind: .secondary) {
                        chooseFile()
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
        .frame(width: 540, height: 520)
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
                Text("\(preview.missingCredentials.joined(separator: "、")) 的账号文件在这台机器上不存在，文件里也没带账号，导入后要在对应节点里重新填。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preview.issues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("不能导入：")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(preview.issues, id: \.self) { issue in
                        Text("· \(issue)").font(.system(size: 12))
                    }
                }
                .foregroundStyle(theme.bad)
            }
            HStack(spacing: 8) {
                if preview.issues.isEmpty {
                    ActionButton(title: "导入并替换当前配置", symbol: "checkmark", kind: .primary) {
                        apply(preview)
                    }
                }
                ActionButton(title: "取消", kind: .secondary) {
                    self.preview = nil
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.line, lineWidth: 1))
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.title = "导出配置"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "netlink-config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let current = ConfigStore.loadIfValid() ?? model.config
            try ConfigTransfer.write(current, to: url, includeSecrets: includeSecrets)
            show(
                includeSecrets
                    ? "已导出到 \(url.path)（含密码和私钥，请妥善保管）"
                    : "已导出到 \(url.path)",
                failed: false
            )
        } catch {
            show("导出失败：\(error.localizedDescription)", failed: true)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的配置"
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
            show("已导入。原配置备份为 config.json.bak，转发和 VPN 的改动重新连接后生效。", failed: false)
            Task { await model.refresh() }
        } catch {
            show("导入失败：\(error.localizedDescription)", failed: true)
        }
    }

    private func show(_ text: String, failed: Bool) {
        message = text
        self.failed = failed
    }
}

@MainActor
struct MenuPanel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.netlinkTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.menuSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(overallTint)
                Text("内网连接")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    Task { await model.refresh(manual: true) }
                } label: {
                    if model.refreshingVisible {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.muted)
                .help("刷新")
                Button("打开") { showMain() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .padding(.bottom, 4)
            menuSection("VPN", first: true)
            menuRow(
                title: menuVPNName,
                status: menuStatus(model.vpn.phase),
                symbol: model.vpn.phase == .up ? "lock.shield.fill" : "lock.shield",
                tint: phaseTint(model.vpn.phase),
                action: model.vpn.phase == .down ? "连接" : "断开",
                danger: model.vpn.phase != .down,
                spinning: model.job == .vpnConnect || model.job == .vpnDisconnect
            ) {
                if model.vpn.phase == .down {
                    model.connectVPN()
                } else {
                    model.disconnectVPN()
                }
            }
            ForEach(model.config.vpns.filter(\.isSystemVPN)) { profile in
                let on = model.vpn.systemUp.contains(profile.serviceName)
                menuRow(
                    title: profile.name,
                    status: on ? .up : .down,
                    iconFile: Engine.systemVPNAppPath(kind: profile.kind),
                    tint: on ? theme.ok : theme.muted,
                    action: on ? "断开" : "连接",
                    danger: on,
                    spinning: model.job == .vpnConnect || model.job == .vpnDisconnect
                ) {
                    if on {
                        model.disconnectVPNProfile(profile.id)
                    } else {
                        model.connectVPNProfile(profile.id)
                    }
                }
            }
            if !model.tunnel.ports.isEmpty {
                menuSection("隧道")
                ForEach(model.tunnel.ports) { port in
                    menuRow(
                        title: port.name,
                        status: port.httpOK ? .up : (port.listening ? .warn : .down),
                        pageURL: port.browseURL,
                        tint: port.httpOK ? theme.ok : (port.listening ? theme.warn : theme.bad),
                        action: port.httpOK || port.listening ? "断开" : "连接",
                        danger: port.httpOK || port.listening,
                        spinning: model.job == .forwardConnect(port.localPort) || model.job == .forwardDisconnect(port.localPort)
                    ) {
                        if port.httpOK || port.listening {
                            model.disconnectForward(port.localPort)
                        } else {
                            model.connectForward(port.localPort)
                        }
                    }
                }
            }
            Text(watchSummary)
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .padding(.top, 8)
            Rectangle().fill(theme.line).frame(height: 1).padding(.vertical, 8)
            Button("退出并断开") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 268)
        .background(theme.bg)
        .foregroundStyle(theme.text)
        .onChange(of: model.fortiPrompt) { _, show in
            if show {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var overallTint: Color {
        if model.vpn.phase == .up && model.tunnel.phase == .up { return theme.ok }
        if model.vpn.phase == .down && model.tunnel.phase == .down { return theme.bad }
        if model.vpn.phase == .checking || model.tunnel.phase == .checking { return theme.muted }
        return theme.warn
    }

    private var menuVPNName: String {
        let live = model.vpn.connectedHost
        if !live.isEmpty, let match = model.config.vpns.first(where: { profile in
            let host = Credentials.load(file: profile.credentialFile)?.host ?? ""
            return !host.isEmpty && (live == host || live.contains(host) || host.contains(live))
        }) {
            return match.name
        }
        return model.config.vpns.first?.name ?? "VPN"
    }

    private var watchSummary: String {
        switch (model.vpn.watch, model.tunnel.watch) {
        case (.off, .off): return "自动重连关着"
        case (.app, .app): return "自动重连开着"
        case (.off, _): return "VPN 自动重连关着"
        case (_, .off): return "隧道自动重连关着"
        default: return "自动重连：\(model.vpn.watch.label)"
        }
    }

    private enum MenuStatus {
        case up, warn, down, checking

        var symbol: String {
            switch self {
            case .up: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.circle.fill"
            case .down: return "xmark.circle"
            case .checking: return "circle.dotted"
            }
        }

        var help: String {
            switch self {
            case .up: return "已连接"
            case .warn: return "无响应"
            case .down: return "未连接"
            case .checking: return "检查中"
            }
        }

        func tint(_ theme: Theme) -> Color {
            switch self {
            case .up: return theme.ok
            case .warn: return theme.warn
            case .down: return theme.muted
            case .checking: return theme.muted
            }
        }
    }

    private func menuStatus(_ phase: LinkPhase) -> MenuStatus {
        switch phase {
        case .up: return .up
        case .degraded: return .warn
        case .down: return .down
        case .checking: return .checking
        }
    }

    private func menuSection(_ title: String, first: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.muted)
            .padding(.top, first ? 2 : 10)
            .padding(.bottom, 1)
    }

    private func phaseTint(_ phase: LinkPhase) -> Color {
        switch phase {
        case .checking: return theme.muted
        case .up: return theme.ok
        case .degraded: return theme.warn
        case .down: return theme.bad
        }
    }

    private func showMain() {
        let windows = NSApp.windows.filter { window in
            window.styleMask.contains(.titled)
                && window.level == .normal
                && !(window is NSPanel)
        }
        if let window = windows.first {
            for extra in windows.dropFirst() {
                extra.close()
            }
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

    private func menuRow(
        title: String,
        status: MenuStatus,
        pageURL: String? = nil,
        iconFile: String? = nil,
        symbol: String? = nil,
        tint: Color,
        action: String,
        danger: Bool,
        spinning: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            if iconFile != nil {
                ServiceBadge(iconFile: iconFile, symbol: symbol ?? "app", tint: tint, side: 16, chrome: false)
            } else if let pageURL {
                ServiceBadge(pageURL: pageURL, symbol: "globe", tint: tint, side: 16, chrome: false)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
            } else {
                Circle().fill(tint).frame(width: 7, height: 7).frame(width: 16, height: 16)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Image(systemName: status.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.tint(theme))
                .help(status.help)
            Spacer(minLength: 8)
            Button(action: perform) {
                HStack(spacing: 4) {
                    if spinning {
                        ProgressView().controlSize(.mini)
                    }
                    Text(action)
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(width: 52, height: 24)
                .foregroundStyle(danger ? theme.bad : theme.accent)
                .background((danger ? theme.bad : theme.accent).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke((danger ? theme.bad : theme.accent).opacity(0.45), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(spinning)
        }
        .padding(.vertical, 5)
    }

}

@MainActor
private struct FortiAccountSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.netlinkTheme) private var theme
    @State private var user = ""
    @State private var password = ""
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FortiClient 账号")
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("用户")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                TextField("用户名", text: $user)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("密码")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                SecureField(FortiClient.hasLogin() ? "留空则不改" : "必填", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            Text("密码只写在本机的凭据文件里，不进配置，也不进日志。FortiClient 自己没有记住密码。")
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.bad)
            }
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.fortiConnectAfterSave ? "保存并连接" : "保存") { save() }
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
        }
    }
}

@MainActor
private struct PathConfigSheet: View {
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
                field("名称", text: $name, prompt: "VPN")
                field("主机", text: $host, prompt: "vpn.example.com")
                field("用户", text: $user, prompt: "用户名")
                VStack(alignment: .leading, spacing: 6) {
                    Text("密码")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.muted)
                    SecureField(isAddingVPN ? "必填" : "留空则不改", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                Text(isAddingVPN ? "密码只写在本机的凭据文件里，不会进配置。" : "正在使用的连接不会马上切换。同一时间只连一个 VPN。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .jump, .addJump:
                field("名称", text: $name, prompt: "跳板")
                field("跳板", text: $jump, prompt: "user@host")
                field("私钥", text: $identity, prompt: "~/.ssh/id_ed25519")
                if !identity.trimmingCharacters(in: .whitespaces).isEmpty, !keyExists {
                    Text("找不到这个私钥")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.warn)
                }
                Text("写成 user@host。改完要重新连接，正在用的隧道不会马上切换。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            case .addTunnel:
                field("名称", text: $name, prompt: "GitLab")
                field("本地端口", text: Binding(
                    get: { String(localPort) },
                    set: { localPort = Int($0.filter(\.isNumber)) ?? localPort }
                ), prompt: "9000")
                field("目标主机", text: $targetHost, prompt: "10.0.0.10")
                field("目标端口", text: Binding(
                    get: { String(targetPort) },
                    set: { targetPort = Int($0.filter(\.isNumber)) ?? targetPort }
                ), prompt: "80")
                field("打开时的域名，可空", text: $openHost, prompt: "留空则用 127.0.0.1")
                Text("先出现在图上，点连接才会建隧道。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
            case .renameMachine, .renameVPN, .renameJump, .renameForward:
                field("名称", text: $name, prompt: "显示名称")
                Text("只改图上和菜单里的名字，不会动正在用的连接。")
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
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save() }
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

    private var title: String {
        switch kind {
        case .vpn: return "修改 VPN"
        case .jump: return "修改跳板"
        case .addVPN: return "添加 VPN"
        case .addJump: return "添加跳板"
        case .addTunnel: return "添加隧道"
        case .renameMachine, .renameVPN, .renameJump, .renameForward: return "改名"
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
            name = item?.name ?? "跳板"
            jump = item?.host ?? ""
            identity = item?.identityFile ?? ""
        case .addVPN:
            name = "VPN"
        case .addJump:
            name = "跳板"
            identity = "~/.ssh/"
        case .addTunnel:
            name = "新隧道"
            localPort = suggestedPort()
            targetPort = 80
        case .renameMachine:
            name = model.config.machineName
        case .renameVPN(let id):
            name = model.config.vpns.first { $0.id == id }?.name ?? "VPN"
        case .renameJump(let id):
            name = model.config.jumps.first { $0.id == id }?.name ?? "跳板"
        case .renameForward(let id):
            name = model.config.forwards.first { $0.id == id }?.name ?? "隧道"
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
            }
            dismiss()
        } catch {
            note = error.localizedDescription
        }
    }
}

@MainActor
struct SettingsView: View {
    private static let plainNumber = IntegerFormatStyle<Int>().grouping(.never)
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.appearanceKey) private var appearanceRaw = AppearanceChoice.system.rawValue
    @State private var draft = AppConfig()
    @State private var host = ""
    @State private var user = ""
    @State private var password = ""
    @State private var note = ""
    @State private var loaded = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("开机启动") {
                    Toggle("登录后自动打开本应用", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                    if loginStatus == .requiresApproval {
                        HStack {
                            Text("需要在系统设置的「登录项」里允许")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("打开系统设置") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    if !model.loginMessage.isEmpty {
                        Text(model.loginMessage).foregroundStyle(.red)
                    }
                    Text("只是登录后把应用打开，不会自动连接。自动重连看各卡片上的开关。应用换了位置需要重新打开这个开关，建议放在「应用程序」里。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("主题") {
                    Picker("主题", selection: $appearanceRaw) {
                        Text("深色").tag(AppearanceChoice.dark.rawValue)
                        Text("浅色").tag(AppearanceChoice.light.rawValue)
                        Text("跟随系统").tag(AppearanceChoice.system.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("VPN 账号") {
                    TextField("主机", text: $host)
                    TextField("用户", text: $user)
                    SecureField("新密码，留空则不改", text: $password)
                    Text("写在 \(draft.credentialFile)。保存后文件权限会收成仅本人可读。应用不另存一份密码。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("更新账号") { updateCredential() }
                }
                Section("跳板和密钥") {
                    TextField("跳板 user@host", text: $draft.jumpHost)
                    TextField("私钥路径", text: $draft.identityFile)
                    TextField("凭据文件", text: $draft.credentialFile)
                }
                Section("转发") {
                    ForEach($draft.forwards) { $forward in
                        HStack {
                            TextField("名称", text: $forward.name).frame(width: 110)
                            TextField("本地", value: $forward.localPort, format: Self.plainNumber).frame(width: 70)
                            TextField("目标主机", text: $forward.targetHost)
                            TextField("目标端口", value: $forward.targetPort, format: Self.plainNumber).frame(width: 80)
                            Button {
                                draft.forwards.removeAll { $0.id == forward.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .disabled(draft.forwards.count <= 1)
                        }
                    }
                    Button("加一条") {
                        draft.forwards.append(Forward(name: "新转发", localPort: 9000, targetHost: "10.0.0.10", targetPort: 80))
                    }
                    Text("改完要重启隧道才生效。健康检查也按这里的端口来。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("VPN 健康检查") {
                    TextField("路由里要出现的网段", text: $draft.routeMarker)
                    TextField("要 ping 的网关", text: $draft.pingHost)
                    TextField("检查间隔（秒）", value: $draft.vpnWatchdogInterval, format: .number)
                    TextField("连续失败几次才重启", value: $draft.vpnFailThreshold, format: .number)
                    TextField("隧道检查间隔（秒）", value: $draft.tunnelWatchdogInterval, format: .number)
                }
            }
            .formStyle(.grouped)
            if !note.isEmpty {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            HStack {
                Button("关闭") { dismiss() }
                Spacer()
                Button("保存") { saveConfig() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 720)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = model.config
            host = model.vpn.host
            user = model.vpn.user
        }
    }

    private func saveConfig() {
        if let index = draft.jumps.firstIndex(where: { $0.id == Jump.primary }) ?? draft.jumps.indices.first {
            draft.jumps[index].host = draft.jumpHost
            draft.jumps[index].identityFile = draft.identityFile
        }
        if let index = draft.vpns.firstIndex(where: { $0.id == VPNProfile.primary }) ?? draft.vpns.indices.first {
            draft.vpns[index].credentialFile = draft.credentialFile
        }
        do {
            try model.save(config: draft)
            note = "配置已保存"
        } catch {
            note = error.localizedDescription
        }
    }

    private func updateCredential() {
        do {
            try model.saveCredential(host: host, user: user, password: password)
            password = ""
            note = "账号已更新"
            Task { await model.refresh() }
        } catch {
            note = error.localizedDescription
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            model.loginMessage = ""
        } catch {
            model.loginMessage = error.localizedDescription
        }
        // 以系统实际状态为准：注册可能需要用户批准，也可能失败。
        loginStatus = SMAppService.mainApp.status
        launchAtLogin = loginStatus == .enabled || (on && loginStatus == .requiresApproval)
    }
}

@MainActor
struct NetLinkCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandMenu("连接") {
            Button("刷新状态") { Task { await model.refresh(manual: true) } }
                .keyboardShortcut("r")
            Button("连接隧道") { model.connectTunnel() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("连接 VPN") { model.connectVPN() }
            Button("断开 VPN") { model.disconnectVPN() }
            Button("断开隧道") { model.disconnectTunnel() }
        }
    }
}

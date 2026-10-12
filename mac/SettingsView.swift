import AppKit
import ServiceManagement
import SwiftUI

/// 设置窗口（⌘,）：只放应用级的设置。账号、跳板、转发在主窗口里点对应节点编辑。
@MainActor
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label(tr("通用", "General"), systemImage: "gearshape") }
            HealthSettings(model: model)
                .tabItem { Label(tr("健康检查", "Health Check"), systemImage: "waveform.path.ecg") }
            AdvancedSettings(model: model)
                .tabItem { Label(tr("高级", "Advanced"), systemImage: "slider.horizontal.3") }
        }
        .frame(width: 500)
    }
}

@MainActor
private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @AppStorage(Prefs.appearanceKey) private var appearanceRaw = AppearanceChoice.system.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section {
                Toggle(tr("登录时打开内网连接", "Open NetLink at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text(tr("需要在系统设置的「登录项」里允许", "Allow it under Login Items in System Settings"))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(tr("打开系统设置", "Open System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if !model.loginMessage.isEmpty {
                    Text(model.loginMessage).foregroundStyle(.red)
                }
                Toggle(tr("断线后自动重连 VPN 和隧道", "Reconnect the VPN and tunnels when they drop"), isOn: Binding(
                    get: { model.autoReconnectOn },
                    set: { model.setAutoReconnect($0) }
                ))
            } footer: {
                Text(tr("登录时只打开应用，不会自动连接。", "Opening at login doesn't connect anything by itself."))
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker(tr("外观", "Appearance"), selection: $appearanceRaw) {
                    Text(tr("浅色", "Light")).tag(AppearanceChoice.light.rawValue)
                    Text(tr("深色", "Dark")).tag(AppearanceChoice.dark.rawValue)
                    Text(tr("跟随系统", "System")).tag(AppearanceChoice.system.rawValue)
                }
                .pickerStyle(.segmented)
                Picker(tr("语言", "Language"), selection: Binding(
                    get: { LanguageStore.shared.choice },
                    set: {
                        LanguageStore.shared.choice = $0
                        // 默认名（跳板、本机……）在读配置时按语言换，重读一次让图上立刻变。
                        Task { await model.refresh() }
                    }
                )) {
                    Text(tr("跟随系统", "System")).tag(AppLanguage.system)
                    Text(verbatim: "中文").tag(AppLanguage.zh)
                    Text(verbatim: "English").tag(AppLanguage.en)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 270)
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
private struct HealthSettings: View {
    @Bindable var model: AppModel
    @State private var draft = AppConfig()
    @State private var loaded = false
    @State private var note = ""
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                TextField(tr("路由里要出现的网段", "Network in the routes"), text: $draft.routeMarker, prompt: Text("10.0.0"))
                TextField(tr("网关探测", "Gateway check"), text: $draft.pingHost, prompt: Text("10.0.0.1:443"))
            } header: {
                Text("VPN")
            } footer: {
                Text(tr("网关写成 主机:端口 用 TCP 探测（推荐，很多内网主机不回 ping）；不带端口就 ping。", "Write the gateway as host:port to use a TCP check (recommended, many intranet hosts don't answer ping); without a port it pings."))
                    .foregroundStyle(.secondary)
            }
            Section(tr("间隔和重试", "Interval and retries")) {
                TextField(tr("VPN 检查间隔（秒）", "VPN check interval (s)"), value: $draft.vpnWatchdogInterval, format: .number)
                TextField(tr("VPN 失败几次才重启", "VPN failures before restart"), value: $draft.vpnFailThreshold, format: .number)
                TextField(tr("隧道检查间隔（秒）", "Tunnel check interval (s)"), value: $draft.tunnelWatchdogInterval, format: .number)
                TextField(tr("隧道失败几次才重启", "Tunnel failures before restart"), value: $draft.tunnelFailThreshold, format: .number)
            }
            SaveRow(note: note, failed: failed, changed: changed) { save() }
        }
        .formStyle(.grouped)
        .frame(height: 400)
        .onAppear(perform: load)
    }

    private var changed: Bool {
        draft.routeMarker != model.config.routeMarker
            || draft.pingHost != model.config.pingHost
            || draft.vpnWatchdogInterval != model.config.vpnWatchdogInterval
            || draft.vpnFailThreshold != model.config.vpnFailThreshold
            || draft.tunnelWatchdogInterval != model.config.tunnelWatchdogInterval
            || draft.tunnelFailThreshold != model.config.tunnelFailThreshold
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        draft = model.config
    }

    private func save() {
        var next = model.config
        next.routeMarker = draft.routeMarker.trimmingCharacters(in: .whitespaces)
        next.pingHost = draft.pingHost.trimmingCharacters(in: .whitespaces)
        next.vpnWatchdogInterval = draft.vpnWatchdogInterval
        next.vpnFailThreshold = draft.vpnFailThreshold
        next.tunnelWatchdogInterval = draft.tunnelWatchdogInterval
        next.tunnelFailThreshold = draft.tunnelFailThreshold
        do {
            try model.updateHealthCheck(next)
            draft = model.config
            note = tr("已保存，下次检查起生效", "Saved; applies from the next check")
            failed = false
        } catch {
            note = error.localizedDescription
            failed = true
        }
    }
}

@MainActor
private struct AdvancedSettings: View {
    @Bindable var model: AppModel
    @State private var draft = AppConfig()
    @State private var loaded = false
    @State private var note = ""
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                TextField("openconnect", text: $draft.openconnectPath)
                    .font(.system(size: 12, design: .monospaced))
                TextField("autossh", text: $draft.autosshPath)
                    .font(.system(size: 12, design: .monospaced))
                TextField(tr("VPN 重连超时（秒）", "VPN reconnect timeout (s)"), value: $draft.reconnectTimeout, format: .number)
            } header: {
                Text(tr("程序", "Programs"))
            } footer: {
                Text(tr("默认是 Homebrew 在 Apple Silicon 上的路径。改了路径，免密 sudo 规则也要跟着改。", "Defaults are the Homebrew paths on Apple Silicon. If you change them, the passwordless sudo rule must change too."))
                    .foregroundStyle(.secondary)
            }
            SaveRow(note: note, failed: failed, changed: changed) { save() }
            Section(tr("数据", "Data")) {
                HStack {
                    Text(tr("配置、导入的账号和日志", "Config, imported accounts and logs"))
                    Spacer()
                    Button(tr("在访达中显示", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.file])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 340)
        .onAppear(perform: load)
    }

    private var changed: Bool {
        draft.openconnectPath != model.config.openconnectPath
            || draft.autosshPath != model.config.autosshPath
            || draft.reconnectTimeout != model.config.reconnectTimeout
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        draft = model.config
    }

    private func save() {
        var next = model.config
        next.openconnectPath = draft.openconnectPath.trimmingCharacters(in: .whitespaces)
        next.autosshPath = draft.autosshPath.trimmingCharacters(in: .whitespaces)
        next.reconnectTimeout = draft.reconnectTimeout
        do {
            try model.updateHealthCheck(next)
            draft = model.config
            note = tr("已保存", "Saved")
            failed = false
        } catch {
            note = error.localizedDescription
            failed = true
        }
    }
}

/// 设置页里「保存」那一行：左边是结果，右边是按钮；没改动时按钮不可点。
private struct SaveRow: View {
    var note: String
    var failed: Bool
    var changed: Bool
    var save: () -> Void

    var body: some View {
        HStack {
            Text(note)
                .font(.callout)
                .foregroundStyle(failed ? Color.red : Color.secondary)
                .lineLimit(3)
            Spacer()
            Button(tr("保存", "Save"), action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!changed)
        }
    }
}

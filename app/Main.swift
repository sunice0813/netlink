import AppKit
import SwiftUI

@main
struct AppLauncher {
    static func main() {
        if ProcessInfo.processInfo.environment["NETLINK_SERVICE_DRY"] == "1" {
            print("dry-ready")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 20)
            exit(0)
        }
        let arguments = CommandLine.arguments
        if arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        if arguments.contains("--status") {
            exit(StatusCLI.run())
        }
        if arguments.contains("--service") {
            DispatchQueue.global(qos: .utility).async {
                Service.run()
                exit(0)
            }
            dispatchMain()
        }
        NetLinkApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var allowTerminate = false
    private var terminatePending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppearanceWindows.apply()
        presentMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.presentMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 真正退出时先断开 VPN / 隧道并停掉后台守护，再结束进程。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowTerminate { return .terminateNow }
        if terminatePending { return .terminateLater }
        terminatePending = true
        Engine.operationQueue.async { [weak self] in
            Engine.disconnectAll()
            DispatchQueue.main.async {
                self?.allowTerminate = true
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private func presentMainWindow() {
        let titled = NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.level == .normal }
        for window in titled {
            window.minSize = NSSize(width: 880, height: 400)
            let frame = window.frame
            let tiny = frame.width < 860 || frame.height < 430
            let loose = frame.height > 520 && frame.height < 700
            if tiny || loose {
                let width = frame.width < 860 ? 980 : frame.width
                window.setContentSize(NSSize(width: width, height: 480))
            }
            if let screen = NSScreen.main {
                window.setFrameOrigin(origin(for: window.frame.size, on: screen))
            } else {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func origin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
    }
}

enum AppearanceWindows {
    static func apply() {
        let appearance: NSAppearance?
        switch AppearanceChoice.current {
        case .system:
            appearance = nil
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        case .light:
            appearance = NSAppearance(named: .aqua)
        }
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}

struct NetLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window(tr("内网连接", "NetLink"), id: "main") {
            ContentView(model: model)
                .themed()
        }
        .defaultSize(width: 980, height: 480)
        .windowResizability(.contentMinSize)
        .commands {
            NetLinkCommands(model: model)
        }

        MenuBarExtra {
            MenuPanel(model: model)
                .themed()
        } label: {
            Image(systemName: model.menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

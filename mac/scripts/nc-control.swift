import Foundation
import SystemConfiguration

/// 用 SystemConfiguration 启停系统 VPN，避免 scutil --nc stop 卡死。
/// 用法：nc-control <start|stop|status> <service-name-or-uuid>
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs("usage: nc-control start|stop|status <service>\n", stderr)
            exit(2)
        }
        let action = args[1]
        let service = args[2]
        guard let id = resolveServiceID(service) else {
            fputs("service not found\n", stderr)
            exit(1)
        }
        fputs("id=\(id)\n", stderr)
        switch action {
        case "status":
            print(connectionStatus(id))
        case "start":
            let ok = start(id)
            Thread.sleep(forTimeInterval: 1.5)
            fputs("after=\(connectionStatus(id))\n", stderr)
            exit(ok ? 0 : 1)
        case "stop":
            let ok = stop(id)
            Thread.sleep(forTimeInterval: 1.5)
            fputs("after=\(connectionStatus(id))\n", stderr)
            exit(ok ? 0 : 1)
        default:
            fputs("unknown action\n", stderr)
            exit(2)
        }
    }

    static func resolveServiceID(_ nameOrID: String) -> String? {
        if let prefs = SCPreferencesCreate(nil, "netlink-nc" as CFString, nil),
           let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] {
            for service in services {
                let id = SCNetworkServiceGetServiceID(service) as String? ?? ""
                let name = SCNetworkServiceGetName(service) as String? ?? ""
                if id.caseInsensitiveCompare(nameOrID) == .orderedSame
                    || name.caseInsensitiveCompare(nameOrID) == .orderedSame {
                    return id
                }
            }
        }
        // NE VPN 可能不在 SCNetworkService 列表里，UUID 直接用。
        if nameOrID.count >= 30 { return nameOrID }
        // 从 scutil --nc list 解析（只读，很快）。
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        proc.arguments = ["--nc", "list"]
        proc.standardOutput = pipe
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            guard raw.contains("\"\(nameOrID)\"") || raw.contains(nameOrID) else { continue }
            if let uuid = raw.split(whereSeparator: \.isWhitespace).first(where: {
                $0.count == 36 && $0.contains("-")
            }) {
                return String(uuid)
            }
        }
        return nil
    }

    static func makeConnection(_ serviceID: String) -> SCNetworkConnection? {
        var context = SCNetworkConnectionContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        return SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, &context)
    }

    static func connectionStatus(_ serviceID: String) -> String {
        guard let conn = makeConnection(serviceID) else { return "Unavailable" }
        switch SCNetworkConnectionGetStatus(conn).rawValue {
        case -1: return "Invalid"
        case 0: return "Disconnected"
        case 1: return "Connecting"
        case 2: return "Connected"
        case 3: return "Disconnecting"
        default: return "Unknown"
        }
    }

    static func start(_ serviceID: String) -> Bool {
        guard let conn = makeConnection(serviceID) else {
            fputs("create failed\n", stderr)
            return false
        }
        let ok = SCNetworkConnectionStart(conn, nil, true)
        if !ok { fputs("start failed errno=\(SCError()) \(String(cString: SCErrorString(SCError())))\n", stderr) }
        return ok
    }

    static func stop(_ serviceID: String) -> Bool {
        guard let conn = makeConnection(serviceID) else {
            fputs("create failed\n", stderr)
            return false
        }
        let ok = SCNetworkConnectionStop(conn, true)
        if !ok { fputs("stop failed errno=\(SCError()) \(String(cString: SCErrorString(SCError())))\n", stderr) }
        return ok
    }
}

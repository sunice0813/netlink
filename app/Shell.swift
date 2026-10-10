import Darwin
import Foundation

struct Proc: Equatable {
    var pid: Int32
    var command: String
}

struct CommandResult: Equatable {
    var code: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool = false
    var ok: Bool { code == 0 && !timedOut }
}

enum Redact {
    static func line(_ raw: String) -> String {
        guard let range = raw.range(of: "password=", options: .caseInsensitive) else { return raw }
        return String(raw[..<range.upperBound]) + "***"
    }

    static func text(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line(String($0)) }
            .joined(separator: "\n")
    }
}

enum PathExpander {
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

enum Timestamp {
    static func now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

/// 后台线程写入，主线程读取。操作过程中的提示不走 Swift 并发隔离。
final class JournalStore: @unchecked Sendable {
    static let shared = JournalStore()
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ raw: String) {
        let text = Redact.line(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.lock()
        lines.append(text)
        if lines.count > 80 {
            lines.removeFirst(lines.count - 80)
        }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}

/// 配置文件里的路径是用户可改的，不能原样交给 sudo 去读写或删除。
/// 只有家目录下、不是符号链接、以 .pid / .log 结尾的文件，才允许在没有权限时回退到 sudo。
enum SudoPath {
    static func allowed(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix(home + "/") else { return false }
        guard url.path.hasSuffix(".pid") || url.path.hasSuffix(".log") else { return false }
        return url.resolvingSymlinksInPath().path == url.path
    }
}

enum Shell {
    static func parsePS(_ output: String) -> [Proc] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { return nil }
            let pidText = trimmed[..<space]
            guard let pid = Int32(pidText), pid > 0 else { return nil }
            let command = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            return Proc(pid: pid, command: command)
        }
    }

    static func processes() -> [Proc] {
        // 进程多、命令行长的时候 ps 输出会超过默认上限，后面（pid 大的）会被截掉，
        // 新起的进程就看不见了，所以这里放宽。
        let result = run("/bin/ps", ["-ax", "-o", "pid=,command="], maxOutput: 8_000_000)
        return parsePS(result.stdout)
    }

    static func run(
        _ launchPath: String,
        _ arguments: [String] = [],
        stdin: Data? = nil,
        sudo: Bool = false,
        timeout: TimeInterval? = nil,
        appendLog: String? = nil,
        environment: [String: String]? = nil,
        maxOutput: Int = 200_000
    ) -> CommandResult {
        let binary = sudo ? "/usr/bin/sudo" : launchPath
        let argv = sudo ? ["-n", launchPath] + arguments : arguments
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return CommandResult(code: 127, stdout: "", stderr: "找不到 \(binary)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = argv
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        var logHandle: FileHandle?
        var logHandleErr: FileHandle?
        if let appendLog {
            if !FileManager.default.fileExists(atPath: appendLog) {
                FileManager.default.createFile(atPath: appendLog, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: appendLog)) {
                do {
                    try handle.seekToEnd()
                    let duplicate = Darwin.dup(handle.fileDescriptor)
                    if duplicate >= 0 {
                        logHandle = handle
                        logHandleErr = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
                        process.standardOutput = handle
                        process.standardError = logHandleErr
                    } else {
                        try? handle.close()
                    }
                } catch {
                    try? handle.close()
                }
            }
        }
        if logHandle == nil {
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        let inPipe = Pipe()
        if stdin != nil {
            process.standardInput = inPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        var stdout = ""
        var stderr = ""
        let readers = DispatchGroup()
        if logHandle == nil {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                stdout = decode((try? outPipe.fileHandleForReading.readToEnd()) ?? Data())
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                stderr = decode((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())
                readers.leave()
            }
        }

        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            readers.wait()
            return CommandResult(code: 127, stdout: "", stderr: error.localizedDescription)
        }

        if let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        var timedOut = false
        if let timeout {
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                _ = finished.wait(timeout: .now() + 2)
            }
        } else {
            finished.wait()
        }
        // 子进程退出后，如果它留下的后台进程还抓着管道，不能无限等下去。
        if readers.wait(timeout: .now() + (timedOut ? 2 : 5)) == .timedOut {
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + 1)
        }
        try? logHandle?.close()
        try? logHandleErr?.close()

        let code: Int32 = timedOut ? 124 : process.terminationStatus
        return CommandResult(
            code: code,
            stdout: String(stdout.prefix(maxOutput)),
            stderr: String(stderr.prefix(maxOutput)),
            timedOut: timedOut
        )
    }

    static func append(path: String, text: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            guard SudoPath.allowed(path) else { return }
            _ = run("/usr/bin/tee", ["-a", path], stdin: Data(text.utf8), sudo: true)
        }
    }

    static func tail(path: String, lines: Int) -> String {
        if let text = readTail(path, maxBytes: 48_000) {
            return lastLines(text, lines)
        }
        guard SudoPath.allowed(path) else { return "" }
        let result = run("/usr/bin/tail", ["-n", "\(lines)", path], sudo: true, timeout: 8)
        return result.ok ? result.stdout : ""
    }

    static func readSmall(_ path: String) -> String? {
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return text
        }
        guard SudoPath.allowed(path) else { return nil }
        let result = run("/bin/cat", [path], sudo: true, timeout: 8)
        return result.ok ? result.stdout : nil
    }

    private static func readTail(_ path: String, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start: UInt64 = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func lastLines(_ text: String, _ count: Int) -> String {
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        return parts.suffix(count).joined(separator: "\n")
    }

    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

// struct flock 把同名的 flock(2) 遮住了，直接绑定 C 符号。
@_silgen_name("flock")
private func c_flock(_ fd: Int32, _ operation: Int32) -> Int32

enum FileLock {
    private static let heldKey = "netlink.fileLock.held"

    /// 用 flock：锁跟打开的文件描述（open file description）走，同进程里不同线程也互斥，
    /// 关掉别的描述符不会放掉它。fcntl 记录锁是按进程算的，做不到这一点。
    /// 必须 CLOEXEC，否则 openconnect / autossh 继承这个 fd 后，父进程解锁也不会真正放开。
    /// 同一个线程里嵌套调用直接执行，不会自己等自己。
    static func with(_ body: () -> Void) {
        let thread = Thread.current
        if thread.threadDictionary[heldKey] != nil {
            body()
            return
        }
        ConfigStore.ensureDir()
        let fd = Darwin.open(ConfigStore.lockPath, Darwin.O_CREAT | Darwin.O_RDWR | Darwin.O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            body()
            return
        }
        while c_flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        thread.threadDictionary[heldKey] = true
        defer {
            thread.threadDictionary.removeObject(forKey: heldKey)
            _ = c_flock(fd, LOCK_UN)
            Darwin.close(fd)
        }
        body()
    }
}

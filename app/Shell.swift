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
        let result = run("/bin/ps", ["-ax", "-o", "pid=,command="])
        return parsePS(result.stdout)
    }

    static func run(
        _ launchPath: String,
        _ arguments: [String] = [],
        stdin: Data? = nil,
        sudo: Bool = false,
        timeout: TimeInterval? = nil,
        appendLog: String? = nil,
        environment: [String: String]? = nil
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
        readers.wait()
        try? logHandle?.close()
        try? logHandleErr?.close()

        let code: Int32 = timedOut ? 124 : process.terminationStatus
        return CommandResult(
            code: code,
            stdout: String(stdout.prefix(200_000)),
            stderr: String(stderr.prefix(200_000)),
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
            _ = run("/usr/bin/tee", ["-a", path], stdin: Data(text.utf8), sudo: true)
        }
    }

    static func tail(path: String, lines: Int) -> String {
        if let text = readTail(path, maxBytes: 48_000) {
            return lastLines(text, lines)
        }
        let result = run("/usr/bin/tail", ["-n", "\(lines)", path], sudo: true, timeout: 8)
        return result.ok ? result.stdout : ""
    }

    static func readSmall(_ path: String) -> String? {
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return text
        }
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

enum FileLock {
    /// flock 跟打开的文件描述符走。必须 CLOEXEC，否则 openconnect / autossh
    /// 继承这个 fd 后，父进程解锁也不会真正放开。
    static func with(_ body: () -> Void) {
        ConfigStore.ensureDir()
        let fd = Darwin.open(ConfigStore.lockPath, Darwin.O_CREAT | Darwin.O_RDWR | Darwin.O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            body()
            return
        }
        var lock = Darwin.flock()
        lock.l_type = Int16(Darwin.F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while fcntl(fd, F_SETLKW, &lock) != 0 && errno == EINTR {}
        defer {
            lock.l_type = Int16(Darwin.F_UNLCK)
            _ = fcntl(fd, F_SETLK, &lock)
            Darwin.close(fd)
        }
        body()
    }
}

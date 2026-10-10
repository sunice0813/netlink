import AppKit
import Foundation

/// 从网页里找出浏览器标签用的那张图标。
enum SiteIconLookup {
    static func linkIcon(in html: String, base: URL) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"<link\b([^>]*)>"#, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var best: (score: Int, url: URL)?
        for match in matches {
            let tag = ns.substring(with: match.range)
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon") else { continue }
            if rel.contains("apple") || rel.contains("mask") { continue }
            guard let href = attribute("href", in: tag), let url = resolve(href, base: base) else { continue }
            var score = 0
            if rel == "icon" || rel.contains("shortcut") { score += 2 }
            if (attribute("type", in: tag) ?? "").lowercased().contains("png") { score += 1 }
            if best == nil || score > best!.score {
                best = (score, url)
            }
        }
        return best?.url
    }

    /// JumpServer 的标签图标不写在 HTML 里，而在公开设置的 INTERFACE.favicon。
    static func interfaceFavicon(in data: Data, base: URL) -> URL? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let interface = object["INTERFACE"] as? [String: Any],
            let favicon = interface["favicon"] as? String
        else { return nil }
        return resolve(favicon, base: base)
    }

    static func resolve(_ href: String, base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("data:") else { return nil }
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    static func origin(of url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }

    static func cacheKey(for url: URL) -> String {
        let host = (url.host ?? "site").replacingOccurrences(of: ":", with: "_")
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let raw = "\(host)_\(port)"
        return raw.map { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
                ? character
                : "_"
        }.reduce(into: "") { $0.append($1) }
    }

    static func isImage(_ data: Data, type: String?) -> Bool {
        if let type, type.lowercased().contains("text/html") { return false }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if data.starts(with: [0x00, 0x00, 0x01, 0x00]) { return true }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { return true }
        if data.starts(with: Data("RIFF".utf8)), data.count >= 12, data.subdata(in: 8..<12) == Data("WEBP".utf8) {
            return true
        }
        return false
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"(?i)\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for index in 1...3 where match.range(at: index).location != NSNotFound {
            return ns.substring(with: match.range(at: index))
        }
        return nil
    }
}

actor SiteIcons {
    static let shared = SiteIcons()

    private var memory: [String: Data] = [:]
    private var inflight: [String: Task<Data?, Never>] = [:]
    // 内网页面是 http。Info.plist 允许任意 HTTP，否则系统只放行 IP，GitLab 这种域名会被拦下。
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func data(for page: String) async -> Data? {
        guard let pageURL = URL(string: page), pageURL.host != nil else { return nil }
        let key = SiteIconLookup.cacheKey(for: pageURL)
        if let cached = memory[key] { return cached }
        if let existing = inflight[key] { return await existing.value }
        if let disk = Self.readDisk(key), !Self.isStale(key) {
            memory[key] = disk
            return disk
        }
        let task = Task<Data?, Never> { [session] in
            await Self.fetch(pageURL: pageURL, key: key, session: session)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            memory[key] = result
            return result
        }
        if let disk = Self.readDisk(key) {
            memory[key] = disk
            return disk
        }
        return nil
    }

    private static func fetch(pageURL: URL, key: String, session: URLSession) async -> Data? {
        guard let origin = SiteIconLookup.origin(of: pageURL) else { return nil }
        if let html = await body(pageURL, limit: 80_000, session: session),
           let text = String(data: html, encoding: .utf8),
           let icon = SiteIconLookup.linkIcon(in: text, base: pageURL),
           let image = await image(icon, session: session) {
            writeDisk(key, image)
            return image
        }
        if let open = rooted(origin, "/api/v1/settings/public/open/"),
           let json = await body(open, limit: 20_000, session: session),
           let icon = SiteIconLookup.interfaceFavicon(in: json, base: origin),
           let image = await image(icon, session: session) {
            writeDisk(key, image)
            return image
        }
        if let icon = rooted(origin, "/favicon.ico"),
           let image = await image(icon, session: session) {
            writeDisk(key, image)
            return image
        }
        return nil
    }

    private static func rooted(_ origin: URL, _ path: String) -> URL? {
        var root = origin.absoluteString
        if root.hasSuffix("/") { root.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: root + suffix)
    }

    private static func body(_ url: URL, limit: Int, session: URLSession) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("NetLink", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            !data.isEmpty,
            data.count <= limit
        else { return nil }
        return data
    }

    private static func image(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("NetLink", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            data.count > 16,
            data.count < 512_000,
            SiteIconLookup.isImage(data, type: http.value(forHTTPHeaderField: "Content-Type"))
        else { return nil }
        return data
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NetLink/favicons", isDirectory: true)
    }

    private static func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(key)
    }

    private static func readDisk(_ key: String) -> Data? {
        guard let data = try? Data(contentsOf: fileURL(key)), !data.isEmpty else { return nil }
        return data
    }

    private static func isStale(_ key: String) -> Bool {
        guard
            let values = try? fileURL(key).resourceValues(forKeys: [.contentModificationDateKey]),
            let modified = values.contentModificationDate
        else { return true }
        return Date().timeIntervalSince(modified) > 24 * 60 * 60
    }

    private static func writeDisk(_ key: String, _ data: Data) {
        let folder = directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key), options: .atomic)
    }
}

/// 应用自己的图标。有 icns 时用原图，避免系统在图标上再加一把锁。
enum AppIcon {
    static func image(forApp path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let url = bundledIconURL(appPath: path), let image = NSImage(contentsOf: url), image.isValid {
            return image
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    static func bundledIconURL(appPath: String) -> URL? {
        let info = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: info) else { return nil }
        guard let file = plist["CFBundleIconFile"] as? String else { return nil }
        let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = trimmed.hasSuffix(".icns") ? trimmed : trimmed + ".icns"
        let url = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

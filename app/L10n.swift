import Foundation
import Observation

// 界面只支持中文和英文，两种文案直接写在调用处：tr("连接", "Connect")。
// 编译器保证两边都写了；插值各写各的，语序可以不同。

enum AppLanguage: String, CaseIterable {
    case system
    case zh
    case en

    static func parse(_ raw: String?) -> AppLanguage {
        guard let raw, let language = AppLanguage(rawValue: raw) else { return .system }
        return language
    }
}

enum L10n {
    static let key = "netlink.language"

    /// 设置里选的语言。后台守护和命令行是同一个程序，读的也是这一项。
    static var choice: AppLanguage {
        AppLanguage.parse(UserDefaults.standard.string(forKey: key))
    }

    static func isChinese(_ choice: AppLanguage, preferred: [String]) -> Bool {
        switch choice {
        case .zh: return true
        case .en: return false
        case .system: return preferred.first?.hasPrefix("zh") ?? false
        }
    }

    static var isChinese: Bool {
        isChinese(choice, preferred: Locale.preferredLanguages)
    }

    /// 应用生成的默认名。配置里存的是生成时的语言，读取时换成当前语言；用户自己起的名字不动。
    static let defaultNames: [(zh: String, en: String)] = [
        ("本机", "Local"),
        ("跳板", "Jump host"),
        ("转发", "Forward"),
        ("隧道", "Tunnel"),
        ("新隧道", "New tunnel"),
        ("新转发", "New forward"),
        ("示例网站", "Example site"),
    ]

    static func localizedDefault(_ name: String, chinese: Bool = isChinese) -> String {
        guard let pair = defaultNames.first(where: { $0.zh == name || $0.en == name }) else { return name }
        return chinese ? pair.zh : pair.en
    }
}

/// 让界面在切换语言后立刻重画：tr 在主线程上读一下这里的值，SwiftUI 就会记下依赖。
@Observable
final class LanguageStore {
    @MainActor static let shared = LanguageStore()

    var choice: AppLanguage = L10n.choice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: L10n.key) }
    }
}

func tr(_ zh: String, _ en: String) -> String {
    if Thread.isMainThread {
        MainActor.assumeIsolated { _ = LanguageStore.shared.choice }
    }
    return L10n.isChinese ? zh : en
}

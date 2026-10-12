import AppKit
import SwiftUI

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

    /// 全部用系统语义色：随浅色/深色和系统强调色变化，和 Finder、系统设置一个样子。
    static let system = Theme(
        bg: Color(nsColor: .windowBackgroundColor),
        line: Color(nsColor: .separatorColor),
        text: Color(nsColor: .labelColor),
        muted: Color(nsColor: .secondaryLabelColor),
        ok: Color(nsColor: .systemGreen),
        warn: Color(nsColor: .systemOrange),
        bad: Color(nsColor: .systemRed),
        accent: Color.accentColor,
        accentHover: Color.accentColor.opacity(0.85),
        onAccent: Color.white,
        hoverFill: Color(nsColor: .quaternaryLabelColor).opacity(0.6),
        hoverLine: Color(nsColor: .tertiaryLabelColor),
        log: Color(nsColor: .textColor)
    )

    /// 画布底色：比窗口底色更亮一点（深色下更暗），节点浮在上面。
    static let canvas = Color(nsColor: .controlBackgroundColor)
}

private struct ThemeKey: EnvironmentKey {
    static var defaultValue: Theme { .system }
}

extension EnvironmentValues {
    var netlinkTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

private struct Themed: ViewModifier {
    @AppStorage(Prefs.appearanceKey) private var appearanceRaw = AppearanceChoice.system.rawValue

    private var choice: AppearanceChoice { AppearanceChoice.parse(appearanceRaw) }

    func body(content: Content) -> some View {
        content
            .environment(\.netlinkTheme, .system)
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

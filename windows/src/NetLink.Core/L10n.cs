using System.Globalization;

namespace NetLink.Core;

// 界面只支持中文和英文，两种文案直接写在调用处：Tr("连接", "Connect")。
// 和 Mac 版 mac/L10n.swift 一致。

public enum AppLanguage
{
    System,
    Zh,
    En,
}

public static class L10n
{
    /// 设置里选的语言。应用启动时从设置文件读进来。
    public static AppLanguage Choice { get; set; } = AppLanguage.System;

    /// 系统界面语言，测试里可以换掉。
    public static Func<string> SystemCulture { get; set; } = () => CultureInfo.CurrentUICulture.Name;

    public static AppLanguage Parse(string? raw) => raw switch
    {
        "zh" => AppLanguage.Zh,
        "en" => AppLanguage.En,
        _ => AppLanguage.System,
    };

    public static string Raw(AppLanguage language) => language switch
    {
        AppLanguage.Zh => "zh",
        AppLanguage.En => "en",
        _ => "system",
    };

    public static bool IsChineseFor(AppLanguage choice, string systemCulture) => choice switch
    {
        AppLanguage.Zh => true,
        AppLanguage.En => false,
        _ => systemCulture.StartsWith("zh", StringComparison.OrdinalIgnoreCase),
    };

    public static bool IsChinese => IsChineseFor(Choice, SystemCulture());

    /// 应用生成的默认名。配置里存的是生成时的语言，读取时换成当前语言；用户自己起的名字不动。
    public static readonly (string Zh, string En)[] DefaultNames =
    [
        ("本机", "Local"),
        ("跳板", "Jump host"),
        ("转发", "Forward"),
        ("隧道", "Tunnel"),
        ("新隧道", "New tunnel"),
        ("新转发", "New forward"),
        ("示例网站", "Example site"),
    ];

    public static string LocalizedDefault(string name, bool? chinese = null)
    {
        foreach (var pair in DefaultNames)
        {
            if (pair.Zh == name || pair.En == name)
            {
                return (chinese ?? IsChinese) ? pair.Zh : pair.En;
            }
        }
        return name;
    }
}

public static class Text
{
    public static string Tr(string zh, string en) => L10n.IsChinese ? zh : en;
}

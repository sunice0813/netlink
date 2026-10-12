namespace NetLink.Core;

/// 配置里的路径可以写成 `~/...`，Mac 导出的配置在这里也指得对。
public static class PathExpander
{
    /// 家目录。测试里可以换掉。
    public static string Home { get; set; } = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public static string Expand(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return path;
        var text = Environment.ExpandEnvironmentVariables(path.Trim());
        if (text == "~")
        {
            text = Home;
        }
        else if (text.StartsWith("~/", StringComparison.Ordinal) || text.StartsWith("~\\", StringComparison.Ordinal))
        {
            text = Path.Combine(Home, text[2..]);
        }
        text = text.Replace('/', Path.DirectorySeparatorChar);
        try
        {
            return Path.GetFullPath(text);
        }
        catch
        {
            return text;
        }
    }

    /// 家目录下的路径写成 `~/...`，换一台机器、换一个用户名、换一个系统也指得对。
    public static string Portable(string path, string? home = null)
    {
        var root = TrimEnd(home ?? Home);
        var expanded = Expand(path);
        if (string.Equals(TrimEnd(expanded), root, PathComparison)) return "~";
        var prefix = root + Path.DirectorySeparatorChar;
        if (expanded.StartsWith(prefix, PathComparison))
        {
            return "~/" + expanded[prefix.Length..].Replace('\\', '/');
        }
        return path;
    }

    public static bool IsUnder(string path, string directory)
    {
        var root = TrimEnd(Expand(directory)) + Path.DirectorySeparatorChar;
        return Expand(path).StartsWith(root, PathComparison);
    }

    public static StringComparison PathComparison =>
        OperatingSystem.IsWindows() || OperatingSystem.IsMacOS() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    private static string TrimEnd(string path) => path.TrimEnd('\\', '/');
}

/// 应用自己的数据目录：%APPDATA%\NetLink。可以用 NETLINK_HOME 改到别处（测试用）。
public static class AppPaths
{
    private static string? overrideDirectory;

    public static string Directory
    {
        get
        {
            if (overrideDirectory != null) return overrideDirectory;
            var env = Environment.GetEnvironmentVariable("NETLINK_HOME");
            if (!string.IsNullOrWhiteSpace(env)) return env;
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "NetLink");
        }
        set => overrideDirectory = value;
    }

    public static string ConfigFile => Path.Combine(Directory, "config.json");
    public static string ConfigBackup => Path.Combine(Directory, "config.json.bak");
    public static string SettingsFile => Path.Combine(Directory, "settings.json");
    public static string AppLog => Path.Combine(Directory, "netlink.log");
    public static string CredentialsDirectory => Path.Combine(Directory, "credentials");
    public static string ImportedDirectory => Path.Combine(Directory, "imported");
    /// 自动重连的开关标记。在就表示守护要管它，和 Mac 版的 ~/.openconnect.watchdog 同义。
    public static string VpnWatchFlag => Path.Combine(Directory, "vpn.watch");
    public static string TunnelWatchFlag => Path.Combine(Directory, "tunnel.watch");
    /// 守护重启 VPN 时用哪份凭据：最近一次连上的那个。
    public static string ActiveCredential => Path.Combine(Directory, "vpn.credential");

    public static void EnsureDirectory() => System.IO.Directory.CreateDirectory(Directory);
}

/// 配置里的日志路径是用户可改的。应用会按日志路径认「自己的」ssh 进程再结束它们，
/// 所以只接受家目录下、以 .log / .pid 结尾、不是链接的文件。和 Mac 版 SudoPath 一致。
public static class PathRules
{
    public static bool Allowed(string path, string suffix)
    {
        var expanded = PathExpander.Expand(path);
        if (!PathExpander.IsUnder(expanded, PathExpander.Home)) return false;
        if (!expanded.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return false;
        try
        {
            var info = new FileInfo(expanded);
            if (info.Exists && info.Attributes.HasFlag(FileAttributes.ReparsePoint)) return false;
        }
        catch
        {
            return false;
        }
        return true;
    }
}

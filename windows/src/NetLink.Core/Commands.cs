namespace NetLink.Core;

/// openconnect 和 ssh 的命令行参数。密码从不进参数，只走 openconnect 的标准输入。
public static class Commands
{
    /// Windows 上没有 --background / --pid-file：openconnect 由后台服务直接看管。
    /// vpnc-script 不传，openconnect 默认用自己旁边的 vpnc-script-win.js（经 cscript 运行）。
    public static List<string> OpenConnectArguments(string host, string user, int reconnectTimeout) =>
    [
        "--protocol=anyconnect",
        $"--user={user}",
        "--passwd-on-stdin",
        $"--reconnect-timeout={reconnectTimeout}",
        host,
    ];

    /// 一条转发一个 ssh 进程。-E 指向隧道日志，也用它认出「自己的」ssh，手动开的 ssh 不会被误杀。
    public static List<string> SshArguments(AppConfig config, Forward forward)
    {
        var jump = config.JumpFor(forward);
        return
        [
            "-N",
            "-E", PathExpander.Expand(config.TunnelLogFile),
            "-i", PathExpander.Expand(jump.IdentityFile),
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", forward.Spec,
            jump.Host,
        ];
    }

    /// 跳板连不连得上：登录跑一下 true 就退出。
    public static List<string> JumpProbeArguments(Jump jump, int timeout) =>
    [
        "-i", PathExpander.Expand(jump.IdentityFile),
        "-o", $"ConnectTimeout={timeout}",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        jump.Host,
        "true",
    ];

    /// 写成 `主机:端口` 就测 TCP 连得上，否则 ping。公司网关常常不回 ICMP。
    public static (string Host, int Port)? TcpTarget(string raw)
    {
        var colon = raw.LastIndexOf(':');
        if (colon <= 0 || raw.Contains(']')) return null;
        var host = raw[..colon];
        if (!int.TryParse(raw[(colon + 1)..], out var port) || port is < 1 or > 65535) return null;
        return (host, port);
    }

    /// 凭据里可能是完整 URL，进程里可能只有主机名，比较时两边都收成 host。
    public static string HostKey(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Contains("://") && Uri.TryCreate(trimmed, UriKind.Absolute, out var uri) && uri.Host.Length > 0)
        {
            return uri.Host.ToLowerInvariant();
        }
        return trimmed.ToLowerInvariant();
    }

    public static bool SameHost(string a, string b)
    {
        var left = HostKey(a);
        var right = HostKey(b);
        if (left.Length == 0 || right.Length == 0) return false;
        return left == right || left.Contains(right) || right.Contains(left);
    }

    /// 带空格的参数加引号，用来拼 Windows 的命令行（Process.ArgumentList 也是这个规则）。
    public static string Quote(string argument)
    {
        if (argument.Length > 0 && !argument.Any(c => char.IsWhiteSpace(c) || c == '"')) return argument;
        var builder = new System.Text.StringBuilder("\"");
        var backslashes = 0;
        foreach (var c in argument)
        {
            if (c == '\\')
            {
                backslashes++;
                continue;
            }
            if (c == '"')
            {
                builder.Append('\\', backslashes * 2 + 1).Append('"');
            }
            else
            {
                builder.Append('\\', backslashes).Append(c);
            }
            backslashes = 0;
        }
        builder.Append('\\', backslashes * 2).Append('"');
        return builder.ToString();
    }
}

public static class Watchdog
{
    /// 守护只有在「开关还开着、当前不健康、失败次数够了」时才重连。
    public static bool ShouldRestart(bool flag, bool healthy, int fails, int threshold) =>
        flag && !healthy && fails >= threshold;
}

public static class Redact
{
    public static string Line(string raw)
    {
        var index = raw.IndexOf("password=", StringComparison.OrdinalIgnoreCase);
        return index < 0 ? raw : raw[..(index + "password=".Length)] + "***";
    }

    public static string Text(string raw) => string.Join("\n", raw.Split('\n').Select(Line));
}

/// 操作过程中的提示。后台线程写，界面读。
public sealed class Journal
{
    public static readonly Journal Shared = new();
    private readonly object gate = new();
    private readonly List<string> lines = [];

    public event Action? Changed;

    public void Add(string raw)
    {
        var text = Redact.Line(raw).Trim();
        if (text.Length == 0) return;
        lock (gate)
        {
            lines.Add(text);
            if (lines.Count > 80) lines.RemoveRange(0, lines.Count - 80);
        }
        Changed?.Invoke();
    }

    public List<string> Snapshot()
    {
        lock (gate) return [.. lines];
    }

    public void Clear()
    {
        lock (gate) lines.Clear();
        Changed?.Invoke();
    }
}

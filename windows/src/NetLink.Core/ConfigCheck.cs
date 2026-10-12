using static NetLink.Core.Text;

namespace NetLink.Core;

/// 保存前的校验，和 Mac 版 ConfigCheck 一致。主机名、私钥路径会拼进 ssh 的参数，所以不许以 - 开头或带空白。
public static class ConfigCheck
{
    public static List<string> Issues(AppConfig config)
    {
        var found = new List<string>();
        if (config.Jumps.Count == 0) found.Add(Tr("至少保留一台跳板", "Keep at least one jump host"));
        if (config.Vpns.Count == 0) found.Add(Tr("至少保留一个 VPN", "Keep at least one VPN"));
        foreach (var jump in config.Jumps)
        {
            if (!jump.Host.Contains('@') || jump.Host.StartsWith('@') || jump.Host.EndsWith('@'))
            {
                found.Add(Tr($"{jump.Name} 要写成 user@host", $"{jump.Name} must be written as user@host"));
            }
            if (jump.Host.StartsWith('-') || jump.Host.Any(char.IsWhiteSpace) || jump.IdentityFile.StartsWith('-'))
            {
                found.Add(Tr($"{jump.Name} 的主机或密钥不能以 - 开头，也不能含空白", $"The host or key of {jump.Name} can't start with - or contain whitespace"));
            }
            if (string.IsNullOrWhiteSpace(jump.IdentityFile))
            {
                found.Add(Tr($"{jump.Name} 缺少私钥", $"{jump.Name} has no private key"));
            }
        }
        if (string.IsNullOrWhiteSpace(config.MachineName))
        {
            found.Add(Tr("本机名称不能为空", "The name of this computer can't be empty"));
        }
        foreach (var vpn in config.Vpns)
        {
            if (string.IsNullOrWhiteSpace(vpn.Name)) found.Add(Tr("VPN 名称不能为空", "VPN name can't be empty"));
            if (string.IsNullOrWhiteSpace(vpn.CredentialFile))
            {
                found.Add(Tr($"{vpn.Name} 缺少凭据文件", $"{vpn.Name} has no credential file"));
            }
        }
        foreach (var jump in config.Jumps.Where(j => string.IsNullOrWhiteSpace(j.Name)))
        {
            found.Add(Tr("跳板名称不能为空", "Jump host name can't be empty"));
        }
        foreach (var forward in config.Forwards.Where(f => string.IsNullOrWhiteSpace(f.Name)))
        {
            found.Add(Tr("隧道名称不能为空", "Tunnel name can't be empty"));
        }
        if (config.Forwards.Count == 0) found.Add(Tr("至少保留一条端口转发", "Keep at least one port forward"));
        var ports = config.Forwards.Select(f => f.LocalPort).ToList();
        if (ports.Distinct().Count() != ports.Count) found.Add(Tr("本地端口有重复", "Local ports must be unique"));
        foreach (var forward in config.Forwards)
        {
            if (forward.LocalPort is < 1 or > 65535 || forward.TargetPort is < 1 or > 65535)
            {
                found.Add(Tr($"{forward.Name} 的端口不在 1–65535", $"The port of {forward.Name} must be within 1–65535"));
            }
            if (string.IsNullOrWhiteSpace(forward.TargetHost))
            {
                found.Add(Tr($"{forward.Name} 缺少目标主机", $"{forward.Name} has no target host"));
            }
            else if (forward.TargetHost.StartsWith('-') || !forward.TargetHost.All(c => char.IsLetterOrDigit(c) || c is '.' or '-' or '_'))
            {
                found.Add(Tr($"{forward.Name} 的目标主机只能含字母、数字、点和横线", $"The target host of {forward.Name} may only contain letters, digits, dots and hyphens"));
            }
        }
        if (string.IsNullOrWhiteSpace(config.RouteMarker) || string.IsNullOrWhiteSpace(config.PingHost))
        {
            found.Add(Tr("VPN 路由标记和网关地址不能为空", "VPN route marker and gateway address can't be empty"));
        }
        if (!PathRules.Allowed(config.TunnelLogFile, ".log"))
        {
            found.Add(Tr("隧道日志 必须在家目录下，以 .log 结尾，且不是链接", "Tunnel log must be inside your home folder, end with .log, and not be a link"));
        }
        if (config.VpnFailThreshold < 1 || config.TunnelFailThreshold < 1)
        {
            found.Add(Tr("连续失败次数至少为 1", "Failure threshold must be at least 1"));
        }
        if (config.VpnWatchdogInterval < 5 || config.TunnelWatchdogInterval < 5)
        {
            found.Add(Tr("检查间隔至少 5 秒", "Check interval must be at least 5 seconds"));
        }
        if (config.ReconnectTimeout < 0) found.Add(Tr("重连超时不能为负", "Reconnect timeout can't be negative"));
        if (string.IsNullOrWhiteSpace(config.SshPath)) found.Add(Tr("ssh 路径不能为空", "The ssh path can't be empty"));
        return found;
    }
}

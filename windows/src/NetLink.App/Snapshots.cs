using static NetLink.Core.Text;

namespace NetLink.App;

public enum LinkPhase
{
    Checking,
    Up,
    Degraded,
    Down,
}

public enum WatchdogOwner
{
    Off,
    App,
}

public sealed record PortStatus(
    string Name,
    int LocalPort,
    string Target,
    string BrowseLabel,
    string BrowseUrl,
    bool Enabled,
    bool Listening,
    bool HttpOk);

public sealed record VpnSnapshot
{
    public LinkPhase Phase { get; init; } = LinkPhase.Checking;
    public string Host { get; init; } = "";
    public string User { get; init; } = "";
    /// 服务正在连的主机。用来区分图上的哪一个 VPN 正在连。
    public string ConnectedHost { get; init; } = "";
    public bool CredentialOk { get; init; }
    public bool ServiceReachable { get; init; } = true;
    public string ServiceError { get; init; } = "";
    public bool OpenconnectInstalled { get; init; } = true;
    public int? Pid { get; init; }
    public bool ProcessAlive { get; init; }
    public bool RoutePresent { get; init; }
    public bool GatewayReachable { get; init; }
    public WatchdogOwner Watch { get; init; }
}

public sealed record TunnelSnapshot
{
    public LinkPhase Phase { get; init; } = LinkPhase.Checking;
    public bool SshInstalled { get; init; } = true;
    public bool SshRunning { get; init; }
    public List<string> RunningJumpHosts { get; init; } = [];
    public List<PortStatus> Ports { get; init; } = [];
    public WatchdogOwner Watch { get; init; }

    public int OkCount => Ports.Count(p => p.HttpOk);
}

public static class PhaseText
{
    public static string Title(this LinkPhase phase) => phase switch
    {
        LinkPhase.Checking => Tr("检查中", "Checking"),
        LinkPhase.Up => Tr("已连接", "Connected"),
        LinkPhase.Degraded => Tr("不完整", "Incomplete"),
        _ => Tr("未连接", "Disconnected"),
    };
}

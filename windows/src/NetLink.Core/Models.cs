using static NetLink.Core.Text;

namespace NetLink.Core;

// 和 Mac 版 app/Config.swift 的结构一一对应，config.json 两边可以互相导入。

public enum ForwardCheck
{
    /// 请求一次 HTTP，端到端。
    Http,
    /// 只看本地端口能不能连上，给不是 HTTP 的目标（数据库、SSH 等）用。
    Tcp,
}

public sealed class Forward
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public int LocalPort { get; set; }
    public string TargetHost { get; set; } = "";
    public int TargetPort { get; set; }
    /// 浏览器打开时用的主机名。空则用 127.0.0.1。
    public string OpenHost { get; set; } = "";
    /// 为 false 时这条转发保持断开，自动重连也不会把它拉起来。
    public bool Enabled { get; set; } = true;
    /// 空则走主跳板。
    public Guid? JumpId { get; set; }
    public ForwardCheck Check { get; set; } = ForwardCheck.Http;

    public string Target => $"{TargetHost}:{TargetPort}";
    /// ssh -L 的参数。只写端口时 ssh 默认只监听 127.0.0.1。
    public string Spec => $"{LocalPort}:{TargetHost}:{TargetPort}";
    public string BrowseHost => string.IsNullOrEmpty(OpenHost) ? "127.0.0.1" : OpenHost;
    public string BrowseLabel => LocalPort == 80 ? BrowseHost : $"{BrowseHost}:{LocalPort}";
    public string BrowseUrl => LocalPort == 80 ? $"http://{BrowseHost}/" : $"http://{BrowseHost}:{LocalPort}/";

    public Forward Clone() => (Forward)MemberwiseClone();

    /// 首次启动时的示例，换成自己的目标即可。
    public static List<Forward> Example() =>
    [
        new Forward { Name = Tr("示例网站", "Example site"), LocalPort = 8080, TargetHost = "10.0.0.10", TargetPort = 80 },
    ];
}

public sealed class Jump
{
    public static readonly Guid Primary = Guid.Parse("A1000000-0000-4000-8000-000000000001");

    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    /// user@host
    public string Host { get; set; } = "";
    public string IdentityFile { get; set; } = "";
    /// 空则挂在主 VPN 下。
    public Guid? VpnId { get; set; }

    public Jump Clone() => (Jump)MemberwiseClone();
}

public sealed class VpnProfile
{
    public static readonly Guid Primary = Guid.Parse("B1000000-0000-4000-8000-000000000001");

    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "VPN";
    public string CredentialFile { get; set; } = "";
    /// openconnect：公司 VPN。Mac 版还有 shadowrocket / forticlient，Windows 版不支持，读到会去掉。
    public string Kind { get; set; } = "openconnect";
    public string ServiceName { get; set; } = "";
    /// 流量先经过的另一个 VPN。只用来画图，不影响连接。
    public Guid? ViaId { get; set; }

    public bool IsSystemVpn => Kind != "openconnect";

    public VpnProfile Clone() => (VpnProfile)MemberwiseClone();
}

public readonly record struct PointD(double X, double Y);

public sealed class AppConfig
{
    public const int LayoutRevision = 2;

    public string CredentialFile { get; set; } = "~/.internalvpn";
    public string VpnPidFile { get; set; } = "~/.openconnect.pid";
    public string VpnLogFile { get; set; } = "~/.vpn.log";
    public string VpnWatchdogFile { get; set; } = "~/.openconnect.watchdog";
    /// 连上 VPN 后路由表（route print）里应该出现的网段片段。
    public string RouteMarker { get; set; } = "10.0.0";
    /// VPN 连通性探测。写 `主机:端口` 用 TCP 连接，不带端口则 ping。
    public string PingHost { get; set; } = "10.0.0.1:22";
    public int ReconnectTimeout { get; set; } = 30;
    public int VpnWatchdogInterval { get; set; } = 15;
    public int VpnFailThreshold { get; set; } = 2;

    public string JumpHost { get; set; } = "user@jump.example.com";
    public string IdentityFile { get; set; } = "~/.ssh/id_ed25519";
    public string TunnelLogFile { get; set; } = "~/.tunnel.log";
    public string TunnelWatchdogFile { get; set; } = "~/.tunnel.watchdog";
    public int TunnelWatchdogInterval { get; set; } = 20;
    /// 隧道连续几次检查不通才重启。一次偶发超时不应该把全部转发拆掉重连。
    public int TunnelFailThreshold { get; set; } = 2;
    public List<Forward> Forwards { get; set; } = Forward.Example();
    public List<Jump> Jumps { get; set; } =
    [
        new Jump { Id = Jump.Primary, Name = Tr("跳板", "Jump host"), Host = "user@jump.example.com", IdentityFile = "~/.ssh/id_ed25519" },
    ];
    public List<VpnProfile> Vpns { get; set; } =
    [
        new VpnProfile { Id = VpnProfile.Primary, Name = "VPN", CredentialFile = "~/.internalvpn" },
    ];

    public string MachineName { get; set; } = Tr("本机", "Local");
    /// 拓扑图节点左上角坐标。键是 machine / vpn:<uuid> / jump:<uuid> / forward:<uuid>。
    public Dictionary<string, PointD> Layout { get; set; } = new();
    public int LayoutVersion { get; set; } = LayoutRevision;
    /// Mac 版的程序路径。Windows 版不用，原样保留，导出回 Mac 时不丢。
    public string OpenconnectPath { get; set; } = "/opt/homebrew/bin/openconnect";
    public string AutosshPath { get; set; } = "/opt/homebrew/bin/autossh";
    /// Windows 自带的 OpenSSH 客户端。Mac 版读到这个键会忽略。
    public string SshPath { get; set; } = DefaultSshPath;

    public static string DefaultSshPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe");

    public AppConfig Clone()
    {
        var copy = (AppConfig)MemberwiseClone();
        copy.Forwards = Forwards.Select(f => f.Clone()).ToList();
        copy.Jumps = Jumps.Select(j => j.Clone()).ToList();
        copy.Vpns = Vpns.Select(v => v.Clone()).ToList();
        copy.Layout = new Dictionary<string, PointD>(Layout);
        return copy;
    }

    /// Windows 版不支持的系统 VPN（Shadowrocket、FortiClient）。返回去掉的名字。
    public List<string> DropSystemVpns()
    {
        var dropped = Vpns.Where(v => v.IsSystemVpn).ToList();
        if (dropped.Count == 0) return [];
        var ids = dropped.Select(v => v.Id).ToHashSet();
        Vpns.RemoveAll(v => ids.Contains(v.Id));
        foreach (var vpn in Vpns)
        {
            if (vpn.ViaId is { } via && ids.Contains(via)) vpn.ViaId = null;
        }
        foreach (var jump in Jumps)
        {
            if (jump.VpnId is { } owner && ids.Contains(owner)) jump.VpnId = null;
        }
        foreach (var id in ids)
        {
            Layout.Remove(TopologyKey.Vpn(id));
        }
        return dropped.Select(v => v.Name).ToList();
    }

    public void Normalize()
    {
        DropSystemVpns();
        if (Jumps.Count == 0)
        {
            Jumps = [new Jump { Id = Jump.Primary, Name = Tr("跳板", "Jump host"), Host = JumpHost, IdentityFile = IdentityFile }];
        }
        if (Vpns.Count == 0)
        {
            Vpns = [new VpnProfile { Id = VpnProfile.Primary, Name = "VPN", CredentialFile = CredentialFile }];
        }
        var primaryJump = Jumps.FirstOrDefault(j => j.Id == Jump.Primary) ?? Jumps[0];
        JumpHost = primaryJump.Host;
        IdentityFile = primaryJump.IdentityFile;
        var primaryVpn = Vpns.FirstOrDefault(v => v.Id == VpnProfile.Primary) ?? Vpns[0];
        CredentialFile = primaryVpn.CredentialFile;

        var ids = Vpns.Select(v => v.Id).ToHashSet();
        foreach (var vpn in Vpns)
        {
            if (vpn.ViaId is { } via && (via == vpn.Id || !ids.Contains(via))) vpn.ViaId = null;
        }
        foreach (var vpn in Vpns)
        {
            var seen = new HashSet<Guid> { vpn.Id };
            var cursor = vpn.ViaId;
            while (cursor is { } id)
            {
                if (seen.Contains(id))
                {
                    vpn.ViaId = null;
                    break;
                }
                seen.Add(id);
                cursor = Vpns.FirstOrDefault(v => v.Id == id)?.ViaId;
            }
        }
    }

    /// 从这个 VPN 往上走，经过的所有上游 VPN。
    public HashSet<Guid> UpstreamIds(Guid id)
    {
        var found = new HashSet<Guid>();
        var cursor = Vpns.FirstOrDefault(v => v.Id == id)?.ViaId;
        while (cursor is { } next && !found.Contains(next) && next != id)
        {
            found.Add(next);
            cursor = Vpns.FirstOrDefault(v => v.Id == next)?.ViaId;
        }
        return found;
    }

    public List<VpnProfile> VpnsVia(Guid id) => Vpns.Where(v => v.ViaId == id).ToList();

    public Jump PrimaryJump =>
        Jumps.FirstOrDefault(j => j.Id == Jump.Primary) ?? Jumps.FirstOrDefault()
        ?? new Jump { Id = Jump.Primary, Name = Tr("跳板", "Jump host"), Host = JumpHost, IdentityFile = IdentityFile };

    public Jump JumpFor(Forward forward)
    {
        var id = forward.JumpId ?? Jump.Primary;
        return Jumps.FirstOrDefault(j => j.Id == id) ?? Jumps[0];
    }

    public VpnProfile VpnFor(Jump jump)
    {
        var id = jump.VpnId ?? VpnProfile.Primary;
        return Vpns.FirstOrDefault(v => v.Id == id) ?? Vpns[0];
    }

    public List<Forward> ForwardsOn(Guid jumpId) => Forwards.Where(f => (f.JumpId ?? Jump.Primary) == jumpId).ToList();

    public List<Jump> JumpsOn(Guid vpnId) => Jumps.Where(j => (j.VpnId ?? VpnProfile.Primary) == vpnId).ToList();
}

public static class TopologyKey
{
    public const string Machine = "machine";
    public static string Vpn(Guid id) => $"vpn:{Ids.Format(id)}";
    public static string Jump(Guid id) => $"jump:{Ids.Format(id)}";
    public static string Forward(Guid id) => $"forward:{Ids.Format(id)}";
}

public static class Ids
{
    /// Swift 的 UUID 编码成大写，两边保持一样，图上的位置键才对得上。
    public static string Format(Guid id) => id.ToString("D").ToUpperInvariant();
}

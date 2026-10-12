using System.Diagnostics;
using System.Windows.Threading;
using NetLink.App.Platform;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App;

public enum JobKind
{
    VpnConnect,
    VpnDisconnect,
    VpnRestart,
    TunnelConnect,
    TunnelDisconnect,
    TunnelRestart,
    ForwardConnect,
    ForwardDisconnect,
    WatchOn,
    WatchOff,
    Setup,
}

public sealed record Job(JobKind Kind, int Port = 0);

public enum SetupAction
{
    StartService,
    OpenOptionalFeatures,
}

public sealed record Banner(string Text, SetupAction? Action = null);

/// 界面状态和所有用户操作，对应 Mac 版 AppModel。全部在 UI 线程上读写；耗时的事交给后台线程。
public sealed class AppModel
{
    public VpnSnapshot Vpn { get; private set; } = new();
    public TunnelSnapshot Tunnel { get; private set; } = new();
    public List<string> JournalLines { get; private set; } = [];
    public string VpnLog { get; private set; } = "";
    public string TunnelLog { get; private set; } = "";
    public string AppLog { get; private set; } = "";
    public bool Busy { get; private set; }
    public string? BusyLabel { get; private set; }
    public Job? Job { get; private set; }
    public bool RefreshingVisible { get; private set; }
    public string? StatusLine { get; private set; }
    public DateTime? CheckedAt { get; private set; }
    public AppConfig Config { get; private set; }
    public string? ConfigWarning { get; private set; }

    /// 任何状态变了都会触发，界面据此重画。
    public event Action? Changed;

    private readonly Dispatcher dispatcher;
    private readonly OperationQueue queue = new("NetLink operations");
    private readonly WatchdogLoop watchdog = new();
    private DispatcherTimer? refreshTimer;
    private DispatcherTimer? statusTimer;
    private bool refreshing;
    private bool autoServiceTried;

    public AppModel(Dispatcher dispatcher)
    {
        this.dispatcher = dispatcher;
        AppPaths.EnsureDirectory();
        if (!File.Exists(AppPaths.ConfigFile))
        {
            Config = new AppConfig();
            try { ConfigStore.Save(Config); } catch { }
        }
        else if (ConfigStore.LoadIfValid() is { } loaded)
        {
            if (loaded.LayoutVersion < AppConfig.LayoutRevision)
            {
                loaded.Layout = TopologyLayout.Default(loaded);
                loaded.LayoutVersion = AppConfig.LayoutRevision;
                try { ConfigStore.Save(loaded); } catch { }
            }
            Config = loaded;
        }
        else
        {
            Config = new AppConfig();
            ConfigWarning = Tr("配置文件读不了，先按默认值显示。点保存才会覆盖原文件。", "Can't read the config file. Showing defaults for now; the original file is only overwritten when you click Save.");
        }
        Journal.Shared.Changed += () => dispatcher.InvokeAsync(() =>
        {
            JournalLines = Journal.Shared.Snapshot();
            if (Busy && JournalLines.Count > 0) StatusLine = Clip(JournalLines[^1]);
            Notify();
        });
    }

    public void Start()
    {
        watchdog.Start();
        refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
        refreshTimer.Tick += async (_, _) =>
        {
            if (!Busy) await RefreshAsync();
        };
        refreshTimer.Start();
        _ = RefreshAsync();
    }

    public void Stop()
    {
        refreshTimer?.Stop();
        watchdog.Stop();
    }

    private void Notify() => Changed?.Invoke();

    // MARK: - 状态

    public Banner? Banner
    {
        get
        {
            if (ConfigWarning != null) return new Banner(ConfigWarning);
            if (Vpn.Phase == LinkPhase.Checking) return null;
            if (!Vpn.ServiceReachable)
            {
                return new Banner(Tr("NetLink 后台服务没在运行，VPN 连不上", "The NetLink background service isn't running, so the VPN can't connect"), SetupAction.StartService);
            }
            if (!Vpn.OpenconnectInstalled)
            {
                return new Banner(Tr("安装不完整：找不到 openconnect，请重新安装 NetLink", "Incomplete installation: openconnect is missing. Reinstall NetLink"));
            }
            if (!Tunnel.SshInstalled)
            {
                return new Banner(Tr($"找不到 {Config.SshPath}，需要 Windows 的「OpenSSH 客户端」", $"{Config.SshPath} not found. Windows' \"OpenSSH Client\" is required"), SetupAction.OpenOptionalFeatures);
            }
            if (!Vpn.CredentialOk)
            {
                return new Banner(Tr($"读不到 {Config.CredentialFile} 里的 host / user / password", $"Can't read host / user / password from {Config.CredentialFile}"));
            }
            return null;
        }
    }

    public void Perform(SetupAction action)
    {
        switch (action)
        {
            case SetupAction.StartService:
                Run(new Job(JobKind.Setup), Tr("正在启动后台服务，请在弹出的窗口里允许", "Starting the background service. Allow it in the dialog"), () =>
                {
                    if (ServiceClient.StartElevated())
                    {
                        Thread.Sleep(1500);
                        Engine.Emit(ServiceClient.Status() != null ? Tr("后台服务已启动", "Background service started") : Tr("后台服务还没起来，请重新安装 NetLink", "The background service still isn't up. Reinstall NetLink"));
                    }
                    else
                    {
                        Engine.Emit(Tr("已取消，可以点顶部的「启动服务」重试", "Cancelled. Click \"Start Service\" at the top to try again"));
                    }
                });
                break;
            case SetupAction.OpenOptionalFeatures:
                Open("ms-settings:optionalfeatures");
                break;
        }
    }

    public async Task RefreshAsync(bool manual = false)
    {
        if (refreshing)
        {
            if (manual) Post(Tr("正在刷新，这一步还没结束", "Already refreshing"));
            return;
        }
        if (Busy)
        {
            if (manual) Post(Tr($"{BusyLabel ?? "上一步"}，这一步还没结束", $"{BusyLabel ?? "The previous step"} — still in progress"));
            return;
        }
        refreshing = true;
        if (manual)
        {
            RefreshingVisible = true;
            Post(Tr("正在刷新", "Refreshing"));
        }
        try
        {
            var config = Config;
            var result = await Task.Run(() =>
            {
                var probed = Engine.Probe();
                var vpnLog = ServiceClient.Log(60)?.Log ?? "";
                var tunnelLog = Redact.Text(TextFiles.Tail(PathExpander.Expand(config.TunnelLogFile), 60));
                var appLog = Redact.Text(TextFiles.Tail(AppPaths.AppLog, 80));
                return (probed.Vpn, probed.Tunnel, vpnLog, tunnelLog, appLog);
            });
            Vpn = result.Vpn;
            Tunnel = result.Tunnel;
            VpnLog = result.vpnLog;
            TunnelLog = result.tunnelLog;
            AppLog = result.appLog;
            CheckedAt = DateTime.Now;
            if (ConfigStore.LoadIfValid() is { } loaded) Config = loaded;
            if (manual) Post(Tr($"已刷新 {CheckedAt:HH:mm:ss}", $"Refreshed at {CheckedAt:HH:mm:ss}"));
            AutoSetup();
        }
        finally
        {
            refreshing = false;
            RefreshingVisible = false;
            Notify();
        }
    }

    /// 打开后服务没在跑，就自动请求启动一次（会弹一次 UAC）。失败或取消后改用顶部提示里的按钮。
    private void AutoSetup()
    {
        if (ConfigWarning != null || Busy || Vpn.Phase == LinkPhase.Checking) return;
        if (!autoServiceTried && !Vpn.ServiceReachable)
        {
            autoServiceTried = true;
            Perform(SetupAction.StartService);
        }
    }

    // MARK: - VPN

    public void ConnectVpnProfile(Guid id)
    {
        var profile = Config.Vpns.FirstOrDefault(v => v.Id == id);
        var name = profile?.Name ?? "VPN";
        var file = profile?.CredentialFile ?? Config.CredentialFile;
        Run(new Job(JobKind.VpnConnect), Tr($"正在连接 {name}", $"Connecting {name}"), () =>
        {
            // 同一时间只连一个 VPN：正在连的是别的，先断开。
            var target = Credentials.Load(file)?.Host ?? "";
            var running = Engine.RunningVpnHost();
            if (running.Length > 0 && target.Length > 0 && !Commands.SameHost(running, target))
            {
                Engine.DisconnectVpn();
                Thread.Sleep(2000);
            }
            Engine.ConnectVpn(AppSettings.Current.VpnAutoReconnect, file);
        });
    }

    public void DisconnectVpnProfile(Guid id)
    {
        var file = Config.Vpns.FirstOrDefault(v => v.Id == id)?.CredentialFile ?? Config.CredentialFile;
        var host = Credentials.Load(file)?.Host ?? "";
        var only = Config.Vpns.Count <= 1;
        Run(new Job(JobKind.VpnDisconnect), Tr("正在断开 VPN", "Disconnecting VPN"), () =>
        {
            var running = Engine.RunningVpnHost();
            if (running.Length == 0 || only || host.Length == 0 || Commands.SameHost(running, host))
            {
                Engine.DisconnectVpn();
            }
            else
            {
                Engine.Emit(Tr("这个 VPN 没在连接", "This VPN isn't connected"));
            }
        });
    }

    public void RestartVpnProfile(Guid id)
    {
        var profile = Config.Vpns.FirstOrDefault(v => v.Id == id);
        var name = profile?.Name ?? "VPN";
        var file = profile?.CredentialFile ?? Config.CredentialFile;
        Run(new Job(JobKind.VpnRestart), Tr($"正在重启 {name}", $"Restarting {name}"), () => Engine.RestartVpn(AppSettings.Current.VpnAutoReconnect, file));
    }

    // MARK: - 隧道

    public void ConnectTunnel() =>
        Run(new Job(JobKind.TunnelConnect), Tr("正在连接隧道", "Connecting tunnel"), () => Engine.ConnectTunnel(AppSettings.Current.TunnelAutoReconnect, startVpnIfNeeded: true));

    public void DisconnectTunnel() =>
        Run(new Job(JobKind.TunnelDisconnect), Tr("正在断开隧道", "Disconnecting tunnel"), Engine.DisconnectTunnel);

    public void RestartTunnel() =>
        Run(new Job(JobKind.TunnelRestart), Tr("正在重启隧道", "Restarting tunnel"), () => Engine.RestartTunnel(AppSettings.Current.TunnelAutoReconnect));

    public void ConnectJump(Guid id)
    {
        if (Config.Jumps.Count <= 1)
        {
            ConnectTunnel();
            return;
        }
        var ports = Config.ForwardsOn(id).Select(f => f.LocalPort).ToList();
        Run(new Job(JobKind.TunnelConnect), Tr("正在连接跳板", "Connecting jump host"), () =>
        {
            foreach (var port in ports) Engine.ConnectForward(port, AppSettings.Current.TunnelAutoReconnect, startVpnIfNeeded: true);
        });
    }

    public void DisconnectJump(Guid id)
    {
        if (Config.Jumps.Count <= 1)
        {
            DisconnectTunnel();
            return;
        }
        var ports = Config.ForwardsOn(id).Select(f => f.LocalPort).ToList();
        Run(new Job(JobKind.TunnelDisconnect), Tr("正在断开跳板", "Disconnecting jump host"), () =>
        {
            foreach (var port in ports) Engine.DisconnectForward(port);
        });
    }

    public void RestartJump(Guid id)
    {
        if (Config.Jumps.Count <= 1)
        {
            RestartTunnel();
            return;
        }
        var ports = Config.ForwardsOn(id).Select(f => f.LocalPort).ToList();
        Run(new Job(JobKind.TunnelRestart), Tr("正在重启跳板", "Restarting jump host"), () =>
        {
            foreach (var port in ports) Engine.DisconnectForward(port);
            foreach (var port in ports) Engine.ConnectForward(port, AppSettings.Current.TunnelAutoReconnect, startVpnIfNeeded: true);
        });
    }

    public void ConnectForward(int port)
    {
        var name = Config.Forwards.FirstOrDefault(f => f.LocalPort == port)?.Name ?? Tr("转发", "Forward");
        Run(new Job(JobKind.ForwardConnect, port), Tr($"正在连接 {name}", $"Connecting {name}"), () => Engine.ConnectForward(port, AppSettings.Current.TunnelAutoReconnect, startVpnIfNeeded: true));
    }

    public void DisconnectForward(int port)
    {
        var name = Config.Forwards.FirstOrDefault(f => f.LocalPort == port)?.Name ?? Tr("转发", "Forward");
        Run(new Job(JobKind.ForwardDisconnect, port), Tr($"正在断开 {name}", $"Disconnecting {name}"), () => Engine.DisconnectForward(port));
    }

    // MARK: - 自动重连

    public bool AutoReconnectOn => Vpn.Watch != WatchdogOwner.Off && Tunnel.Watch != WatchdogOwner.Off;

    public void SetAutoReconnect(bool on)
    {
        AppSettings.Update(s =>
        {
            s.VpnAutoReconnect = on;
            s.TunnelAutoReconnect = on;
        });
        Run(new Job(on ? JobKind.WatchOn : JobKind.WatchOff), on ? Tr("正在开启自动重连", "Turning on auto-reconnect") : Tr("正在关闭自动重连", "Turning off auto-reconnect"), () =>
        {
            Engine.SetVpnWatch(on);
            Engine.SetTunnelWatch(on);
        });
    }

    public void SetVpnWatch(bool on)
    {
        AppSettings.Update(s => s.VpnAutoReconnect = on);
        Run(new Job(on ? JobKind.WatchOn : JobKind.WatchOff), on ? Tr("正在开启 VPN 自动重连", "Turning on VPN auto-reconnect") : Tr("正在关闭 VPN 自动重连", "Turning off VPN auto-reconnect"), () => Engine.SetVpnWatch(on));
    }

    public void SetTunnelWatch(bool on)
    {
        AppSettings.Update(s => s.TunnelAutoReconnect = on);
        Run(new Job(on ? JobKind.WatchOn : JobKind.WatchOff), on ? Tr("正在开启隧道自动重连", "Turning on tunnel auto-reconnect") : Tr("正在关闭隧道自动重连", "Turning off tunnel auto-reconnect"), () => Engine.SetTunnelWatch(on));
    }

    public void DisconnectAll() =>
        Run(new Job(JobKind.TunnelDisconnect), Tr("正在全部断开", "Disconnecting everything"), Engine.DisconnectAll);

    /// 「退出并断开」：先断开隧道和 VPN，再退出。
    public void QuitAndDisconnect(Action done)
    {
        Post(Tr("正在断开并退出", "Disconnecting and quitting"));
        queue.Enqueue(() =>
        {
            Engine.DisconnectAll();
            dispatcher.InvokeAsync(done);
        });
    }

    // MARK: - 编辑配置

    public void Save(AppConfig newConfig)
    {
        var next = newConfig.Clone();
        next.Normalize();
        var problems = ConfigCheck.Issues(next);
        if (problems.Count > 0) throw new ConfigException(string.Join("\n", problems));
        MergeRuntimeState(next);
        ConfigStore.Save(next, overwriteCorrupt: true);
        Config = next;
        ConfigWarning = null;
        Notify();
    }

    /// 后台操作会在磁盘上改 enabled、删转发，内存里的 Config 最多晚 6 秒才跟上。
    /// 界面保存时不能把这些改动写回旧值：enabled 以磁盘为准，已被后台删掉的不再复活。
    private void MergeRuntimeState(AppConfig next)
    {
        if (ConfigStore.LoadIfValid() is not { } disk) return;
        var diskForwards = disk.Forwards.ToDictionary(f => f.Id);
        var known = Config.Forwards.Select(f => f.Id).ToHashSet();
        next.Forwards = next.Forwards.Where(f => diskForwards.ContainsKey(f.Id) || !known.Contains(f.Id)).ToList();
        foreach (var forward in next.Forwards)
        {
            if (diskForwards.TryGetValue(forward.Id, out var onDisk)) forward.Enabled = onDisk.Enabled;
        }
        var diskVpns = disk.Vpns.Select(v => v.Id).ToHashSet();
        var knownVpns = Config.Vpns.Select(v => v.Id).ToHashSet();
        next.Vpns.RemoveAll(v => knownVpns.Contains(v.Id) && !diskVpns.Contains(v.Id));
    }

    public void SaveCredential(string file, string host, string user, string password) =>
        Credentials.Update(file, host, user, password);

    public void AddVpn(string name, string host, string user, string password)
    {
        var id = Guid.NewGuid();
        var file = Path.Combine(AppPaths.CredentialsDirectory, Ids.Format(id));
        Credentials.Update(file, host, user, password);
        var next = Config.Clone();
        next.Vpns.Add(new VpnProfile { Id = id, Name = name, CredentialFile = file });
        TopologyLayout.PlaceNew(next, TopologyKey.Vpn(id), TopologyKey.Machine, 1);
        Save(next);
    }

    public void AddJump(string name, string host, string identityFile, Guid vpnId)
    {
        var id = Guid.NewGuid();
        var next = Config.Clone();
        next.Jumps.Add(new Jump
        {
            Id = id,
            Name = name,
            Host = host.Trim(),
            IdentityFile = identityFile.Trim(),
            VpnId = vpnId == VpnProfile.Primary ? null : vpnId,
        });
        TopologyLayout.PlaceNew(next, TopologyKey.Jump(id), TopologyKey.Vpn(vpnId), 2);
        Save(next);
    }

    public void AddTunnel(string name, int localPort, string targetHost, int targetPort, string openHost, Guid jumpId)
    {
        var id = Guid.NewGuid();
        var next = Config.Clone();
        next.Forwards.Add(new Forward
        {
            Id = id,
            Name = name.Trim(),
            LocalPort = localPort,
            TargetHost = targetHost.Trim(),
            TargetPort = targetPort,
            OpenHost = openHost.Trim(),
            Enabled = false,
            JumpId = jumpId == Jump.Primary ? null : jumpId,
        });
        TopologyLayout.PlaceNew(next, TopologyKey.Forward(id), TopologyKey.Jump(jumpId), 3);
        Save(next);
    }

    public void UpdateForward(Guid id, string name, int localPort, string targetHost, int targetPort, string openHost)
    {
        var next = Config.Clone();
        var forward = next.Forwards.FirstOrDefault(f => f.Id == id);
        if (forward == null) return;
        forward.Name = name.Trim();
        forward.LocalPort = localPort;
        forward.TargetHost = targetHost.Trim();
        forward.TargetPort = targetPort;
        forward.OpenHost = openHost.Trim();
        Save(next);
    }

    public void UpdateLayout(string key, PointD origin)
    {
        var next = Config.Clone();
        next.Layout[key] = new PointD(Math.Max(8, origin.X), Math.Max(8, origin.Y));
        Try(() => Save(next));
    }

    public void ReparentForward(Guid id, Guid jumpId)
    {
        var next = Config.Clone();
        var forward = next.Forwards.FirstOrDefault(f => f.Id == id);
        if (forward == null || (forward.JumpId ?? Jump.Primary) == jumpId) return;
        forward.JumpId = jumpId == Jump.Primary ? null : jumpId;
        if (Try(() => Save(next))) Post(Tr("隧道已挂到新跳板，重新连接后生效", "Tunnel moved to the new jump host. Reconnect to apply"));
    }

    public void ReparentJump(Guid id, Guid vpnId)
    {
        var next = Config.Clone();
        var jump = next.Jumps.FirstOrDefault(j => j.Id == id);
        if (jump == null || (jump.VpnId ?? VpnProfile.Primary) == vpnId) return;
        jump.VpnId = vpnId == VpnProfile.Primary ? null : vpnId;
        if (Try(() => Save(next))) Post(Tr("跳板已挂到新 VPN", "Jump host moved to the new VPN"));
    }

    /// 设置流量先经过哪个 VPN。只改图和状态显示，不动任何连接。
    public void SetVpnVia(Guid id, Guid? via)
    {
        var profile = Config.Vpns.FirstOrDefault(v => v.Id == id);
        if (profile == null) return;
        if (via is { } upstream)
        {
            if (upstream == id || Config.Vpns.All(v => v.Id != upstream)) return;
            if (Config.UpstreamIds(upstream).Contains(id))
            {
                Post(Tr("不能绕成一圈", "That would create a loop"));
                return;
            }
        }
        if (profile.ViaId == via) return;
        var next = Config.Clone();
        next.Vpns.First(v => v.Id == id).ViaId = via;
        next.Layout = TopologyLayout.Default(next);
        if (!Try(() => Save(next))) return;
        var viaName = next.Vpns.FirstOrDefault(v => v.Id == via)?.Name;
        Post(viaName != null
            ? Tr($"{profile.Name} 的流量经过 {viaName}", $"{profile.Name} now goes through {viaName}")
            : Tr($"{profile.Name} 直接从本机出去", $"{profile.Name} now goes out directly from this computer"));
    }

    public void RemoveForward(int port)
    {
        if (Config.Forwards.Count <= 1) return;
        var name = Config.Forwards.FirstOrDefault(f => f.LocalPort == port)?.Name ?? Tr("转发", "Forward");
        Run(new Job(JobKind.ForwardDisconnect, port), Tr($"正在移除 {name}", $"Removing {name}"), () =>
        {
            Engine.DisconnectForward(port);
            ConfigStore.Mutate(c =>
            {
                c.Forwards.RemoveAll(f => f.LocalPort == port);
                c.Normalize();
            });
        });
    }

    public void RemoveJump(Guid id)
    {
        if (Config.Jumps.Count <= 1) return;
        if (Config.ForwardsOn(id).Count > 0)
        {
            Post(Tr("先删掉这台跳板上的隧道", "Remove the tunnels on this jump host first"));
            return;
        }
        var next = Config.Clone();
        next.Jumps.RemoveAll(j => j.Id == id);
        Try(() => Save(next));
    }

    public void RemoveVpn(Guid id)
    {
        var profile = Config.Vpns.FirstOrDefault(v => v.Id == id);
        if (Config.Vpns.Count <= 1 || profile == null) return;
        if (id == VpnProfile.Primary)
        {
            Post(Tr("主 VPN 不能删，可以改账号", "The primary VPN can't be removed, but you can change its account"));
            return;
        }
        var file = profile.CredentialFile;
        var host = Credentials.Load(file)?.Host ?? "";
        Run(new Job(JobKind.VpnDisconnect), Tr($"正在移除 {profile.Name}", $"Removing {profile.Name}"), () =>
        {
            var running = Engine.RunningVpnHost();
            if (running.Length > 0 && Commands.SameHost(running, host)) Engine.DisconnectVpn();
            ConfigStore.Mutate(c =>
            {
                c.Vpns.RemoveAll(v => v.Id == id);
                c.Normalize();
            });
            var path = PathExpander.Expand(file);
            // 只删应用自己建的凭据文件。
            if (PathExpander.IsUnder(path, AppPaths.Directory))
            {
                try { File.Delete(path); } catch { }
            }
        });
    }

    public void FixKeyPermissions(Guid jumpId)
    {
        var jump = Config.Jumps.FirstOrDefault(j => j.Id == jumpId);
        if (jump == null) return;
        try
        {
            KeyAcl.Restrict(PathExpander.Expand(jump.IdentityFile));
            Post(Tr("私钥权限已收紧，只有你自己能读", "Key permissions tightened; only you can read it now"));
        }
        catch (Exception error)
        {
            Post(Tr($"改不了私钥权限：{error.Message}", $"Couldn't change the key permissions: {error.Message}"));
        }
        Notify();
    }

    // MARK: - 给界面用

    public bool IsOn(VpnProfile profile)
    {
        var host = Commands.HostKey(Credentials.Load(profile.CredentialFile)?.Host ?? "");
        var live = Commands.HostKey(Vpn.ConnectedHost);
        if (live.Length == 0)
        {
            return Config.Vpns.Count == 1 && Vpn.Phase == LinkPhase.Up;
        }
        return host.Length > 0 && Commands.SameHost(live, host);
    }

    public bool IsOn(Jump jump)
    {
        if (Tunnel.RunningJumpHosts.Contains(jump.Host)) return true;
        return Config.Jumps.Count == 1 && Tunnel.SshRunning;
    }

    public PortStatus StatusOf(Forward forward) =>
        Tunnel.Ports.FirstOrDefault(p => p.LocalPort == forward.LocalPort)
        ?? new PortStatus(forward.Name, forward.LocalPort, forward.Target, forward.BrowseLabel, forward.BrowseUrl, forward.Enabled, false, false);

    /// 转发是否算「开着」：通了，或者端口已经在听（远端暂时没响应）。
    public bool IsOn(Forward forward)
    {
        var port = StatusOf(forward);
        return port.HttpOk || port.Listening;
    }

    public string VpnHost(VpnProfile profile) => Credentials.Load(profile.CredentialFile)?.Host ?? "";

    public string Summary
    {
        get
        {
            var when = CheckedAt?.ToString("HH:mm:ss") ?? Tr("尚未检查", "not checked yet");
            if (Vpn.Phase == LinkPhase.Checking) return Tr("检查中…", "Checking…");
            if (Vpn.Phase == LinkPhase.Up && Tunnel.Phase == LinkPhase.Up) return Tr($"全部正常 · {when}", $"All good · {when}");
            var tunnel = Tunnel.Ports.Count == 0 ? Tr("没有转发", "no forwards") : $"{Tunnel.OkCount}/{Tunnel.Ports.Count}";
            return Tr($"VPN {Vpn.Phase.Title()} · 转发 {tunnel} · {when}", $"VPN {Vpn.Phase.Title()} · forwards {tunnel} · {when}");
        }
    }

    public LinkState LinkState
    {
        get
        {
            if (Vpn.Phase == LinkPhase.Checking || Tunnel.Phase == LinkPhase.Checking) return LinkState.Checking;
            if (Vpn.Phase == LinkPhase.Up && Tunnel.Phase == LinkPhase.Up) return LinkState.Up;
            if (Vpn.Phase == LinkPhase.Down && Tunnel.Phase == LinkPhase.Down) return LinkState.Down;
            return LinkState.Partial;
        }
    }

    public static void Open(string target)
    {
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true })?.Dispose();
        }
        catch
        {
            // 打不开就算了，地址在界面上可以复制。
        }
    }

    // MARK: - 执行

    private void Run(Job job, string label, Action work)
    {
        if (Busy)
        {
            Post(BusyLabel != null ? Tr($"{BusyLabel}，这一步还没结束", $"{BusyLabel} — still in progress") : Tr("上一步还没结束", "The previous step is still in progress"));
            return;
        }
        Busy = true;
        BusyLabel = label;
        Job = job;
        Journal.Shared.Clear();
        Post(label);
        queue.Enqueue(() =>
        {
            // 出了异常也要走完下面的收尾，不然界面会一直停在「正在…」。
            try
            {
                work();
            }
            catch (Exception error)
            {
                Engine.Emit(error.Message);
            }
            var lines = Journal.Shared.Snapshot();
            dispatcher.InvokeAsync(async () =>
            {
                JournalLines = lines;
                Busy = false;
                BusyLabel = null;
                Job = null;
                Post(lines.Count > 0 ? lines[^1] : Tr("完成", "Done"));
                await RefreshAsync();
            });
        });
    }

    public void Post(string text)
    {
        StatusLine = Clip(text);
        Notify();
        statusTimer?.Stop();
        statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        statusTimer.Tick += (_, _) =>
        {
            statusTimer?.Stop();
            if (Busy || RefreshingVisible) return;
            StatusLine = null;
            Notify();
        };
        statusTimer.Start();
    }

    private bool Try(Action action)
    {
        try
        {
            action();
            return true;
        }
        catch (Exception error)
        {
            Post(error.Message);
            return false;
        }
    }

    private static string Clip(string text)
    {
        var line = text.Replace('\n', ' ').Trim();
        return line.Length > 180 ? line[..180] : line;
    }
}

public enum LinkState
{
    Checking,
    Up,
    Partial,
    Down,
}

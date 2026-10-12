using NetLink.App.Platform;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App;

/// 连接和断开的实际步骤，行为对齐 Mac 版 app/Engine.swift。
/// 改连接状态的函数都在 OperationLock 里跑，和自动重连的守护互斥。
/// VPN 交给 NetLink.Service（SYSTEM）去连；ssh 隧道以当前用户身份跑，不需要管理员权限。
public static class Engine
{
    /// 同一线程里可以重入（lock 本身就是可重入的），和 Mac 版 FileLock 的嵌套规则一样。
    public static readonly object OperationLock = new();

    // MARK: - 状态

    public static (VpnSnapshot Vpn, TunnelSnapshot Tunnel) Probe()
    {
        var config = ConfigStore.Load();
        var ssh = Shell.SshProcesses();
        return (VpnSnapshotOf(config), TunnelSnapshotOf(config, ssh));
    }

    private static VpnSnapshot VpnSnapshotOf(AppConfig config)
    {
        var credential = Credentials.Load(config.CredentialFile);
        var status = ServiceClient.Status();
        var alive = status?.Running == true;
        var route = Probes.RoutePresent(config.RouteMarker);
        var gateway = Probes.Reachable(config.PingHost);
        return new VpnSnapshot
        {
            Phase = alive && route && gateway ? LinkPhase.Up : alive ? LinkPhase.Degraded : LinkPhase.Down,
            Host = credential?.Host ?? "",
            User = credential?.User ?? "",
            CredentialOk = credential != null,
            ConnectedHost = status?.Host ?? "",
            ServiceReachable = status != null,
            ServiceError = status == null ? ServiceClient.LastError ?? "" : "",
            OpenconnectInstalled = status?.OpenconnectInstalled ?? true,
            Pid = status?.Pid,
            ProcessAlive = alive,
            RoutePresent = route,
            GatewayReachable = gateway,
            Watch = Flag(AppPaths.VpnWatchFlag) ? WatchdogOwner.App : WatchdogOwner.Off,
        };
    }

    private static TunnelSnapshot TunnelSnapshotOf(AppConfig config, List<Proc> ssh)
    {
        var ours = ssh.Where(p => IsOurSsh(p, config)).ToList();
        var checks = config.Forwards.Select(forward => Task.Run(() =>
        {
            var listening = PortTable.Listeners(forward.LocalPort).Count > 0;
            return new PortStatus(
                forward.Name,
                forward.LocalPort,
                forward.Target,
                forward.BrowseLabel,
                forward.BrowseUrl,
                forward.Enabled,
                listening,
                listening && Probes.ForwardUp(forward));
        })).ToArray();
        Task.WaitAll(checks);
        var ports = checks.Select(t => t.Result).OrderBy(p => p.LocalPort).ToList();
        var wanted = ports.Where(p => p.Enabled).ToList();
        var ok = wanted.Count(p => p.HttpOk);
        var phase = wanted.Count == 0 ? LinkPhase.Down
            : ok == wanted.Count ? LinkPhase.Up
            : ok > 0 || ours.Count > 0 ? LinkPhase.Degraded
            : LinkPhase.Down;
        return new TunnelSnapshot
        {
            Phase = phase,
            SshInstalled = File.Exists(PathExpander.Expand(config.SshPath)),
            SshRunning = ours.Count > 0,
            RunningJumpHosts = ours.Select(p => p.Arguments.LastOrDefault() ?? "").Where(h => h.Length > 0).Distinct().ToList(),
            Ports = ports,
            Watch = Flag(AppPaths.TunnelWatchFlag) ? WatchdogOwner.App : WatchdogOwner.Off,
        };
    }

    /// 配置文件坏了的时候 Load() 给的是默认值，拿它去连接只会连错地方。
    private static bool ConfigUsable()
    {
        if (!ConfigStore.IsCorrupt) return true;
        Emit(Tr("配置文件读不了，先在应用里修好或重新保存，再连接", "Can't read the config file. Fix it or save it again in the app, then connect"));
        return false;
    }

    // MARK: - VPN

    private enum VpnStart
    {
        Connected,
        Degraded,
        Failed,
    }

    public static void ConnectVpn(bool enableWatch, string? credentialFile = null)
    {
        lock (OperationLock)
        {
            if (!ConfigUsable()) return;
            var config = ConfigStore.Load();
            var status = ServiceClient.Status();
            if (status == null)
            {
                Emit(ServiceUnavailable());
                return;
            }
            if (status.Running)
            {
                Emit(Tr($"VPN 已在运行（PID {status.Pid}）", $"VPN is already running (PID {status.Pid})"));
                if (enableWatch) ArmVpnWatch();
                return;
            }
            switch (StartOpenConnect(config, credentialFile, out var seconds))
            {
                case VpnStart.Connected:
                    Emit(Tr($"VPN 已连接（{seconds} 秒）", $"VPN connected ({seconds}s)"));
                    if (enableWatch) ArmVpnWatch();
                    break;
                case VpnStart.Degraded:
                    Emit(Tr("VPN 进程在运行，但路由还没出现", "VPN process is running, but the route hasn't appeared yet"));
                    Emit(VpnLogTail());
                    break;
                default:
                    Emit(Tr("VPN 启动失败", "VPN failed to start"));
                    Emit(VpnLogTail());
                    break;
            }
        }
    }

    public static void DisconnectVpn()
    {
        lock (OperationLock)
        {
            WriteFlag(AppPaths.VpnWatchFlag, false);
            var status = ServiceClient.Disconnect();
            if (status == null)
            {
                Emit(ServiceUnavailable());
            }
            else if (!status.Running)
            {
                Emit(Tr("VPN 已断开", "VPN disconnected"));
            }
            else
            {
                Emit(Tr("openconnect 进程还没退出", "The openconnect process hasn't exited yet"));
            }
        }
    }

    public static void RestartVpn(bool enableWatch, string? credentialFile)
    {
        DisconnectVpn();
        Thread.Sleep(2000);
        ConnectVpn(enableWatch, credentialFile);
    }

    public static string RunningVpnHost() => ServiceClient.Status()?.Host ?? "";

    private static VpnStart StartOpenConnect(AppConfig config, string? credentialFile, out int seconds)
    {
        seconds = 0;
        var file = credentialFile ?? config.CredentialFile;
        var credential = Credentials.Load(file);
        if (credential == null)
        {
            Emit(Tr($"{file} 缺少 host、user 或 password", $"{file} is missing host, user or password"));
            return VpnStart.Failed;
        }
        try { File.WriteAllText(AppPaths.ActiveCredential, PathExpander.Expand(file)); } catch { }
        EmitLog(AppPaths.AppLog, Tr($"开始连接 VPN {credential.Host}", $"Connecting VPN {credential.Host}"));
        var started = ServiceClient.Connect(credential, config.ReconnectTimeout);
        if (started == null)
        {
            Emit(ServiceUnavailable());
            return VpnStart.Failed;
        }
        if (!started.Ok)
        {
            Emit(started.Error ?? Tr("后台服务拒绝了连接请求", "The background service refused the request"));
            return VpnStart.Failed;
        }
        var deadline = DateTime.UtcNow.AddSeconds(25);
        while (DateTime.UtcNow < deadline)
        {
            Thread.Sleep(1000);
            seconds++;
            var status = ServiceClient.Status();
            if (status?.Running != true) return VpnStart.Failed;
            if (Probes.RoutePresent(config.RouteMarker)) return VpnStart.Connected;
        }
        return ServiceClient.Status()?.Running == true ? VpnStart.Degraded : VpnStart.Failed;
    }

    public static bool VpnHealthy(AppConfig config)
    {
        if (ServiceClient.Status()?.Running != true) return false;
        if (!Probes.RoutePresent(config.RouteMarker)) return false;
        return Probes.Reachable(config.PingHost);
    }

    /// 守护用的重启：失败时不清掉自动重连的开关，下一轮还会再试。重连最近一次连上的那个账号。
    public static void RestartVpnPreservingFlag(AppConfig config)
    {
        if (!Flag(AppPaths.VpnWatchFlag)) return;
        EmitLog(AppPaths.AppLog, Tr("强制重启 VPN", "Force-restarting VPN"));
        lock (OperationLock) ServiceClient.Disconnect();
        Thread.Sleep(3000);
        if (!Flag(AppPaths.VpnWatchFlag)) return;
        string? last = null;
        try { last = File.ReadAllText(AppPaths.ActiveCredential).Trim(); } catch { }
        lock (OperationLock) StartOpenConnect(config, string.IsNullOrEmpty(last) ? null : last, out _);
    }

    public static string VpnLogTail(int lines = 8)
    {
        var text = ServiceClient.Log(lines)?.Log?.Trim() ?? "";
        return text.Length == 0 ? Tr("日志是空的", "The log is empty") : text;
    }

    private static string ServiceUnavailable() =>
        Tr("NetLink 后台服务没在运行，连不了 VPN。点顶部的「启动服务」，或重新安装 NetLink。",
           "The NetLink background service isn't running, so the VPN can't connect. Click \"Start Service\" at the top, or reinstall NetLink.");

    // MARK: - 隧道

    public static void ConnectTunnel(bool enableWatch, bool startVpnIfNeeded)
    {
        lock (OperationLock)
        {
            if (!ConfigUsable()) return;
            ConfigStore.Mutate(c => c.Forwards.ForEach(f => f.Enabled = true));
            var config = ConfigStore.Load();
            var pending = config.Forwards.Where(f => !Probes.ForwardUp(f)).ToList();
            if (pending.Count == 0)
            {
                Emit(Tr("隧道已在运行", "Tunnel is already running"));
                if (enableWatch) ArmTunnelWatch();
                return;
            }
            var started = false;
            foreach (var forward in pending)
            {
                if (!EnsureJump(config, config.JumpFor(forward), startVpnIfNeeded)) return;
                if (PortBusy(forward)) continue;
                Emit(Tr($"启动 {forward.Name}", $"Starting {forward.Name}"));
                if (StartSsh(config, forward)) started = true;
            }
            if (!started)
            {
                Emit(Tr("ssh 启动失败", "ssh failed to start"));
                Emit(LogTail(config.TunnelLogFile));
                return;
            }
            if (WaitFor(() => TunnelHealthy(config), 12))
            {
                Emit(Tr("隧道已就绪", "Tunnel is ready"));
                if (enableWatch) ArmTunnelWatch();
            }
            else
            {
                Emit(Tr("隧道还没完全就绪", "Tunnel isn't fully ready yet"));
                Emit(LogTail(config.TunnelLogFile));
            }
        }
    }

    public static void ConnectForward(int localPort, bool enableWatch, bool startVpnIfNeeded)
    {
        lock (OperationLock)
        {
            if (!ConfigUsable()) return;
            ConfigStore.Mutate(c =>
            {
                if (c.Forwards.FirstOrDefault(f => f.LocalPort == localPort) is { } found) found.Enabled = true;
            });
            var config = ConfigStore.Load();
            var forward = config.Forwards.FirstOrDefault(f => f.LocalPort == localPort);
            if (forward == null)
            {
                Emit(Tr($"没有本地端口 {localPort} 的转发", $"No forward on local port {localPort}"));
                return;
            }
            if (Probes.ForwardUp(forward))
            {
                Emit(Tr($"{forward.Name} 已在运行", $"{forward.Name} is already running"));
                if (enableWatch) ArmTunnelWatch();
                return;
            }
            if (!EnsureJump(config, config.JumpFor(forward), startVpnIfNeeded)) return;
            if (PortBusy(forward)) return;
            Emit(Tr($"启动 {forward.Name}", $"Starting {forward.Name}"));
            if (!StartSsh(config, forward))
            {
                Emit(Tr($"{forward.Name} 启动失败", $"{forward.Name} failed to start"));
                Emit(LogTail(config.TunnelLogFile));
                return;
            }
            if (WaitFor(() => Probes.ForwardUp(forward), 12))
            {
                Emit(Tr($"{forward.Name} 已就绪", $"{forward.Name} is ready"));
                if (enableWatch) ArmTunnelWatch();
            }
            else
            {
                Emit(Tr($"{forward.Name} 还没就绪", $"{forward.Name} isn't ready yet"));
                Emit(LogTail(config.TunnelLogFile));
            }
        }
    }

    public static void DisconnectForward(int localPort)
    {
        lock (OperationLock)
        {
            if (!ConfigUsable()) return;
            ConfigStore.Mutate(c =>
            {
                if (c.Forwards.FirstOrDefault(f => f.LocalPort == localPort) is { } found) found.Enabled = false;
            });
            var config = ConfigStore.Load();
            var forward = config.Forwards.FirstOrDefault(f => f.LocalPort == localPort);
            if (forward == null)
            {
                Emit(Tr($"没有本地端口 {localPort} 的转发", $"No forward on local port {localPort}"));
                return;
            }
            StopForward(config, forward);
            Thread.Sleep(500);
            if (PortTable.Listeners(forward.LocalPort).Count == 0)
            {
                Emit(Tr($"{forward.Name} 已断开", $"{forward.Name} disconnected"));
            }
            else
            {
                Emit(Tr($"{forward.Name} 的端口还没释放", $"The port for {forward.Name} hasn't been released yet"));
            }
        }
    }

    public static void DisconnectTunnel()
    {
        lock (OperationLock)
        {
            ConfigStore.Mutate(c => c.Forwards.ForEach(f => f.Enabled = false));
            var config = ConfigStore.Load();
            WriteFlag(AppPaths.TunnelWatchFlag, false);
            foreach (var proc in Shell.SshProcesses().Where(p => IsOurSsh(p, config)))
            {
                Shell.Kill(proc.Pid);
            }
            Thread.Sleep(500);
            var busy = config.Forwards.FirstOrDefault(f => PortTable.Listeners(f.LocalPort).Count > 0);
            if (busy == null)
            {
                Emit(Tr("隧道已断开", "Tunnel disconnected"));
            }
            else
            {
                Emit(Tr("还有转发端口没释放", "Some forward ports haven't been released"));
                ReportForeign(config, busy);
            }
        }
    }

    public static void RestartTunnel(bool enableWatch)
    {
        DisconnectTunnel();
        Thread.Sleep(2000);
        ConnectTunnel(enableWatch, startVpnIfNeeded: true);
    }

    public static void DisconnectAll()
    {
        DisconnectTunnel();
        DisconnectVpn();
    }

    public static bool TunnelHealthy(AppConfig config) =>
        config.Forwards.Where(f => f.Enabled).All(Probes.ForwardUp);

    public static void RestartTunnelPreservingFlag(AppConfig config)
    {
        if (!Flag(AppPaths.TunnelWatchFlag)) return;
        var down = config.Forwards.Where(f => f.Enabled && !Probes.ForwardUp(f)).ToList();
        if (down.Count == 0) return;
        EmitLog(config.TunnelLogFile, Tr($"隧道异常，重连 {string.Join("、", down.Select(f => f.Name))}", $"Tunnel unhealthy, reconnecting {string.Join(", ", down.Select(f => f.Name))}"));
        lock (OperationLock)
        {
            foreach (var forward in down) StopForward(config, forward);
        }
        Thread.Sleep(2000);
        if (!Flag(AppPaths.TunnelWatchFlag)) return;
        lock (OperationLock)
        {
            foreach (var forward in down)
            {
                if (PortTable.Listeners(forward.LocalPort).Count == 0) StartSsh(config, forward);
            }
        }
    }

    private static bool PortBusy(Forward forward)
    {
        var pid = PortTable.Listeners(forward.LocalPort).FirstOrDefault();
        if (pid == 0) return false;
        var name = Shell.ProcessName(pid);
        var hint = forward.LocalPort == 80 && (pid == 4 || name.Equals("System", StringComparison.OrdinalIgnoreCase))
            ? Tr("。80 端口常被 IIS / http.sys 占用，可以把这条转发改成 8080 这类端口", ". Port 80 is often taken by IIS / http.sys; consider moving this forward to a port like 8080")
            : "";
        Emit(Tr(
            $"{forward.Name} 的端口 {forward.LocalPort} 已被占用（{name} PID {pid}）{hint}",
            $"Port {forward.LocalPort} for {forward.Name} is already in use ({name} PID {pid}){hint}"));
        return true;
    }

    private static bool StartSsh(AppConfig config, Forward forward)
    {
        var ssh = PathExpander.Expand(config.SshPath);
        if (!File.Exists(ssh))
        {
            Emit(Tr($"找不到 {ssh}。在「设置 → 系统 → 可选功能」里添加「OpenSSH 客户端」", $"{ssh} not found. Add \"OpenSSH Client\" under Settings → System → Optional features"));
            return false;
        }
        var jump = config.JumpFor(forward);
        var key = PathExpander.Expand(jump.IdentityFile);
        if (!File.Exists(key))
        {
            Emit(Tr($"读不到密钥 {jump.IdentityFile}", $"Can't read key {jump.IdentityFile}"));
            return false;
        }
        if (KeyAcl.TooOpen(key))
        {
            Emit(Tr($"私钥 {jump.IdentityFile} 别的用户也能读，ssh 会拒绝使用。在跳板的详情里点「修复私钥权限」",
                    $"Other users can read the key {jump.IdentityFile}, so ssh will refuse it. Click \"Fix Key Permissions\" in the jump host details"));
        }
        EmitLog(config.TunnelLogFile, Tr($"开始连接 {forward.Name}", $"Connecting {forward.Name}"));
        try
        {
            using var process = Shell.Spawn(ssh, Commands.SshArguments(config, forward));
            if (process == null) return false;
            // ssh 认证失败、端口绑定失败会很快退出；还活着就当已经起来了，后面再按端口确认。
            if (process.WaitForExit(1500))
            {
                Emit(LogTail(config.TunnelLogFile, 4));
                return false;
            }
            return true;
        }
        catch (Exception error)
        {
            Emit(error.Message);
            return false;
        }
    }

    private static void StopForward(AppConfig config, Forward forward)
    {
        foreach (var proc in Shell.SshProcesses().Where(p => Carries(p, forward, config)))
        {
            Shell.Kill(proc.Pid);
        }
        ReportForeign(config, forward);
    }

    /// 端口上的监听者里，只有我们自己的隧道进程才会被结束。别的程序占着端口，只提示不动手。
    private static void ReportForeign(AppConfig config, Forward forward)
    {
        var ours = Shell.SshProcesses().Where(p => IsOurSsh(p, config)).Select(p => p.Pid).ToHashSet();
        foreach (var pid in PortTable.Listeners(forward.LocalPort))
        {
            if (ours.Contains(pid))
            {
                Shell.Kill(pid);
                continue;
            }
            Emit(Tr(
                $"{forward.Name} 的端口 {forward.LocalPort} 被别的程序占着（{Shell.ProcessName(pid)} PID {pid}），没有动它",
                $"Port {forward.LocalPort} for {forward.Name} is held by another program ({Shell.ProcessName(pid)} PID {pid}); left it alone"));
        }
    }

    /// 本应用起的 ssh 都带 `-E <隧道日志>`，用它认「自己的」进程，手动开的 ssh -L 不会被误杀。
    public static bool IsOurSsh(Proc proc, AppConfig config)
    {
        var log = PathExpander.Expand(config.TunnelLogFile);
        var args = proc.Arguments;
        for (var i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "-E" && string.Equals(PathExpander.Expand(args[i + 1]), log, StringComparison.OrdinalIgnoreCase))
            {
                return args.Contains("-L");
            }
        }
        return false;
    }

    /// 按参数逐个比，"80:host:80" 不会误中 "8080:host:80"。
    public static bool Carries(Proc proc, Forward forward, AppConfig config)
    {
        if (!IsOurSsh(proc, config)) return false;
        var args = proc.Arguments;
        for (var i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "-L" && args[i + 1] == forward.Spec)
            {
                return true;
            }
        }
        return false;
    }

    private static bool EnsureJump(AppConfig config, Jump jump, bool startVpnIfNeeded)
    {
        Emit(Tr("检查跳板机连通性", "Checking the jump host"));
        if (JumpReachable(config, jump, 5))
        {
            Emit(Tr("跳板机可达", "Jump host is reachable"));
            return true;
        }
        Emit(Tr("跳板机不可达，先连接 VPN", "Jump host unreachable, connecting VPN first"));
        if (!startVpnIfNeeded)
        {
            Emit(Tr("已取消连接隧道", "Tunnel connection cancelled"));
            return false;
        }
        if (ServiceClient.Status()?.Running != true)
        {
            // 跳板挂在哪个 VPN 下就用哪个账号。
            var owner = config.VpnFor(jump);
            switch (StartOpenConnect(config, owner.CredentialFile, out var seconds))
            {
                case VpnStart.Connected:
                    Emit(Tr($"VPN 已连接（{seconds} 秒）", $"VPN connected ({seconds}s)"));
                    if (AppSettings.Current.VpnAutoReconnect) ArmVpnWatch();
                    break;
                case VpnStart.Degraded:
                    Emit(Tr("VPN 进程在，但路由未确认，继续等跳板机", "VPN process is up but the route isn't confirmed; still waiting for the jump host"));
                    break;
                default:
                    Emit(Tr("VPN 没连上，隧道中止", "VPN didn't connect, tunnel aborted"));
                    Emit(VpnLogTail());
                    return false;
            }
        }
        Emit(Tr("等待跳板机，最多 30 秒", "Waiting for the jump host, up to 30 seconds"));
        if (!WaitFor(() => JumpReachable(config, jump, 3), 30, 3))
        {
            Emit(Tr("30 秒内跳板机仍不可达", "Jump host still unreachable after 30 seconds"));
            return false;
        }
        Emit(Tr("跳板机已可达", "Jump host is now reachable"));
        return true;
    }

    private static bool JumpReachable(AppConfig config, Jump jump, int timeout)
    {
        var ssh = PathExpander.Expand(config.SshPath);
        if (!File.Exists(ssh)) return false;
        return Shell.Run(ssh, Commands.JumpProbeArguments(jump, timeout), TimeSpan.FromSeconds(timeout + 2)).Ok;
    }

    private static bool WaitFor(Func<bool> condition, int seconds, int step = 1)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < deadline)
        {
            if (condition()) return true;
            Thread.Sleep(step * 1000);
        }
        return condition();
    }

    // MARK: - 自动重连

    public static void SetVpnWatch(bool on)
    {
        WriteFlag(AppPaths.VpnWatchFlag, on);
        Emit(on ? Tr("已开启 VPN 自动重连", "VPN auto-reconnect on") : Tr("已关闭 VPN 自动重连，当前连接保持不变", "VPN auto-reconnect off. The current connection stays as is"));
    }

    public static void SetTunnelWatch(bool on)
    {
        WriteFlag(AppPaths.TunnelWatchFlag, on);
        Emit(on ? Tr("已开启隧道自动重连", "Tunnel auto-reconnect on") : Tr("已关闭隧道自动重连，当前连接保持不变", "Tunnel auto-reconnect off. The current connection stays as is"));
    }

    private static void ArmVpnWatch()
    {
        WriteFlag(AppPaths.VpnWatchFlag, true);
        Emit(Tr("VPN 自动重连由本应用负责", "VPN auto-reconnect is handled by this app"));
    }

    private static void ArmTunnelWatch()
    {
        WriteFlag(AppPaths.TunnelWatchFlag, true);
        Emit(Tr("隧道自动重连由本应用负责", "Tunnel auto-reconnect is handled by this app"));
    }

    public static bool Flag(string path) => File.Exists(path);

    public static void WriteFlag(string path, bool on)
    {
        try
        {
            if (on)
            {
                AppPaths.EnsureDirectory();
                File.WriteAllText(path, "");
            }
            else
            {
                File.Delete(path);
            }
        }
        catch
        {
            // 标记写不进去，下一次操作再试。
        }
    }

    // MARK: - 提示和日志

    public static string LogTail(string file, int lines = 8)
    {
        var text = Redact.Text(TextFiles.Tail(PathExpander.Expand(file), lines)).Trim();
        return text.Length == 0 ? Tr("日志是空的", "The log is empty") : text;
    }

    public static void Emit(string message)
    {
        foreach (var line in Redact.Text(message).Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            Journal.Shared.Add(line);
        }
    }

    public static void EmitLog(string file, string message)
    {
        Emit(message);
        TextFiles.Append(PathExpander.Expand(file), $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {Redact.Line(message)}\n");
    }
}

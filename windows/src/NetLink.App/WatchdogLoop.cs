using System.Collections.Concurrent;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App;

/// 串行执行连接操作的后台线程，对应 Mac 版的 Engine.operationQueue。
public sealed class OperationQueue
{
    private readonly BlockingCollection<Action> work = new();

    public OperationQueue(string name)
    {
        var thread = new Thread(Loop) { IsBackground = true, Name = name };
        thread.Start();
    }

    public void Enqueue(Action action) => work.Add(action);

    private void Loop()
    {
        foreach (var action in work.GetConsumingEnumerable())
        {
            try
            {
                action();
            }
            catch (Exception error)
            {
                Engine.Emit(error.Message);
            }
        }
    }
}

/// 自动重连。Mac 版是一个单独的 --service 进程；Windows 版应用一直在通知区域里，守护就跑在应用里。
/// 规则一样：开关开着、按间隔检查、连续失败够次数才重启，重启失败不清掉开关。
public sealed class WatchdogLoop
{
    private Thread? thread;
    private volatile bool stopping;

    public void Start()
    {
        if (thread != null) return;
        thread = new Thread(Loop) { IsBackground = true, Name = "NetLink watchdog" };
        thread.Start();
    }

    public void Stop() => stopping = true;

    private void Loop()
    {
        var lastVpn = DateTime.MinValue;
        var lastTunnel = DateTime.MinValue;
        var vpnFails = 0;
        var tunnelFails = 0;
        while (!stopping)
        {
            Thread.Sleep(1000);
            try
            {
                // 配置读不了就什么都不做：用默认值去「修复」只会把连接弄坏。
                if (ConfigStore.IsCorrupt) continue;
                var vpnFlag = Engine.Flag(AppPaths.VpnWatchFlag);
                var tunnelFlag = Engine.Flag(AppPaths.TunnelWatchFlag);
                if (!vpnFlag) vpnFails = 0;
                if (!tunnelFlag) tunnelFails = 0;
                if (!vpnFlag && !tunnelFlag) continue;
                var config = ConfigStore.Load();
                var now = DateTime.UtcNow;

                if (vpnFlag && (now - lastVpn).TotalSeconds >= Math.Max(config.VpnWatchdogInterval, 5))
                {
                    lastVpn = now;
                    if (Engine.VpnHealthy(config))
                    {
                        vpnFails = 0;
                    }
                    else
                    {
                        vpnFails++;
                        Engine.EmitLog(AppPaths.AppLog, Tr($"VPN 健康检查失败（{vpnFails}/{config.VpnFailThreshold}）", $"VPN health check failed ({vpnFails}/{config.VpnFailThreshold})"));
                        if (Watchdog.ShouldRestart(true, false, vpnFails, config.VpnFailThreshold))
                        {
                            Engine.RestartVpnPreservingFlag(config);
                            vpnFails = 0;
                            Thread.Sleep(10_000);
                        }
                    }
                }

                if (tunnelFlag && (now - lastTunnel).TotalSeconds >= Math.Max(config.TunnelWatchdogInterval, 5))
                {
                    lastTunnel = now;
                    if (Engine.TunnelHealthy(config))
                    {
                        tunnelFails = 0;
                    }
                    else
                    {
                        tunnelFails++;
                        Engine.EmitLog(config.TunnelLogFile, Tr($"隧道健康检查失败（{tunnelFails}/{config.TunnelFailThreshold}）", $"Tunnel health check failed ({tunnelFails}/{config.TunnelFailThreshold})"));
                        if (Watchdog.ShouldRestart(true, false, tunnelFails, config.TunnelFailThreshold))
                        {
                            Engine.RestartTunnelPreservingFlag(config);
                            tunnelFails = 0;
                            Thread.Sleep(8_000);
                        }
                    }
                }
            }
            catch (Exception error)
            {
                Engine.EmitLog(AppPaths.AppLog, error.Message);
            }
        }
    }
}

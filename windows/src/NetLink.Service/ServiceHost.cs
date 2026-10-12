using System.ServiceProcess;
using NetLink.Core;

namespace NetLink.Service;

public sealed class NetLinkWindowsService : ServiceBase
{
    private readonly ServiceHost host = new();

    public NetLinkWindowsService()
    {
        ServiceName = ServiceProtocol.ServiceName;
        CanStop = true;
        CanShutdown = true;
    }

    protected override void OnStart(string[] args) => host.Start();

    protected override void OnStop() => host.Stop();

    /// 关机时也先正常断开，让 vpnc-script 把路由和 DNS 收回去。
    protected override void OnShutdown() => host.Stop();

    protected override void Dispose(bool disposing)
    {
        if (disposing) host.Dispose();
        base.Dispose(disposing);
    }
}

/// 服务本体：一个 openconnect 看管者，加一个命名管道服务端。
public sealed class ServiceHost : IDisposable
{
    private readonly OpenConnectRunner runner = new();
    private readonly CancellationTokenSource stopping = new();
    private PipeServer? server;

    public void Start()
    {
        ServiceLog.Write($"NetLink service {typeof(ServiceHost).Assembly.GetName().Version} starting");
        server = new PipeServer(runner);
        server.Start(stopping.Token);
    }

    public void Stop()
    {
        if (stopping.IsCancellationRequested) return;
        stopping.Cancel();
        runner.Disconnect();
        ServiceLog.Write("NetLink service stopped");
    }

    public void Dispose()
    {
        Stop();
        stopping.Dispose();
    }
}

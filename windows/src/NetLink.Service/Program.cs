using System.ServiceProcess;
using NetLink.Service;

// 正常由服务管理器启动。`--console` 在前台跑，调试用（需要管理员权限的终端）。
if (args.Contains("--console"))
{
    using var host = new ServiceHost();
    host.Start();
    Console.WriteLine($"NetLink service running, pipe \\\\.\\pipe\\{NetLink.Core.ServiceProtocol.PipeName}. Press Enter to stop.");
    Console.ReadLine();
    host.Stop();
    return;
}

ServiceBase.Run(new NetLinkWindowsService());

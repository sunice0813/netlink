using System.Runtime.InteropServices;
using NetLink.App.Platform;
using NetLink.Core;

namespace NetLink.App;

public static class Program
{
    private const string MutexName = @"Local\NetLink.App";
    private const string ShowEventName = @"Local\NetLink.App.Show";
    private const string QuitEventName = @"Local\NetLink.App.Quit";

    [STAThread]
    public static int Main(string[] args)
    {
        Credentials.Protector = new DpapiProtector();
        Credentials.PrivateFiles = new WindowsPrivateFiles();
        L10n.Choice = L10n.Parse(AppSettings.Current.Language);

        if (args.Contains("--status")) return StatusCli.Run();
        if (args.Contains("--quit")) return QuitRunning();

        // 只开一个实例；再次打开时把已经在跑的那个窗口叫出来。
        using var mutex = new Mutex(true, MutexName, out var first);
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        using var quit = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEventName);
        if (!first)
        {
            if (!args.Contains("--background")) show.Set();
            return 0;
        }

        // 托盘图标的右键菜单是 WinForms 的，打开视觉样式才是系统原生的样子。
        System.Windows.Forms.Application.EnableVisualStyles();
        var app = new App { StartHidden = args.Contains("--background") };
        app.InitializeComponent();
        ThreadPool.RegisterWaitForSingleObject(show, (_, _) => app.Dispatcher.InvokeAsync(app.ShowMain), null, -1, false);
        ThreadPool.RegisterWaitForSingleObject(quit, (_, _) => app.Dispatcher.InvokeAsync(app.QuitAndDisconnect), null, -1, true);
        app.Run();
        GC.KeepAlive(mutex);
        return 0;
    }

    /// `NetLink.exe --quit`：让正在运行的实例断开隧道和 VPN 后退出（卸载、升级时用），最多等 30 秒。
    private static int QuitRunning()
    {
        if (!EventWaitHandle.TryOpenExisting(QuitEventName, out var quit)) return 0;
        using (quit) quit.Set();
        try
        {
            using var mutex = Mutex.OpenExisting(MutexName);
            if (mutex.WaitOne(TimeSpan.FromSeconds(30))) mutex.ReleaseMutex();
        }
        catch (AbandonedMutexException)
        {
            // 那边已经退出了。
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            // 那边已经退出了。
        }
        return 0;
    }
}

/// `NetLink.exe --status`：只打印状态，不改任何东西。
public static class StatusCli
{
    public static int Run()
    {
        AttachConsole(AttachParentProcess);
        try { Console.OutputEncoding = System.Text.Encoding.UTF8; } catch (IOException) { }
        var (vpn, tunnel) = Engine.Probe();
        var writer = Console.Out;
        writer.WriteLine();
        writer.WriteLine($"VPN: {vpn.Phase.Title()}{(vpn.ConnectedHost.Length > 0 ? $" ({vpn.ConnectedHost})" : "")}");
        writer.WriteLine($"  service: {(vpn.ServiceReachable ? "running" : "not running")}");
        writer.WriteLine($"  openconnect: {(vpn.ProcessAlive ? $"running, PID {vpn.Pid}" : "not running")}");
        writer.WriteLine($"  route: {(vpn.RoutePresent ? "present" : "missing")}, gateway: {(vpn.GatewayReachable ? "reachable" : "unreachable")}");
        writer.WriteLine($"  auto-reconnect: {(vpn.Watch == WatchdogOwner.App ? "on" : "off")}");
        writer.WriteLine($"Tunnel: {tunnel.Phase.Title()} ({tunnel.OkCount}/{tunnel.Ports.Count})");
        foreach (var port in tunnel.Ports)
        {
            var state = port.HttpOk ? "up" : port.Listening ? "no response" : "off";
            writer.WriteLine($"  :{port.LocalPort} {port.Name} -> {port.Target} [{state}]");
        }
        writer.WriteLine($"  auto-reconnect: {(tunnel.Watch == WatchdogOwner.App ? "on" : "off")}");
        writer.Flush();
        return 0;
    }

    private const int AttachParentProcess = -1;

    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int processId);
}

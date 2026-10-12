using System.Windows;
using NetLink.App.UI;

namespace NetLink.App;

public partial class App : Application
{
    public AppModel Model { get; private set; } = null!;
    public MainWindow Main { get; private set; } = null!;
    private TrayIcon? tray;
    private bool quitting;

    public bool StartHidden { get; init; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Palette.Apply();
        Model = new AppModel(Dispatcher);
        Main = new MainWindow(Model);
        tray = new TrayIcon(Model, this);
        // 注销时断开 VPN：后台服务不跟着用户注销，不断开的话 VPN 会一直连着。隧道会随用户进程一起结束。
        SessionEnding += (_, _) => Platform.ServiceClient.Disconnect();
        Model.Start();
        if (!StartHidden) ShowMain();
    }

    public void ShowMain()
    {
        if (!Main.IsVisible) Main.Show();
        if (Main.WindowState == WindowState.Minimized) Main.WindowState = WindowState.Normal;
        Main.Activate();
        Main.Topmost = true;
        Main.Topmost = false;
        Main.Focus();
    }

    /// 关掉主窗口只是藏起来；「退出并断开」才会断开 VPN 和隧道并退出。
    public bool Quitting => quitting;

    public void QuitAndDisconnect()
    {
        if (quitting) return;
        quitting = true;
        tray?.ShowBusy();
        Model.QuitAndDisconnect(() =>
        {
            Model.Stop();
            tray?.Dispose();
            Shutdown();
        });
    }

    protected override void OnExit(ExitEventArgs e)
    {
        tray?.Dispose();
        base.OnExit(e);
    }
}

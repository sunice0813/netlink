using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using NetLink.Core;
using static NetLink.Core.Text;
using Forms = System.Windows.Forms;

namespace NetLink.App.UI;

/// 通知区域图标，对应 Mac 版的菜单栏图标。左键打开开关面板，右键是命令菜单，双击打开主窗口。
public sealed class TrayIcon : IDisposable
{
    public static TrayIcon? Current { get; private set; }

    private readonly AppModel model;
    private readonly App app;
    private readonly Forms.NotifyIcon icon = new();
    private readonly TrayPanel panel;
    private LinkState? drawn;
    private bool drawnDark;
    private IntPtr handle;

    public TrayIcon(AppModel model, App app)
    {
        this.model = model;
        this.app = app;
        Current = this;
        panel = new TrayPanel(model, app);
        icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) panel.Toggle();
        };
        icon.MouseDoubleClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) app.ShowMain();
        };
        BuildMenu();
        Update();
        icon.Visible = true;
        model.Changed += Update;
        Palette.Changed += () =>
        {
            BuildMenu();
            drawn = null;
            Update();
        };
    }

    private void BuildMenu()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(Tr("打开内网连接", "Open NetLink"), null, (_, _) => app.ShowMain());
        menu.Items.Add(Tr("设置…", "Settings…"), null, (_, _) =>
        {
            app.ShowMain();
            app.Main.ShowSettings();
        });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Tr("全部断开", "Disconnect All"), null, (_, _) => model.DisconnectAll());
        menu.Items.Add(Tr("退出并断开", "Quit and Disconnect"), null, (_, _) => app.QuitAndDisconnect());
        var old = icon.ContextMenuStrip;
        icon.ContextMenuStrip = menu;
        old?.Dispose();
    }

    private void Update()
    {
        var state = model.LinkState;
        var dark = Palette.TaskbarDark();
        icon.Text = Tip();
        if (drawn == state && drawnDark == dark) return;
        drawn = state;
        drawnDark = dark;
        var next = PathGlyph.Draw(state, dark);
        var previousHandle = handle;
        icon.Icon = Icon.FromHandle(next);
        handle = next;
        if (previousHandle != IntPtr.Zero) DestroyIcon(previousHandle);
    }

    private string Tip()
    {
        var text = Tr("内网连接", "NetLink") + " — " + model.Summary;
        // NotifyIcon.Text 最多 127 个字符。
        return text.Length > 120 ? text[..120] : text;
    }

    public void ShowBusy() => icon.Text = Tr("正在断开并退出…", "Disconnecting and quitting…");

    public void Balloon(string title, string text)
    {
        icon.BalloonTipTitle = title;
        icon.BalloonTipText = text;
        icon.ShowBalloonTip(5000);
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        if (handle != IntPtr.Zero) DestroyIcon(handle);
        handle = IntPtr.Zero;
        panel.Close();
        if (Current == this) Current = null;
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);
}

/// 应用图标「链路」的单色版：三个节点连成一条线。和 Mac 版 PathGlyph 一样靠形状区分状态：
/// 全通是实心，部分通最后一个节点空心，没连是虚线加空心，检查中整体半透明。
public static class PathGlyph
{
    public static IntPtr Draw(LinkState state, bool darkTaskbar)
    {
        var dpi = 32;
        using var bitmap = new Bitmap(dpi, dpi);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(System.Drawing.Color.Transparent);
            var alpha = state == LinkState.Checking ? 128 : 255;
            var color = darkTaskbar ? System.Drawing.Color.FromArgb(alpha, 255, 255, 255) : System.Drawing.Color.FromArgb(alpha, 0, 0, 0);
            var unit = dpi / 24f;
            PointF P(float x, float y) => new(x * unit, y * unit);
            using var pen = new Pen(color, 2 * unit) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            if (state == LinkState.Down) pen.DashPattern = [0.8f, 1.3f];
            using var path = new GraphicsPath();
            path.AddBezier(P(5, 16), P(9, 16), P(9, 8), P(12, 8));
            path.AddBezier(P(12, 8), P(15, 8), P(15, 14), P(19, 14));
            g.DrawPath(pen, path);
            using var fill = new SolidBrush(color);
            using var ring = new Pen(color, 1.6f * unit);
            (float X, float Y, float R, bool Filled)[] nodes =
            [
                (5, 16, 2.4f, state != LinkState.Down),
                (12, 8, 2.4f, state != LinkState.Down),
                (19, 14, 2.8f, state is LinkState.Up or LinkState.Checking),
            ];
            foreach (var (x, y, r, filled) in nodes)
            {
                var center = P(x, y);
                var radius = r * unit;
                if (filled)
                {
                    g.FillEllipse(fill, center.X - radius, center.Y - radius, radius * 2, radius * 2);
                }
                else
                {
                    // 空心节点：先挖掉线，再描一圈。
                    g.CompositingMode = CompositingMode.SourceCopy;
                    using (var clear = new SolidBrush(System.Drawing.Color.Transparent))
                    {
                        g.FillEllipse(clear, center.X - radius, center.Y - radius, radius * 2, radius * 2);
                    }
                    g.CompositingMode = CompositingMode.SourceOver;
                    var inner = radius - 0.8f * unit;
                    g.DrawEllipse(ring, center.X - inner, center.Y - inner, inner * 2, inner * 2);
                }
            }
        }
        return bitmap.GetHicon();
    }

    /// 托盘面板头部用的 WPF 图片。
    public static BitmapSource Image(LinkState state, bool dark)
    {
        var hicon = Draw(state, dark);
        try
        {
            var source = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(hicon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            return source;
        }
        finally
        {
            DestroyIcon(hicon);
        }
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);
}

/// 托盘面板：每个 VPN 和转发一行开关，状态和操作是同一个控件。对应 Mac 版 MenuPanel。
public sealed class TrayPanel : Window
{
    private readonly AppModel model;
    private readonly App app;
    private readonly StackPanel content = new() { Margin = new Thickness(6) };
    private DateTime hiddenAt = DateTime.MinValue;

    public TrayPanel(AppModel model, App app)
    {
        this.model = model;
        this.app = app;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = 320;
        SizeToContent = SizeToContent.Height;
        var frame = new Border { Child = content, CornerRadius = new CornerRadius(8) };
        frame.Bg(Palette.Card).Stroke(Palette.Line);
        Content = frame;
        this.Bg(Palette.Card);
        Deactivated += (_, _) =>
        {
            hiddenAt = DateTime.UtcNow;
            Hide();
        };
        model.Changed += () =>
        {
            if (IsVisible) Render();
        };
    }

    public void Toggle()
    {
        // 点托盘图标时面板先失去焦点自己藏起来，紧接着的这次点击不应该再把它打开。
        if (IsVisible || (DateTime.UtcNow - hiddenAt).TotalMilliseconds < 300)
        {
            Hide();
            return;
        }
        Render();
        Show();
        UpdateLayout();
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 12;
        Top = area.Bottom - ActualHeight - 12;
        Activate();
    }

    private void Render()
    {
        content.Children.Clear();
        content.Children.Add(Header());
        content.Children.Add(Ui.Divider(new Thickness(8, 5, 8, 5)));
        content.Children.Add(Section("VPN"));
        foreach (var profile in model.Config.Vpns)
        {
            var on = model.IsOn(profile);
            var busy = model.Job?.Kind is JobKind.VpnConnect or JobKind.VpnDisconnect;
            content.Children.Add(ToggleRow(profile.Name, null, on ? model.Vpn.Phase.Title() : Tr("未连接", "Off"), on ? Palette.Ok : Palette.Muted, on, busy, null,
                value =>
                {
                    if (value) model.ConnectVpnProfile(profile.Id);
                    else model.DisconnectVpnProfile(profile.Id);
                }));
        }
        if (model.Config.Forwards.Count > 0)
        {
            content.Children.Add(Section(Tr("转发", "Forwards")));
            foreach (var forward in model.Config.Forwards)
            {
                var port = model.StatusOf(forward);
                var busy = model.Job is { Kind: JobKind.ForwardConnect or JobKind.ForwardDisconnect } job && job.Port == forward.LocalPort;
                var detail = port.HttpOk ? Tr("已连接", "Connected") : port.Listening ? Tr("无响应", "No response") : Tr("未连接", "Off");
                var tint = port.HttpOk ? Palette.Ok : port.Listening ? Palette.Warn : Palette.Muted;
                content.Children.Add(ToggleRow(forward.Name, $":{forward.LocalPort}", detail, tint, port.HttpOk || port.Listening, busy,
                    port.HttpOk ? port.BrowseUrl : null,
                    value =>
                    {
                        if (value) model.ConnectForward(forward.LocalPort);
                        else model.DisconnectForward(forward.LocalPort);
                    }));
            }
        }
        content.Children.Add(Ui.Divider(new Thickness(8, 5, 8, 5)));
        content.Children.Add(ToggleRow(Tr("自动重连", "Auto-reconnect"), null, null, Palette.Muted, model.AutoReconnectOn,
            model.Job?.Kind is JobKind.WatchOn or JobKind.WatchOff, null, model.SetAutoReconnect));
        content.Children.Add(Ui.Divider(new Thickness(8, 5, 8, 5)));
        content.Children.Add(Command(Tr("打开内网连接", "Open NetLink"), () =>
        {
            Hide();
            app.ShowMain();
        }));
        content.Children.Add(Command(Tr("设置…", "Settings…"), () =>
        {
            Hide();
            app.ShowMain();
            app.Main.ShowSettings();
        }));
        content.Children.Add(Command(Tr("退出并断开", "Quit and Disconnect"), () =>
        {
            Hide();
            app.QuitAndDisconnect();
        }));
    }

    private UIElement Header()
    {
        var state = model.LinkState;
        var tint = state switch
        {
            LinkState.Up => Palette.Ok,
            LinkState.Partial => Palette.Warn,
            _ => Palette.Muted,
        };
        var title = state switch
        {
            LinkState.Checking => Tr("检查中", "Checking"),
            LinkState.Up => Tr("全部正常", "All good"),
            LinkState.Down => Tr("未连接", "Disconnected"),
            _ => Tr("部分连接", "Partly connected"),
        };
        var vpns = model.Config.Vpns.Count(model.IsOn);
        var detail = Tr(
            $"{vpns}/{model.Config.Vpns.Count} 个 VPN · {model.Tunnel.OkCount}/{model.Config.Forwards.Count} 条转发",
            $"{vpns}/{model.Config.Vpns.Count} VPN · {model.Tunnel.OkCount}/{model.Config.Forwards.Count} forwards");
        var grid = new Grid { Margin = new Thickness(8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var badge = new Grid { Width = 30, Height = 30 };
        var back = new Border { CornerRadius = new CornerRadius(8), Opacity = 0.14 };
        back.Bg(tint);
        badge.Children.Add(back);
        badge.Children.Add(new System.Windows.Controls.Image { Source = PathGlyph.Image(state, Palette.IsDark), Width = 20, Height = 20 });
        grid.Children.Add(badge);
        var text = new StackPanel { Margin = new Thickness(10, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Label(title, 13, FontWeights.SemiBold));
        text.Children.Add(Ui.Label(detail, 11, color: Palette.Muted));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var refresh = Ui.IconButton(Glyph.Refresh, "", () => _ = model.RefreshAsync(manual: true), flat: true, tooltip: Tr("刷新", "Refresh"));
        refresh.IsEnabled = !model.RefreshingVisible;
        Grid.SetColumn(refresh, 2);
        grid.Children.Add(refresh);
        return grid;
    }

    private static TextBlock Section(string title)
    {
        var label = Ui.Label(title, 11, FontWeights.SemiBold, Palette.Muted);
        label.Margin = new Thickness(8, 4, 8, 2);
        return label;
    }

    private static UIElement ToggleRow(string title, string? trailing, string? detail, string tint, bool on, bool busy, string? open, Action<bool> toggle)
    {
        var grid = new Grid { Height = 34, Margin = new Thickness(8, 0, 8, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(Ui.Label(title, 13));
        if (trailing != null)
        {
            var tail = Ui.Label(trailing, 11, color: Palette.Muted);
            tail.Margin = new Thickness(6, 0, 0, 0);
            left.Children.Add(tail);
        }
        grid.Children.Add(left);
        var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (open != null)
        {
            var link = new Button { Content = Ui.Label(Tr("打开", "Open"), 11, FontWeights.SemiBold, Palette.Accent), Margin = new Thickness(0, 0, 8, 0) };
            link.SetResourceReference(FrameworkElement.StyleProperty, "NL.Link");
            link.Click += (_, _) => AppModel.Open(open);
            right.Children.Add(link);
        }
        if (detail != null)
        {
            var state = Ui.Label(detail, 11, color: tint);
            state.Margin = new Thickness(0, 0, 8, 0);
            right.Children.Add(state);
        }
        right.Children.Add(busy ? Ui.Spinner(40) : Ui.Switch(on, toggle));
        Grid.SetColumn(right, 1);
        grid.Children.Add(right);
        return grid;
    }

    private static UIElement Command(string title, Action action)
    {
        var button = new Button { Content = Ui.Label(title, 13), HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(8, 6, 8, 6) };
        button.SetResourceReference(FrameworkElement.StyleProperty, "NL.Flat");
        button.Click += (_, _) => action();
        return button;
    }
}

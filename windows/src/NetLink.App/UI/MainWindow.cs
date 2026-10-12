using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App.UI;

/// 主窗口：左侧边栏、中间拓扑图、右侧检查器，上面工具栏，下面状态栏。
public sealed class MainWindow : Window
{
    private readonly AppModel model;
    private readonly SidebarView sidebar;
    private readonly TopologyView topology;
    private readonly InspectorView inspector;
    private readonly Border inspectorPane;
    private readonly ColumnDefinition inspectorColumn = new() { Width = new GridLength(290), MinWidth = 250, MaxWidth = 380 };
    private readonly Border banner = new() { Padding = new Thickness(14, 8, 14, 8), Visibility = Visibility.Collapsed };
    private readonly TextBlock title = Ui.Label("", 15, FontWeights.SemiBold);
    private readonly TextBlock subtitle = Ui.Label("", 12, color: Palette.Muted);
    private readonly TextBlock statusText = Ui.Label("", 11, color: Palette.Muted);
    private readonly TextBlock statusRight = Ui.Label("", 11, color: Palette.Muted);
    private readonly ProgressBar statusSpinner = Ui.Spinner(28);
    private readonly StackPanel toolbar = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
    private Selection? selection;
    private bool hintShown;
    private LogsWindow? logs;
    private TransferWindow? transfer;
    private SettingsWindow? settings;

    public MainWindow(AppModel model)
    {
        this.model = model;
        Width = 1100;
        Height = 660;
        MinWidth = 900;
        MinHeight = 520;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/netlink.ico"));
        this.Bg(Palette.Window);

        sidebar = new SidebarView(model, () => selection, Select, Edit);
        topology = new TopologyView(model, () => selection, Select, Edit);
        inspector = new InspectorView(model, Edit, () => this);
        inspectorPane = new Border { Child = inspector };
        inspectorPane.Bg(Palette.Window);

        var root = new DockPanel();
        root.Children.Add(Toolbar());
        root.Children.Add(StatusBar());
        root.Children.Add(Body());
        Content = root;

        model.Changed += Render;
        Palette.Changed += () => Render(force: true);
        PreviewKeyDown += OnKey;
        Render(force: true);
    }

    // MARK: - 布局

    private UIElement Toolbar()
    {
        var bar = new Grid { Margin = new Thickness(16, 10, 10, 10) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var heading = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        heading.Children.Add(title);
        heading.Children.Add(subtitle);
        bar.Children.Add(heading);
        Grid.SetColumn(toolbar, 1);
        bar.Children.Add(toolbar);
        var wrapper = new DockPanel();
        var line = Ui.Divider();
        DockPanel.SetDock(line, Dock.Bottom);
        wrapper.Children.Add(line);
        wrapper.Children.Add(bar);
        DockPanel.SetDock(wrapper, Dock.Top);
        return wrapper;
    }

    private void BuildToolbarButtons()
    {
        toolbar.Children.Clear();
        void Add(string glyph, string tip, Action action)
        {
            var button = Ui.IconButton(glyph, "", action, flat: true, tooltip: tip);
            button.Padding = new Thickness(9, 7, 9, 7);
            button.Margin = new Thickness(2, 0, 0, 0);
            toolbar.Children.Add(button);
        }
        Add(Glyph.Refresh, Tr("刷新状态（Ctrl+R）", "Refresh status (Ctrl+R)"), () => _ = model.RefreshAsync(manual: true));
        Add(Glyph.Document, Tr("日志", "Logs"), ShowLogs);
        Add(Glyph.Import, Tr("导入或导出配置", "Import or export the config"), ShowTransfer);
        Add(Glyph.Settings, Tr("设置（Ctrl+,）", "Settings (Ctrl+,)"), ShowSettings);
        Add(Glyph.Pane, Tr("显示或隐藏右侧详情", "Show or hide the details panel"), ToggleInspector);
    }

    private UIElement StatusBar()
    {
        var grid = new Grid { Height = 26, Margin = new Thickness(12, 0, 12, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        statusSpinner.Margin = new Thickness(0, 0, 8, 0);
        grid.Children.Add(statusSpinner);
        Grid.SetColumn(statusText, 1);
        grid.Children.Add(statusText);
        Grid.SetColumn(statusRight, 2);
        grid.Children.Add(statusRight);
        var wrapper = new DockPanel();
        var line = Ui.Divider();
        DockPanel.SetDock(line, Dock.Top);
        wrapper.Children.Add(line);
        wrapper.Children.Add(grid);
        DockPanel.SetDock(wrapper, Dock.Bottom);
        return wrapper;
    }

    private UIElement Body()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220), MinWidth = 190, MaxWidth = 300 });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(inspectorColumn);

        grid.Children.Add(sidebar);
        var leftSplit = Splitter();
        Grid.SetColumn(leftSplit, 1);
        grid.Children.Add(leftSplit);

        var center = new DockPanel();
        banner.Bg(Palette.WarnBack);
        DockPanel.SetDock(banner, Dock.Top);
        center.Children.Add(banner);
        center.Children.Add(topology);
        Grid.SetColumn(center, 2);
        grid.Children.Add(center);

        var rightSplit = Splitter();
        Grid.SetColumn(rightSplit, 3);
        grid.Children.Add(rightSplit);
        Grid.SetColumn(inspectorPane, 4);
        grid.Children.Add(inspectorPane);
        return grid;
    }

    private static GridSplitter Splitter()
    {
        var splitter = new GridSplitter { Width = 1, ResizeBehavior = GridResizeBehavior.PreviousAndNext, HorizontalAlignment = HorizontalAlignment.Stretch };
        splitter.Bg(Palette.Line);
        return splitter;
    }

    // MARK: - 刷新

    private void Render() => Render(force: false);

    private void Render(bool force)
    {
        Title = Tr("内网连接", "NetLink");
        title.Text = Tr("内网连接", "NetLink");
        subtitle.Text = model.Summary;
        if (force) BuildToolbarButtons();

        if (model.Banner is { } notice)
        {
            banner.Visibility = Visibility.Visible;
            banner.Child = BannerContent(notice);
        }
        else
        {
            banner.Visibility = Visibility.Collapsed;
        }

        statusSpinner.Visibility = model.Busy || model.RefreshingVisible ? Visibility.Visible : Visibility.Collapsed;
        statusText.Text = model.StatusLine ?? "";
        var reconnect = model.AutoReconnectOn ? Tr("自动重连：开", "Auto-reconnect: on") : Tr("自动重连：关", "Auto-reconnect: off");
        statusRight.Text = model.CheckedAt is { } at ? $"{reconnect} · {Tr($"检查于 {at:HH:mm:ss}", $"Checked {at:HH:mm:ss}")}" : reconnect;
        statusRight.ToolTip = Tr("关掉窗口不会断开；托盘菜单里的「退出并断开」才会断开 VPN 和隧道。", "Closing the window doesn't disconnect; use Quit and Disconnect in the tray menu to stop the VPN and tunnels.");

        // 选中的节点被删掉了，就回到空白。
        if (selection != null && NodeLook.Of(selection, model) == null) selection = null;
        sidebar.Render(force);
        topology.Render(force);
        inspector.Render(selection, force);
    }

    private UIElement BannerContent(Banner notice)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.Icon(Glyph.Warning, 14, Palette.Warn));
        var text = Ui.Label(notice.Text, 12, wrap: true);
        text.Margin = new Thickness(10, 0, 10, 0);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (notice.Action is { } action)
        {
            var button = Ui.TextButton(action switch
            {
                SetupAction.StartService => Tr("启动服务", "Start Service"),
                _ => Tr("打开可选功能", "Open Optional Features"),
            }, () => model.Perform(action));
            button.IsEnabled = !model.Busy;
            Grid.SetColumn(button, 2);
            grid.Children.Add(button);
        }
        return grid;
    }

    private void Select(Selection? next)
    {
        selection = next;
        Render(force: false);
    }

    private void ToggleInspector()
    {
        var visible = inspectorPane.Visibility == Visibility.Visible;
        inspectorPane.Visibility = visible ? Visibility.Collapsed : Visibility.Visible;
        inspectorColumn.MinWidth = visible ? 0 : 250;
        inspectorColumn.Width = visible ? new GridLength(0) : new GridLength(290);
    }

    public void Edit(PathEdit request)
    {
        var dialog = new PathEditDialog(model, request) { Owner = IsVisible ? this : null };
        dialog.ShowDialog();
    }

    public void ShowLogs() => logs = ShowTool(logs, () => new LogsWindow(model));

    public void ShowTransfer() => transfer = ShowTool(transfer, () => new TransferWindow(model));

    public void ShowSettings() => settings = ShowTool(settings, () => new SettingsWindow(model));

    private T ShowTool<T>(T? existing, Func<T> make) where T : Window
    {
        if (existing is { IsLoaded: true })
        {
            existing.Activate();
            return existing;
        }
        var window = make();
        if (IsVisible) window.Owner = this;
        window.Show();
        window.Activate();
        return window;
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.R)
        {
            _ = model.RefreshAsync(manual: true);
            e.Handled = true;
        }
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.OemComma)
        {
            ShowSettings();
            e.Handled = true;
        }
        else if (Keyboard.Modifiers == (ModifierKeys.Control | ModifierKeys.Shift) && e.Key == Key.K)
        {
            model.ConnectTunnel();
            e.Handled = true;
        }
    }

    /// 关掉窗口只是藏到通知区域，连接和自动重连都继续。
    protected override void OnClosing(CancelEventArgs e)
    {
        if (Application.Current is App { Quitting: true })
        {
            base.OnClosing(e);
            return;
        }
        e.Cancel = true;
        Hide();
        if (!hintShown)
        {
            hintShown = true;
            TrayIcon.Current?.Balloon(Tr("内网连接还在运行", "NetLink is still running"),
                Tr("连接保持不变。在通知区域的图标上右键，选「退出并断开」才会断开。", "Connections stay up. Right-click the notification area icon and choose Quit and Disconnect to stop them."));
        }
    }
}

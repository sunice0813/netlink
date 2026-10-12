using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using NetLink.App.Platform;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App.UI;

public abstract class ToolWindow : Window
{
    protected ToolWindow()
    {
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/netlink.ico"));
        this.Bg(Palette.Window);
    }
}

/// 日志：VPN（后台服务里的 openconnect）、隧道（ssh）、应用（自动重连等）。密码不会出现在日志里。
public sealed class LogsWindow : ToolWindow
{
    private readonly AppModel model;
    private readonly TextBox journal = LogBox();
    private readonly TextBox body = LogBox();
    private readonly List<ToggleButton> tabs = [];
    private int source;

    public LogsWindow(AppModel model)
    {
        this.model = model;
        Title = Tr("日志", "Logs");
        Width = 760;
        Height = 520;
        MinWidth = 560;
        MinHeight = 360;

        var header = new DockPanel { Margin = new Thickness(16, 10, 16, 10) };
        var segments = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (index, title) in new[] { (0, "VPN"), (1, Tr("隧道", "Tunnel")), (2, Tr("应用", "App")) })
        {
            var tab = new ToggleButton { Content = title, Padding = new Thickness(14, 4, 14, 4), Margin = new Thickness(0, 0, 4, 0), IsChecked = index == 0 };
            tab.Click += (_, _) =>
            {
                source = index;
                Update();
            };
            tabs.Add(tab);
            segments.Children.Add(tab);
        }
        var hint = Ui.Label(Tr("密码不会出现在日志里", "Passwords never appear in logs"), 11, color: Palette.Muted);
        DockPanel.SetDock(hint, Dock.Right);
        header.Children.Add(hint);
        header.Children.Add(segments);

        journal.MaxHeight = 140;
        journal.Margin = new Thickness(16, 0, 16, 10);
        journal.Fg(Palette.Accent);
        body.Padding = new Thickness(16);
        body.Bg(Palette.Canvas);

        var root = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        DockPanel.SetDock(journal, Dock.Top);
        root.Children.Add(journal);
        var line = Ui.Divider();
        DockPanel.SetDock(line, Dock.Top);
        root.Children.Add(line);
        root.Children.Add(body);
        Content = root;

        model.Changed += Update;
        Closed += (_, _) => model.Changed -= Update;
        Update();
    }

    private static TextBox LogBox()
    {
        var box = new TextBox
        {
            IsReadOnly = true,
            TextWrapping = TextWrapping.NoWrap,
            BorderThickness = new Thickness(0),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontSize = 12,
            Background = System.Windows.Media.Brushes.Transparent,
        };
        box.SetResourceReference(Control.FontFamilyProperty, "NL.Mono");
        return box.Fg(Palette.Text);
    }

    private void Update()
    {
        for (var i = 0; i < tabs.Count; i++) tabs[i].IsChecked = i == source;
        var lines = model.JournalLines.TakeLast(8).ToList();
        journal.Visibility = lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        journal.Text = string.Join("\n", lines);
        var raw = source switch
        {
            0 => model.VpnLog,
            1 => model.TunnelLog,
            _ => model.AppLog,
        };
        var text = raw.Trim();
        var next = text.Length == 0 ? Tr("还没有日志", "No logs yet") : text;
        if (body.Text != next)
        {
            body.Text = next;
            body.ScrollToEnd();
        }
    }
}

/// 导入导出配置。规则和 Mac 版一样：带机密的文件导入后存进应用自己的数据目录。
public sealed class TransferWindow : ToolWindow
{
    private readonly AppModel model;
    private readonly CheckBox includeSecrets = new() { IsChecked = true };
    private readonly TextBlock secretsWarning = Ui.Label(Tr("导出的文件里是明文密码和私钥，请当成密码一样保管，只交给自己信任的人。", "The exported file contains plain-text passwords and private keys. Keep it as safe as a password and only give it to people you trust."), 12, color: Palette.Warn, wrap: true);
    private readonly StackPanel previewArea = new();
    private readonly TextBlock message = Ui.Label("", 12, wrap: true);
    private ImportPreview? preview;

    public TransferWindow(AppModel model)
    {
        this.model = model;
        Title = Tr("导入导出", "Import / Export");
        Width = 560;
        SizeToContent = SizeToContent.Height;
        MinHeight = 420;
        ResizeMode = ResizeMode.CanMinimize;

        includeSecrets.Content = Ui.Label(Tr("包含 VPN 密码和 SSH 私钥", "Include VPN passwords and SSH private keys"));
        includeSecrets.Click += (_, _) => secretsWarning.Visibility = includeSecrets.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        var export = Ui.IconButton(Glyph.Document, Tr("导出到文件…", "Export to File…"), Export);
        export.HorizontalAlignment = HorizontalAlignment.Left;
        var choose = Ui.IconButton(Glyph.Import, Tr("选择文件…", "Choose File…"), Choose);
        choose.HorizontalAlignment = HorizontalAlignment.Left;

        var root = new StackPanel { Margin = new Thickness(20) };
        root.Children.Add(Section(
            Tr("导出", "Export"),
            Tr("把当前的 VPN、跳板、转发和图上的位置存成一个 JSON 文件。勾选下面的选项后，VPN 账号和 SSH 私钥的内容也一起带上，换一台电脑（Windows 或 Mac）导入就能直接用。", "Saves the current VPNs, jump hosts, forwards and their positions on the map as a JSON file. With the option below checked, the VPN accounts and SSH private keys are included too, so importing it on another computer (Windows or Mac) just works."),
            Ui.Column(8, includeSecrets, secretsWarning, export)));
        Ui.AddSpaced(root, Ui.Divider(), 18);
        Ui.AddSpaced(root, Section(
            Tr("导入", "Import"),
            Tr("选择之前导出的文件（Mac 版导出的也可以），确认内容后替换当前配置。替换前会把现在的配置备份为 config.json.bak。文件里带的账号和私钥会存进应用自己的数据目录。", "Choose a previously exported file (one exported by the Mac version works too), review it, then replace the current config. The current config is backed up as config.json.bak first. Accounts and keys in the file are stored in the app's own data folder."),
            Ui.Column(8, choose, previewArea)), 18);
        Ui.AddSpaced(root, message, 18);
        Content = root;
    }

    private static StackPanel Section(string title, string detail, UIElement content) =>
        Ui.Column(8, Ui.Label(title, 13, FontWeights.SemiBold), Ui.Label(detail, 12, color: Palette.Muted, wrap: true), content);

    private void Export()
    {
        var dialog = new SaveFileDialog
        {
            Title = Tr("导出配置", "Export Config"),
            FileName = "netlink-config.json",
            Filter = "JSON|*.json",
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            var current = ConfigStore.LoadIfValid() ?? model.Config;
            var secrets = includeSecrets.IsChecked == true;
            ConfigTransfer.Write(current, dialog.FileName, secrets);
            Show(secrets
                ? Tr($"已导出到 {dialog.FileName}（含密码和私钥，请妥善保管）", $"Exported to {dialog.FileName} (includes passwords and private keys, keep it safe)")
                : Tr($"已导出到 {dialog.FileName}", $"Exported to {dialog.FileName}"), failed: false);
        }
        catch (Exception error)
        {
            Show(Tr($"导出失败：{error.Message}", $"Export failed: {error.Message}"), failed: true);
        }
    }

    private void Choose()
    {
        var dialog = new OpenFileDialog
        {
            Title = Tr("选择要导入的配置", "Choose a Config to Import"),
            Filter = "JSON|*.json|" + Tr("所有文件", "All files") + "|*.*",
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            preview = ConfigTransfer.Parse(File.ReadAllBytes(dialog.FileName));
            ShowPreview(Path.GetFileName(dialog.FileName), preview);
            message.Text = "";
        }
        catch (Exception error)
        {
            preview = null;
            previewArea.Children.Clear();
            Show(error.Message, failed: true);
        }
    }

    private void ShowPreview(string fileName, ImportPreview current)
    {
        previewArea.Children.Clear();
        var card = new StackPanel();
        card.Children.Add(Ui.Label(fileName, 12, FontWeights.SemiBold));
        Ui.AddSpaced(card, Ui.Label(current.Summary, 12, color: Palette.Muted, wrap: true), 6);
        if (current.DroppedVpns.Count > 0)
        {
            Ui.AddSpaced(card, Ui.Label(Tr($"Windows 版不支持 {string.Join("、", current.DroppedVpns)}，导入时会去掉。", $"The Windows version doesn't support {string.Join(", ", current.DroppedVpns)}; they'll be left out."), 12, color: Palette.Muted, wrap: true), 6);
        }
        if (current.MissingCredentials.Count > 0)
        {
            Ui.AddSpaced(card, Ui.Label(Tr($"{string.Join("、", current.MissingCredentials)} 的账号文件在这台电脑上不存在，文件里也没带账号，导入后要在对应节点里重新填。", $"The account files for {string.Join(", ", current.MissingCredentials)} don't exist on this computer and aren't in the file. Enter them again on those nodes after importing."), 12, color: Palette.Warn, wrap: true), 6);
        }
        if (current.Issues.Count > 0)
        {
            Ui.AddSpaced(card, Ui.Label(Tr("不能导入：", "Can't import:"), 12, FontWeights.SemiBold, Palette.Bad), 6);
            foreach (var issue in current.Issues) card.Children.Add(Ui.Label("· " + issue, 12, color: Palette.Bad, wrap: true));
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        if (current.Issues.Count == 0)
        {
            var apply = Ui.TextButton(Tr("导入并替换当前配置", "Import and Replace Current Config"), () => Apply(current), primary: true);
            apply.Margin = new Thickness(0, 0, 8, 0);
            buttons.Children.Add(apply);
        }
        buttons.Children.Add(Ui.TextButton(Tr("取消", "Cancel"), () =>
        {
            preview = null;
            previewArea.Children.Clear();
        }));
        card.Children.Add(buttons);
        var frame = new Border { Child = card, Padding = new Thickness(12), CornerRadius = new CornerRadius(8) };
        frame.Bg(Palette.Card).Stroke(Palette.Line);
        previewArea.Children.Add(frame);
    }

    private void Apply(ImportPreview current)
    {
        ConfigStore.BackupCurrent();
        try
        {
            var ready = ConfigTransfer.Materialize(current);
            model.Save(ready);
            preview = null;
            previewArea.Children.Clear();
            Show(Tr("已导入。原配置备份为 config.json.bak，转发和 VPN 的改动重新连接后生效。", "Imported. The previous config was backed up as config.json.bak. Reconnect for forward and VPN changes to take effect."), failed: false);
            _ = model.RefreshAsync();
        }
        catch (Exception error)
        {
            Show(Tr($"导入失败：{error.Message}", $"Import failed: {error.Message}"), failed: true);
        }
    }

    private void Show(string text, bool failed)
    {
        message.Text = text;
        message.Fg(failed ? Palette.Bad : Palette.Ok);
    }
}

/// 设置：只放应用级的设置。账号、跳板、转发在主窗口里点对应节点编辑。
public sealed class SettingsWindow : ToolWindow
{
    private readonly AppModel model;

    public SettingsWindow(AppModel model)
    {
        this.model = model;
        Title = Tr("设置", "Settings");
        Width = 520;
        Height = 480;
        ResizeMode = ResizeMode.NoResize;
        var tabs = new TabControl { Margin = new Thickness(12) };
        tabs.Items.Add(new TabItem { Header = Tr("通用", "General"), Content = General() });
        tabs.Items.Add(new TabItem { Header = Tr("健康检查", "Health Check"), Content = Health() });
        tabs.Items.Add(new TabItem { Header = Tr("高级", "Advanced"), Content = Advanced() });
        Content = tabs;
    }

    private UIElement General()
    {
        var panel = new StackPanel { Margin = new Thickness(16) };
        var loginNote = Ui.Label("", 12, color: Palette.Bad, wrap: true);
        var login = Ui.Switch(Autostart.Enabled, on =>
        {
            try
            {
                Autostart.Set(on);
                loginNote.Text = "";
            }
            catch (Exception error)
            {
                loginNote.Text = error.Message;
            }
        }, Tr("登录 Windows 后打开内网连接", "Open NetLink when you sign in to Windows"));
        panel.Children.Add(login);
        Ui.AddSpaced(panel, loginNote, 4);
        Ui.AddSpaced(panel, Ui.Switch(model.AutoReconnectOn, model.SetAutoReconnect, Tr("断线后自动重连 VPN 和隧道", "Reconnect the VPN and tunnels when they drop")), 12);
        Ui.AddSpaced(panel, Ui.Note(Tr("登录时只打开应用（藏在通知区域），不会自动连接。", "Opening at sign-in only starts the app in the notification area; it doesn't connect anything by itself.")), 6);
        Ui.AddSpaced(panel, Ui.Divider(), 16);

        var appearance = Ui.Picker(
            [("light", Tr("浅色", "Light")), ("dark", Tr("深色", "Dark")), ("system", Tr("跟随系统", "System"))],
            AppSettings.Current.Appearance,
            value =>
            {
                AppSettings.Update(s => s.Appearance = value);
                Palette.Apply();
            });
        Ui.AddSpaced(panel, LabeledRow(Tr("外观", "Appearance"), appearance), 16);

        var language = Ui.Picker(
            [("system", Tr("跟随系统", "System")), ("zh", "中文"), ("en", "English")],
            AppSettings.Current.Language,
            value =>
            {
                AppSettings.Update(s => s.Language = value);
                L10n.Choice = L10n.Parse(value);
                // 默认名（跳板、本机……）在读配置时按语言换，重读一次让图上立刻变。
                _ = model.RefreshAsync();
                Palette.Apply();
                Close();
            });
        Ui.AddSpaced(panel, LabeledRow(Tr("语言", "Language"), language), 10);
        return panel;
    }

    private static Grid LabeledRow(string label, FrameworkElement control)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) });
        grid.Children.Add(Ui.Label(label, 13));
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    private UIElement Health()
    {
        var config = model.Config;
        var route = Ui.Field(config.RouteMarker, "10.0.0");
        var ping = Ui.Field(config.PingHost, "10.0.0.1:443");
        var vpnInterval = Ui.Field(config.VpnWatchdogInterval.ToString());
        var vpnFails = Ui.Field(config.VpnFailThreshold.ToString());
        var tunnelInterval = Ui.Field(config.TunnelWatchdogInterval.ToString());
        var tunnelFails = Ui.Field(config.TunnelFailThreshold.ToString());
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(Ui.Label("VPN", 12, FontWeights.SemiBold, Palette.Muted));
        Ui.AddSpaced(panel, LabeledRow(Tr("路由里要出现的网段", "Network in the routes"), route), 8);
        Ui.AddSpaced(panel, LabeledRow(Tr("网关探测", "Gateway check"), ping), 8);
        Ui.AddSpaced(panel, Ui.Note(Tr("网关写成 主机:端口 用 TCP 探测（推荐，很多内网主机不回 ping）；不带端口就 ping。", "Write the gateway as host:port to use a TCP check (recommended, many intranet hosts don't answer ping); without a port it pings.")), 6);
        Ui.AddSpaced(panel, Ui.Label(Tr("间隔和重试", "Interval and retries"), 12, FontWeights.SemiBold, Palette.Muted), 16);
        Ui.AddSpaced(panel, LabeledRow(Tr("VPN 检查间隔（秒）", "VPN check interval (s)"), vpnInterval), 8);
        Ui.AddSpaced(panel, LabeledRow(Tr("VPN 失败几次才重启", "VPN failures before restart"), vpnFails), 8);
        Ui.AddSpaced(panel, LabeledRow(Tr("隧道检查间隔（秒）", "Tunnel check interval (s)"), tunnelInterval), 8);
        Ui.AddSpaced(panel, LabeledRow(Tr("隧道失败几次才重启", "Tunnel failures before restart"), tunnelFails), 8);
        Ui.AddSpaced(panel, SaveRow(note =>
        {
            var next = model.Config.Clone();
            next.RouteMarker = route.Text.Trim();
            next.PingHost = ping.Text.Trim();
            next.VpnWatchdogInterval = Number(vpnInterval);
            next.VpnFailThreshold = Number(vpnFails);
            next.TunnelWatchdogInterval = Number(tunnelInterval);
            next.TunnelFailThreshold = Number(tunnelFails);
            model.Save(next);
            return Tr("已保存，下次检查起生效", "Saved; applies from the next check");
        }), 16);
        return panel;
    }

    private UIElement Advanced()
    {
        var config = model.Config;
        var ssh = Ui.Field(config.SshPath);
        ssh.SetResourceReference(Control.FontFamilyProperty, "NL.Mono");
        var timeout = Ui.Field(config.ReconnectTimeout.ToString());
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(Ui.Label(Tr("程序", "Programs"), 12, FontWeights.SemiBold, Palette.Muted));
        Ui.AddSpaced(panel, LabeledRow("ssh", ssh), 8);
        Ui.AddSpaced(panel, LabeledRow(Tr("VPN 重连超时（秒）", "VPN reconnect timeout (s)"), timeout), 8);
        Ui.AddSpaced(panel, Ui.Note(Tr("ssh 默认用 Windows 自带的 OpenSSH 客户端。openconnect 随应用安装，由后台服务运行。", "ssh defaults to Windows' built-in OpenSSH client. openconnect ships with the app and is run by the background service.")), 6);
        Ui.AddSpaced(panel, SaveRow(note =>
        {
            var next = model.Config.Clone();
            next.SshPath = ssh.Text.Trim();
            next.ReconnectTimeout = Number(timeout);
            model.Save(next);
            return Tr("已保存", "Saved");
        }), 12);
        Ui.AddSpaced(panel, Ui.Divider(), 16);
        Ui.AddSpaced(panel, Ui.Label(Tr("数据", "Data"), 12, FontWeights.SemiBold, Palette.Muted), 16);
        var show = Ui.TextButton(Tr("在资源管理器中显示", "Show in File Explorer"), () =>
        {
            AppPaths.EnsureDirectory();
            AppModel.Open(AppPaths.Directory);
        });
        Ui.AddSpaced(panel, LabeledRow(Tr("配置、导入的账号和日志", "Config, imported accounts and logs"), show), 8);
        var service = model.Vpn.ServiceReachable ? Tr("在运行", "Running") : Tr("没在运行", "Not running");
        Ui.AddSpaced(panel, Ui.Note(Tr($"后台服务（{ServiceProtocol.ServiceName}）：{service}", $"Background service ({ServiceProtocol.ServiceName}): {service}")), 10);
        return panel;
    }

    private static int Number(TextBox box) => int.TryParse(box.Text.Trim(), out var value) ? value : -1;

    /// 左边是结果，右边是保存按钮。
    private static UIElement SaveRow(Func<TextBlock, string> save)
    {
        var note = Ui.Label("", 12, color: Palette.Muted, wrap: true);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(note);
        var button = Ui.TextButton(Tr("保存", "Save"), () =>
        {
            try
            {
                note.Text = save(note);
                note.Fg(Palette.Muted);
            }
            catch (Exception error) when (error is ConfigException or IOException)
            {
                note.Text = error.Message;
                note.Fg(Palette.Bad);
            }
        });
        Grid.SetColumn(button, 1);
        grid.Children.Add(button);
        return grid;
    }
}

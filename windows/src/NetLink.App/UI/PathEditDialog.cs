using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App.UI;

/// 添加、修改 VPN / 跳板 / 转发，以及改名。和 Mac 版 PathConfigSheet 一样的字段和提示。
public sealed class PathEditDialog : Window
{
    private readonly AppModel model;
    private readonly PathEdit kind;
    private readonly StackPanel form = new();
    private readonly TextBlock note = Ui.Label("", 12, color: Palette.Bad, wrap: true);
    private readonly TextBox name = Ui.Field("");
    private readonly TextBox host = Ui.Field("", "vpn.example.com");
    private readonly TextBox user = Ui.Field("");
    private readonly PasswordBox password = new() { Padding = new Thickness(6, 4, 6, 4) };
    private readonly TextBox jump = Ui.Field("", "user@host");
    private readonly TextBox identity = Ui.Field("", "~/.ssh/id_ed25519");
    private readonly TextBlock keyWarning = Ui.Label(Tr("找不到这个私钥", "Can't find this private key"), 12, color: Palette.Warn);
    private readonly TextBox localPort = Ui.Field("9000");
    private readonly TextBox targetHost = Ui.Field("", "10.0.0.10");
    private readonly TextBox targetPort = Ui.Field("80");
    private readonly TextBox openHost = Ui.Field("", Tr("留空则用 127.0.0.1", "Empty means 127.0.0.1"));

    public PathEditDialog(AppModel model, PathEdit kind)
    {
        this.model = model;
        this.kind = kind;
        Title = TitleText();
        Width = 440;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Icon = new BitmapImage(new Uri("pack://application:,,,/Assets/netlink.ico"));
        this.Bg(Palette.Window);
        Load();

        var root = new StackPanel { Margin = new Thickness(20) };
        root.Children.Add(Ui.Label(TitleText(), 16, FontWeights.SemiBold));
        form.Margin = new Thickness(0, 14, 0, 0);
        BuildForm();
        root.Children.Add(form);
        note.Margin = new Thickness(0, 10, 0, 0);
        root.Children.Add(note);
        var buttons = new DockPanel { Margin = new Thickness(0, 16, 0, 0), LastChildFill = false };
        var cancel = Ui.TextButton(Tr("取消", "Cancel"), Close);
        cancel.IsCancel = true;
        var save = Ui.TextButton(Tr("保存", "Save"), Save, primary: true);
        save.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(save, Dock.Right);
        DockPanel.SetDock(cancel, Dock.Right);
        buttons.Children.Add(save);
        buttons.Children.Add(cancel);
        root.Children.Add(buttons);
        Content = root;
        Loaded += (_, _) => name.Focus();
    }

    private string TitleText() => kind switch
    {
        PathEdit.EditVpn => Tr("修改 VPN", "Edit VPN"),
        PathEdit.EditJump => Tr("修改跳板", "Edit Jump Host"),
        PathEdit.AddVpn => Tr("添加 VPN", "Add VPN"),
        PathEdit.AddJump => Tr("添加跳板", "Add Jump Host"),
        PathEdit.AddTunnel => Tr("添加转发", "Add Forward"),
        PathEdit.EditForward => Tr("编辑转发", "Edit Forward"),
        _ => Tr("改名", "Rename"),
    };

    private void BuildForm()
    {
        switch (kind)
        {
            case PathEdit.EditVpn or PathEdit.AddVpn:
                var adding = kind is PathEdit.AddVpn;
                Field(Tr("名称", "Name"), name);
                Field(Tr("主机", "Host"), host);
                Field(Tr("用户", "User"), user);
                Field(adding ? Tr("密码（必填）", "Password (required)") : Tr("密码（留空则不改）", "Password (leave empty to keep)"), password);
                Hint(adding
                    ? Tr("密码只写在本机的凭据文件里（用 Windows 账户加密），不会进配置。", "The password is only written to the credential file on this computer (encrypted with your Windows account), never to the config.")
                    : Tr("正在使用的连接不会马上切换。同一时间只连一个 VPN。", "The connection in use won't switch right away. Only one VPN is connected at a time."));
                break;
            case PathEdit.EditJump or PathEdit.AddJump:
                Field(Tr("名称", "Name"), name);
                Field(Tr("跳板", "Jump host"), jump);
                var keyRow = new DockPanel();
                var browse = Ui.TextButton(Tr("浏览…", "Browse…"), BrowseKey);
                browse.Margin = new Thickness(6, 0, 0, 0);
                DockPanel.SetDock(browse, Dock.Right);
                keyRow.Children.Add(browse);
                keyRow.Children.Add(identity);
                Field(Tr("私钥", "Private key"), keyRow);
                keyWarning.Margin = new Thickness(0, 4, 0, 0);
                form.Children.Add(keyWarning);
                identity.TextChanged += (_, _) => UpdateKeyWarning();
                UpdateKeyWarning();
                Hint(Tr("写成 user@host。改完要重新连接，正在用的隧道不会马上切换。", "Write it as user@host. Reconnect after changing it; tunnels in use won't switch right away."));
                break;
            case PathEdit.AddTunnel or PathEdit.EditForward:
                Field(Tr("名称", "Name"), name);
                Field(Tr("本地端口", "Local port"), localPort);
                Field(Tr("目标主机", "Target host"), targetHost);
                Field(Tr("目标端口", "Target port"), targetPort);
                Field(Tr("打开时的域名，可空", "Host name to open (optional)"), openHost);
                Hint(kind is PathEdit.EditForward
                    ? Tr("正在用的转发要断开重连才按新的端口和目标走。", "A forward in use follows the new port and target after you reconnect it.")
                    : Tr("先出现在图上，点连接才会建隧道。", "It appears on the map first; the tunnel is only created when you click Connect."));
                break;
            default:
                Field(Tr("名称", "Name"), name);
                Hint(Tr("只改图上和菜单里的名字，不会动正在用的连接。", "Only changes the name on the map and in the menu; connections in use aren't touched."));
                break;
        }
    }

    private void Field(string label, UIElement input)
    {
        var block = new StackPanel { Margin = new Thickness(0, form.Children.Count > 0 ? 10 : 0, 0, 0) };
        block.Children.Add(Ui.Label(label, 12, color: Palette.Muted));
        if (input is FrameworkElement element) element.Margin = new Thickness(0, 5, 0, 0);
        block.Children.Add(input);
        form.Children.Add(block);
    }

    private void Hint(string text)
    {
        var hint = Ui.Label(text, 12, color: Palette.Muted, wrap: true);
        hint.Margin = new Thickness(0, 12, 0, 0);
        form.Children.Add(hint);
    }

    private void UpdateKeyWarning()
    {
        var text = identity.Text.Trim();
        keyWarning.Visibility = text.Length > 0 && !File.Exists(PathExpander.Expand(text)) ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BrowseKey()
    {
        var dialog = new OpenFileDialog
        {
            Title = Tr("选择 SSH 私钥", "Choose an SSH private key"),
            InitialDirectory = Path.Combine(PathExpander.Home, ".ssh"),
            Filter = Tr("所有文件", "All files") + "|*.*",
        };
        if (dialog.ShowDialog(this) == true) identity.Text = PathExpander.Portable(dialog.FileName);
    }

    private void Load()
    {
        var config = model.Config;
        switch (kind)
        {
            case PathEdit.EditVpn(var id):
                var profile = config.Vpns.FirstOrDefault(v => v.Id == id);
                name.Text = profile?.Name ?? "VPN";
                if (profile != null && Credentials.Load(profile.CredentialFile) is { } credential)
                {
                    host.Text = credential.Host;
                    user.Text = credential.User;
                }
                break;
            case PathEdit.EditJump(var id):
                var item = config.Jumps.FirstOrDefault(j => j.Id == id);
                name.Text = item?.Name ?? Tr("跳板", "Jump host");
                jump.Text = item?.Host ?? "";
                identity.Text = item?.IdentityFile ?? "";
                break;
            case PathEdit.AddVpn:
                name.Text = "VPN";
                break;
            case PathEdit.AddJump:
                name.Text = Tr("跳板", "Jump host");
                identity.Text = "~/.ssh/id_ed25519";
                break;
            case PathEdit.AddTunnel:
                name.Text = Tr("新隧道", "New tunnel");
                var used = config.Forwards.Select(f => f.LocalPort).ToHashSet();
                var port = 9000;
                while (used.Contains(port)) port++;
                localPort.Text = port.ToString();
                targetPort.Text = "80";
                break;
            case PathEdit.RenameMachine:
                name.Text = config.MachineName;
                break;
            case PathEdit.RenameVpn(var id):
                name.Text = config.Vpns.FirstOrDefault(v => v.Id == id)?.Name ?? "VPN";
                break;
            case PathEdit.RenameJump(var id):
                name.Text = config.Jumps.FirstOrDefault(j => j.Id == id)?.Name ?? Tr("跳板", "Jump host");
                break;
            case PathEdit.EditForward(var id):
                if (config.Forwards.FirstOrDefault(f => f.Id == id) is { } forward)
                {
                    name.Text = forward.Name;
                    localPort.Text = forward.LocalPort.ToString();
                    targetHost.Text = forward.TargetHost;
                    targetPort.Text = forward.TargetPort.ToString();
                    openHost.Text = forward.OpenHost;
                }
                break;
        }
    }

    private static int Port(TextBox box) => int.TryParse(box.Text.Trim(), out var value) ? value : 0;

    private void Save()
    {
        try
        {
            var trimmed = name.Text.Trim();
            switch (kind)
            {
                case PathEdit.EditVpn(var id):
                    var file = model.Config.Vpns.FirstOrDefault(v => v.Id == id)?.CredentialFile ?? model.Config.CredentialFile;
                    model.SaveCredential(file, host.Text, user.Text, password.Password);
                    model.Save(With(model.Config.Clone(), c => c.Vpns.First(v => v.Id == id).Name = trimmed));
                    _ = model.RefreshAsync();
                    break;
                case PathEdit.AddVpn:
                    model.AddVpn(trimmed, host.Text, user.Text, password.Password);
                    break;
                case PathEdit.EditJump(var id):
                    model.Save(With(model.Config.Clone(), c =>
                    {
                        var item = c.Jumps.First(j => j.Id == id);
                        item.Name = trimmed;
                        item.Host = jump.Text.Trim();
                        item.IdentityFile = identity.Text.Trim();
                    }));
                    _ = model.RefreshAsync();
                    break;
                case PathEdit.AddJump(var vpnId):
                    model.AddJump(trimmed, jump.Text, identity.Text, vpnId);
                    break;
                case PathEdit.AddTunnel(var jumpId):
                    model.AddTunnel(trimmed, Port(localPort), targetHost.Text, Port(targetPort), openHost.Text, jumpId);
                    break;
                case PathEdit.EditForward(var id):
                    model.UpdateForward(id, trimmed, Port(localPort), targetHost.Text, Port(targetPort), openHost.Text);
                    break;
                case PathEdit.RenameMachine:
                    model.Save(With(model.Config.Clone(), c => c.MachineName = trimmed));
                    break;
                case PathEdit.RenameVpn(var id):
                    model.Save(With(model.Config.Clone(), c => c.Vpns.First(v => v.Id == id).Name = trimmed));
                    break;
                case PathEdit.RenameJump(var id):
                    model.Save(With(model.Config.Clone(), c => c.Jumps.First(j => j.Id == id).Name = trimmed));
                    break;
            }
            password.Clear();
            DialogResult = true;
        }
        catch (Exception error) when (error is ConfigException or CredentialException or IOException or InvalidOperationException)
        {
            note.Text = error.Message;
        }
    }

    private static AppConfig With(AppConfig config, Action<AppConfig> change)
    {
        change(config);
        return config;
    }
}

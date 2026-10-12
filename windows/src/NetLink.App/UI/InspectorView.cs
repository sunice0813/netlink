using System.Windows;
using System.Windows.Controls;
using NetLink.App.Platform;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App.UI;

/// 右侧检查器：选中节点的状态、开关、详情和操作。和 Mac 版 InspectorView 一样的分组。
public sealed class InspectorView : ScrollViewer
{
    private readonly AppModel model;
    private readonly Action<PathEdit> edit;
    private readonly Func<Window?> owner;
    private string signature = "";

    public InspectorView(AppModel model, Action<PathEdit> edit, Func<Window?> owner)
    {
        this.model = model;
        this.edit = edit;
        this.owner = owner;
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
    }

    /// 状态没变就不重建，免得下拉框、文字选择被 6 秒一次的刷新打断。
    public void Render(Selection? selection, bool force = false)
    {
        var next = Signature(selection);
        if (!force && next == signature) return;
        signature = next;
        var panel = new StackPanel { Margin = new Thickness(16) };
        foreach (var part in Build(selection)) Ui.AddSpaced(panel, part, 18);
        Content = panel;
    }

    private string Signature(Selection? selection)
    {
        var config = ConfigJson.Serialize(model.Config);
        return string.Join("|", selection?.ToString() ?? "-", L10n.IsChinese, config, model.Vpn, string.Join(",", model.Tunnel.Ports), model.Tunnel.SshRunning,
            string.Join(",", model.Tunnel.RunningJumpHosts), model.Tunnel.Watch, model.Job?.ToString() ?? "", Palette.IsDark);
    }

    private IEnumerable<UIElement> Build(Selection? selection)
    {
        var config = model.Config;
        switch (selection?.Kind)
        {
            case NodeKind.Machine:
                return Machine();
            case NodeKind.Vpn when config.Vpns.FirstOrDefault(v => v.Id == selection.Id) is { } profile:
                return Vpn(profile);
            case NodeKind.Jump when config.Jumps.FirstOrDefault(j => j.Id == selection.Id) is { } jump:
                return Jump(jump);
            case NodeKind.Forward when config.Forwards.FirstOrDefault(f => f.Id == selection.Id) is { } forward:
                return Forward(forward);
            default:
                return Empty();
        }
    }

    private IEnumerable<UIElement> Empty()
    {
        var intro = new StackPanel();
        var icon = Ui.Icon(Glyph.Pane, 22, Palette.Muted);
        icon.HorizontalAlignment = HorizontalAlignment.Left;
        intro.Children.Add(icon);
        Ui.AddSpaced(intro, Ui.Label(Tr("选择一个节点", "Select a node"), 15, FontWeights.SemiBold), 6);
        Ui.AddSpaced(intro, Ui.Label(Tr("在左侧列表或图上点一个节点，这里显示它的状态和操作。右键节点也能直接操作。", "Click a node in the list or on the map to see its status and actions here. You can also right-click a node."), 12, color: Palette.Muted, wrap: true), 6);
        yield return intro;
        var on = model.Config.Vpns.Count(model.IsOn);
        yield return Ui.Section(Tr("概览", "Overview"),
            Ui.InfoRow("VPN", $"{on}/{model.Config.Vpns.Count} " + Tr("已连接", "connected")),
            Ui.InfoRow(Tr("转发", "Forwards"), $"{model.Tunnel.OkCount}/{model.Config.Forwards.Count} " + Tr("通", "up")),
            Ui.InfoRow(Tr("自动重连", "Auto-reconnect"), model.AutoReconnectOn ? Tr("开", "On") : Tr("关", "Off")));
    }

    private IEnumerable<UIElement> Machine()
    {
        yield return Header(Selection.Machine, null, false);
        yield return Ui.Section(Tr("概览", "Overview"),
            Ui.InfoRow("VPN", model.Config.Vpns.Count.ToString()),
            Ui.InfoRow(Tr("跳板", "Jump hosts"), model.Config.Jumps.Count.ToString()),
            Ui.InfoRow(Tr("转发", "Forwards"), model.Config.Forwards.Count.ToString()));
        yield return Ui.Section(Tr("自动重连", "Auto-reconnect"),
            Ui.Switch(model.AutoReconnectOn, model.SetAutoReconnect, Tr("断线后自动重连 VPN 和隧道", "Reconnect the VPN and tunnels when they drop")));
        yield return Ui.Actions(
            Ui.IconButton(Glyph.Edit, Tr("改名", "Rename"), () => edit(new PathEdit.RenameMachine())),
            Ui.IconButton(Glyph.Add, Tr("添加 VPN", "Add VPN"), () => edit(new PathEdit.AddVpn())));
    }

    private IEnumerable<UIElement> Vpn(VpnProfile profile)
    {
        var on = model.IsOn(profile);
        var credential = Credentials.Load(profile.CredentialFile);
        var busy = model.Job?.Kind is JobKind.VpnConnect or JobKind.VpnDisconnect or JobKind.VpnRestart;
        yield return Header(new Selection(NodeKind.Vpn, profile.Id), value =>
        {
            if (value) model.ConnectVpnProfile(profile.Id);
            else model.DisconnectVpnProfile(profile.Id);
        }, busy, on);
        var details = new List<UIElement>
        {
            Ui.InfoRow(Tr("主机", "Host"), credential?.Host ?? Tr("未设置", "Not set"), mono: true),
            Ui.InfoRow(Tr("用户", "User"), credential?.User ?? "—"),
        };
        if (on)
        {
            details.Add(Ui.InfoRow(Tr("路由", "Route"), model.Vpn.RoutePresent ? Tr("已出现", "Present") : Tr("没有", "Missing"), tint: model.Vpn.RoutePresent ? Palette.Ok : Palette.Warn));
            details.Add(Ui.InfoRow(Tr("网关", "Gateway"), model.Vpn.GatewayReachable ? Tr("可达", "Reachable") : Tr("不可达", "Unreachable"), tint: model.Vpn.GatewayReachable ? Palette.Ok : Palette.Warn));
        }
        details.Add(Ui.InfoRow(Tr("后台服务", "Service"), model.Vpn.ServiceReachable ? Tr("在运行", "Running") : Tr("没在运行", "Not running"), tint: model.Vpn.ServiceReachable ? null : Palette.Bad));
        yield return Ui.Section(Tr("详情", "Details"), details.ToArray());
        if (ViaPicker(profile) is { } via) yield return via;
        yield return WatchSection(model.Vpn.Watch, isVpn: true);
        yield return Ui.Actions(
            Ui.IconButton(Glyph.Person, Tr("修改账号", "Edit Account"), () => edit(new PathEdit.EditVpn(profile.Id))),
            Ui.IconButton(Glyph.Refresh, Tr("重启", "Restart"), () => model.RestartVpnProfile(profile.Id)),
            Ui.IconButton(Glyph.Edit, Tr("改名", "Rename"), () => edit(new PathEdit.RenameVpn(profile.Id))),
            Ui.IconButton(Glyph.Add, Tr("添加跳板", "Add Jump Host"), () => edit(new PathEdit.AddJump(profile.Id))));
        if (model.Config.Vpns.Count > 1 && profile.Id != VpnProfile.Primary)
        {
            yield return Ui.Destructive(Tr("删除这个 VPN…", "Delete This VPN…"), () => model.RemoveVpn(profile.Id), owner());
        }
    }

    private IEnumerable<UIElement> Jump(Jump jump)
    {
        var on = model.IsOn(jump);
        var keyPath = PathExpander.Expand(jump.IdentityFile);
        var keyOk = File.Exists(keyPath);
        var tooOpen = keyOk && KeyAcl.TooOpen(keyPath);
        var busy = model.Job?.Kind is JobKind.TunnelConnect or JobKind.TunnelDisconnect or JobKind.TunnelRestart;
        yield return Header(new Selection(NodeKind.Jump, jump.Id), value =>
        {
            if (value) model.ConnectJump(jump.Id);
            else model.DisconnectJump(jump.Id);
        }, busy, on);
        var keyText = !keyOk ? Tr("找不到", "Missing") : tooOpen ? Tr("权限太宽", "Too open") : Tr("可读", "Readable");
        yield return Ui.Section(Tr("详情", "Details"),
            Ui.InfoRow(Tr("地址", "Address"), jump.Host.Length == 0 ? Tr("未设置", "Not set") : jump.Host, mono: true),
            Ui.InfoRow(Tr("私钥", "Key"), keyText, tint: !keyOk ? Palette.Bad : tooOpen ? Palette.Warn : null),
            Ui.InfoRow("ssh", on ? Tr("在跑", "Running") : Tr("没在跑", "Not running")));
        if (tooOpen)
        {
            yield return Ui.Column(6,
                Ui.Note(Tr("这把私钥别的用户也能读，Windows 的 ssh 会拒绝使用它。", "Other users can read this key, so Windows' ssh will refuse to use it.")),
                Ui.IconButton(Glyph.Shield, Tr("修复私钥权限", "Fix Key Permissions"), () => model.FixKeyPermissions(jump.Id)));
        }
        var behind = Ui.Picker(model.Config.Vpns.Select(v => (v.Id, v.Name)), jump.VpnId ?? VpnProfile.Primary, id => model.ReparentJump(jump.Id, id));
        yield return Ui.Section(Tr("挂在", "Behind"), behind, Ui.Note(Tr("跳板不通时，连接隧道会先连这个 VPN。", "If the jump host is unreachable, this VPN is connected first.")));
        yield return WatchSection(model.Tunnel.Watch, isVpn: false);
        yield return Ui.Actions(
            Ui.IconButton(Glyph.Server, Tr("修改跳板", "Edit Jump Host"), () => edit(new PathEdit.EditJump(jump.Id))),
            Ui.IconButton(Glyph.Refresh, Tr("重启", "Restart"), () => model.RestartJump(jump.Id)),
            Ui.IconButton(Glyph.Edit, Tr("改名", "Rename"), () => edit(new PathEdit.RenameJump(jump.Id))),
            Ui.IconButton(Glyph.Add, Tr("添加转发", "Add Forward"), () => edit(new PathEdit.AddTunnel(jump.Id))));
        if (model.Config.Jumps.Count > 1)
        {
            if (model.Config.ForwardsOn(jump.Id).Count == 0)
            {
                yield return Ui.Destructive(Tr("删除这台跳板…", "Delete This Jump Host…"), () => model.RemoveJump(jump.Id), owner());
            }
            else
            {
                yield return Ui.Note(Tr("要删除这台跳板，先删掉或移走它上面的转发。", "To delete this jump host, remove or move its forwards first."));
            }
        }
    }

    private IEnumerable<UIElement> Forward(Forward forward)
    {
        var port = model.StatusOf(forward);
        var on = port.HttpOk || port.Listening;
        var busy = model.Job is { Kind: JobKind.ForwardConnect or JobKind.ForwardDisconnect } job && job.Port == forward.LocalPort;
        yield return Header(new Selection(NodeKind.Forward, forward.Id), value =>
        {
            if (value) model.ConnectForward(forward.LocalPort);
            else model.DisconnectForward(forward.LocalPort);
        }, busy, on);
        yield return Ui.Section(Tr("详情", "Details"),
            Ui.InfoRow(Tr("本地", "Local"), $"127.0.0.1:{forward.LocalPort}", mono: true),
            Ui.InfoRow(Tr("目标", "Target"), forward.Target, mono: true),
            Ui.InfoRow(Tr("打开地址", "Opens"), forward.BrowseLabel, mono: true),
            Ui.InfoRow(Tr("检查方式", "Check"), forward.Check == ForwardCheck.Http ? "HTTP" : "TCP"));
        if (model.Config.Jumps.Count > 1)
        {
            var via = Ui.Picker(model.Config.Jumps.Select(j => (j.Id, j.Name)), forward.JumpId ?? Core.Jump.Primary, id => model.ReparentForward(forward.Id, id));
            yield return Ui.Section(Tr("经由", "Via"), via);
        }
        var actions = new List<UIElement>();
        if (on) actions.Add(Ui.IconButton(Glyph.Globe, Tr("在浏览器打开", "Open in Browser"), () => AppModel.Open(port.BrowseUrl)));
        actions.Add(Ui.IconButton(Glyph.Edit, Tr("编辑", "Edit"), () => edit(new PathEdit.EditForward(forward.Id))));
        yield return Ui.Actions(actions.ToArray());
        if (model.Config.Forwards.Count > 1)
        {
            yield return Ui.Destructive(Tr("删除这条转发…", "Delete This Forward…"), () => model.RemoveForward(forward.LocalPort), owner());
        }
    }

    // MARK: - 组件

    private UIElement Header(Selection selection, Action<bool>? toggle, bool busy, bool on = false)
    {
        var look = NodeLook.Of(selection, model)!;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Ui.Badge(look.Glyph, look.On ? look.Tint : Palette.Muted, 38));
        var text = new StackPanel { Margin = new Thickness(12, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Label(look.Title, 15, FontWeights.SemiBold));
        text.Children.Add(Ui.Label(look.Detail, 12, color: look.On ? look.Tint : Palette.Muted));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (busy)
        {
            var spinner = Ui.Spinner();
            Grid.SetColumn(spinner, 2);
            grid.Children.Add(spinner);
        }
        else if (toggle != null)
        {
            var box = Ui.Switch(on, toggle);
            box.ToolTip = on ? Tr("断开", "Disconnect") : Tr("连接", "Connect");
            Grid.SetColumn(box, 2);
            grid.Children.Add(box);
        }
        return grid;
    }

    private UIElement? ViaPicker(VpnProfile profile)
    {
        var config = model.Config;
        var options = config.Vpns.Where(o => o.Id != profile.Id && !config.UpstreamIds(o.Id).Contains(profile.Id)).ToList();
        if (options.Count == 0) return null;
        var choices = new List<(Guid?, string)> { (null, Tr("本机直接出去", "Directly from this computer")) };
        choices.AddRange(options.Select(o => ((Guid?)o.Id, o.Name)));
        var picker = Ui.Picker(choices, profile.ViaId, via => model.SetVpnVia(profile.Id, via));
        return Ui.Section(Tr("流量经过", "Traffic goes through"), picker, Ui.Note(Tr("只影响图和状态显示，不改连接。", "Only affects the map and status, not the connection.")));
    }

    private UIElement WatchSection(WatchdogOwner owner, bool isVpn)
    {
        var box = Ui.Switch(owner != WatchdogOwner.Off, on =>
        {
            if (isVpn) model.SetVpnWatch(on);
            else model.SetTunnelWatch(on);
        }, Tr("断线后自动重连", "Reconnect when it drops"));
        return Ui.Section(Tr("自动重连", "Auto-reconnect"), box);
    }
}

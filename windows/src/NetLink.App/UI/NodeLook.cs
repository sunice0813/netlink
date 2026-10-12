using System.Windows;
using System.Windows.Controls;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App.UI;

public enum NodeKind
{
    Machine,
    Vpn,
    Jump,
    Forward,
}

/// 侧边栏、拓扑图和检查器共用的选中项。
public sealed record Selection(NodeKind Kind, Guid Id = default)
{
    public static readonly Selection Machine = new(NodeKind.Machine);

    public string Key => Kind switch
    {
        NodeKind.Machine => TopologyKey.Machine,
        NodeKind.Vpn => TopologyKey.Vpn(Id),
        NodeKind.Jump => TopologyKey.Jump(Id),
        _ => TopologyKey.Forward(Id),
    };
}

/// 节点长什么样：图标、名字、状态文字和颜色。
public sealed record NodeLook(string Glyph, string Title, string Detail, string Tint, bool On)
{
    public static NodeLook? Of(Selection selection, AppModel model)
    {
        var config = model.Config;
        switch (selection.Kind)
        {
            case NodeKind.Machine:
                return new NodeLook(UI.Glyph.Laptop, config.MachineName, Tr("这台电脑", "This computer"), Palette.Text, true);
            case NodeKind.Vpn:
                if (config.Vpns.FirstOrDefault(v => v.Id == selection.Id) is not { } profile) return null;
                var on = model.IsOn(profile);
                var host = model.VpnHost(profile);
                var detail = on ? model.Vpn.Phase.Title() : host.Length == 0 ? Tr("未设置", "Not set") : host;
                var tint = !on ? Palette.Muted : model.Vpn.Phase == LinkPhase.Up ? Palette.Ok : Palette.Warn;
                return new NodeLook(UI.Glyph.Vpn, profile.Name, detail, tint, on);
            case NodeKind.Jump:
                if (config.Jumps.FirstOrDefault(j => j.Id == selection.Id) is not { } jump) return null;
                var jumpOn = model.IsOn(jump);
                return new NodeLook(UI.Glyph.Server, jump.Name, HostOnly(jump.Host), jumpOn ? Palette.Ok : Palette.Muted, jumpOn);
            default:
                if (config.Forwards.FirstOrDefault(f => f.Id == selection.Id) is not { } forward) return null;
                var port = model.StatusOf(forward);
                var state = port.HttpOk ? Tr("已连接", "connected") : port.Listening ? Tr("无响应", "no response") : Tr("未连接", "off");
                var forwardTint = port.HttpOk ? Palette.Ok : port.Listening ? Palette.Warn : Palette.Muted;
                return new NodeLook(ServiceGlyph(forward.Name), forward.Name, $":{forward.LocalPort} {state}", forwardTint, port.HttpOk);
        }
    }

    public static string HostOnly(string raw)
    {
        var host = raw.Split('@').LastOrDefault();
        if (!string.IsNullOrEmpty(host)) return host;
        return raw.Length == 0 ? Tr("未设置", "Not set") : raw;
    }

    public static string ServiceGlyph(string name)
    {
        var lower = name.ToLowerInvariant();
        if (lower.Contains("git")) return UI.Glyph.Code;
        if (lower.Contains("jump")) return UI.Glyph.Key;
        return UI.Glyph.Swap;
    }
}

/// 打开编辑框的请求。
public abstract record PathEdit
{
    public sealed record EditVpn(Guid Id) : PathEdit;
    public sealed record EditJump(Guid Id) : PathEdit;
    public sealed record AddVpn : PathEdit;
    public sealed record AddJump(Guid VpnId) : PathEdit;
    public sealed record AddTunnel(Guid JumpId) : PathEdit;
    public sealed record RenameMachine : PathEdit;
    public sealed record RenameVpn(Guid Id) : PathEdit;
    public sealed record RenameJump(Guid Id) : PathEdit;
    public sealed record EditForward(Guid Id) : PathEdit;
}

/// 右键菜单：图上的节点和侧边栏的行共用。
public static class NodeMenu
{
    public static ContextMenu Build(AppModel model, Selection selection, Action<PathEdit> edit)
    {
        var menu = new ContextMenu();
        void Add(string title, Action action)
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        var config = model.Config;
        switch (selection.Kind)
        {
            case NodeKind.Machine:
                Add(Tr("改名…", "Rename…"), () => edit(new PathEdit.RenameMachine()));
                Add(Tr("添加 VPN…", "Add VPN…"), () => edit(new PathEdit.AddVpn()));
                break;
            case NodeKind.Vpn when config.Vpns.FirstOrDefault(v => v.Id == selection.Id) is { } profile:
                if (model.IsOn(profile)) Add(Tr("断开", "Disconnect"), () => model.DisconnectVpnProfile(profile.Id));
                else Add(Tr("连接", "Connect"), () => model.ConnectVpnProfile(profile.Id));
                Add(Tr("重启", "Restart"), () => model.RestartVpnProfile(profile.Id));
                menu.Items.Add(new Separator());
                Add(Tr("修改账号…", "Edit Account…"), () => edit(new PathEdit.EditVpn(profile.Id)));
                Add(Tr("添加跳板…", "Add Jump Host…"), () => edit(new PathEdit.AddJump(profile.Id)));
                Add(Tr("改名…", "Rename…"), () => edit(new PathEdit.RenameVpn(profile.Id)));
                break;
            case NodeKind.Jump when config.Jumps.FirstOrDefault(j => j.Id == selection.Id) is { } jump:
                if (model.IsOn(jump)) Add(Tr("断开", "Disconnect"), () => model.DisconnectJump(jump.Id));
                else Add(Tr("连接", "Connect"), () => model.ConnectJump(jump.Id));
                Add(Tr("重启", "Restart"), () => model.RestartJump(jump.Id));
                menu.Items.Add(new Separator());
                Add(Tr("修改跳板…", "Edit Jump Host…"), () => edit(new PathEdit.EditJump(jump.Id)));
                Add(Tr("添加转发…", "Add Forward…"), () => edit(new PathEdit.AddTunnel(jump.Id)));
                Add(Tr("改名…", "Rename…"), () => edit(new PathEdit.RenameJump(jump.Id)));
                break;
            case NodeKind.Forward when config.Forwards.FirstOrDefault(f => f.Id == selection.Id) is { } forward:
                var port = model.StatusOf(forward);
                if (port.HttpOk || port.Listening)
                {
                    Add(Tr("断开", "Disconnect"), () => model.DisconnectForward(forward.LocalPort));
                    Add(Tr("在浏览器打开", "Open in Browser"), () => AppModel.Open(port.BrowseUrl));
                }
                else
                {
                    Add(Tr("连接", "Connect"), () => model.ConnectForward(forward.LocalPort));
                }
                menu.Items.Add(new Separator());
                Add(Tr("编辑…", "Edit…"), () => edit(new PathEdit.EditForward(forward.Id)));
                break;
        }
        return menu;
    }
}

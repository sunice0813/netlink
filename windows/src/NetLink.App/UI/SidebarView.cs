using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App.UI;

/// 左侧边栏：链路（本机、VPN、跳板）和转发两组，选中后右侧显示详情。
public sealed class SidebarView : DockPanel
{
    private readonly AppModel model;
    private readonly Func<Selection?> selection;
    private readonly Action<Selection?> select;
    private readonly Action<PathEdit> edit;
    private readonly StackPanel list = new() { Margin = new Thickness(8, 8, 8, 8) };
    private readonly Button addButton;
    private string signature = "";

    public SidebarView(AppModel model, Func<Selection?> selection, Action<Selection?> select, Action<PathEdit> edit)
    {
        this.model = model;
        this.selection = selection;
        this.select = select;
        this.edit = edit;
        this.Bg(Palette.Window);
        addButton = Ui.IconButton(Glyph.Add, Tr("添加", "Add"), ShowAddMenu, flat: true);
        addButton.Margin = new Thickness(8);
        addButton.HorizontalAlignment = HorizontalAlignment.Left;
        SetDock(addButton, Dock.Bottom);
        Children.Add(addButton);
        Children.Add(new ScrollViewer { Content = list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
    }

    public void Render(bool force = false)
    {
        var config = model.Config;
        var next = string.Join("|",
            selection()?.ToString() ?? "-",
            L10n.IsChinese,
            config.MachineName,
            string.Join(",", config.Vpns.Select(v => $"{v.Id}{v.Name}{model.IsOn(v)}")),
            string.Join(",", config.Jumps.Select(j => $"{j.Id}{j.Name}{j.Host}{model.IsOn(j)}")),
            string.Join(",", config.Forwards.Select(f => $"{f.Id}{f.Name}{f.LocalPort}{model.StatusOf(f)}")));
        if (!force && next == signature) return;
        signature = next;
        list.Children.Clear();
        ((TextBlock)((StackPanel)addButton.Content).Children[1]).Text = Tr("添加", "Add");
        list.Children.Add(Header(Tr("链路", "Path")));
        list.Children.Add(Row(Selection.Machine, null));
        foreach (var vpn in config.Vpns) list.Children.Add(Row(new Selection(NodeKind.Vpn, vpn.Id), null));
        foreach (var jump in config.Jumps) list.Children.Add(Row(new Selection(NodeKind.Jump, jump.Id), NodeLook.HostOnly(jump.Host)));
        var forwards = Header(Tr("转发", "Forwards"));
        forwards.Margin = new Thickness(8, 14, 0, 4);
        list.Children.Add(forwards);
        foreach (var forward in config.Forwards) list.Children.Add(Row(new Selection(NodeKind.Forward, forward.Id), $":{forward.LocalPort}"));
    }

    private static TextBlock Header(string title)
    {
        var header = Ui.Label(title, 11, FontWeights.SemiBold, Palette.Muted);
        header.Margin = new Thickness(8, 0, 0, 4);
        return header;
    }

    private UIElement Row(Selection item, string? trailing)
    {
        var look = NodeLook.Of(item, model);
        if (look == null) return new Border();
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var dot = Ui.Dot(look.On ? look.Tint : Palette.Muted, 8);
        if (!look.On) dot.Opacity = 0.5;
        grid.Children.Add(dot);
        var title = Ui.Label(look.Title, 13);
        title.Margin = new Thickness(8, 0, 6, 0);
        Grid.SetColumn(title, 1);
        grid.Children.Add(title);
        if (trailing != null)
        {
            var tail = Ui.Label(trailing, 11, color: Palette.Muted);
            tail.MaxWidth = 110;
            Grid.SetColumn(tail, 2);
            grid.Children.Add(tail);
        }
        var row = new Border
        {
            Child = grid,
            Padding = new Thickness(8, 6, 8, 6),
            CornerRadius = new CornerRadius(4),
            Cursor = Cursors.Hand,
            ContextMenu = NodeMenu.Build(model, item, edit),
        };
        var selected = item == selection();
        if (selected) row.Bg(Palette.Selected);
        row.MouseEnter += (_, _) => { if (!selected) row.Bg(Palette.Hover); };
        row.MouseLeave += (_, _) => { if (!selected) row.Background = null; };
        row.MouseLeftButtonUp += (_, _) => select(item);
        return row;
    }

    /// 新跳板挂在选中的 VPN 下，没选就挂主 VPN；新转发走选中的跳板，没选就走主跳板。
    private void ShowAddMenu()
    {
        var current = selection();
        var config = model.Config;
        var vpn = current?.Kind switch
        {
            NodeKind.Vpn => current.Id,
            NodeKind.Jump => config.Jumps.FirstOrDefault(j => j.Id == current.Id)?.VpnId ?? VpnProfile.Primary,
            _ => VpnProfile.Primary,
        };
        var jump = current?.Kind switch
        {
            NodeKind.Jump => current.Id,
            NodeKind.Forward => config.Forwards.FirstOrDefault(f => f.Id == current.Id)?.JumpId ?? Jump.Primary,
            _ => Jump.Primary,
        };
        var menu = new ContextMenu { PlacementTarget = addButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Top };
        void Add(string title, PathEdit request)
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => edit(request);
            menu.Items.Add(item);
        }
        Add(Tr("添加 VPN…", "Add VPN…"), new PathEdit.AddVpn());
        Add(Tr("添加跳板…", "Add Jump Host…"), new PathEdit.AddJump(vpn));
        Add(Tr("添加转发…", "Add Forward…"), new PathEdit.AddTunnel(jump));
        menu.IsOpen = true;
    }
}

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using NetLink.Core;

namespace NetLink.App.UI;

/// 拓扑图：本机、VPN、跳板、转发画成一张图，连通的一跳是绿色实线。节点可以拖动，位置会保存；
/// 把转发拖到别的跳板旁边就挂过去。和 Mac 版 TopologyCanvas 一样的几何。
public sealed class TopologyView : Grid
{
    private readonly AppModel model;
    private readonly Func<Selection?> selection;
    private readonly Action<Selection?> select;
    private readonly Action<PathEdit> edit;
    private readonly ScrollViewer scroller = new()
    {
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Focusable = false,
    };
    private readonly Canvas surface = new();
    private readonly Canvas wires = new() { IsHitTestVisible = false };
    private readonly Canvas nodes = new();
    private readonly ScaleTransform zoom = new(1, 1);

    private string? dragKey;
    private Point dragStart;
    private PointD dragOrigin;
    private Vector dragOffset;
    private bool didDrag;
    private Dictionary<string, PointD> placed = new();
    private string signature = "";

    public TopologyView(AppModel model, Func<Selection?> selection, Action<Selection?> select, Action<PathEdit> edit)
    {
        this.model = model;
        this.selection = selection;
        this.select = select;
        this.edit = edit;
        this.Bg(Palette.Canvas);
        surface.LayoutTransform = zoom;
        surface.Children.Add(wires);
        surface.Children.Add(nodes);
        surface.Background = DotGrid();
        surface.MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource == surface) select(null);
        };
        scroller.Content = surface;
        Children.Add(scroller);
        SizeChanged += (_, _) => Render();
        Palette.Changed += () =>
        {
            surface.Background = DotGrid();
            Render(force: true);
        };
    }

    /// 状态、选中项和大小都没变就不重画，免得右键菜单被 6 秒一次的刷新关掉。
    public void Render(bool force = false)
    {
        if (dragKey != null) return;
        var config = model.Config;
        var next = string.Join("|",
            ConfigJson.Serialize(config),
            selection()?.ToString() ?? "-",
            L10n.IsChinese,
            Palette.IsDark,
            ActualWidth,
            ActualHeight,
            model.Vpn.Phase,
            string.Join(",", config.Vpns.Select(model.IsOn)),
            string.Join(",", config.Jumps.Select(model.IsOn)),
            string.Join(",", config.Forwards.Select(model.StatusOf)));
        if (!force && next == signature) return;
        signature = next;
        placed = TopologyLayout.Resolved(config);
        var (width, height) = ContentSize(placed);
        var viewport = new Size(Math.Max(ActualWidth, 1), Math.Max(ActualHeight, 1));
        // 内容比可见区域大时整体缩小，最小 0.65；再放不下就滚动。
        var fit = Math.Min(viewport.Width / width, viewport.Height / height);
        var scale = Math.Min(1, Math.Max(0.65, fit));
        zoom.ScaleX = zoom.ScaleY = scale;
        surface.Width = Math.Max(width, viewport.Width / scale);
        surface.Height = Math.Max(height, viewport.Height / scale);
        DrawWires(placed);
        DrawNodes(placed);
    }

    private static (double, double) ContentSize(Dictionary<string, PointD> placed)
    {
        var maxX = placed.Values.Select(p => p.X).DefaultIfEmpty(0).Max();
        var maxY = placed.Values.Select(p => p.Y).DefaultIfEmpty(0).Max();
        return (maxX + TopologyMetrics.NodeWidth + 28, maxY + TopologyMetrics.NodeHeight + 28);
    }

    private Brush DotGrid()
    {
        var dot = new GeometryDrawing(Palette.Brush(Palette.Dot), null, new EllipseGeometry(new Point(9, 9), 0.8, 0.8));
        var tile = new DrawingGroup();
        tile.Children.Add(new GeometryDrawing(Brushes.Transparent, null, new RectangleGeometry(new Rect(0, 0, 18, 18))));
        tile.Children.Add(dot);
        var brush = new DrawingBrush(tile)
        {
            TileMode = TileMode.Tile,
            Viewport = new Rect(0, 0, 18, 18),
            ViewportUnits = BrushMappingMode.Absolute,
            Stretch = Stretch.None,
        };
        brush.Freeze();
        return brush;
    }

    // MARK: - 连线

    private void DrawWires(Dictionary<string, PointD> at)
    {
        wires.Children.Clear();
        var config = model.Config;
        var machine = at.GetValueOrDefault(TopologyKey.Machine, TopologyMetrics.Origin);
        var ids = config.Vpns.Select(v => v.Id).ToHashSet();
        var roots = config.Vpns.Where(v => v.ViaId is not { } via || !ids.Contains(via)).ToList();
        var visited = new HashSet<Guid>();

        void Emit(VpnProfile vpn)
        {
            if (!visited.Add(vpn.Id)) return;
            if (!at.TryGetValue(TopologyKey.Vpn(vpn.Id), out var origin)) return;
            var children = config.VpnsVia(vpn.Id).Where(c => !visited.Contains(c.Id)).ToList();
            var childBiases = TopologyMetrics.SideBiases(children.Select(c => at.GetValueOrDefault(TopologyKey.Vpn(c.Id))).ToList(), origin);
            for (var i = 0; i < children.Count; i++)
            {
                if (!at.TryGetValue(TopologyKey.Vpn(children[i].Id), out var childOrigin)) continue;
                Wire(TopologyMetrics.Link(origin, childOrigin, childBiases[i]), model.IsOn(vpn) && model.IsOn(children[i]));
                Emit(children[i]);
            }
            var jumps = config.JumpsOn(vpn.Id);
            var jumpBiases = TopologyMetrics.SideBiases(jumps.Select(j => at.GetValueOrDefault(TopologyKey.Jump(j.Id))).ToList(), origin);
            for (var j = 0; j < jumps.Count; j++)
            {
                if (!at.TryGetValue(TopologyKey.Jump(jumps[j].Id), out var jumpOrigin)) continue;
                Wire(TopologyMetrics.Link(origin, jumpOrigin, jumpBiases[j]), model.IsOn(jumps[j]));
                var forwards = config.ForwardsOn(jumps[j].Id);
                var forwardBiases = TopologyMetrics.SideBiases(forwards.Select(f => at.GetValueOrDefault(TopologyKey.Forward(f.Id))).ToList(), jumpOrigin);
                for (var f = 0; f < forwards.Count; f++)
                {
                    if (!at.TryGetValue(TopologyKey.Forward(forwards[f].Id), out var forwardOrigin)) continue;
                    Wire(TopologyMetrics.Link(jumpOrigin, forwardOrigin, forwardBiases[f]), model.StatusOf(forwards[f]).HttpOk);
                }
            }
        }

        var rootBiases = TopologyMetrics.SideBiases(roots.Select(r => at.GetValueOrDefault(TopologyKey.Vpn(r.Id))).ToList(), machine);
        for (var i = 0; i < roots.Count; i++)
        {
            if (!at.TryGetValue(TopologyKey.Vpn(roots[i].Id), out var origin)) continue;
            Wire(TopologyMetrics.Link(machine, origin, rootBiases[i]), model.IsOn(roots[i]));
            Emit(roots[i]);
        }
    }

    private void Wire(TopologyLink link, bool on)
    {
        var color = on ? Palette.Ok : Palette.Line;
        var from = new Point(link.From.X, link.From.Y);
        var to = new Point(link.To.X, link.To.Y);
        var span = (to - from).Length;
        var pull = Math.Max(28, Math.Min(72, span * 0.4));
        var c1 = TopologyMetrics.Pull(link.From, link.FromSide, pull);
        var c2 = TopologyMetrics.Pull(link.To, link.ToSide, pull);
        var angle = Math.Atan2(to.Y - c2.Y, to.X - c2.X);
        var tip = new Point(to.X - Math.Cos(angle) * 1.5, to.Y - Math.Sin(angle) * 1.5);

        var figure = new PathFigure { StartPoint = from };
        figure.Segments.Add(new BezierSegment(new Point(c1.X, c1.Y), new Point(c2.X, c2.Y), tip, true));
        var curve = new System.Windows.Shapes.Path
        {
            Data = new PathGeometry([figure]),
            StrokeThickness = on ? 2 : 1.5,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeDashArray = on ? null : [3, 3],
        };
        curve.SetResourceReference(Shape.StrokeProperty, color);
        wires.Children.Add(curve);

        const double length = 9, half = 4.5;
        var cos = Math.Cos(angle);
        var sin = Math.Sin(angle);
        var b = new Point(to.X - cos * length, to.Y - sin * length);
        var head = new Polygon
        {
            Points = [to, new Point(b.X + sin * half, b.Y - cos * half), new Point(b.X - sin * half, b.Y + cos * half)],
        };
        head.SetResourceReference(Shape.FillProperty, color);
        wires.Children.Add(head);
    }

    // MARK: - 节点

    private void DrawNodes(Dictionary<string, PointD> at)
    {
        nodes.Children.Clear();
        var config = model.Config;
        var items = new List<Selection> { Selection.Machine };
        items.AddRange(config.Vpns.Select(v => new Selection(NodeKind.Vpn, v.Id)));
        items.AddRange(config.Jumps.Select(j => new Selection(NodeKind.Jump, j.Id)));
        items.AddRange(config.Forwards.Select(f => new Selection(NodeKind.Forward, f.Id)));
        foreach (var item in items)
        {
            if (NodeLook.Of(item, model) is not { } look) continue;
            var origin = at.GetValueOrDefault(item.Key, TopologyMetrics.Origin);
            var node = Node(look, item == selection());
            Canvas.SetLeft(node, origin.X);
            Canvas.SetTop(node, origin.Y);
            node.Tag = item;
            node.ToolTip = look.Title;
            node.ContextMenu = NodeMenu.Build(model, item, edit);
            node.MouseLeftButtonDown += NodeDown;
            node.MouseMove += NodeMove;
            node.MouseLeftButtonUp += NodeUp;
            node.LostMouseCapture += (_, _) => EndDrag(commit: false);
            nodes.Children.Add(node);
        }
    }

    /// 横向小卡片：左边图标（角上压一个状态点），右边名字和状态。
    public static Border Node(NodeLook look, bool selected)
    {
        var grid = new Grid { Margin = new Thickness(12, 0, 8, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var badge = new Grid { VerticalAlignment = VerticalAlignment.Center };
        badge.Children.Add(Ui.Badge(look.Glyph, look.On ? look.Tint : Palette.Muted, 28));
        var dot = Ui.Dot(look.On ? look.Tint : Palette.Muted);
        dot.HorizontalAlignment = HorizontalAlignment.Right;
        dot.VerticalAlignment = VerticalAlignment.Bottom;
        dot.Margin = new Thickness(0, 0, -3, -3);
        if (!look.On) dot.Opacity = 0.6;
        badge.Children.Add(dot);
        grid.Children.Add(badge);
        var text = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Label(look.Title, 12.5, FontWeights.SemiBold));
        text.Children.Add(Ui.Label(look.Detail, 11, color: look.On ? look.Tint : Palette.Muted));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var card = new Border
        {
            Width = TopologyMetrics.NodeWidth,
            Height = TopologyMetrics.NodeHeight,
            CornerRadius = new CornerRadius(8),
            Child = grid,
            Cursor = Cursors.Hand,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 4, ShadowDepth = 1, Opacity = 0.08, Direction = 270 },
        };
        card.Bg(Palette.Card).Stroke(selected ? Palette.Accent : Palette.Line, selected ? 2 : 1);
        return card;
    }

    private void NodeDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: Selection item } node) return;
        dragKey = item.Key;
        dragStart = e.GetPosition(surface);
        dragOrigin = placed.GetValueOrDefault(item.Key, TopologyMetrics.Origin);
        dragOffset = default;
        didDrag = false;
        node.CaptureMouse();
        e.Handled = true;
    }

    private void NodeMove(object sender, MouseEventArgs e)
    {
        if (dragKey == null || sender is not Border { Tag: Selection item } node || item.Key != dragKey) return;
        var offset = e.GetPosition(surface) - dragStart;
        if (!didDrag && offset.Length < 5) return;
        didDrag = true;
        dragOffset = offset;
        var live = new PointD(dragOrigin.X + offset.X, dragOrigin.Y + offset.Y);
        Canvas.SetLeft(node, live.X);
        Canvas.SetTop(node, live.Y);
        Panel.SetZIndex(node, 10);
        node.Opacity = 0.9;
        var positions = new Dictionary<string, PointD>(placed) { [item.Key] = live };
        DrawWires(positions);
    }

    private void NodeUp(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Border { Tag: Selection item } node || item.Key != dragKey) return;
        var moved = didDrag;
        var target = new PointD(dragOrigin.X + dragOffset.X, dragOrigin.Y + dragOffset.Y);
        dragKey = null;
        node.ReleaseMouseCapture();
        if (moved) Commit(item, target);
        select(item);
        e.Handled = true;
    }

    private void EndDrag(bool commit)
    {
        if (dragKey == null) return;
        dragKey = null;
        if (!commit) Render(force: true);
    }

    private void Commit(Selection item, PointD origin)
    {
        model.UpdateLayout(item.Key, origin);
        var center = TopologyMetrics.Center(origin);
        var resolved = TopologyLayout.Resolved(model.Config);
        switch (item.Kind)
        {
            case NodeKind.Forward:
                var jump = model.Config.Jumps
                    .Select(j => (j, d: Distance(center, resolved.GetValueOrDefault(TopologyKey.Jump(j.Id)))))
                    .Where(p => p.d < 120).OrderBy(p => p.d).Select(p => p.j).FirstOrDefault();
                if (jump != null) model.ReparentForward(item.Id, jump.Id);
                break;
            case NodeKind.Jump:
                var vpn = model.Config.Vpns
                    .Select(v => (v, d: Distance(center, resolved.GetValueOrDefault(TopologyKey.Vpn(v.Id)))))
                    .Where(p => p.d < 140).OrderBy(p => p.d).Select(p => p.v).FirstOrDefault();
                if (vpn != null) model.ReparentJump(item.Id, vpn.Id);
                break;
        }
    }

    private static double Distance(PointD center, PointD origin)
    {
        var other = TopologyMetrics.Center(origin);
        return Math.Sqrt(Math.Pow(center.X - other.X, 2) + Math.Pow(center.Y - other.Y, 2));
    }
}

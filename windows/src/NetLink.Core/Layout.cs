namespace NetLink.Core;

public enum TopologySide
{
    Left,
    Right,
    Top,
    Bottom,
}

public readonly record struct TopologyLink(PointD From, PointD To, TopologySide FromSide, TopologySide ToSide);

/// 拓扑图的尺寸和连线几何，和 Mac 版 TopologyMetrics 相同，两边存下来的位置可以互用。
public static class TopologyMetrics
{
    public const double NodeWidth = 160;
    public const double NodeHeight = 54;
    public const double ColumnGap = 44;
    public const double RowGap = 16;
    public const double Inset = 12;
    public static readonly PointD Origin = new(28, 28);

    public static PointD Center(PointD origin) => new(origin.X + NodeWidth / 2, origin.Y + NodeHeight / 2);

    /// 按两个节点中心的相对位置选出口和入口，上下左右都会用到。
    public static TopologyLink Link(PointD a, PointD b, double fromBias = 0, double toBias = 0)
    {
        var ca = Center(a);
        var cb = Center(b);
        var dx = cb.X - ca.X;
        var dy = cb.Y - ca.Y;
        TopologySide fromSide, toSide;
        if (Math.Abs(dx) >= Math.Abs(dy))
        {
            fromSide = dx >= 0 ? TopologySide.Right : TopologySide.Left;
            toSide = dx >= 0 ? TopologySide.Left : TopologySide.Right;
        }
        else
        {
            fromSide = dy >= 0 ? TopologySide.Bottom : TopologySide.Top;
            toSide = dy >= 0 ? TopologySide.Top : TopologySide.Bottom;
        }
        return new TopologyLink(Port(a, fromSide, fromBias), Port(b, toSide, toBias), fromSide, toSide);
    }

    public static PointD Port(PointD origin, TopologySide side, double bias = 0)
    {
        var midX = origin.X + NodeWidth / 2;
        var midY = origin.Y + NodeHeight / 2;
        var minX = origin.X + Inset;
        var maxX = origin.X + NodeWidth - Inset;
        var minY = origin.Y + Inset;
        var maxY = origin.Y + NodeHeight - Inset;
        return side switch
        {
            TopologySide.Left => new PointD(origin.X, Math.Clamp(midY + bias, minY, maxY)),
            TopologySide.Right => new PointD(origin.X + NodeWidth, Math.Clamp(midY + bias, minY, maxY)),
            TopologySide.Top => new PointD(Math.Clamp(midX + bias, minX, maxX), origin.Y),
            _ => new PointD(Math.Clamp(midX + bias, minX, maxX), origin.Y + NodeHeight),
        };
    }

    public static PointD Pull(PointD point, TopologySide side, double distance) => side switch
    {
        TopologySide.Left => new PointD(point.X - distance, point.Y),
        TopologySide.Right => new PointD(point.X + distance, point.Y),
        TopologySide.Top => new PointD(point.X, point.Y - distance),
        _ => new PointD(point.X, point.Y + distance),
    };

    /// 同一侧多个子节点时，沿边错开附着点，避免线叠在一起。
    public static double[] SideBiases(IReadOnlyList<PointD> children, PointD parent)
    {
        var biases = new double[children.Count];
        if (children.Count <= 1) return biases;
        var pc = Center(parent);
        var ranked = children.Select((point, index) => (point, index)).ToList();
        ranked.Sort((left, right) =>
        {
            var a = Center(left.point);
            var b = Center(right.point);
            var dxA = Math.Abs(a.X - pc.X);
            var dyA = Math.Abs(a.Y - pc.Y);
            var dxB = Math.Abs(b.X - pc.X);
            var dyB = Math.Abs(b.Y - pc.Y);
            if (dyA > dxA && dyB > dxB) return a.X.CompareTo(b.X);
            return a.Y.CompareTo(b.Y);
        });
        const double step = 28;
        var start = -step * (children.Count - 1) / 2;
        for (var rank = 0; rank < ranked.Count; rank++)
        {
            biases[ranked[rank].index] = start + step * rank;
        }
        return biases;
    }
}

public static class TopologyLayout
{
    private sealed record JumpBlock(Guid Id, double Height, List<Guid> Forwards);

    private sealed record VpnBlock(Guid Id, double Height, double Span, bool HasJumps, List<VpnBlock> Children, List<JumpBlock> Jumps);

    /// 从左到右：本机、（上游 VPN）、VPN、跳板、隧道。有隧道的 VPN 放在中间，父节点相对子节点垂直居中。
    public static Dictionary<string, PointD> Default(AppConfig config)
    {
        const double nodeH = TopologyMetrics.NodeHeight;
        const double rowGap = TopologyMetrics.RowGap;
        const double step = TopologyMetrics.NodeWidth + TopologyMetrics.ColumnGap;
        double Column(int index) => TopologyMetrics.Origin.X + index * step;
        double StackHeight(int count) => count <= 0 ? 0 : count * nodeH + (count - 1) * rowGap;
        var placed = new Dictionary<string, PointD>();
        var seen = new HashSet<Guid>();

        VpnBlock Build(VpnProfile vpn)
        {
            seen.Add(vpn.Id);
            var children = new List<VpnBlock>();
            foreach (var child in config.Vpns.Where(v => v.ViaId == vpn.Id).ToList())
            {
                if (!seen.Contains(child.Id)) children.Add(Build(child));
            }
            var jumpBlocks = config.JumpsOn(vpn.Id).Select(jump =>
            {
                var list = config.ForwardsOn(jump.Id);
                var height = list.Count == 0 ? nodeH : Math.Max(nodeH, StackHeight(list.Count));
                return new JumpBlock(jump.Id, height, list.Select(f => f.Id).ToList());
            }).ToList();
            var heights = children.Select(c => c.Height).Concat(jumpBlocks.Select(j => j.Height)).ToList();
            var span = heights.Count == 0 ? 0 : heights.Sum() + (heights.Count - 1) * rowGap;
            return new VpnBlock(vpn.Id, Math.Max(nodeH, span), span, jumpBlocks.Count > 0 || children.Any(c => c.HasJumps), children, jumpBlocks);
        }

        var ids = config.Vpns.Select(v => v.Id).ToHashSet();
        var roots = config.Vpns.Where(v => v.ViaId is not { } via || !ids.Contains(via)).ToList();
        var built = roots.Select(Build).ToList();
        foreach (var vpn in config.Vpns.Where(v => !seen.Contains(v.Id)).ToList())
        {
            built.Add(Build(vpn));
        }
        var linked = built.Where(b => b.HasJumps).ToList();
        var alone = built.Where(b => !b.HasJumps).ToList();
        var head = alone.Count / 2;
        var blocks = alone.Take(head).Concat(linked).Concat(alone.Skip(head)).ToList();

        void Place(VpnBlock block, int depth, double top)
        {
            placed[TopologyKey.Vpn(block.Id)] = new PointD(Column(depth + 1), top + (block.Height - nodeH) / 2);
            var cursor = top + (block.Height - block.Span) / 2;
            foreach (var child in block.Children)
            {
                Place(child, depth + 1, cursor);
                cursor += child.Height + rowGap;
            }
            foreach (var jump in block.Jumps)
            {
                placed[TopologyKey.Jump(jump.Id)] = new PointD(Column(depth + 2), cursor + (jump.Height - nodeH) / 2);
                var forwardCursor = cursor + (jump.Height - StackHeight(jump.Forwards.Count)) / 2;
                foreach (var id in jump.Forwards)
                {
                    placed[TopologyKey.Forward(id)] = new PointD(Column(depth + 3), forwardCursor);
                    forwardCursor += nodeH + rowGap;
                }
                cursor += jump.Height + rowGap;
            }
        }

        var total = blocks.Count == 0 ? nodeH : blocks.Sum(b => b.Height) + Math.Max(blocks.Count - 1, 0) * rowGap;
        var top = TopologyMetrics.Origin.Y;
        foreach (var block in blocks)
        {
            Place(block, 0, top);
            top += block.Height + rowGap;
        }
        placed[TopologyKey.Machine] = new PointD(Column(0), TopologyMetrics.Origin.Y + Math.Max(0, (total - nodeH) / 2));

        var spill = top;
        foreach (var jump in config.Jumps.Where(j => !placed.ContainsKey(TopologyKey.Jump(j.Id))))
        {
            placed[TopologyKey.Jump(jump.Id)] = new PointD(Column(2), spill);
            spill += nodeH + rowGap;
        }
        foreach (var forward in config.Forwards.Where(f => !placed.ContainsKey(TopologyKey.Forward(f.Id))))
        {
            placed[TopologyKey.Forward(forward.Id)] = new PointD(Column(3), spill);
            spill += nodeH + rowGap;
        }
        return placed;
    }

    public static Dictionary<string, PointD> Resolved(AppConfig config)
    {
        var placed = Default(config);
        foreach (var (key, point) in config.Layout) placed[key] = point;
        return placed;
    }

    /// 新节点放在父节点右边一列，和已有节点错开。
    public static void PlaceNew(AppConfig config, string key, string parent, int column)
    {
        var placed = Resolved(config);
        const double step = TopologyMetrics.NodeWidth + TopologyMetrics.ColumnGap;
        var hasParent = placed.TryGetValue(parent, out var parentOrigin);
        if (!hasParent) parentOrigin = TopologyMetrics.Origin;
        var x = hasParent ? parentOrigin.X + step : TopologyMetrics.Origin.X + column * step;
        var y = parentOrigin.Y;
        var occupied = placed.Values.Where(p => Math.Abs(p.X - x) < 40).Select(p => p.Y).ToList();
        while (occupied.Any(o => Math.Abs(o - y) < TopologyMetrics.NodeHeight))
        {
            y += TopologyMetrics.NodeHeight + TopologyMetrics.RowGap;
        }
        config.Layout[key] = new PointD(x, y);
    }
}

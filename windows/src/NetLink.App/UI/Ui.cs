using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App.UI;

/// Segoe Fluent Icons / Segoe MDL2 Assets 里的字形，两套字体都有。
public static class Glyph
{
    public const string Refresh = "";
    public const string Settings = "";
    public const string Document = "";
    public const string Import = "";
    public const string Add = "";
    public const string Edit = "";
    public const string Delete = "";
    public const string Power = "";
    public const string Globe = "";
    public const string Person = "";
    public const string Laptop = "";
    public const string Vpn = "";
    public const string Server = "";
    public const string Swap = "";
    public const string Code = "";
    public const string Key = "";
    public const string Pane = "";
    public const string Warning = "";
    public const string Folder = "";
    public const string Shield = "";
}

/// 代码里搭界面的小工具。颜色一律用 SetResourceReference 指向 Palette 的键，切换深浅色时自动更新。
public static class Ui
{
    public static T Fg<T>(this T element, string key) where T : FrameworkElement
    {
        switch (element)
        {
            case TextBlock text: text.SetResourceReference(TextBlock.ForegroundProperty, key); break;
            case Control control: control.SetResourceReference(Control.ForegroundProperty, key); break;
        }
        return element;
    }

    public static T Bg<T>(this T element, string key) where T : FrameworkElement
    {
        switch (element)
        {
            case Border border: border.SetResourceReference(Border.BackgroundProperty, key); break;
            case Panel panel: panel.SetResourceReference(Panel.BackgroundProperty, key); break;
            case Control control: control.SetResourceReference(Control.BackgroundProperty, key); break;
        }
        return element;
    }

    public static Border Stroke(this Border border, string key, double thickness = 1)
    {
        border.SetResourceReference(Border.BorderBrushProperty, key);
        border.BorderThickness = new Thickness(thickness);
        return border;
    }

    public static TextBlock Label(string text, double size = 12, FontWeight? weight = null, string color = Palette.Text, bool wrap = false)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = weight ?? FontWeights.Normal,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        return block.Fg(color);
    }

    public static TextBlock Note(string text) => Label(text, 11, color: Palette.Muted, wrap: true);

    public static TextBlock Icon(string glyph, double size = 14, string color = Palette.Text)
    {
        var block = new TextBlock
        {
            Text = glyph,
            FontSize = size,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        block.SetResourceReference(TextBlock.FontFamilyProperty, "NL.Icons");
        return block.Fg(color);
    }

    public static Border Divider(Thickness? margin = null)
    {
        var line = new Border { Height = 1, Margin = margin ?? new Thickness(0) };
        return line.Bg(Palette.Line);
    }

    public static StackPanel Row(double spacing, params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        for (var i = 0; i < children.Length; i++)
        {
            if (i > 0 && children[i] is FrameworkElement element)
            {
                element.Margin = new Thickness(spacing, element.Margin.Top, element.Margin.Right, element.Margin.Bottom);
            }
            panel.Children.Add(children[i]);
        }
        return panel;
    }

    public static StackPanel Column(double spacing, params UIElement[] children)
    {
        var panel = new StackPanel();
        foreach (var child in children) AddSpaced(panel, child, spacing);
        return panel;
    }

    public static void AddSpaced(StackPanel panel, UIElement child, double spacing)
    {
        if (panel.Children.Count > 0 && child is FrameworkElement element)
        {
            var margin = element.Margin;
            element.Margin = new Thickness(margin.Left, margin.Top + spacing, margin.Right, margin.Bottom);
        }
        panel.Children.Add(child);
    }

    /// 图标加文字的按钮（检查器里的操作、工具栏）。
    public static Button IconButton(string glyph, string text, Action action, bool flat = false, string? tooltip = null)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(Icon(glyph, 13));
        if (text.Length > 0)
        {
            var label = Label(text);
            label.Margin = new Thickness(6, 0, 0, 0);
            content.Children.Add(label);
        }
        var button = new Button
        {
            Content = content,
            ToolTip = tooltip,
            Padding = new Thickness(10, 5, 10, 5),
            HorizontalContentAlignment = HorizontalAlignment.Center,
        };
        if (flat) button.SetResourceReference(FrameworkElement.StyleProperty, "NL.Flat");
        button.Click += (_, _) => action();
        return button;
    }

    public static Button TextButton(string text, Action action, bool primary = false)
    {
        var button = new Button { Content = text, Padding = new Thickness(14, 5, 14, 5), MinWidth = 72 };
        if (primary)
        {
            button.IsDefault = true;
            button.SetResourceReference(FrameworkElement.StyleProperty, "AccentButtonStyle");
        }
        button.Click += (_, _) => action();
        return button;
    }

    /// 拨动开关。改变时才回调（初始值不触发）。
    public static CheckBox Switch(bool on, Action<bool> changed, string? text = null)
    {
        var box = new CheckBox { IsChecked = on, VerticalAlignment = VerticalAlignment.Center };
        box.SetResourceReference(FrameworkElement.StyleProperty, "NL.Switch");
        if (text != null) box.Content = Label(text, wrap: true);
        box.Click += (_, _) => changed(box.IsChecked == true);
        return box;
    }

    public static ProgressBar Spinner(double width = 40) =>
        new() { IsIndeterminate = true, Width = width, Height = 4, VerticalAlignment = VerticalAlignment.Center };

    /// 状态小圆点，外面一圈卡片底色描边，压在图标角上也看得清。
    public static Border Dot(string color, double size = 9)
    {
        var dot = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size / 2) };
        dot.Bg(color).Stroke(Palette.Card, 1.5);
        return dot;
    }

    /// 节点图标：圆角方块，底色是状态色的淡色，中间一个字形。
    public static Grid Badge(string glyph, string tint, double side)
    {
        var grid = new Grid { Width = side, Height = side };
        var back = new Border { CornerRadius = new CornerRadius(side * 0.22) };
        back.Bg(tint);
        back.Opacity = 0.14;
        var frame = new Border { CornerRadius = new CornerRadius(side * 0.22) };
        frame.Stroke(Palette.Line);
        grid.Children.Add(back);
        grid.Children.Add(frame);
        grid.Children.Add(Icon(glyph, side * 0.45, tint));
        return grid;
    }

    public static TextBox Field(string text, string placeholder = "")
    {
        var box = new TextBox { Text = text, Padding = new Thickness(6, 4, 6, 4), ToolTip = placeholder.Length > 0 ? placeholder : null };
        return box;
    }

    /// 一组：小标题加内容。
    public static StackPanel Section(string title, params UIElement[] content)
    {
        var panel = new StackPanel();
        panel.Children.Add(Label(title, 11, FontWeights.SemiBold, Palette.Muted));
        foreach (var child in content) AddSpaced(panel, child, 6);
        return panel;
    }

    /// 一行「名称 —— 值」。值可以选中复制。
    public static Grid InfoRow(string label, string value, bool mono = false, string? tint = null)
    {
        var grid = new Grid { Margin = new Thickness(0, 1, 0, 1) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var name = Label(label, color: Palette.Muted);
        var text = new TextBox
        {
            Text = value,
            IsReadOnly = true,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Padding = new Thickness(0),
            FontSize = 12,
            HorizontalContentAlignment = HorizontalAlignment.Right,
            TextAlignment = TextAlignment.Right,
            Margin = new Thickness(12, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            MinHeight = 0,
            Cursor = System.Windows.Input.Cursors.IBeam,
        };
        // 只读文本框在 Fluent 主题下仍会画边框和底色，换成最简单的模板。
        text.Template = PlainTextBoxTemplate();
        text.Fg(tint ?? Palette.Text);
        if (mono) text.SetResourceReference(Control.FontFamilyProperty, "NL.Mono");
        Grid.SetColumn(text, 1);
        grid.Children.Add(name);
        grid.Children.Add(text);
        return grid;
    }

    private static ControlTemplate? plainTemplate;

    private static ControlTemplate PlainTextBoxTemplate()
    {
        if (plainTemplate != null) return plainTemplate;
        var template = new ControlTemplate(typeof(TextBox));
        var host = new FrameworkElementFactory(typeof(ScrollViewer)) { Name = "PART_ContentHost" };
        host.SetValue(ScrollViewer.HorizontalScrollBarVisibilityProperty, ScrollBarVisibility.Hidden);
        host.SetValue(ScrollViewer.VerticalScrollBarVisibilityProperty, ScrollBarVisibility.Hidden);
        host.SetValue(Control.PaddingProperty, new Thickness(0));
        template.VisualTree = host;
        template.Seal();
        plainTemplate = template;
        return template;
    }

    /// 两列排的操作按钮。
    public static UniformGrid Actions(params UIElement[] buttons)
    {
        var grid = new UniformGrid { Columns = 2 };
        foreach (var button in buttons)
        {
            if (button is FrameworkElement element) element.Margin = new Thickness(0, 0, 6, 6);
            grid.Children.Add(button);
        }
        return grid;
    }

    /// 删除类操作：红字，点了先确认一次。
    public static Button Destructive(string title, Action action, Window? owner)
    {
        var button = new Button { Content = Label(title, color: Palette.Bad), HorizontalAlignment = HorizontalAlignment.Left };
        button.SetResourceReference(FrameworkElement.StyleProperty, "NL.Link");
        button.Click += (_, _) =>
        {
            var answer = owner != null
                ? MessageBox.Show(owner, Tr("删除后要重新添加才能恢复。", "You'll need to add it again to restore it."), title, MessageBoxButton.OKCancel, MessageBoxImage.Warning)
                : MessageBox.Show(Tr("删除后要重新添加才能恢复。", "You'll need to add it again to restore it."), title, MessageBoxButton.OKCancel, MessageBoxImage.Warning);
            if (answer == MessageBoxResult.OK) action();
        };
        return button;
    }

    public static ComboBox Picker<T>(IEnumerable<(T Value, string Title)> options, T selected, Action<T> changed)
    {
        var combo = new ComboBox { MinWidth = 160, HorizontalAlignment = HorizontalAlignment.Stretch };
        var list = options.ToList();
        foreach (var option in list) combo.Items.Add(new ComboBoxItem { Content = option.Title, Tag = option.Value });
        combo.SelectedIndex = Math.Max(0, list.FindIndex(o => EqualityComparer<T>.Default.Equals(o.Value, selected)));
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is ComboBoxItem { Tag: T value }) changed(value);
            else if (combo.SelectedItem is ComboBoxItem { Tag: null } && default(T) == null) changed(default!);
        };
        return combo;
    }
}

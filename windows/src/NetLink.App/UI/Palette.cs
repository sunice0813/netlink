using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using NetLink.Core;

namespace NetLink.App.UI;

/// 浅色 / 深色两套颜色，写进应用资源；界面上的元素都用 DynamicResource 引用，切换时立刻跟着变。
/// 标准控件用 WPF 的 Fluent 主题（和 Windows 11 设置一个样子）。
public static class Palette
{
    public const string Text = "NL.Text";
    public const string Muted = "NL.Muted";
    public const string Line = "NL.Line";
    public const string Card = "NL.Card";
    public const string Window = "NL.Window";
    public const string Canvas = "NL.Canvas";
    public const string Dot = "NL.Dot";
    public const string Accent = "NL.Accent";
    public const string Ok = "NL.Ok";
    public const string Warn = "NL.Warn";
    public const string Bad = "NL.Bad";
    public const string WarnBack = "NL.WarnBack";
    public const string Hover = "NL.Hover";
    public const string Selected = "NL.Selected";
    public const string SwitchOff = "NL.SwitchOff";

    public static bool IsDark { get; private set; }

    public static event Action? Changed;

    private static bool hooked;

    public static void Apply()
    {
        var app = Application.Current;
        if (app == null) return;
        var choice = AppSettings.Current.AppearanceChoice;
        IsDark = choice switch
        {
            AppearanceChoice.Dark => true,
            AppearanceChoice.Light => false,
            _ => SystemPrefersDark(),
        };
        app.ThemeMode = choice switch
        {
            AppearanceChoice.Dark => ThemeMode.Dark,
            AppearanceChoice.Light => ThemeMode.Light,
            _ => ThemeMode.System,
        };
        var accent = SystemAccent() ?? (IsDark ? Color.FromRgb(0x4C, 0xC2, 0xFF) : Color.FromRgb(0x00, 0x67, 0xC0));
        if (IsDark)
        {
            accent = Lighten(accent);
        }
        var colors = IsDark
            ? new Dictionary<string, Color>
            {
                [Text] = Rgb(0xFFFFFF),
                [Muted] = Rgb(0xA8A8A8),
                [Line] = Rgb(0x3D3D3D),
                [Card] = Rgb(0x2C2C2C),
                [Window] = Rgb(0x202020),
                [Canvas] = Rgb(0x1A1A1A),
                [Dot] = Rgb(0x383838),
                [Ok] = Rgb(0x6CCB5F),
                [Warn] = Rgb(0xFCB040),
                [Bad] = Rgb(0xFF99A4),
                [WarnBack] = Rgb(0x433519),
                [Hover] = Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF),
                [Selected] = Color.FromArgb(0x28, 0xFF, 0xFF, 0xFF),
                [SwitchOff] = Rgb(0x9E9E9E),
            }
            : new Dictionary<string, Color>
            {
                [Text] = Rgb(0x1B1B1B),
                [Muted] = Rgb(0x616161),
                [Line] = Rgb(0xE0E0E0),
                [Card] = Rgb(0xFFFFFF),
                [Window] = Rgb(0xF3F3F3),
                [Canvas] = Rgb(0xF9F9F9),
                [Dot] = Rgb(0xD6D6D6),
                [Ok] = Rgb(0x0F7B0F),
                [Warn] = Rgb(0x9D5D00),
                [Bad] = Rgb(0xC42B1C),
                [WarnBack] = Rgb(0xFFF4CE),
                [Hover] = Color.FromArgb(0x0F, 0, 0, 0),
                [Selected] = Color.FromArgb(0x1A, 0, 0, 0),
                [SwitchOff] = Rgb(0x8A8A8A),
            };
        colors[Accent] = accent;
        foreach (var (key, color) in colors)
        {
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            app.Resources[key] = brush;
        }
        if (!hooked)
        {
            hooked = true;
            SystemEvents.UserPreferenceChanged += (_, e) =>
            {
                if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle)
                {
                    app.Dispatcher.InvokeAsync(Apply);
                }
            };
        }
        Changed?.Invoke();
    }

    public static Brush Brush(string key) => (Application.Current?.Resources[key] as Brush) ?? Brushes.Gray;

    /// 应用（不是任务栏）用深色：Personalize\AppsUseLightTheme = 0。
    private static bool SystemPrefersDark()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
    }

    /// 任务栏用深色：SystemUsesLightTheme = 0。托盘图标按它选黑白。
    public static bool TaskbarDark()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is not int value || value == 0;
    }

    private static Color? SystemAccent()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\DWM");
        if (key?.GetValue("AccentColor") is not int raw) return null;
        var abgr = unchecked((uint)raw);
        return Color.FromRgb((byte)(abgr & 0xFF), (byte)((abgr >> 8) & 0xFF), (byte)((abgr >> 16) & 0xFF));
    }

    private static Color Lighten(Color color)
    {
        static byte Up(byte channel) => (byte)Math.Min(255, channel + (255 - channel) * 0.35);
        return Color.FromRgb(Up(color.R), Up(color.G), Up(color.B));
    }

    private static Color Rgb(int hex) => Color.FromRgb((byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);
}

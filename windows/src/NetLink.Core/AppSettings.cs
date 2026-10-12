using System.Text.Json;

namespace NetLink.Core;

public enum AppearanceChoice
{
    System,
    Light,
    Dark,
}

/// 应用级偏好，存在 %APPDATA%\NetLink\settings.json。对应 Mac 版放在 UserDefaults 里的几项。
public sealed class AppSettings
{
    public string Language { get; set; } = "system";
    public string Appearance { get; set; } = "system";
    public bool VpnAutoReconnect { get; set; } = true;
    public bool TunnelAutoReconnect { get; set; } = true;

    private static readonly object Gate = new();
    private static AppSettings? current;

    public static AppSettings Current
    {
        get
        {
            lock (Gate) return current ??= Load();
        }
    }

    public AppearanceChoice AppearanceChoice => Appearance switch
    {
        "light" => AppearanceChoice.Light,
        "dark" => AppearanceChoice.Dark,
        _ => AppearanceChoice.System,
    };

    public static AppSettings Load()
    {
        try
        {
            var text = File.ReadAllText(AppPaths.SettingsFile);
            return JsonSerializer.Deserialize<AppSettings>(text, ServiceProtocol.Json) ?? new AppSettings();
        }
        catch
        {
            return new AppSettings();
        }
    }

    public static void Update(Action<AppSettings> change)
    {
        lock (Gate)
        {
            var settings = current ??= Load();
            change(settings);
            try
            {
                AppPaths.EnsureDirectory();
                File.WriteAllText(AppPaths.SettingsFile, JsonSerializer.Serialize(settings, new JsonSerializerOptions(ServiceProtocol.Json) { WriteIndented = true }));
            }
            catch
            {
                // 偏好写不进去不影响连接，下次启动按默认值来。
            }
        }
    }
}

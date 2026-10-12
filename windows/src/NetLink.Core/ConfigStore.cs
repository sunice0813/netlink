using System.Text;
using static NetLink.Core.Text;

namespace NetLink.Core;

public sealed class ConfigException(string message) : Exception(message);

/// 配置文件的读写。后台操作和界面都会读改写配置，写入互斥。
public static class ConfigStore
{
    private static readonly object WriteLock = new();

    /// 文件在，但解不出来。这时 Load() 给的是默认值，不能拿它去覆盖原文件，也不该拿它去连接。
    public static bool IsCorrupt => File.Exists(AppPaths.ConfigFile) && LoadIfValid() == null;

    public static AppConfig Load()
    {
        AppPaths.EnsureDirectory();
        if (!File.Exists(AppPaths.ConfigFile))
        {
            var config = new AppConfig();
            try { Save(config); } catch { }
            return config;
        }
        return LoadIfValid() ?? new AppConfig();
    }

    public static AppConfig? LoadIfValid()
    {
        try
        {
            var text = File.ReadAllText(AppPaths.ConfigFile, Encoding.UTF8);
            return ConfigJson.Decode(text);
        }
        catch
        {
            return null;
        }
    }

    /// 原文件解不出来时默认拒绝写入。用户在界面里明确点保存才允许覆盖，并先留一份备份。
    public static void Save(AppConfig config, bool overwriteCorrupt = false)
    {
        lock (WriteLock)
        {
            AppPaths.EnsureDirectory();
            if (IsCorrupt)
            {
                if (!overwriteCorrupt)
                {
                    throw new ConfigException(Tr("配置文件读不了，已保留原文件。先修好它，或在应用里点保存覆盖（会先备份成 config.json.bak）", "Can't read the config file; the original is kept. Fix it, or click Save in the app to overwrite it (a backup is saved as config.json.bak first)"));
                }
                File.Copy(AppPaths.ConfigFile, AppPaths.ConfigBackup, overwrite: true);
            }
            var temp = AppPaths.ConfigFile + ".tmp";
            File.WriteAllText(temp, ConfigJson.Serialize(config) + "\n", new UTF8Encoding(false));
            File.Move(temp, AppPaths.ConfigFile, overwrite: true);
        }
    }

    /// 读最新的、改、写，整个过程互斥。后台操作改配置都走这里，不要自己 Load 再 Save。
    public static bool Mutate(Action<AppConfig> body)
    {
        lock (WriteLock)
        {
            if (IsCorrupt) return false;
            var config = Load();
            body(config);
            try
            {
                Save(config);
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    public static void BackupCurrent()
    {
        if (!File.Exists(AppPaths.ConfigFile)) return;
        try { File.Copy(AppPaths.ConfigFile, AppPaths.ConfigBackup, overwrite: true); } catch { }
    }
}

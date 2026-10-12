using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using static NetLink.Core.Text;

namespace NetLink.Core;

/// 随配置一起带走的机密：VPN 账号（按 VPN 的 id）和 SSH 私钥内容（按跳板的 id）。
public sealed class ImportedSecrets
{
    public Dictionary<Guid, VpnCredential> Credentials { get; } = new();
    public Dictionary<Guid, string> Keys { get; } = new();
    public bool IsEmpty => Credentials.Count == 0 && Keys.Count == 0;
}

public sealed class ImportPreview
{
    public required AppConfig Config { get; init; }
    public required List<string> Issues { get; init; }
    public required ImportedSecrets Secrets { get; init; }
    /// 配置里指向的凭据文件在这台机器上不存在，而文件里也没带账号：导入后要重新填。
    public required List<string> MissingCredentials { get; init; }
    /// Windows 版不支持、导入时去掉的系统 VPN（Shadowrocket、FortiClient）。
    public required List<string> DroppedVpns { get; init; }

    public string Summary
    {
        get
        {
            var text = Tr(
                $"{Config.Vpns.Count} 个 VPN · {Config.Jumps.Count} 台跳板 · {Config.Forwards.Count} 条转发",
                $"{Config.Vpns.Count} VPN · {Config.Jumps.Count} jump hosts · {Config.Forwards.Count} forwards");
            if (!Secrets.IsEmpty)
            {
                text += Tr(
                    $" · 含 {Secrets.Credentials.Count} 个账号、{Secrets.Keys.Count} 把私钥",
                    $" · includes {Secrets.Credentials.Count} accounts, {Secrets.Keys.Count} private keys");
            }
            return text;
        }
    }
}

/// 配置的导出和导入，规则和 Mac 版 ConfigTransfer 一样，文件两边通用。
///
/// 导出时可以把 VPN 账号的内容和 SSH 私钥的内容直接写进文件，换一台机器导入就能用。
/// 这样的文件里是明文密码和私钥，要当密码一样保管。
///
/// 导入时机密不会写回文件里写的路径（那是任意路径），而是存进应用自己的数据目录，再把配置里的路径指过去。
public static class ConfigTransfer
{
    private static readonly HashSet<string> KnownKeys = ["forwards", "jumps", "vpns", "jumpHost", "credentialFile", "routeMarker", "pingHost"];
    private const int MaxKeyBytes = 64 * 1024;

    public static byte[] Export(AppConfig config, bool includeSecrets = false)
    {
        var root = ConfigJson.Encode(config);

        if (root["vpns"] is JsonArray vpns)
        {
            foreach (var node in vpns.OfType<JsonObject>())
            {
                var path = node["credentialFile"]?.GetValue<string>();
                if (path == null) continue;
                if (includeSecrets && path.Length > 0 && Credentials.Load(path) is { } credential)
                {
                    node["credential"] = new JsonObject
                    {
                        ["host"] = credential.Host,
                        ["password"] = credential.Password,
                        ["user"] = credential.User,
                    };
                    node.Remove("credentialFile");
                }
                else
                {
                    node["credentialFile"] = PathExpander.Portable(path);
                }
            }
        }

        if (root["jumps"] is JsonArray jumps)
        {
            foreach (var node in jumps.OfType<JsonObject>())
            {
                var path = node["identityFile"]?.GetValue<string>();
                if (path == null) continue;
                var key = includeSecrets && path.Length > 0 ? ReadKey(path) : null;
                if (key != null)
                {
                    node["identity"] = key;
                    node.Remove("identityFile");
                }
                else
                {
                    node["identityFile"] = PathExpander.Portable(path);
                }
            }
        }

        // 顶层这两项只是主 VPN / 主跳板的镜像，导入时会从它们那里重新算出来。
        foreach (var key in new[] { "credentialFile", "identityFile" })
        {
            if (includeSecrets)
            {
                root.Remove(key);
            }
            else if (root[key]?.GetValue<string>() is { } value)
            {
                root[key] = PathExpander.Portable(value);
            }
        }
        return Encoding.UTF8.GetBytes(SortKeys(root).ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    private static string? ReadKey(string path)
    {
        try
        {
            var expanded = PathExpander.Expand(path);
            var info = new FileInfo(expanded);
            if (!info.Exists || info.Length > MaxKeyBytes) return null;
            var key = File.ReadAllText(expanded, Encoding.UTF8);
            return key.Contains("PRIVATE KEY", StringComparison.Ordinal) ? key : null;
        }
        catch
        {
            return null;
        }
    }

    private static JsonNode SortKeys(JsonNode node)
    {
        switch (node)
        {
            case JsonObject obj:
                var sorted = new JsonObject();
                foreach (var (key, value) in obj.OrderBy(p => p.Key, StringComparer.Ordinal).ToList())
                {
                    obj.Remove(key);
                    sorted[key] = value == null ? null : SortKeys(value);
                }
                return sorted;
            case JsonArray array:
                var items = array.ToList();
                array.Clear();
                var copy = new JsonArray();
                foreach (var item in items) copy.Add(item == null ? null : SortKeys(item));
                return copy;
            default:
                return node;
        }
    }

    public static void Write(AppConfig config, string path, bool includeSecrets)
    {
        var data = Export(config, includeSecrets);
        if (includeSecrets)
        {
            Credentials.WritePrivate(path, data);
        }
        else
        {
            File.WriteAllBytes(path, data);
        }
    }

    /// 配置的解码对缺字段很宽容（`{}` 也能解出一份默认值），所以先确认它确实像 NetLink 的配置。
    public static ImportPreview Parse(byte[] data)
    {
        JsonObject root;
        try
        {
            root = JsonNode.Parse(data) as JsonObject ?? throw new FormatException();
        }
        catch
        {
            throw new ConfigException(Tr("这不是 NetLink 的配置文件", "This isn't a NetLink config file"));
        }
        if (!root.Select(p => p.Key).Any(KnownKeys.Contains))
        {
            throw new ConfigException(Tr("这不是 NetLink 的配置文件", "This isn't a NetLink config file"));
        }

        var secrets = new ImportedSecrets();
        var problems = new List<string>();

        if (root["vpns"] is JsonArray vpns)
        {
            foreach (var node in vpns.OfType<JsonObject>())
            {
                if (node["credential"] is not JsonObject embedded) continue;
                node.Remove("credential");
                var name = TryString(node["name"]) ?? "VPN";
                if (!Guid.TryParse(TryString(node["id"]), out var id))
                {
                    problems.Add(Tr($"{name} 的账号没有有效的 id", $"The account of {name} has no valid id"));
                    continue;
                }
                var host = TryString(embedded["host"]) ?? "";
                var user = TryString(embedded["user"]) ?? "";
                var password = TryString(embedded["password"]) ?? "";
                if (host.Length == 0 || user.Length == 0 || password.Length == 0)
                {
                    problems.Add(Tr($"{name} 的账号不完整", $"The account of {name} is incomplete"));
                }
                else if (new[] { host, user, password }.Any(v => v.Contains('\n') || v.Contains('\r')))
                {
                    problems.Add(Tr($"{name} 的账号里有换行", $"The account of {name} contains a line break"));
                }
                else
                {
                    secrets.Credentials[id] = new VpnCredential(host, user, password);
                }
            }
        }

        if (root["jumps"] is JsonArray jumps)
        {
            foreach (var node in jumps.OfType<JsonObject>())
            {
                if (node["identity"] is not JsonNode keyNode) continue;
                node.Remove("identity");
                var name = TryString(node["name"]) ?? Tr("跳板", "Jump host");
                if (!Guid.TryParse(TryString(node["id"]), out var id))
                {
                    problems.Add(Tr($"{name} 的私钥没有有效的 id", $"The private key of {name} has no valid id"));
                    continue;
                }
                var key = TryString(keyNode) ?? "";
                if (!key.Contains("PRIVATE KEY", StringComparison.Ordinal) || Encoding.UTF8.GetByteCount(key) > MaxKeyBytes)
                {
                    problems.Add(Tr($"{name} 的私钥格式不对", $"The private key of {name} is malformed"));
                }
                else
                {
                    secrets.Keys[id] = key;
                }
            }
        }

        AppConfig config;
        List<string> dropped;
        try
        {
            using var document = JsonDocument.Parse(root.ToJsonString());
            // 先看有哪些系统 VPN 会被去掉，好在预览里说出来。
            dropped = document.RootElement.TryGetProperty("vpns", out var list) && list.ValueKind == JsonValueKind.Array
                ? list.EnumerateArray()
                    .Where(v => v.ValueKind == JsonValueKind.Object && (ConfigJson.Str(v, "kind") ?? "openconnect") != "openconnect")
                    .Select(v => ConfigJson.Str(v, "name") ?? "VPN")
                    .ToList()
                : [];
            config = ConfigJson.Decode(document.RootElement);
        }
        catch (Exception error)
        {
            throw new ConfigException(Tr($"读不了这个文件：{error.Message}", $"Can't read this file: {error.Message}"));
        }

        var missing = config.Vpns
            .Where(v => !secrets.Credentials.ContainsKey(v.Id))
            .Where(v => v.CredentialFile.Length == 0 || !File.Exists(PathExpander.Expand(v.CredentialFile)))
            .Select(v => v.Name)
            .ToList();

        // 带了机密的条目，路径会在导入时指到应用的数据目录，这里只校验其他部分。
        var checkedConfig = config.Clone();
        foreach (var vpn in checkedConfig.Vpns.Where(v => secrets.Credentials.ContainsKey(v.Id)))
        {
            vpn.CredentialFile = "~/.netlink-imported";
        }
        foreach (var jump in checkedConfig.Jumps.Where(j => secrets.Keys.ContainsKey(j.Id)))
        {
            jump.IdentityFile = "~/.netlink-imported";
        }
        checkedConfig.Normalize();

        return new ImportPreview
        {
            Config = config,
            Issues = problems.Concat(ConfigCheck.Issues(checkedConfig)).ToList(),
            Secrets = secrets,
            MissingCredentials = missing,
            DroppedVpns = dropped,
        };
    }

    /// 把带来的机密落到 `directory/imported/` 下，并把配置里的路径指过去。返回可以保存的配置。
    public static AppConfig Materialize(ImportPreview preview, string? directory = null)
    {
        var root = directory ?? AppPaths.Directory;
        var config = preview.Config.Clone();
        var credentials = Path.Combine(root, "imported", "credentials");
        var keys = Path.Combine(root, "imported", "keys");
        foreach (var vpn in config.Vpns)
        {
            if (!preview.Secrets.Credentials.TryGetValue(vpn.Id, out var credential)) continue;
            var path = Path.Combine(credentials, Ids.Format(vpn.Id));
            Credentials.Update(path, credential.Host, credential.User, credential.Password);
            vpn.CredentialFile = path;
        }
        foreach (var jump in config.Jumps)
        {
            if (!preview.Secrets.Keys.TryGetValue(jump.Id, out var key)) continue;
            var path = Path.Combine(keys, Ids.Format(jump.Id));
            // OpenSSH 要求私钥以换行结尾；Windows 上统一成 \n，ssh.exe 两种都认。
            var text = key.Replace("\r\n", "\n");
            if (!text.EndsWith('\n')) text += "\n";
            Credentials.WritePrivate(path, Encoding.UTF8.GetBytes(text));
            jump.IdentityFile = path;
        }
        config.Normalize();
        return config;
    }

    private static string? TryString(JsonNode? node)
    {
        try
        {
            return node?.GetValue<string>();
        }
        catch
        {
            return null;
        }
    }
}

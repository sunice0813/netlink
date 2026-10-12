using System.Text.Json;
using System.Text.Json.Nodes;
using static NetLink.Core.Text;

namespace NetLink.Core;

/// config.json 的读写，规则照 Mac 版的 Codable：缺的字段用默认值，类型不对整个文件算读不了。
/// 写出时键按字母排序，和 Mac 版的 JSONEncoder(.sortedKeys) 一样。
public static class ConfigJson
{
    private static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true };

    public static AppConfig Decode(string json)
    {
        using var document = JsonDocument.Parse(json);
        return Decode(document.RootElement);
    }

    public static AppConfig Decode(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) throw new FormatException("config must be an object");
        var defaults = new AppConfig();
        var config = new AppConfig
        {
            CredentialFile = Str(root, "credentialFile") ?? defaults.CredentialFile,
            VpnPidFile = Str(root, "vpnPidFile") ?? defaults.VpnPidFile,
            VpnLogFile = Str(root, "vpnLogFile") ?? defaults.VpnLogFile,
            VpnWatchdogFile = Str(root, "vpnWatchdogFile") ?? defaults.VpnWatchdogFile,
            RouteMarker = Str(root, "routeMarker") ?? defaults.RouteMarker,
            PingHost = Str(root, "pingHost") ?? defaults.PingHost,
            ReconnectTimeout = Int(root, "reconnectTimeout") ?? defaults.ReconnectTimeout,
            VpnWatchdogInterval = Int(root, "vpnWatchdogInterval") ?? defaults.VpnWatchdogInterval,
            VpnFailThreshold = Int(root, "vpnFailThreshold") ?? defaults.VpnFailThreshold,
            JumpHost = Str(root, "jumpHost") ?? defaults.JumpHost,
            IdentityFile = Str(root, "identityFile") ?? defaults.IdentityFile,
            TunnelLogFile = Str(root, "tunnelLogFile") ?? defaults.TunnelLogFile,
            TunnelWatchdogFile = Str(root, "tunnelWatchdogFile") ?? defaults.TunnelWatchdogFile,
            TunnelWatchdogInterval = Int(root, "tunnelWatchdogInterval") ?? defaults.TunnelWatchdogInterval,
            TunnelFailThreshold = Int(root, "tunnelFailThreshold") ?? defaults.TunnelFailThreshold,
            Forwards = Array(root, "forwards")?.Select(DecodeForward).ToList() ?? defaults.Forwards,
            Jumps = Array(root, "jumps")?.Select(DecodeJump).ToList() ?? [],
            Vpns = Array(root, "vpns")?.Select(DecodeVpn).ToList() ?? [],
            MachineName = L10n.LocalizedDefault(Str(root, "machineName") ?? defaults.MachineName),
            Layout = DecodeLayout(root),
            LayoutVersion = Int(root, "layoutVersion") ?? 0,
            OpenconnectPath = Str(root, "openconnectPath") ?? defaults.OpenconnectPath,
            AutosshPath = Str(root, "autosshPath") ?? defaults.AutosshPath,
            SshPath = Str(root, "sshPath") ?? defaults.SshPath,
        };
        config.Normalize();
        return config;
    }

    public static Forward DecodeForward(JsonElement item)
    {
        RequireObject(item);
        return new Forward
        {
            Id = Uuid(item, "id") ?? Guid.NewGuid(),
            Name = L10n.LocalizedDefault(Str(item, "name") ?? Tr("转发", "Forward")),
            LocalPort = Int(item, "localPort") ?? 0,
            TargetHost = Str(item, "targetHost") ?? "",
            TargetPort = Int(item, "targetPort") ?? 0,
            OpenHost = (Str(item, "openHost") ?? "").Trim(),
            Enabled = Bool(item, "enabled") ?? true,
            JumpId = Uuid(item, "jumpID"),
            Check = Str(item, "check") switch
            {
                null or "http" => ForwardCheck.Http,
                "tcp" => ForwardCheck.Tcp,
                var other => throw new FormatException($"unknown check {other}"),
            },
        };
    }

    public static Jump DecodeJump(JsonElement item)
    {
        RequireObject(item);
        return new Jump
        {
            Id = Uuid(item, "id") ?? Guid.NewGuid(),
            Name = L10n.LocalizedDefault(Str(item, "name") ?? Tr("跳板", "Jump host")),
            Host = Str(item, "host") ?? "",
            IdentityFile = Str(item, "identityFile") ?? "",
            VpnId = Uuid(item, "vpnID"),
        };
    }

    public static VpnProfile DecodeVpn(JsonElement item)
    {
        RequireObject(item);
        return new VpnProfile
        {
            Id = Uuid(item, "id") ?? Guid.NewGuid(),
            Name = Str(item, "name") ?? "VPN",
            CredentialFile = Str(item, "credentialFile") ?? "",
            Kind = Str(item, "kind") ?? "openconnect",
            ServiceName = Str(item, "serviceName") ?? "",
            ViaId = Uuid(item, "viaID"),
        };
    }

    private static Dictionary<string, PointD> DecodeLayout(JsonElement root)
    {
        var layout = new Dictionary<string, PointD>();
        if (!root.TryGetProperty("layout", out var node) || node.ValueKind == JsonValueKind.Null) return layout;
        RequireObject(node);
        foreach (var entry in node.EnumerateObject())
        {
            RequireObject(entry.Value);
            var x = Number(entry.Value, "x") ?? throw new FormatException("layout x");
            var y = Number(entry.Value, "y") ?? throw new FormatException("layout y");
            layout[entry.Name] = new PointD(x, y);
        }
        return layout;
    }

    public static JsonObject Encode(AppConfig config)
    {
        var root = new SortedDictionary<string, JsonNode?>(StringComparer.Ordinal)
        {
            ["credentialFile"] = config.CredentialFile,
            ["vpnPidFile"] = config.VpnPidFile,
            ["vpnLogFile"] = config.VpnLogFile,
            ["vpnWatchdogFile"] = config.VpnWatchdogFile,
            ["routeMarker"] = config.RouteMarker,
            ["pingHost"] = config.PingHost,
            ["reconnectTimeout"] = config.ReconnectTimeout,
            ["vpnWatchdogInterval"] = config.VpnWatchdogInterval,
            ["vpnFailThreshold"] = config.VpnFailThreshold,
            ["jumpHost"] = config.JumpHost,
            ["identityFile"] = config.IdentityFile,
            ["tunnelLogFile"] = config.TunnelLogFile,
            ["tunnelWatchdogFile"] = config.TunnelWatchdogFile,
            ["tunnelWatchdogInterval"] = config.TunnelWatchdogInterval,
            ["tunnelFailThreshold"] = config.TunnelFailThreshold,
            ["forwards"] = new JsonArray(config.Forwards.Select(f => (JsonNode)EncodeForward(f)).ToArray()),
            ["jumps"] = new JsonArray(config.Jumps.Select(j => (JsonNode)EncodeJump(j)).ToArray()),
            ["vpns"] = new JsonArray(config.Vpns.Select(v => (JsonNode)EncodeVpn(v)).ToArray()),
            ["machineName"] = config.MachineName,
            ["layout"] = EncodeLayout(config.Layout),
            ["layoutVersion"] = config.LayoutVersion,
            ["openconnectPath"] = config.OpenconnectPath,
            ["autosshPath"] = config.AutosshPath,
            ["sshPath"] = config.SshPath,
        };
        return Sorted(root);
    }

    private static JsonObject EncodeForward(Forward forward)
    {
        var map = new SortedDictionary<string, JsonNode?>(StringComparer.Ordinal)
        {
            ["id"] = Ids.Format(forward.Id),
            ["name"] = forward.Name,
            ["localPort"] = forward.LocalPort,
            ["targetHost"] = forward.TargetHost,
            ["targetPort"] = forward.TargetPort,
            ["openHost"] = forward.OpenHost,
            ["enabled"] = forward.Enabled,
            ["check"] = forward.Check == ForwardCheck.Tcp ? "tcp" : "http",
        };
        if (forward.JumpId is { } jump) map["jumpID"] = Ids.Format(jump);
        return Sorted(map);
    }

    private static JsonObject EncodeJump(Jump jump)
    {
        var map = new SortedDictionary<string, JsonNode?>(StringComparer.Ordinal)
        {
            ["id"] = Ids.Format(jump.Id),
            ["name"] = jump.Name,
            ["host"] = jump.Host,
            ["identityFile"] = jump.IdentityFile,
        };
        if (jump.VpnId is { } vpn) map["vpnID"] = Ids.Format(vpn);
        return Sorted(map);
    }

    private static JsonObject EncodeVpn(VpnProfile vpn)
    {
        var map = new SortedDictionary<string, JsonNode?>(StringComparer.Ordinal)
        {
            ["id"] = Ids.Format(vpn.Id),
            ["name"] = vpn.Name,
            ["credentialFile"] = vpn.CredentialFile,
            ["kind"] = vpn.Kind,
            ["serviceName"] = vpn.ServiceName,
        };
        if (vpn.ViaId is { } via) map["viaID"] = Ids.Format(via);
        return Sorted(map);
    }

    private static JsonObject EncodeLayout(Dictionary<string, PointD> layout)
    {
        var map = new SortedDictionary<string, JsonNode?>(StringComparer.Ordinal);
        foreach (var (key, point) in layout)
        {
            map[key] = new JsonObject { ["x"] = point.X, ["y"] = point.Y };
        }
        return Sorted(map);
    }

    private static JsonObject Sorted(SortedDictionary<string, JsonNode?> map)
    {
        var obj = new JsonObject();
        foreach (var (key, value) in map) obj[key] = value;
        return obj;
    }

    public static string Serialize(JsonNode node) => node.ToJsonString(Pretty);

    public static string Serialize(AppConfig config) => Serialize(Encode(config));

    // MARK: - 宽容地读、严格地校验类型

    private static void RequireObject(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object) throw new FormatException("expected an object");
    }

    private static bool TryGet(JsonElement obj, string key, out JsonElement value)
    {
        if (obj.TryGetProperty(key, out value) && value.ValueKind != JsonValueKind.Null) return true;
        value = default;
        return false;
    }

    internal static string? Str(JsonElement obj, string key)
    {
        if (!TryGet(obj, key, out var value)) return null;
        if (value.ValueKind != JsonValueKind.String) throw new FormatException($"{key} must be a string");
        return value.GetString();
    }

    internal static int? Int(JsonElement obj, string key)
    {
        if (!TryGet(obj, key, out var value)) return null;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var number))
        {
            throw new FormatException($"{key} must be an integer");
        }
        return number;
    }

    private static double? Number(JsonElement obj, string key)
    {
        if (!TryGet(obj, key, out var value)) return null;
        if (value.ValueKind != JsonValueKind.Number) throw new FormatException($"{key} must be a number");
        return value.GetDouble();
    }

    private static bool? Bool(JsonElement obj, string key)
    {
        if (!TryGet(obj, key, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw new FormatException($"{key} must be a boolean"),
        };
    }

    internal static Guid? Uuid(JsonElement obj, string key)
    {
        var text = Str(obj, key);
        if (text == null) return null;
        if (!Guid.TryParseExact(text, "D", out var id)) throw new FormatException($"{key} must be a UUID");
        return id;
    }

    private static IEnumerable<JsonElement>? Array(JsonElement obj, string key)
    {
        if (!TryGet(obj, key, out var value)) return null;
        if (value.ValueKind != JsonValueKind.Array) throw new FormatException($"{key} must be an array");
        return value.EnumerateArray().ToList();
    }
}

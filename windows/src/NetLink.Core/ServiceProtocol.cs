using System.Text.Json;
using System.Text.Json.Serialization;

namespace NetLink.Core;

/// 应用和后台服务之间的协议：命名管道上一行一个 JSON。
/// 服务以 SYSTEM 身份运行，所以它只做一件事：用自己目录里的 openconnect 连、断公司 VPN。
/// 程序路径、日志路径都由服务自己决定，不接受应用传进来的路径。
public static class ServiceProtocol
{
    public const string PipeName = "NetLink.Service";
    public const string ServiceName = "NetLinkService";
    public const int Version = 1;

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// 主机、用户名会拼进 openconnect 的参数，挡住以 - 开头、带空白或换行的值。
    public static string? Validate(ServiceRequest request)
    {
        switch (request.Op)
        {
            case "status":
            case "disconnect":
            case "log":
                return null;
            case "connect":
                if (string.IsNullOrWhiteSpace(request.Host) || request.Host.StartsWith('-') || request.Host.Any(char.IsWhiteSpace))
                {
                    return "bad host";
                }
                if (string.IsNullOrWhiteSpace(request.User) || request.User.StartsWith('-') || request.User.Any(c => c is '\r' or '\n'))
                {
                    return "bad user";
                }
                if (string.IsNullOrEmpty(request.Password) || request.Password.Any(c => c is '\r' or '\n'))
                {
                    return "bad password";
                }
                if (request.ReconnectTimeout is < 0 or > 86400) return "bad timeout";
                return null;
            default:
                return "unknown op";
        }
    }
}

public sealed class ServiceRequest
{
    public string Op { get; set; } = "";
    public string? Host { get; set; }
    public string? User { get; set; }
    public string? Password { get; set; }
    public int ReconnectTimeout { get; set; } = 30;
    public int Lines { get; set; } = 40;
}

public sealed class ServiceResponse
{
    public bool Ok { get; set; }
    public string? Error { get; set; }
    public int Version { get; set; } = ServiceProtocol.Version;
    /// openconnect 在不在跑。
    public bool Running { get; set; }
    public int? Pid { get; set; }
    /// 正在连的主机（连接请求里的 host）。
    public string? Host { get; set; }
    public DateTimeOffset? StartedAt { get; set; }
    /// 安装目录里有没有 openconnect.exe。
    public bool OpenconnectInstalled { get; set; }
    public string? Log { get; set; }
}

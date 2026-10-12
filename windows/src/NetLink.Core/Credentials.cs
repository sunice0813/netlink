using System.Text;
using static NetLink.Core.Text;

namespace NetLink.Core;

public sealed record VpnCredential(string Host, string User, string Password);

/// 把机密加密存盘。Windows 上是 DPAPI（只有当前用户能解开），测试里是原样。
public interface ISecretProtector
{
    byte[] Protect(byte[] plain);
    byte[] Unprotect(byte[] sealedBytes);
}

/// 写完私密文件之后收紧权限：Windows 上只留当前用户（OpenSSH 也要求私钥这样），别的系统上是 600。
public interface IPrivateFiles
{
    void Restrict(string path);
}

public sealed class PlainProtector : ISecretProtector
{
    public byte[] Protect(byte[] plain) => plain;
    public byte[] Unprotect(byte[] sealedBytes) => sealedBytes;
}

public sealed class UnixPrivateFiles : IPrivateFiles
{
    public void Restrict(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }
}

public sealed class CredentialException(string message) : Exception(message);

/// VPN 账号文件，格式和 Mac 版一样：host= / user= / password= 三行。
/// Windows 版写盘时整份用 DPAPI 加密，读的时候两种都认（手写的明文文件也能用）。
public static class Credentials
{
    private const string SealedPrefix = "NLDPAPI1:";
    private const int MaxBytes = 64 * 1024;

    public static ISecretProtector Protector { get; set; } = new PlainProtector();
    public static IPrivateFiles PrivateFiles { get; set; } = new UnixPrivateFiles();

    public static VpnCredential? Parse(string text)
    {
        string host = "", user = "";
        string? password = null;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.TrimEnd('\r').Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var index = line.IndexOf('=');
            if (index < 0) continue;
            var key = line[..index].Trim();
            // 和 Mac 版一样：整行先去掉首尾空白，密码中间的空格保留。
            var value = line[(index + 1)..];
            switch (key)
            {
                case "host": host = value.Trim(); break;
                case "user": user = value.Trim(); break;
                case "password": password = value; break;
            }
        }
        if (host.Length == 0 || user.Length == 0 || string.IsNullOrEmpty(password)) return null;
        return new VpnCredential(host, user, password);
    }

    public static string Format(VpnCredential credential) =>
        $"host={credential.Host}\nuser={credential.User}\npassword={credential.Password}\n";

    public static VpnCredential? Load(string file)
    {
        if (string.IsNullOrWhiteSpace(file)) return null;
        var text = ReadSecretText(PathExpander.Expand(file));
        return text == null ? null : Parse(text);
    }

    /// 读私密文件：加过密的先解开，没加密的原样返回。
    public static string? ReadSecretText(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > MaxBytes * 2) return null;
            var raw = File.ReadAllText(path, Encoding.UTF8);
            if (!raw.StartsWith(SealedPrefix, StringComparison.Ordinal)) return raw;
            var sealedBytes = Convert.FromBase64String(raw[SealedPrefix.Length..].Trim());
            return Encoding.UTF8.GetString(Protector.Unprotect(sealedBytes));
        }
        catch
        {
            return null;
        }
    }

    /// 只在用户点了「更新账号」时写文件。密码留空则保留原密码。
    public static void Update(string file, string host, string user, string? newPassword)
    {
        var trimmedHost = host.Trim();
        var trimmedUser = user.Trim();
        if (trimmedHost.Length == 0 || trimmedUser.Length == 0)
        {
            throw new CredentialException(Tr("主机和用户名不能为空", "Host and user name can't be empty"));
        }
        string password;
        if (!string.IsNullOrEmpty(newPassword))
        {
            password = newPassword;
        }
        else if (Load(file) is { } existing)
        {
            password = existing.Password;
        }
        else
        {
            throw new CredentialException(Tr("凭据文件里还没有密码，需要填写一次", "The credential file has no password yet. Enter it once"));
        }
        if (new[] { trimmedHost, trimmedUser, password }.Any(v => v.Contains('\n') || v.Contains('\r')))
        {
            throw new CredentialException(Tr("主机、用户名和密码里不能有换行", "Host, user name and password can't contain line breaks"));
        }
        var text = Format(new VpnCredential(trimmedHost, trimmedUser, password));
        WriteSecret(PathExpander.Expand(file), text);
    }

    /// 加密后写盘。
    public static void WriteSecret(string path, string text)
    {
        var sealedBytes = Protector.Protect(Encoding.UTF8.GetBytes(text));
        var body = Protector is PlainProtector ? text : SealedPrefix + Convert.ToBase64String(sealedBytes) + "\n";
        WritePrivate(path, Encoding.UTF8.GetBytes(body));
    }

    /// 先在同一目录写临时文件、收紧权限，再改名替换，别人不会读到半截或宽权限的文件。
    public static void WritePrivate(string path, byte[] data)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        var temp = $"{path}.tmp.{Environment.ProcessId}";
        try
        {
            // 先建空文件收紧权限，再写内容。
            using (File.Create(temp)) { }
            PrivateFiles.Restrict(temp);
            using (var stream = new FileStream(temp, FileMode.Truncate, FileAccess.Write, FileShare.None))
            {
                stream.Write(data);
                stream.Flush(true);
            }
            File.Move(temp, path, overwrite: true);
            PrivateFiles.Restrict(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temp); } catch { }
            throw new CredentialException(Tr($"写不进凭据文件：{error.Message}", $"Can't write the credential file: {error.Message}"));
        }
    }
}

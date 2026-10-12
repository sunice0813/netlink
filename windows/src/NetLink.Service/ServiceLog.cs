using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
using NetLink.Core;

namespace NetLink.Service;

/// openconnect 和服务自己的日志，在 C:\ProgramData\NetLink\openconnect.log。
/// 应用通过管道读它的末尾，不直接碰这个文件。每行都过一遍 Redact，密码不会落盘。
public static class ServiceLog
{
    private static readonly object Gate = new();
    private const long MaxBytes = 2 * 1024 * 1024;
    private static bool secured;

    public static string Directory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "NetLink");

    public static string FilePath => Path.Combine(Directory, "openconnect.log");

    public static void Write(string message)
    {
        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {Redact.Line(message.TrimEnd())}\n";
        lock (Gate)
        {
            try
            {
                Secure();
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > MaxBytes)
                {
                    File.Move(FilePath, FilePath + ".1", overwrite: true);
                }
                File.AppendAllText(FilePath, line, Encoding.UTF8);
            }
            catch
            {
                // 日志写不进去不影响连接。
            }
        }
    }

    /// 服务是 SYSTEM，往一个普通用户能动手脚的目录里写文件，可能被链接到系统文件上。
    /// 所以第一次写之前把目录权限收成「只有 SYSTEM 和管理员能写」，并清掉不是普通文件的旧日志。
    private static void Secure()
    {
        if (secured) return;
        var security = new DirectorySecurity();
        security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        var inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.ReadAndExecute, inherit, PropagationFlags.None, AccessControlType.Allow));
        var directory = new DirectoryInfo(Directory);
        if (directory.Exists && directory.Attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            directory.Delete();
        }
        directory.Refresh();
        if (directory.Exists)
        {
            directory.SetAccessControl(security);
        }
        else
        {
            directory.Create(security);
        }
        foreach (var path in new[] { FilePath, FilePath + ".1" })
        {
            if (File.Exists(path) && !IsPlainFile(path)) File.Delete(path);
        }
        secured = true;
    }

    /// 不是链接、也没有别的硬链接指向它。
    private static bool IsPlainFile(string path)
    {
        if (new FileInfo(path).Attributes.HasFlag(FileAttributes.ReparsePoint)) return false;
        using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return GetFileInformationByHandle(handle, out var info) && info.NumberOfLinks == 1;
    }

    public static string Tail(int lines)
    {
        lock (Gate)
        {
            try
            {
                using var stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                var start = Math.Max(0, stream.Length - 64_000);
                stream.Seek(start, SeekOrigin.Begin);
                using var reader = new StreamReader(stream, Encoding.UTF8);
                var text = reader.ReadToEnd();
                var all = text.Split('\n');
                return Redact.Text(string.Join("\n", all.TakeLast(Math.Clamp(lines, 1, 400))));
            }
            catch
            {
                return "";
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandleFileInformation information);
}

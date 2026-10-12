using System.Diagnostics;
using System.Management;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using NetLink.Core;

namespace NetLink.App.Platform;

public sealed record Proc(int Pid, string CommandLine, string[] Arguments);

public sealed record CommandResult(int Code, string Stdout, string Stderr, bool TimedOut)
{
    public bool Ok => Code == 0 && !TimedOut;
}

/// 跑外部命令、看进程、看端口。都在后台线程里调用。
public static class Shell
{
    public static CommandResult Run(string executable, IEnumerable<string> arguments, TimeSpan timeout)
    {
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = PathExpander.Home,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        try
        {
            using var process = Process.Start(info);
            if (process == null) return new CommandResult(127, "", "start failed", false);
            process.StandardInput.Close();
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(timeout))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                return new CommandResult(124, "", "", true);
            }
            process.WaitForExit();
            return new CommandResult(process.ExitCode, Completed(stdout), Completed(stderr), false);
        }
        catch (Exception error)
        {
            return new CommandResult(127, "", error.Message, false);
        }
    }

    private static string Completed(Task<string> task) => task.Wait(TimeSpan.FromSeconds(2)) ? task.Result : "";

    /// 起一个脱离应用的进程（ssh 隧道）：不接管它的输入输出，应用退出它也继续跑，和 Mac 版 autossh -f 一样。
    public static Process? Spawn(string executable, IEnumerable<string> arguments)
    {
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = PathExpander.Home,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        return Process.Start(info);
    }

    /// 当前用户的 ssh.exe 进程和它们的命令行。命令行只有用 WMI 才拿得到。
    public static List<Proc> SshProcesses()
    {
        var found = new List<Proc>();
        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'ssh.exe'");
            foreach (var item in searcher.Get().Cast<ManagementObject>())
            {
                using (item)
                {
                    var pid = Convert.ToInt32(item["ProcessId"]);
                    var command = item["CommandLine"] as string ?? "";
                    if (command.Length == 0) continue;
                    found.Add(new Proc(pid, command, SplitArguments(command)));
                }
            }
        }
        catch
        {
            // WMI 不可用时当作没有隧道进程。
        }
        return found;
    }

    public static string[] SplitArguments(string commandLine)
    {
        var argv = CommandLineToArgvW(commandLine, out var count);
        if (argv == IntPtr.Zero) return [];
        try
        {
            var result = new string[count];
            for (var i = 0; i < count; i++)
            {
                result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size)) ?? "";
            }
            return result;
        }
        finally
        {
            LocalFree(argv);
        }
    }

    public static bool Alive(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch
        {
            return false;
        }
    }

    public static string ProcessName(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return process.ProcessName;
        }
        catch
        {
            return "";
        }
    }

    public static void Kill(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            process.Kill(entireProcessTree: true);
            process.WaitForExit(3000);
        }
        catch
        {
            // 已经退出了。
        }
    }

    [DllImport("shell32.dll", SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string commandLine, out int count);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}

/// 谁在监听某个 TCP 端口。GetExtendedTcpTable 不需要管理员权限，能拿到 PID。
public static class PortTable
{
    public static List<int> Listeners(int port)
    {
        var pids = new HashSet<int>();
        Collect(AfInet, port, pids);
        Collect(AfInet6, port, pids);
        return pids.ToList();
    }

    private const int AfInet = 2;
    private const int AfInet6 = 23;
    private const int TcpTableOwnerPidListener = 3;

    private static void Collect(int family, int port, HashSet<int> pids)
    {
        var size = 0;
        _ = GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, TcpTableOwnerPidListener, 0);
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (GetExtendedTcpTable(buffer, ref size, false, family, TcpTableOwnerPidListener, 0) != 0) return;
            var count = Marshal.ReadInt32(buffer);
            // MIB_TCPROW_OWNER_PID：state, localAddr, localPort, remoteAddr, remotePort, pid，每项 4 字节。
            // MIB_TCP6ROW_OWNER_PID：localAddr[16], localScope, localPort, remoteAddr[16], remoteScope, remotePort, state, pid。
            var rowSize = family == AfInet ? 24 : 56;
            var portOffset = family == AfInet ? 8 : 20;
            var pidOffset = family == AfInet ? 20 : 52;
            for (var i = 0; i < count; i++)
            {
                var row = buffer + 4 + i * rowSize;
                var raw = (uint)Marshal.ReadInt32(row + portOffset);
                var localPort = (int)(((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF));
                if (localPort == port) pids.Add(Marshal.ReadInt32(row + pidOffset));
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int family, int tableClass, uint reserved);
}

/// 健康检查：路由、网关、本地转发端口。
public static class Probes
{
    private static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        UseProxy = false,
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(3),
    })
    {
        Timeout = TimeSpan.FromSeconds(3),
    };

    /// 路由表里出现了这个网段片段。和 Mac 版看 netstat -rn 一样，只做字符串包含。
    public static bool RoutePresent(string marker)
    {
        if (string.IsNullOrWhiteSpace(marker)) return false;
        var route = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "route.exe");
        var result = Shell.Run(route, ["print", "-4"], TimeSpan.FromSeconds(8));
        return result.Stdout.Contains(marker.Trim(), StringComparison.Ordinal);
    }

    /// 写成 `主机:端口` 就测 TCP，否则 ping。
    public static bool Reachable(string target)
    {
        if (Commands.TcpTarget(target) is { } tcp) return TcpUp(tcp.Host, tcp.Port);
        try
        {
            using var ping = new Ping();
            return ping.Send(target.Trim(), 3000).Status == IPStatus.Success;
        }
        catch
        {
            return false;
        }
    }

    public static bool TcpUp(string host, int port, int timeoutMs = 3000)
    {
        try
        {
            using var client = new TcpClient();
            return client.ConnectAsync(host, port).Wait(timeoutMs) && client.Connected;
        }
        catch
        {
            return false;
        }
    }

    /// 本地端口回了任何 HTTP 响应（包括 302、404）都算通，和 curl -s 的判断一样。
    public static bool HttpUp(int port)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"http://127.0.0.1:{port}/");
            using var response = Http.Send(request, HttpCompletionOption.ResponseHeadersRead);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static bool ForwardUp(Forward forward) =>
        forward.Check == ForwardCheck.Tcp ? TcpUp(IPAddress.Loopback.ToString(), forward.LocalPort) : HttpUp(forward.LocalPort);
}

/// 登录后打开应用：当前用户的 Run 键，不需要管理员权限。
public static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "NetLink";

    public static bool Enabled
    {
        get
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
    }

    public static void Set(bool on)
    {
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey, true);
        if (on)
        {
            var exe = Environment.ProcessPath ?? throw new InvalidOperationException("no process path");
            key.SetValue(Name, $"\"{exe}\" --background");
        }
        else
        {
            key.DeleteValue(Name, false);
        }
    }
}

public static class TextFiles
{
    public static string Tail(string path, int lines)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(Math.Max(0, stream.Length - 48_000), SeekOrigin.Begin);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var text = reader.ReadToEnd().Replace("\r\n", "\n");
            return string.Join("\n", text.Split('\n').TakeLast(lines));
        }
        catch
        {
            return "";
        }
    }

    public static void Append(string path, string text)
    {
        try
        {
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            var bytes = Encoding.UTF8.GetBytes(text);
            stream.Write(bytes);
        }
        catch
        {
            // 日志写不进去不影响连接。
        }
    }
}

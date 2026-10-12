using System.Diagnostics;
using System.Runtime.InteropServices;
using NetLink.Core;

namespace NetLink.Service;

/// 看管一个 openconnect 进程。同一时间只连一个 VPN，和 Mac 版一致。
/// 程序只用安装目录里 openconnect\openconnect.exe，不接受外面传来的路径（服务是 SYSTEM，路径可控就等于提权）。
public sealed class OpenConnectRunner
{
    private readonly object gate = new();
    private Process? process;
    private string? host;
    private DateTimeOffset? startedAt;

    public static string Executable => Path.Combine(AppContext.BaseDirectory, "openconnect", "openconnect.exe");

    public ServiceResponse Status()
    {
        lock (gate)
        {
            var response = new ServiceResponse { Ok = true, OpenconnectInstalled = File.Exists(Executable) };
            if (process is { HasExited: false })
            {
                response.Running = true;
                response.Pid = process.Id;
                response.Host = host;
                response.StartedAt = startedAt;
                return response;
            }
            // 服务重启过：openconnect 还在跑，但不是这次起的。照样算在跑，断开时一起结束。
            var stray = StrayProcesses().FirstOrDefault();
            if (stray != null)
            {
                response.Running = true;
                response.Pid = stray.Id;
            }
            return response;
        }
    }

    public ServiceResponse Connect(string vpnHost, string user, string password, int reconnectTimeout)
    {
        lock (gate)
        {
            if (!File.Exists(Executable))
            {
                return new ServiceResponse { Ok = false, Error = $"openconnect not found: {Executable}" };
            }
            StopLocked();
            var info = new ProcessStartInfo(Executable)
            {
                UseShellExecute = false,
                // CREATE_NO_WINDOW：有控制台但不显示，断开时才能给它发 Ctrl+C。
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                WorkingDirectory = Path.GetDirectoryName(Executable)!,
            };
            foreach (var argument in Commands.OpenConnectArguments(vpnHost, user, reconnectTimeout))
            {
                info.ArgumentList.Add(argument);
            }
            ServiceLog.Write($"Connecting {vpnHost} as {user}");
            Process started;
            try
            {
                started = Process.Start(info) ?? throw new InvalidOperationException("Process.Start returned null");
            }
            catch (Exception error)
            {
                ServiceLog.Write($"openconnect failed to start: {error.Message}");
                return new ServiceResponse { Ok = false, Error = error.Message };
            }
            started.EnableRaisingEvents = true;
            started.OutputDataReceived += (_, e) => { if (e.Data != null) ServiceLog.Write(e.Data); };
            started.ErrorDataReceived += (_, e) => { if (e.Data != null) ServiceLog.Write(e.Data); };
            started.Exited += (_, _) => ServiceLog.Write($"openconnect exited ({SafeExitCode(started)})");
            started.BeginOutputReadLine();
            started.BeginErrorReadLine();
            // --passwd-on-stdin 读的是标准输入的第一行。写完就关掉，后面再要输入的提示会直接失败而不是卡住。
            try
            {
                started.StandardInput.Write(password + "\n");
                started.StandardInput.Flush();
                started.StandardInput.Close();
            }
            catch (IOException)
            {
                // 进程已经退出，退出原因在日志里。
            }
            process = started;
            host = vpnHost;
            startedAt = DateTimeOffset.Now;
            return Status();
        }
    }

    public ServiceResponse Disconnect()
    {
        lock (gate)
        {
            StopLocked();
            return Status();
        }
    }

    private void StopLocked()
    {
        var targets = new List<Process>();
        if (process is { HasExited: false }) targets.Add(process);
        targets.AddRange(StrayProcesses().Where(p => process == null || p.Id != process.Id));
        foreach (var target in targets)
        {
            ServiceLog.Write($"Stopping openconnect (PID {target.Id})");
            // 先 Ctrl+C，openconnect 会跑 vpnc-script 的 disconnect，把路由和 DNS 收回去。
            if (SendCtrlC(target.Id) && WaitExit(target, TimeSpan.FromSeconds(8))) continue;
            try
            {
                target.Kill(entireProcessTree: true);
                WaitExit(target, TimeSpan.FromSeconds(3));
            }
            catch (Exception error)
            {
                ServiceLog.Write($"Couldn't stop PID {target.Id}: {error.Message}");
            }
        }
        process = null;
        host = null;
        startedAt = null;
    }

    /// 安装目录里的 openconnect.exe 起的进程。别处的 openconnect（比如用户自己装的 GUI）不动。
    private static List<Process> StrayProcesses()
    {
        var found = new List<Process>();
        foreach (var candidate in Process.GetProcessesByName("openconnect"))
        {
            try
            {
                var path = candidate.MainModule?.FileName;
                if (path != null && string.Equals(Path.GetFullPath(path), Path.GetFullPath(Executable), StringComparison.OrdinalIgnoreCase))
                {
                    found.Add(candidate);
                    continue;
                }
            }
            catch
            {
                // 读不到路径的进程不是我们起的。
            }
            candidate.Dispose();
        }
        return found;
    }

    private static bool WaitExit(Process target, TimeSpan timeout)
    {
        try
        {
            return target.WaitForExit(timeout);
        }
        catch
        {
            return true;
        }
    }

    private static string SafeExitCode(Process target)
    {
        try { return target.ExitCode.ToString(); } catch { return "?"; }
    }

    // 给另一个控制台里的进程发 Ctrl+C：挂到它的控制台上，自己先屏蔽 Ctrl+C，发完再脱开。
    private static readonly object ConsoleGate = new();

    private static bool SendCtrlC(int pid)
    {
        lock (ConsoleGate)
        {
            FreeConsole();
            if (!AttachConsole((uint)pid)) return false;
            try
            {
                SetConsoleCtrlHandler(IntPtr.Zero, true);
                var sent = GenerateConsoleCtrlEvent(CtrlCEvent, 0);
                Thread.Sleep(300);
                return sent;
            }
            finally
            {
                FreeConsole();
                SetConsoleCtrlHandler(IntPtr.Zero, false);
            }
        }
    }

    private const uint CtrlCEvent = 0;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
}

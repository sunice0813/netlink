using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using NetLink.Core;
using static NetLink.Core.Text;

namespace NetLink.App.Platform;

/// 和 NetLink.Service 说话。连上管道后先确认对面真是服务（SYSTEM、会话 0 里的 NetLink.Service），再发密码。
public static class ServiceClient
{
    public static ServiceResponse? Status() => Send(new ServiceRequest { Op = "status" });

    public static ServiceResponse? Log(int lines) => Send(new ServiceRequest { Op = "log", Lines = lines });

    public static ServiceResponse? Disconnect() => Send(new ServiceRequest { Op = "disconnect" }, TimeSpan.FromSeconds(20));

    public static ServiceResponse? Connect(VpnCredential credential, int reconnectTimeout) =>
        Send(new ServiceRequest
        {
            Op = "connect",
            Host = credential.Host,
            User = credential.User,
            Password = credential.Password,
            ReconnectTimeout = reconnectTimeout,
        }, TimeSpan.FromSeconds(30));

    public static string? LastError { get; private set; }

    private static ServiceResponse? Send(ServiceRequest request, TimeSpan? timeout = null)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", ServiceProtocol.PipeName, PipeDirection.InOut, PipeOptions.None);
            pipe.Connect(2000);
            if (!IsGenuineService(pipe))
            {
                LastError = Tr("管道另一端不是 NetLink 服务，已拒绝发送", "The pipe isn't served by the NetLink service; refused to send");
                return null;
            }
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, leaveOpen: true);
            writer.WriteLine(JsonSerializer.Serialize(request, ServiceProtocol.Json));
            var read = reader.ReadLineAsync();
            if (!read.Wait(timeout ?? TimeSpan.FromSeconds(10)) || read.Result == null)
            {
                LastError = Tr("后台服务没有回应", "The background service didn't answer");
                return null;
            }
            LastError = null;
            return JsonSerializer.Deserialize<ServiceResponse>(read.Result, ServiceProtocol.Json);
        }
        catch (Exception error) when (error is TimeoutException or IOException or UnauthorizedAccessException or JsonException)
        {
            LastError = error.Message;
            return null;
        }
    }

    private static bool IsGenuineService(NamedPipeClientStream pipe)
    {
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out var pid)) return false;
        try
        {
            using var process = Process.GetProcessById((int)pid);
            return process.SessionId == 0 && string.Equals(process.ProcessName, "NetLink.Service", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    /// 服务没在跑时，用管理员身份启动它（会弹一次 UAC）。相当于 Mac 版的「配置免密 sudo」。
    public static bool StartElevated()
    {
        try
        {
            var sc = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "sc.exe");
            var info = new ProcessStartInfo(sc, $"start {ServiceProtocol.ServiceName}")
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            };
            using var process = Process.Start(info);
            process?.WaitForExit(15000);
            return true;
        }
        catch (Win32Exception)
        {
            // 用户在 UAC 里点了「否」。
            return false;
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint serverProcessId);
}

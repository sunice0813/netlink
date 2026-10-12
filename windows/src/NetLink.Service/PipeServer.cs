using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using NetLink.Core;

namespace NetLink.Service;

/// 命名管道服务端。登录用户能读写，但不能创建同名实例（防止别的程序冒充服务收密码）。
public sealed class PipeServer(OpenConnectRunner runner)
{
    /// 第一个实例同步创建并要求「必须是第一个」：如果有人抢先建了同名管道，服务直接起不来，而不是和它共用。
    public void Start(CancellationToken token)
    {
        var firstPipe = Create(PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance);
        _ = Task.Run(() => AcceptLoop(token, firstPipe), token);
        for (var i = 0; i < 3; i++)
        {
            _ = Task.Run(() => AcceptLoop(token, null), token);
        }
    }

    private static PipeSecurity Security()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        // 客户端以 GENERIC_READ | GENERIC_WRITE 打开，里面含 SYNCHRONIZE，要一并放行。没有 CreateNewInstance。
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize, AccessControlType.Allow));
        return security;
    }

    private static NamedPipeServerStream Create(PipeOptions options)
    {
        return NamedPipeServerStreamAcl.Create(
            ServiceProtocol.PipeName,
            PipeDirection.InOut,
            NamedPipeServerStream.MaxAllowedServerInstances,
            PipeTransmissionMode.Byte,
            options,
            4096,
            4096,
            Security());
    }

    private async Task AcceptLoop(CancellationToken token, NamedPipeServerStream? initial)
    {
        while (!token.IsCancellationRequested)
        {
            NamedPipeServerStream pipe;
            try
            {
                pipe = initial ?? Create(PipeOptions.Asynchronous);
                initial = null;
            }
            catch (Exception error)
            {
                ServiceLog.Write($"Pipe create failed: {error.Message}");
                await Task.Delay(2000, token).ConfigureAwait(false);
                continue;
            }
            await using (pipe)
            {
                try
                {
                    await pipe.WaitForConnectionAsync(token).ConfigureAwait(false);
                    await Handle(pipe, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception error)
                {
                    ServiceLog.Write($"Pipe request failed: {error.Message}");
                }
            }
        }
    }

    private async Task Handle(NamedPipeServerStream pipe, CancellationToken token)
    {
        using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, leaveOpen: true);
        await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        var line = await reader.ReadLineAsync(timeout.Token).ConfigureAwait(false);
        if (line == null || line.Length > 16 * 1024) return;

        ServiceResponse response;
        try
        {
            var request = JsonSerializer.Deserialize<ServiceRequest>(line, ServiceProtocol.Json) ?? new ServiceRequest();
            response = Dispatch(request);
        }
        catch (JsonException)
        {
            response = new ServiceResponse { Ok = false, Error = "bad request" };
        }
        await writer.WriteLineAsync(JsonSerializer.Serialize(response, ServiceProtocol.Json)).ConfigureAwait(false);
        // 等应用读完再关管道，免得回应还在缓冲区里就被丢掉。
        pipe.WaitForPipeDrain();
    }

    private ServiceResponse Dispatch(ServiceRequest request)
    {
        if (ServiceProtocol.Validate(request) is { } problem)
        {
            return new ServiceResponse { Ok = false, Error = problem };
        }
        return request.Op switch
        {
            "connect" => runner.Connect(request.Host!.Trim(), request.User!.Trim(), request.Password!, request.ReconnectTimeout),
            "disconnect" => runner.Disconnect(),
            "log" => WithLog(runner.Status(), request.Lines),
            _ => runner.Status(),
        };
    }

    private static ServiceResponse WithLog(ServiceResponse response, int lines)
    {
        response.Log = ServiceLog.Tail(lines);
        return response;
    }
}

using System.Text;
using System.Text.Json.Nodes;
using NetLink.Core;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace NetLink.Tests;

/// 每个测试一个临时家目录和数据目录，不碰真实的配置。对应 Mac 版 app/SelfTest.swift。
public sealed class Sandbox : IDisposable
{
    public string Root { get; } = Path.Combine(Path.GetTempPath(), "netlink-test-" + Guid.NewGuid().ToString("N"));
    public string Home => Path.Combine(Root, "home");
    public string Data => Path.Combine(Root, "data");

    public Sandbox()
    {
        Directory.CreateDirectory(Home);
        Directory.CreateDirectory(Data);
        PathExpander.Home = Home;
        AppPaths.Directory = Data;
        Credentials.Protector = new PlainProtector();
        L10n.Choice = AppLanguage.Zh;
    }

    public void Dispose()
    {
        try { Directory.Delete(Root, true); } catch { }
    }
}

public sealed class LanguageTests
{
    [Fact]
    public void FollowsSystemAndChoice()
    {
        Assert.Equal(AppLanguage.System, L10n.Parse(null));
        Assert.Equal(AppLanguage.System, L10n.Parse("nope"));
        Assert.True(L10n.IsChineseFor(AppLanguage.System, "zh-CN"));
        Assert.True(L10n.IsChineseFor(AppLanguage.System, "zh-Hant-TW"));
        Assert.False(L10n.IsChineseFor(AppLanguage.System, "ja-JP"));
        Assert.False(L10n.IsChineseFor(AppLanguage.System, ""));
        Assert.True(L10n.IsChineseFor(AppLanguage.Zh, "en-US"));
        Assert.False(L10n.IsChineseFor(AppLanguage.En, "zh-CN"));
    }

    [Fact]
    public void DefaultNamesFollowLanguage()
    {
        Assert.Equal("Jump host", L10n.LocalizedDefault("跳板", chinese: false));
        Assert.Equal("本机", L10n.LocalizedDefault("Local", chinese: true));
        Assert.Equal("GitLab", L10n.LocalizedDefault("GitLab", chinese: false));
        Assert.Equal("跳板 2", L10n.LocalizedDefault("跳板 2", chinese: false));
    }
}

public sealed class CredentialTests
{
    [Fact]
    public void ParsesLikeMac()
    {
        var parsed = Credentials.Parse("host=vpn.example\nuser=alice\npassword=s3cret\n");
        Assert.Equal(new VpnCredential("vpn.example", "alice", "s3cret"), parsed);
        Assert.Null(Credentials.Parse("host=vpn.example\nuser=alice\n"));
        Assert.Equal("a b", Credentials.Parse("host=h\nuser=u\npassword=a b\n")?.Password);
        Assert.Equal("x=y", Credentials.Parse("host=h\r\nuser=u\r\npassword=x=y\r\n")?.Password);
    }

    [Fact]
    public void RedactsPasswords()
    {
        var redacted = Redact.Line("password=s3cret");
        Assert.Equal("password=***", redacted);
        Assert.DoesNotContain("s3cret", Redact.Text("a\nPassword=s3cret\nb"));
    }

    [Fact]
    public void UpdateKeepsPasswordWhenEmpty()
    {
        using var box = new Sandbox();
        var file = Path.Combine(box.Data, "cred");
        Credentials.Update(file, "vpn.example", "alice", "first");
        Credentials.Update(file, "vpn2.example", "bob", "");
        Assert.Equal(new VpnCredential("vpn2.example", "bob", "first"), Credentials.Load(file));
        Assert.Throws<CredentialException>(() => Credentials.Update(Path.Combine(box.Data, "new"), "h", "u", null));
        Assert.Throws<CredentialException>(() => Credentials.Update(file, "h", "u", "a\nb"));
    }

    [Fact]
    public void SealedFilesRoundTrip()
    {
        using var box = new Sandbox();
        Credentials.Protector = new XorProtector();
        var file = Path.Combine(box.Data, "cred");
        Credentials.Update(file, "vpn.example", "alice", "s3cret");
        var raw = File.ReadAllText(file);
        Assert.StartsWith("NLDPAPI1:", raw);
        Assert.DoesNotContain("s3cret", raw);
        Assert.Equal("s3cret", Credentials.Load(file)?.Password);
        // 手写的明文文件也认。
        File.WriteAllText(file, "host=h\nuser=u\npassword=p\n");
        Assert.Equal("p", Credentials.Load(file)?.Password);
    }

    private sealed class XorProtector : ISecretProtector
    {
        public byte[] Protect(byte[] plain) => plain.Select(b => (byte)(b ^ 0x5A)).ToArray();
        public byte[] Unprotect(byte[] sealedBytes) => Protect(sealedBytes);
    }
}

public sealed class CommandTests
{
    private static AppConfig Sample(out Forward web, out Forward admin)
    {
        web = new Forward { Name = "Web", LocalPort = 80, TargetHost = "10.0.0.10", TargetPort = 80, OpenHost = "web.example.internal" };
        admin = new Forward { Name = "Admin", LocalPort = 8080, TargetHost = "10.0.0.11", TargetPort = 80 };
        return new AppConfig { Forwards = [web, admin] };
    }

    [Fact]
    public void PasswordStaysOutOfArguments()
    {
        var args = Commands.OpenConnectArguments("https://vpn.example", "alice", 30);
        Assert.Contains("--passwd-on-stdin", args);
        Assert.Contains("--protocol=anyconnect", args);
        Assert.DoesNotContain("--background", args);
        Assert.Equal("https://vpn.example", args[^1]);
        Assert.DoesNotContain("s3cret", string.Join(" ", args));
    }

    [Fact]
    public void SshForwardsOneTargetThroughItsJump()
    {
        using var box = new Sandbox();
        var config = Sample(out var web, out var admin);
        var args = Commands.SshArguments(config, web);
        Assert.Contains("80:10.0.0.10:80", args);
        Assert.DoesNotContain("8080:10.0.0.11:80", args);
        Assert.Equal("user@jump.example.com", args[^1]);
        Assert.Contains("BatchMode=yes", args);
        Assert.Contains("StrictHostKeyChecking=accept-new", args);
        Assert.Equal(PathExpander.Expand("~/.tunnel.log"), args[args.IndexOf("-E") + 1]);

        var other = new Jump { Name = "备用", Host = "bob@10.1.1.1", IdentityFile = "~/.ssh/bob" };
        config.Jumps.Add(other);
        var extra = new Forward { Name = "临时", LocalPort = 9000, TargetHost = "10.1.1.2", TargetPort = 80, JumpId = other.Id };
        var extraArgs = Commands.SshArguments(config, extra);
        Assert.Equal("bob@10.1.1.1", extraArgs[^1]);
        Assert.Contains(Path.Combine(box.Home, ".ssh", "bob"), extraArgs);
        Assert.Equal("user@jump.example.com", Commands.SshArguments(config, admin)[^1]);
    }

    [Fact]
    public void HealthTargets()
    {
        Assert.Equal(22, Commands.TcpTarget("10.0.0.1:22")?.Port);
        Assert.Null(Commands.TcpTarget("10.0.0.1"));
        Assert.Null(Commands.TcpTarget("host:99999"));
        Assert.True(Commands.SameHost("https://VPN.example.com/group", "vpn.example.com"));
        Assert.False(Commands.SameHost("", "vpn.example.com"));
    }

    [Fact]
    public void QuotesLikeWindows()
    {
        Assert.Equal("plain", Commands.Quote("plain"));
        Assert.Equal("\"C:\\Users\\A B\\x.log\"", Commands.Quote("C:\\Users\\A B\\x.log"));
        Assert.Equal("\"a\\\"b\"", Commands.Quote("a\"b"));
        Assert.Equal("\"\"", Commands.Quote(""));
    }

    [Fact]
    public void WatchdogNeedsEnoughFailures()
    {
        Assert.False(Watchdog.ShouldRestart(flag: true, healthy: false, fails: 1, threshold: 2));
        Assert.True(Watchdog.ShouldRestart(flag: true, healthy: false, fails: 2, threshold: 2));
        Assert.False(Watchdog.ShouldRestart(flag: false, healthy: false, fails: 9, threshold: 2));
        Assert.False(Watchdog.ShouldRestart(flag: true, healthy: true, fails: 9, threshold: 2));
    }

    [Fact]
    public void ServiceRejectsOptionLikeValues()
    {
        var good = new ServiceRequest { Op = "connect", Host = "vpn.example.com", User = "alice", Password = "p w" };
        Assert.Null(ServiceProtocol.Validate(good));
        Assert.NotNull(ServiceProtocol.Validate(new ServiceRequest { Op = "connect", Host = "--script=x", User = "a", Password = "p" }));
        Assert.NotNull(ServiceProtocol.Validate(new ServiceRequest { Op = "connect", Host = "h", User = "-a", Password = "p" }));
        Assert.NotNull(ServiceProtocol.Validate(new ServiceRequest { Op = "connect", Host = "h", User = "a", Password = "p\nq" }));
        Assert.NotNull(ServiceProtocol.Validate(new ServiceRequest { Op = "run" }));
    }
}

public sealed class ConfigTests
{
    [Fact]
    public void LegacyConfigGrowsJumpAndVpn()
    {
        var legacy = ConfigJson.Decode("""{"jumpHost":"a@b","identityFile":"~/.ssh/a","credentialFile":"~/.internalvpn"}""");
        Assert.Equal(Jump.Primary, legacy.Jumps[0].Id);
        Assert.Equal(VpnProfile.Primary, legacy.Vpns[0].Id);
        Assert.Equal("a@b", legacy.JumpHost);
        Assert.Equal("openconnect", legacy.Vpns[0].Kind);
        Assert.Equal(0, legacy.LayoutVersion);
    }

    [Fact]
    public void WrongTypesMakeTheFileUnreadable()
    {
        Assert.Throws<FormatException>(() => ConfigJson.Decode("""{"reconnectTimeout":"30"}"""));
        Assert.Throws<FormatException>(() => ConfigJson.Decode("""{"forwards":[{"id":"nope"}]}"""));
    }

    [Fact]
    public void RoundTripKeepsMacFields()
    {
        var config = new AppConfig();
        config.Vpns.Add(new VpnProfile { Name = "Second", CredentialFile = "~/.second", ViaId = VpnProfile.Primary });
        config.Layout[TopologyKey.Machine] = new PointD(9, 8);
        var json = ConfigJson.Serialize(config);
        Assert.Contains("\"B1000000-0000-4000-8000-000000000001\"", json);
        Assert.Contains("\"autosshPath\"", json);
        Assert.Contains("\"sshPath\"", json);
        var decoded = ConfigJson.Decode(json);
        Assert.Equal(VpnProfile.Primary, decoded.Vpns[1].ViaId);
        Assert.Equal(new PointD(9, 8), decoded.Layout[TopologyKey.Machine]);
        Assert.Equal(config.Forwards.Count, decoded.Forwards.Count);
        Assert.Equal(config.JumpHost, decoded.JumpHost);
    }

    [Fact]
    public void ReadsAMacConfig()
    {
        // Mac 版 JSONEncoder 写出的样子：键排序，UUID 大写，没有 sshPath。
        var mac = """
        {
          "autosshPath" : "/opt/homebrew/bin/autossh",
          "credentialFile" : "~/.internalvpn",
          "forwards" : [
            {
              "check" : "http",
              "enabled" : true,
              "id" : "0F6D4C4E-1111-4222-8333-944455556666",
              "localPort" : 80,
              "name" : "GitLab",
              "openHost" : "",
              "targetHost" : "10.62.1.101",
              "targetPort" : 80
            }
          ],
          "jumps" : [
            {
              "host" : "appdev@10.62.11.31",
              "id" : "A1000000-0000-4000-8000-000000000001",
              "identityFile" : "~/.ssh/id_ed25519",
              "name" : "跳板"
            }
          ],
          "layout" : { "machine" : { "x" : 28, "y" : 40.5 } },
          "layoutVersion" : 2,
          "pingHost" : "10.62.1.10",
          "routeMarker" : "10.62",
          "vpns" : [
            { "credentialFile" : "~/.internalvpn", "id" : "B1000000-0000-4000-8000-000000000001", "kind" : "openconnect", "name" : "Dev VPN", "serviceName" : "" },
            { "credentialFile" : "", "id" : "C1000000-0000-4000-8000-000000000001", "kind" : "shadowrocket", "name" : "Shadowrocket", "serviceName" : "Shadowrocket" }
          ]
        }
        """;
        L10n.Choice = AppLanguage.En;
        var config = ConfigJson.Decode(mac);
        Assert.Single(config.Vpns);
        Assert.Equal("Dev VPN", config.Vpns[0].Name);
        Assert.Equal("Jump host", config.Jumps[0].Name);
        Assert.Equal(80, config.Forwards[0].LocalPort);
        Assert.Equal(AppConfig.DefaultSshPath, config.SshPath);
        Assert.Equal(40.5, config.Layout[TopologyKey.Machine].Y);
    }

    [Fact]
    public void ViaLoopsAndDanglingRefsAreCleared()
    {
        var config = new AppConfig();
        var second = new VpnProfile { Name = "Second", CredentialFile = "~/.second" };
        config.Vpns.Add(second);
        config.Vpns[0].ViaId = second.Id;
        second.ViaId = VpnProfile.Primary;
        config.Normalize();
        Assert.Contains(config.Vpns, v => v.ViaId == null);

        var dangling = new AppConfig();
        dangling.Vpns[0].ViaId = Guid.NewGuid();
        dangling.Normalize();
        Assert.Null(dangling.Vpns[0].ViaId);
    }

    [Fact]
    public void ChecksCatchBadValues()
    {
        using var box = new Sandbox();
        var config = new AppConfig();
        Assert.Empty(ConfigCheck.Issues(config));
        config.Jumps[0].Host = "-oProxyCommand=x@y";
        config.Forwards.Add(new Forward { Name = "Dup", LocalPort = 8080, TargetHost = "a b", TargetPort = 80 });
        config.TunnelLogFile = "C:/elsewhere/tunnel.txt";
        var issues = ConfigCheck.Issues(config);
        Assert.Contains(issues, i => i.Contains("不能以 - 开头"));
        Assert.Contains(issues, i => i.Contains("本地端口有重复"));
        Assert.Contains(issues, i => i.Contains("目标主机只能含"));
        Assert.Contains(issues, i => i.Contains("隧道日志"));
    }

    [Fact]
    public void StoreRefusesToOverwriteACorruptFile()
    {
        using var box = new Sandbox();
        File.WriteAllText(AppPaths.ConfigFile, "{ broken");
        Assert.True(ConfigStore.IsCorrupt);
        Assert.Throws<ConfigException>(() => ConfigStore.Save(new AppConfig()));
        Assert.False(ConfigStore.Mutate(c => c.MachineName = "x"));
        ConfigStore.Save(new AppConfig(), overwriteCorrupt: true);
        Assert.Equal("{ broken", File.ReadAllText(AppPaths.ConfigBackup));
        Assert.False(ConfigStore.IsCorrupt);
        Assert.True(ConfigStore.Mutate(c => c.MachineName = "Desk"));
        Assert.Equal("Desk", ConfigStore.Load().MachineName);
    }
}

public sealed class LayoutTests
{
    [Fact]
    public void DefaultReadsLeftToRight()
    {
        var web = new Forward { Name = "Web", LocalPort = 80, TargetHost = "10.0.0.10", TargetPort = 80 };
        var admin = new Forward { Name = "Admin", LocalPort = 8080, TargetHost = "10.0.0.11", TargetPort = 80 };
        var config = new AppConfig { Forwards = [web, admin] };
        var placed = TopologyLayout.Default(config);
        var machine = placed[TopologyKey.Machine];
        var vpn = placed[TopologyKey.Vpn(VpnProfile.Primary)];
        var jump = placed[TopologyKey.Jump(Jump.Primary)];
        var git = placed[TopologyKey.Forward(web.Id)];
        var server = placed[TopologyKey.Forward(admin.Id)];
        Assert.True(machine.X < vpn.X && vpn.X < jump.X && jump.X < git.X && git.X == server.X);
        Assert.True(Math.Abs(machine.Y - vpn.Y) < 0.5 && Math.Abs(vpn.Y - jump.Y) < 0.5 && git.Y < jump.Y && jump.Y < server.Y);
    }

    [Fact]
    public void SavedPositionWins()
    {
        var config = new AppConfig();
        config.Layout[TopologyKey.Machine] = new PointD(9, 8);
        Assert.Equal(new PointD(9, 8), TopologyLayout.Resolved(config)[TopologyKey.Machine]);
    }

    [Fact]
    public void UpstreamSitsBetweenMachineAndVpn()
    {
        var config = new AppConfig();
        var proxy = new VpnProfile { Name = "Proxy", CredentialFile = "~/.proxy" };
        config.Vpns.Add(proxy);
        config.Vpns[0].ViaId = proxy.Id;
        var placed = TopologyLayout.Default(config);
        var machine = placed[TopologyKey.Machine];
        var up = placed[TopologyKey.Vpn(proxy.Id)];
        var vpn = placed[TopologyKey.Vpn(VpnProfile.Primary)];
        var jump = placed[TopologyKey.Jump(Jump.Primary)];
        Assert.True(machine.X < up.X && up.X < vpn.X && vpn.X < jump.X);
        Assert.True(Math.Abs(up.Y - vpn.Y) < 0.5 && Math.Abs(machine.Y - up.Y) < 0.5);
        Assert.Equal([proxy.Id], config.UpstreamIds(VpnProfile.Primary));
    }

    [Fact]
    public void LinksPickFacingSides()
    {
        var link = TopologyMetrics.Link(new PointD(0, 0), new PointD(300, 10));
        Assert.Equal(TopologySide.Right, link.FromSide);
        Assert.Equal(TopologySide.Left, link.ToSide);
        var biases = TopologyMetrics.SideBiases([new PointD(300, 100), new PointD(300, -100)], new PointD(0, 0));
        Assert.True(biases[1] < biases[0]);
    }
}

public sealed class TransferTests
{
    [Fact]
    public void ExportsAndImportsSecrets()
    {
        using var box = new Sandbox();
        var config = new AppConfig();
        var credentialFile = Path.Combine(box.Home, ".internalvpn");
        Credentials.Update(credentialFile, "vpn.example.com", "alice", "s3cret");
        var keyFile = Path.Combine(box.Home, ".ssh", "id_ed25519");
        Directory.CreateDirectory(Path.GetDirectoryName(keyFile)!);
        File.WriteAllText(keyFile, "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n");
        config.Vpns[0].CredentialFile = credentialFile;
        config.Jumps[0].IdentityFile = keyFile;
        config.Jumps[0].Host = "appdev@10.62.11.31";
        config.Normalize();

        var plain = Encoding.UTF8.GetString(ConfigTransfer.Export(config, includeSecrets: false));
        Assert.Contains("\"~/.internalvpn\"", plain);
        Assert.DoesNotContain("s3cret", plain);

        var data = ConfigTransfer.Export(config, includeSecrets: true);
        var text = Encoding.UTF8.GetString(data);
        Assert.Contains("s3cret", text);
        Assert.Contains("PRIVATE KEY", text);
        Assert.DoesNotContain("\"credentialFile\"", text);

        var preview = ConfigTransfer.Parse(data);
        Assert.Empty(preview.Issues);
        Assert.Single(preview.Secrets.Credentials);
        Assert.Single(preview.Secrets.Keys);
        Assert.Empty(preview.MissingCredentials);

        var ready = ConfigTransfer.Materialize(preview, box.Data);
        Assert.StartsWith(Path.Combine(box.Data, "imported"), ready.Vpns[0].CredentialFile);
        Assert.Equal("s3cret", Credentials.Load(ready.Vpns[0].CredentialFile)?.Password);
        Assert.Contains("PRIVATE KEY", File.ReadAllText(ready.Jumps[0].IdentityFile));
        Assert.Equal(ready.Jumps[0].IdentityFile, ready.IdentityFile);
    }

    [Fact]
    public void RejectsForeignJsonAndDropsSystemVpns()
    {
        using var box = new Sandbox();
        Assert.Throws<ConfigException>(() => ConfigTransfer.Parse(Encoding.UTF8.GetBytes("""{"name":"x"}""")));
        Assert.Throws<ConfigException>(() => ConfigTransfer.Parse(Encoding.UTF8.GetBytes("not json")));

        var root = ConfigJson.Encode(new AppConfig());
        ((JsonArray)root["vpns"]!).Add(new JsonObject
        {
            ["id"] = "D1000000-0000-4000-8000-000000000001",
            ["name"] = "FortiClient",
            ["kind"] = "forticlient",
            ["serviceName"] = "VPN",
            ["credentialFile"] = "",
        });
        var preview = ConfigTransfer.Parse(Encoding.UTF8.GetBytes(root.ToJsonString()));
        Assert.Equal(["FortiClient"], preview.DroppedVpns);
        Assert.Single(preview.Config.Vpns);
        Assert.Contains("VPN", preview.MissingCredentials);
    }

    [Fact]
    public void PortablePathsUseTilde()
    {
        using var box = new Sandbox();
        Assert.Equal("~/.ssh/id", PathExpander.Portable(Path.Combine(box.Home, ".ssh", "id")));
        Assert.Equal(Path.Combine(box.Home, ".ssh", "id"), PathExpander.Expand("~/.ssh/id"));
        Assert.Equal("/elsewhere/x", PathExpander.Portable("/elsewhere/x"));
    }
}

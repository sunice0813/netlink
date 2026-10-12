# NetLink

[English](README.md) | 中文

macOS 菜单栏应用，用来管理访问公司内网的这条链路：

```
本机 → （Shadowrocket）→ VPN → 跳板机 → 内网服务
```

它把三件事放在一张图里：

- **VPN**：用 `openconnect` 连接 AnyConnect 协议的 VPN，掉线自动重连。
- **SSH 隧道**：通过跳板机把内网服务转发到本机端口（`autossh`），每条转发单独开关。
- **状态**：每个节点是否在线一眼可见，哪一环断了直接看图。

关掉窗口不会断开连接，菜单栏图标一直在。

也有 Windows 版，功能基本一致，见 [Windows 版](#windows-版)。

## 安装

要求 macOS 14 或更新、Apple Silicon，并已安装 [Homebrew](https://brew.sh)。

1. 从 [Releases](../../releases) 下载 `NetLink-<版本>-arm64.dmg`，把 NetLink 拖进「应用程序」。
2. 在终端执行（应用没有签名，需要解除一次隔离）：

   ```bash
   xattr -dr com.apple.quarantine /Applications/NetLink.app
   ```

3. 打开 NetLink，按提示输入一次电脑密码，然后点「导入导出」导入配置。

首次打开时会自动安装 `openconnect`、`autossh`，可能要几分钟。输入密码是为了让 VPN 和隧道以后能直接连接、断开，不用每次输密码。

## 快速开始

有别人导出的配置文件（带 VPN 账号和私钥）时，导入后直接点「连接」即可，下面这些都不用做。从零配置时：

主窗口左边是节点列表，中间是拓扑图，右边是选中节点的详情（检查器）。在列表或图上选中节点，或者右键它，就能操作。

1. **VPN 账号**：选中 VPN，在检查器里点「修改账号」，填 VPN 主机、用户名和密码。
2. **跳板机**：选中跳板，点「修改跳板」，填 `user@host` 和 SSH 私钥路径。
3. **转发**：选中跳板，点「添加转发」，填本地端口和内网目标地址。
4. **连接**：打开转发或跳板在检查器顶部的开关。跳板机不通时，会先连 VPN。
5. **连通性探测**：在 设置（⌘,）→ 健康检查 里，把「路由里要出现的网段」和「网关探测」改成你们内网的值，见下面「配置」。网关可以写成 `主机:端口`，改用 TCP 探测。

密码只写在本机的凭据文件里（默认 `~/.internalvpn`，权限 600）。程序把它从标准输入交给 `openconnect`，不会出现在命令行参数、日志或配置里。

## 功能

| 功能 | 说明 |
| --- | --- |
| 拓扑图 | 本机、VPN、跳板、转发画成一张图，绿色实线表示这一段是通的。节点可以拖动，位置会保存；把转发拖到另一台跳板旁边，就改走那台跳板 |
| 检查器 | 选中节点的状态、连接开关、详情和操作都在右侧一栏 |
| 多个 VPN 和跳板 | 一个跳板挂在哪个 VPN 下、一条转发走哪台跳板，都可以单独设置 |
| 上游关系 | 可以标出某个 VPN 的流量先经过另一个 VPN（例如 Shadowrocket）。只影响画图和状态显示，不改连接 |
| 自动重连 | VPN 和隧道各有开关。连续失败 2 次才重启，次数和间隔可配置 |
| 系统 VPN | 能识别 Shadowrocket 和 FortiClient，显示状态、打开和退出应用 |
| 导入导出 | 头部「导入导出」：把配置导出成 JSON，或从文件导入。可以连 VPN 账号和 SSH 私钥一起带走，换一台机器导入就能用。导入前先预览并校验，替换前自动备份 |
| 开机启动 | 设置里的开关，登录后自动打开本应用（不会自动连接） |
| 日志 | 单独的日志窗口，分 VPN、隧道和安装三类，密码不会出现在里面 |
| 语言 | 中文和英文，默认跟随系统，可在设置里切换 |
| 菜单栏 | 每个 VPN 和转发一个开关，外加自动重连开关 |

只看状态、不改连接：

```bash
/Applications/NetLink.app/Contents/MacOS/NetLink --status
```

### 退出

关掉窗口只是隐藏，连接和后台守护继续运行。菜单栏里的「退出并断开」会先停掉 VPN、隧道和后台守护，再退出。

### Shadowrocket 和 FortiClient

- **Shadowrocket** 在 Mac 上是 iOS 应用，没有命令行开关。图上能显示它是否已连接，「连接/断开」会打开应用，开关要在里面点。
- **FortiClient** 的连接依赖它自带的非公开组件，FortiClient 升级后可能失效。没有安装则不会出现在图上。

## 配置

配置文件在 `~/Library/Application Support/NetLink/config.json`。账号、跳板、转发在主窗口的检查器里改；健康检查和 `openconnect` / `autossh` 路径在设置里改。`forwards[].check` 等少数几项只能直接改文件。转发规则改完要重启隧道才生效。

| 键 | 说明 |
| --- | --- |
| `routeMarker` | 连上 VPN 后，`netstat -rn` 里应该出现的网段片段，例如 `10.0.0` |
| `pingHost` | VPN 连通性探测。写 `主机:端口` 用 TCP 连接（推荐，很多内网主机不回 ICMP），不带端口则 ping |
| `reconnectTimeout` | 传给 `openconnect --reconnect-timeout` 的秒数 |
| `vpnWatchdogInterval` / `tunnelWatchdogInterval` | 检查间隔（秒），至少 5 |
| `vpnFailThreshold` / `tunnelFailThreshold` | 连续失败几次才重启，至少 1 |
| `jumps[].vpnID` | 这台跳板挂在哪个 VPN 下；连隧道时跳板不通会先连这个 VPN |
| `vpns[].viaID` | 这个 VPN 的流量先经过哪个 VPN。只影响画图 |
| `forwards[].check` | `http`（默认，请求一次 HTTP，端到端）或 `tcp`（只看本地端口，给数据库、SSH 等非 HTTP 目标用） |
| `forwards[].openHost` | 点击转发节点在浏览器里打开时用的主机名，空则用 `127.0.0.1` |
| `openconnectPath` / `autosshPath` | 可执行文件位置，默认是 Homebrew 在 Apple Silicon 上的路径 |

日志和进程文件（`vpnPidFile`、`vpnLogFile`、`tunnelLogFile`）必须在家目录下，以 `.pid` / `.log` 结尾，这是为了限制程序在需要 root 时能碰哪些文件。

配置文件读不了时，后台操作和自动重连都会停手，不会拿默认值去连接或覆盖原文件。在界面里点保存会覆盖，并先备份成 `config.json.bak`。

### 导入导出

导出时默认勾选「包含 VPN 密码和 SSH 私钥」：

- 每个 VPN 条目里直接是账号内容（`host`、`user`、`password`），每台跳板里直接是私钥内容，不再引用本机的文件路径。
- 导入时这些内容会存进 `~/Library/Application Support/NetLink/imported/`（权限 600），配置里的路径自动指过去。文件里写的路径不会被当成写入位置。
- 这样的文件里是**明文密码和私钥**，请当成密码一样保管，只交给自己信任的人。

取消勾选则只导出配置：路径会写成 `~/...`，导入后凭据文件不存在的 VPN 需要重新填账号，预览里会提示。

## Windows 版

要求 Windows 10 1809 或更新（x64）。代码在 `windows/` 目录下。

1. 从 [Releases](../../releases) 下载 `NetLink-<版本>-x64-setup.exe` 并运行，允许一次 UAC 提示。应用、openconnect（含 Wintun 驱动）和后台服务 `NetLinkService` 会一起装好，不需要另装别的。安装包没有签名，SmartScreen 拦截时点「更多信息 → 仍要运行」。
2. 打开 NetLink，点工具栏的「导入导出」导入配置。Mac 版导出的配置可以直接导入。

主窗口、拓扑图、检查器、导入导出和设置的用法和 Mac 版相同。不同的地方：

| 项目 | Windows 版 |
| --- | --- |
| VPN | openconnect 由后台服务（SYSTEM 身份）运行。应用本身不需要管理员权限，也没有免密 sudo 这一步 |
| 隧道 | 用系统自带的 `ssh.exe`（OpenSSH 客户端），断线重连由应用负责，不用 autossh |
| 菜单栏 | 换成通知区域图标：左键打开开关面板，右键是菜单，双击打开主窗口 |
| 账号文件 | 用当前 Windows 账户加密（DPAPI），别的账户和别的电脑解不开；手写的明文文件也能读 |
| 私钥 | Windows 的 ssh 要求私钥只有自己能读。导入的私钥会自动收紧权限；自己的私钥权限太宽时，跳板详情里有「修复私钥权限」 |
| 路由检查 | `routeMarker` 按 `route print` 的输出匹配 |
| Shadowrocket、FortiClient | 不支持，导入时会去掉 |
| 文件位置 | 配置在 `%APPDATA%\NetLink\config.json`；VPN 日志在 `C:\ProgramData\NetLink\openconnect.log`，在应用的「日志」窗口里看 |

只看状态不做改动：

```powershell
& "C:\Program Files\NetLink\NetLink.exe" --status | Out-Host
```

注意事项：

- 本机 80 端口常被 IIS / http.sys 占用（PID 4）。转发连不上时，提示里会写出占用端口的程序，可以把转发改到 8080 这类端口。
- 注销 Windows 时会断开 VPN；后台服务会一直运行，下次打开应用就能连接。
- 卸载会断开连接、删除后台服务；`%APPDATA%\NetLink` 里的配置和账号会保留。

## 已知限制

- 只发布 arm64 版本，依赖默认指向 `/opt/homebrew`。Intel Mac 需要自己构建并改 `openconnectPath` / `autosshPath`。
- 同一时间只有一个 `openconnect` 连接：连另一个 VPN 会先断开当前的。
- 没有开发者签名和公证，见上面的「安装」。
- 自动安装依赖需要 Homebrew；Homebrew 本身的安装要交互输入密码，应用不代为安装。
- 登录后自动打开应用不等于自动连接；要自动恢复连接，打开各节点的自动重连。

## 从源码构建

需要 Xcode 16 或更新版本（或它的命令行工具，`swiftc`）。编出来的应用仍然支持 macOS 14：`build.sh` 里固定了最低系统版本。

```bash
./scripts/build.sh          # 编译、跑自检、生成 NetLink.app
open NetLink.app
```

`NETLINK_OUT` 指定输出目录，`NETLINK_VERSION` 指定写进应用的版本号。自检也可以单独跑：

```bash
NetLink.app/Contents/MacOS/NetLink --self-test
```

`scripts/make-dmg.sh <NetLink.app> <输出.dmg>` 把构建出的应用打成安装镜像。

界面文案写在代码里，中英文并列：`tr("连接", "Connect")`（见 `app/L10n.swift`）。

### Windows 版

需要 .NET 10 SDK、Inno Setup 6 和 7-Zip，在 Windows 上执行：

```powershell
.\windows\scripts\build.ps1 -Version 0.3.0   # 测试、发布应用和服务、取 openconnect、打安装包
```

产物在 `windows\out\NetLink-0.3.0-x64-setup.exe`。openconnect 固定用官方 v9.12 的 Windows 构建，脚本会校验 sha256，见 `windows/scripts/fetch-openconnect.ps1`。

配置、导入导出、命令参数这些和系统无关的部分在 `windows/src/NetLink.Core`，测试在任何系统上都能跑：

```bash
dotnet test windows/tests/NetLink.Tests
```

### 发布

推送 `v*` 形式的 Tag，GitHub Actions 会编译 arm64 版本、打成 dmg 并发布到 Releases，同时打 Windows 安装包传到同一个 Release：

```bash
git tag v0.2.0
git push origin v0.2.0
```

产物是 `NetLink-v0.2.0-arm64.dmg`、`NetLink-v0.2.0-x64-setup.exe` 和各自的 `.sha256`，应用内版本号取自 Tag。每次推送到 `main` 和每个 PR 也会跑一遍两个版本的编译和测试。

## 许可证

[MIT](LICENSE)

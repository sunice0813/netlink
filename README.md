# NetLink

macOS 菜单栏应用，用来管理访问公司内网的这条链路：

```
本机 → （Shadowrocket）→ VPN → 跳板机 → 内网服务
```

它把三件事放在一张图里：

- **VPN**：用 `openconnect` 连接 AnyConnect 协议的 VPN，掉线自动重连。
- **SSH 隧道**：通过跳板机把内网服务转发到本机端口（`autossh`），每条转发单独开关。
- **状态**：每个节点是否在线一眼可见，哪一环断了直接看图。

关掉窗口不会断开连接，菜单栏图标一直在。

## 安装

要求 macOS 14 或更新，Apple Silicon（arm64）。

1. 安装依赖：

   ```bash
   brew install openconnect autossh
   ```

2. 在 [Releases](../../releases) 下载 `NetLink-<版本>-arm64.dmg`，打开后把 NetLink 拖进「应用程序」。
3. 解除下载带来的隔离标记：

   ```bash
   xattr -dr com.apple.quarantine /Applications/NetLink.app
   ```

4. **配置免密 sudo（必须，见下面「免密 sudo」）**。不配置的话，连接和断开都会失败。
5. 打开 NetLink。

发布的版本没有开发者签名和公证，所以第 3 步是必需的，否则 macOS 会提示「无法验证是否包含恶意软件」。较新的系统上右键选择「打开」已经绕不过这个提示；不想用命令的话，可以在 系统设置 → 隐私与安全性 里点「仍要打开」。

## 快速开始

首次启动会生成带占位值的配置，需要换成自己的环境。

1. **VPN 账号**：点 VPN 节点，选「修改账号」，填 VPN 主机、用户名和密码。
2. **跳板机**：点跳板节点，选「修改跳板」，填 `user@host` 和 SSH 私钥路径。
3. **转发**：点跳板节点，选「添加隧道」，填本地端口和内网目标地址。
4. **连接**：点转发节点或跳板节点的「连接」。跳板机不通时，会先连 VPN。
5. **连通性探测**：在 设置 → VPN 健康检查 里，把「路由里要出现的网段」和「要 ping 的网关」改成你们内网的值，见下面「配置」。网关可以写成 `主机:端口`，改用 TCP 探测。

密码只写在本机的凭据文件里（默认 `~/.internalvpn`，权限 600）。程序把它从标准输入交给 `openconnect`，不会出现在命令行参数、日志或配置里。

## 功能

| 功能 | 说明 |
| --- | --- |
| 拓扑图 | 本机、VPN、跳板、转发画成一张图，线亮表示这一段是通的。节点可以拖动，位置会保存 |
| 多个 VPN 和跳板 | 一个跳板挂在哪个 VPN 下、一条转发走哪台跳板，都可以单独设置 |
| 上游关系 | 可以标出某个 VPN 的流量先经过另一个 VPN（例如 Shadowrocket）。只影响画图和状态显示，不改连接 |
| 自动重连 | VPN 和隧道各有开关。连续失败 2 次才重启，次数和间隔可配置 |
| 系统 VPN | 能识别 Shadowrocket 和 FortiClient，显示状态、打开和退出应用 |
| 导入导出 | 头部「导入导出」：把配置导出成 JSON，或从文件导入。可以连 VPN 账号和 SSH 私钥一起带走，换一台机器导入就能用。导入前先预览并校验，替换前自动备份 |
| 开机启动 | 设置里的开关，登录后自动打开本应用（不会自动连接） |
| 日志 | VPN 和隧道的日志页，密码不会出现在里面 |

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

配置文件在 `~/Library/Application Support/NetLink/config.json`。账号、跳板、转发、健康检查的主要项在设置页里可以改；`tunnelFailThreshold`、`forwards[].check`、`openconnectPath` / `autosshPath` 等只能直接改文件。转发规则改完要重启隧道才生效。

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

## 免密 sudo

**这一步是必须的。** 应用用 `sudo -n` 调用需要 root 的命令，`-n` 表示不允许询问密码。没有免密授权时命令会直接失败，窗口顶部会提示「sudo 不能免密执行，连接和断开都会失败」。

需要 root 的原因：`openconnect` 要建虚拟网卡、改路由；`autossh` 要监听 80 这类低端口；结束 root 起的进程要用 `kill`，查端口占用要用 `lsof`。

用 `sudo visudo -f /etc/sudoers.d/netlink` 创建：

```
# 把 yourname 换成自己的用户名
yourname ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect, /opt/homebrew/bin/autossh, /bin/kill, /usr/sbin/lsof, /usr/bin/true
```

这五项缺一不可，少了哪项，对应的操作就会失败：

| 命令 | 用途 |
| --- | --- |
| `openconnect` | 连接 VPN |
| `autossh` | 建立 SSH 隧道 |
| `kill` | 断开时结束 VPN 和隧道进程 |
| `lsof` | 查本地端口是被谁占用 |
| `true` | 启动时探测 sudo 是否免密可用 |

如果机器上已经有 `NOPASSWD: ALL` 这样的宽泛规则，就不用再加。可以用下面的命令检查，没有报错说明已经满足：

```bash
sudo -n true && echo ok
```

另外，日志和进程文件属 root 时，程序会对家目录下 `.pid` / `.log` 结尾的文件回退用 `cat`、`tail`、`tee`、`rm`。这几项是可选的，不放行只是读不到 root 属主的日志内容。

程序只会结束带自己 `-E <隧道日志>` 标记的 `autossh` / `ssh` 进程，不会动占着同一端口的其他程序。`kill` 的免密授权范围较大，请只在自己的机器上这样配置。

## 已知限制

- 只发布 arm64 版本，依赖默认指向 `/opt/homebrew`。Intel Mac 需要自己构建并改 `openconnectPath` / `autosshPath`。
- 同一时间只有一个 `openconnect` 连接：连另一个 VPN 会先断开当前的。
- 没有开发者签名和公证，见上面的「安装」。
- 登录后自动打开应用不等于自动连接；要自动恢复连接，打开各节点的自动重连。

## 从源码构建

需要 Xcode 命令行工具（`swiftc`）。

```bash
./scripts/build.sh          # 编译、跑自检、生成 NetLink.app
open NetLink.app
```

`NETLINK_OUT` 指定输出目录，`NETLINK_VERSION` 指定写进应用的版本号。自检也可以单独跑：

```bash
NetLink.app/Contents/MacOS/NetLink --self-test
```

`scripts/make-dmg.sh <NetLink.app> <输出.dmg>` 把构建出的应用打成安装镜像。

### 发布

推送 `v*` 形式的 Tag，GitHub Actions 会编译 arm64 版本、打成 dmg 并发布到 Releases：

```bash
git tag v0.2.0
git push origin v0.2.0
```

产物是 `NetLink-v0.2.0-arm64.dmg` 和对应的 `.sha256`，应用内版本号取自 Tag。每次推送到 `main` 和每个 PR 也会跑一遍编译和自检。

## 许可证

[MIT](LICENSE)

# 内网连接

把 `~/.zsh/conf.d/05-vpn.zsh` 和 `06-ssh-tunnel.zsh` 里的 VPN、SSH 隧道做成一个 macOS 应用。窗口里可以看状态、连接、断开、重启；菜单栏图标一直在。

密码仍然只放在 `~/.internalvpn`。程序把它从标准输入交给 `openconnect`，不会写进命令行参数，也不会写进这个仓库。

## 和原来的命令

| 终端 | 应用 |
| --- | --- |
| `startvpn` / `stopvpn` / `restartvpn` | VPN 卡片上的连接、断开、重启 |
| `starttunnel` | 「连接隧道」。跳板不通时会先连 VPN |
| `stoptunnel` / `restarttunnel` | 隧道卡片上的断开、重启 |
| 自动重连 | 连接成功后默认开启。终端里的守护还在跑时，应用不会再起一份，除非点「改由本应用守护」 |

健康检查：VPN 看进程、`routeMarker` 路由，以及 `pingHost` 能不能连通；隧道看每条转发能不能响应。VPN 和隧道都是连续失败 2 次才重启（`vpnFailThreshold`、`tunnelFailThreshold`）。

## 构建

```bash
./scripts/build.sh
open NetLink.app
```

只看状态、不改连接：

```bash
NetLink.app/Contents/MacOS/NetLink --status
```

关掉窗口不会退出。菜单栏里的「退出并断开」会先停掉 VPN、隧道和本应用的后台守护，再退出。

配置在 `~/Library/Application Support/NetLink/config.json`。转发规则改完要重启隧道才生效。

## 配置项

首次启动会生成带占位值的 `config.json`，需要换成自己的环境。几个要注意的：

| 键 | 说明 |
| --- | --- |
| `routeMarker` | 连上 VPN 后，`netstat -rn` 里应该出现的网段片段 |
| `pingHost` | VPN 连通性探测。写 `主机:端口` 用 TCP 连接（推荐，很多内网主机不回 ICMP），不带端口则 ping |
| `forwards[].check` | `http`（默认，请求一次 HTTP，端到端）或 `tcp`（只看本地端口，给数据库、SSH 等非 HTTP 目标用） |
| `jumps[].vpnID` | 这台跳板挂在哪个 VPN 下；连隧道时跳板不通会先连这个 VPN |
| `vpns[].viaID` | 这个 VPN 的流量先经过哪个 VPN（例如 Shadowrocket）。只影响画图和状态显示 |

日志、进程文件（`vpnPidFile`、`vpnLogFile`、`tunnelLogFile`）必须在家目录下，以 `.pid` / `.log` 结尾。需要 root 才能读写它们时，程序只会对这几类文件使用 sudo。

配置文件读不了时，后台操作和自动重连都会停手，不会拿默认值去连接或覆盖原文件。在界面里点保存会覆盖，并先备份成 `config.json.bak`。

## Shadowrocket

Shadowrocket 在 Mac 上是 iOS 应用，没有命令行开关。图上能显示它是否已连接、打开或退出应用，「连接/断开」会打开应用，开关要在里面点。

## 免密 sudo

连接和断开用 `sudo -n` 调用 `openconnect`、`autossh`、`kill`、`lsof`，需要在 sudoers 里放行。应用只结束带自己 `-E <隧道日志>` 标记的 autossh/ssh 进程，不会动占着同一端口的其他程序。

## 安装

在 [Releases](../../releases) 下载 `NetLink-<版本>-arm64.dmg`，然后：

1. 双击打开 dmg，把 NetLink 拖进「应用程序」。
2. 在终端执行一次，解除下载带来的隔离标记：

   ```bash
   xattr -dr com.apple.quarantine /Applications/NetLink.app
   ```

3. 打开 NetLink。

发布的版本没有开发者签名和公证，所以第 2 步是必需的，否则 macOS 会提示「无法验证是否包含恶意软件」。较新的系统上，右键选择「打开」已经绕不过这个提示。不想用命令的话，可以在 系统设置 → 隐私与安全性 里点「仍要打开」。

依赖：`brew install openconnect autossh`。需要免密 sudo，见下面「免密 sudo」一节。

## 发布

推送 `v*` 形式的 Tag，GitHub Actions 会编译 arm64 版本、打成 dmg 并发布到 Releases：

```bash
git tag v0.2.0
git push origin v0.2.0
```

产物是 `NetLink-v0.2.0-arm64.dmg` 和对应的 `.sha256`，应用内版本号取自 Tag。

每次推送到 `main` 和每个 PR 也会跑一遍编译和自检（`.github/workflows/ci.yml`）。本地构建可以用 `NETLINK_OUT` 指定输出目录、`NETLINK_VERSION` 指定版本号；`scripts/make-dmg.sh` 可以把构建出的应用打成 dmg。

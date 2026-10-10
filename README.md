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

健康检查和原来一样：VPN 看进程、`172.16.88` 路由和网关 ping；隧道看本机转发端口能不能打开。VPN 连续失败 2 次才重启，隧道一次不通就重启。

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

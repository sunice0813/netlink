# NetLink

English | [中文](README.zh.md)

A macOS menu bar app for managing the path into a company intranet:

```
This Mac → (Shadowrocket) → VPN → jump host → intranet services
```

It puts three things on one map:

- **VPN**: connects to AnyConnect VPNs with `openconnect` and reconnects automatically when the link drops.
- **SSH tunnels**: forwards intranet services to local ports through a jump host (`autossh`). Each forward can be switched on and off on its own.
- **Status**: see at a glance whether each node is up, and which hop is broken.

Closing the window doesn't disconnect anything; the menu bar icon stays.

## Install

Requires macOS 14 or later, Apple Silicon, and [Homebrew](https://brew.sh).

1. Download `NetLink-<version>-arm64.dmg` from [Releases](../../releases) and drag NetLink into Applications.
2. Run this in Terminal (the app isn't signed, so the quarantine flag has to be removed once):

   ```bash
   xattr -dr com.apple.quarantine /Applications/NetLink.app
   ```

3. Open NetLink, enter your Mac password once when asked, then click **Import / Export** to import your config.

On first launch NetLink installs `openconnect` and `autossh` automatically, which can take a few minutes. The password lets the VPN and tunnels connect and disconnect later without asking each time.

## Quick start

If someone gave you an exported config (with VPN accounts and keys), import it and click **Connect**. Nothing below is needed. To set things up from scratch:

1. **VPN account**: click the VPN node, choose **Edit account**, and enter the VPN host, user name and password.
2. **Jump host**: click the jump host node, choose **Edit jump host**, and enter `user@host` and the SSH private key path.
3. **Forwards**: click the jump host node, choose **Add tunnel**, and enter the local port and the intranet target.
4. **Connect**: click **Connect** on a forward or jump host node. If the jump host is unreachable, the VPN is connected first.
5. **Health check**: in Settings → VPN Health Check, set "Network expected in the routes" and "Gateway to ping" to your intranet values (see [Configuration](#configuration)). The gateway can be written as `host:port` to use a TCP check instead.

The password is only stored in the credential file on this Mac (`~/.internalvpn` by default, mode 600). The app passes it to `openconnect` on standard input; it never appears in command-line arguments, logs or the config.

## Features

| Feature | Description |
| --- | --- |
| Topology map | This Mac, VPNs, jump hosts and forwards drawn as one map; a lit line means that hop is up. Nodes can be dragged and their positions are saved |
| Multiple VPNs and jump hosts | Choose which VPN each jump host sits behind and which jump host each forward uses |
| Upstream | Mark that a VPN's traffic first goes through another VPN (such as Shadowrocket). Only affects the map and status, not the connection |
| Auto-reconnect | Separate switches for the VPN and tunnels. Restarts only after 2 consecutive failures; the count and interval are configurable |
| System VPNs | Detects Shadowrocket and FortiClient, shows their status, and opens or quits them |
| Import / Export | Export the config as JSON or import it from a file. VPN accounts and SSH private keys can be included, so importing on another Mac just works. Imports are previewed and validated, and the current config is backed up before it's replaced |
| Launch at login | A switch in Settings that opens the app after login (it doesn't connect by itself) |
| Logs | Log pages for the VPN and tunnels; passwords never appear in them |
| Language | English and Chinese. Follows the system by default and can be changed in Settings |

To print the status without changing anything:

```bash
/Applications/NetLink.app/Contents/MacOS/NetLink --status
```

### Quitting

Closing the window only hides it; connections and the background service keep running. **Quit and Disconnect** in the menu bar stops the VPN, tunnels and background service, then quits.

### Shadowrocket and FortiClient

- **Shadowrocket** is an iOS app on the Mac and has no command-line switch. The map shows whether it's connected; Connect / Disconnect opens the app, and you toggle it there.
- **FortiClient** connections rely on its private components and may break after a FortiClient update. If it isn't installed, it doesn't appear on the map.

## Configuration

The config file is `~/Library/Application Support/NetLink/config.json`. Accounts, jump hosts, forwards and the main health-check options can be changed in Settings; `tunnelFailThreshold`, `forwards[].check`, `openconnectPath` / `autosshPath` and a few others can only be changed in the file. Restart the tunnel after changing forwards.

| Key | Description |
| --- | --- |
| `routeMarker` | A network prefix that should appear in `netstat -rn` once the VPN is up, such as `10.0.0` |
| `pingHost` | VPN reachability check. `host:port` uses a TCP connection (recommended, since many intranet hosts don't answer ICMP); without a port it pings |
| `reconnectTimeout` | Seconds passed to `openconnect --reconnect-timeout` |
| `vpnWatchdogInterval` / `tunnelWatchdogInterval` | Check interval in seconds, at least 5 |
| `vpnFailThreshold` / `tunnelFailThreshold` | Consecutive failures before restarting, at least 1 |
| `jumps[].vpnID` | Which VPN this jump host sits behind; when connecting a tunnel and the jump host is unreachable, this VPN is connected first |
| `vpns[].viaID` | Which VPN this VPN's traffic goes through first. Only affects the map |
| `forwards[].check` | `http` (default, makes one HTTP request end to end) or `tcp` (only checks the local port, for databases, SSH and other non-HTTP targets) |
| `forwards[].openHost` | Host name used when opening the forward in a browser; empty means `127.0.0.1` |
| `openconnectPath` / `autosshPath` | Executable locations; default to the Homebrew paths on Apple Silicon |

Log and pid files (`vpnPidFile`, `vpnLogFile`, `tunnelLogFile`) must be inside your home folder and end in `.pid` / `.log`. This limits which files the app can touch when it needs root.

If the config file can't be read, background actions and auto-reconnect stop rather than connecting with defaults or overwriting the file. Clicking Save in the app overwrites it, after backing it up as `config.json.bak`.

### Import / Export

"Include VPN passwords and SSH private keys" is checked by default when exporting:

- Each VPN entry contains the account itself (`host`, `user`, `password`), and each jump host contains the private key itself, instead of paths on this Mac.
- On import, these are stored in `~/Library/Application Support/NetLink/imported/` (mode 600) and the config paths point there. Paths written in the file are never used as write locations.
- Such a file contains **plain-text passwords and private keys**. Keep it as safe as a password and only give it to people you trust.

With the option unchecked, only the config is exported: paths are written as `~/...`, and VPNs whose credential file doesn't exist after import need their account entered again. The preview points these out.

## Known limitations

- Only arm64 builds are published, and dependencies default to `/opt/homebrew`. On an Intel Mac, build it yourself and change `openconnectPath` / `autosshPath`.
- Only one `openconnect` connection at a time: connecting another VPN disconnects the current one first.
- No Developer ID signing or notarization; see [Install](#install).
- Installing dependencies automatically requires Homebrew. Installing Homebrew itself asks for a password interactively, so the app doesn't do it for you.
- Opening the app at login doesn't mean connecting automatically; turn on auto-reconnect on each node for that.

## Build from source

Requires the Xcode command line tools (`swiftc`).

```bash
./scripts/build.sh          # compile, run the self-test, build NetLink.app
open NetLink.app
```

`NETLINK_OUT` sets the output folder and `NETLINK_VERSION` the version written into the app. The self-test can also be run on its own:

```bash
NetLink.app/Contents/MacOS/NetLink --self-test
```

`scripts/make-dmg.sh <NetLink.app> <output.dmg>` packages a built app as a disk image.

UI text lives in the code, with Chinese and English side by side: `tr("连接", "Connect")` (see `app/L10n.swift`).

### Release

Push a tag like `v*` and GitHub Actions builds the arm64 app, packages it as a dmg and publishes it to Releases:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The outputs are `NetLink-v0.2.0-arm64.dmg` and its `.sha256`; the app version comes from the tag. Every push to `main` and every PR also runs the build and self-test.

## License

[MIT](LICENSE)

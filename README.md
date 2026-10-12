# NetLink

English | [中文](README.zh.md)

A small macOS and Windows app for managing the path into a company intranet:

```
This computer → (Shadowrocket) → VPN → jump host → intranet services
```

It puts three things on one map:

- **VPN**: connects to AnyConnect VPNs with `openconnect` and reconnects automatically when the link drops.
- **SSH tunnels**: forwards intranet services to local ports through a jump host. Each forward can be switched on and off on its own.
- **Status**: see at a glance whether each node is up, and which hop is broken.

Closing the window doesn't disconnect anything: the menu bar icon (macOS) or notification area icon (Windows) stays.

| Platform | Requirements | Installer | Source |
| --- | --- | --- | --- |
| macOS | macOS 14 or later, Apple Silicon | `NetLink-<version>-arm64.dmg` | `mac/` |
| Windows | Windows 10 1809 or later, x64 | `NetLink-<version>-x64-setup.exe` | `windows/` |

Both versions use the same config and export format, so a config exported on one imports on the other.

## Install

Installers are on [Releases](../../releases).

### macOS

Requires [Homebrew](https://brew.sh).

1. Download `NetLink-<version>-arm64.dmg` and drag NetLink into Applications.
2. Run this in Terminal (the app isn't signed, so the quarantine flag has to be removed once):

   ```bash
   xattr -dr com.apple.quarantine /Applications/NetLink.app
   ```

3. Open NetLink, enter your Mac password once when asked, then click **Import / Export** to import your config.

On first launch NetLink installs `openconnect` and `autossh` automatically, which can take a few minutes. The password lets the VPN and tunnels connect and disconnect later without asking each time.

### Windows

1. Download `NetLink-<version>-x64-setup.exe`, run it and allow the UAC prompt once. It installs the app, openconnect (with the Wintun driver) and the `NetLinkService` background service; nothing else needs installing.
2. The installer isn't signed, so if SmartScreen stops it, click **More info → Run anyway**.
3. Open NetLink and click **Import / Export** in the toolbar to import your config.

SSH tunnels use the OpenSSH Client built into Windows (`ssh.exe`). If it has been removed, the app says so at the top; add it back under **Settings → System → Optional features**.

## Quick start

If someone gave you an exported config (with VPN accounts and keys), import it and click **Connect**. Nothing below is needed. To set things up from scratch:

The main window has the node list on the left, the map in the middle, and the details of the selected node on the right (the inspector). Select a node in the list or on the map, or right-click it, to act on it.

1. **VPN account**: select the VPN and click **Edit Account** in the inspector. Enter the VPN host, user name and password.
2. **Jump host**: select the jump host and click **Edit Jump Host**. Enter `user@host` and the SSH private key path.
3. **Forwards**: select the jump host and click **Add Forward**. Enter the local port and the intranet target.
4. **Connect**: turn on the switch at the top of the inspector for a forward or jump host. If the jump host is unreachable, the VPN is connected first.
5. **Health check**: in Settings (⌘, on macOS, Ctrl+, on Windows) → Health Check, set the network expected in the routes and the gateway to your intranet values (see [Configuration](#configuration)). The gateway can be written as `host:port` to use a TCP check instead.

The password is only stored in the credential file on this computer: `~/.internalvpn` by default on macOS (mode 600); on Windows it's encrypted with your account (DPAPI), so other accounts and other computers can't read it. The app passes it to `openconnect` on standard input; it never appears in command-line arguments, logs or the config.

## Features

| Feature | Description |
| --- | --- |
| Topology map | This computer, VPNs, jump hosts and forwards drawn as one map; a solid green line means that hop is up. Nodes can be dragged and their positions are saved; dropping a forward next to another jump host moves it there |
| Inspector | The selected node's status, connect switch, details and actions in one panel |
| Multiple VPNs and jump hosts | Choose which VPN each jump host sits behind and which jump host each forward uses |
| Upstream | Mark that a VPN's traffic first goes through another VPN (such as Shadowrocket). Only affects the map and status, not the connection |
| Auto-reconnect | Separate switches for the VPN and tunnels. Restarts only after 2 consecutive failures; the count and interval are configurable |
| System VPNs (macOS only) | Detects Shadowrocket and FortiClient, shows their status, and opens or quits them |
| Import / Export | Export the config as JSON or import it from a file. VPN accounts and SSH private keys can be included, so importing on another computer (macOS or Windows) just works. Imports are previewed and validated, and the current config is backed up before it's replaced |
| Launch at login | A switch in Settings that opens the app after login (it doesn't connect by itself). On Windows it starts in the notification area |
| Logs | A separate window with VPN, tunnel and install (on Windows: app) logs; passwords never appear in them |
| Language | English and Chinese. Follows the system by default and can be changed in Settings |
| Menu bar / notification area | A switch for each VPN and forward, plus auto-reconnect. On Windows, left-click opens the switch panel, right-click shows the menu, double-click opens the main window |

To print the status without changing anything:

```bash
/Applications/NetLink.app/Contents/MacOS/NetLink --status
```

```powershell
& "C:\Program Files\NetLink\NetLink.exe" --status | Out-Host
```

### Quitting

Closing the window only hides it; connections and auto-reconnect keep running. **Quit and Disconnect** in the menu bar (on Windows, the notification area icon's right-click menu) stops the VPN and tunnels, then quits.

### Shadowrocket and FortiClient

Only the macOS version supports them; the Windows version leaves them out when importing a config.

- **Shadowrocket** is an iOS app on the Mac and has no command-line switch. The map shows whether it's connected; Connect / Disconnect opens the app, and you toggle it there.
- **FortiClient** connections rely on its private components and may break after a FortiClient update. If it isn't installed, it doesn't appear on the map.

## Configuration

| | macOS | Windows |
| --- | --- | --- |
| Config file | `~/Library/Application Support/NetLink/config.json` | `%APPDATA%\NetLink\config.json` |
| Imported accounts and keys | `~/Library/Application Support/NetLink/imported/` | `%APPDATA%\NetLink\imported\` |
| VPN log | `~/.vpn.log` | `C:\ProgramData\NetLink\openconnect.log` (shown in the app's **Logs** window) |

Accounts, jump hosts and forwards are edited in the main window's inspector; health checks and program paths are in Settings. `forwards[].check` and a few others can only be changed in the file. Restart the tunnel after changing forwards.

| Key | Description |
| --- | --- |
| `routeMarker` | A network prefix that should appear in the routing table once the VPN is up, such as `10.0.0`. macOS checks `netstat -rn`, Windows checks `route print` |
| `pingHost` | VPN reachability check. `host:port` uses a TCP connection (recommended, since many intranet hosts don't answer ICMP); without a port it pings |
| `reconnectTimeout` | Seconds passed to `openconnect --reconnect-timeout` |
| `vpnWatchdogInterval` / `tunnelWatchdogInterval` | Check interval in seconds, at least 5 |
| `vpnFailThreshold` / `tunnelFailThreshold` | Consecutive failures before restarting, at least 1 |
| `jumps[].vpnID` | Which VPN this jump host sits behind; when connecting a tunnel and the jump host is unreachable, this VPN is connected first |
| `vpns[].viaID` | Which VPN this VPN's traffic goes through first. Only affects the map |
| `forwards[].check` | `http` (default, makes one HTTP request end to end) or `tcp` (only checks the local port, for databases, SSH and other non-HTTP targets) |
| `forwards[].openHost` | Host name used when opening the forward in a browser; empty means `127.0.0.1` |
| `openconnectPath` / `autosshPath` | Executable locations on macOS; default to the Homebrew paths on Apple Silicon. The Windows version doesn't use them and keeps them as they are |
| `sshPath` | Location of `ssh.exe` on Windows; defaults to the built-in OpenSSH Client. The macOS version ignores it |

Log and pid files (`vpnPidFile`, `vpnLogFile`, `tunnelLogFile`) must be inside your home folder and end in `.pid` / `.log`. This limits which files the app can touch and which processes it will stop.

If the config file can't be read, background actions and auto-reconnect stop rather than connecting with defaults or overwriting the file. Clicking Save in the app overwrites it, after backing it up as `config.json.bak`.

### Import / Export

"Include VPN passwords and SSH private keys" is checked by default when exporting:

- Each VPN entry contains the account itself (`host`, `user`, `password`), and each jump host contains the private key itself, instead of paths on this computer.
- On import, these are stored in the app's own `imported` folder, readable only by the current user, and the config paths point there. Paths written in the file are never used as write locations.
- Such a file contains **plain-text passwords and private keys**. Keep it as safe as a password and only give it to people you trust.

With the option unchecked, only the config is exported: paths inside your home folder are written as `~/...`, and VPNs whose credential file doesn't exist after import need their account entered again. The preview points these out.

## macOS and Windows differences

The interface and workflow are the same; these parts follow each system's conventions:

| Item | macOS | Windows |
| --- | --- | --- |
| Running the VPN | The app runs `openconnect` through passwordless sudo; you enter your Mac password once on first launch | The `NetLinkService` background service (running as SYSTEM) runs the bundled `openconnect`; the app itself needs no admin rights |
| Tunnels | `autossh` | The built-in `ssh.exe`; the app reconnects dropped tunnels itself |
| Dependencies | Installed with Homebrew on first launch | All included in the installer |
| Auto-reconnect | Handled by a separate background process | Runs inside the app, so it works while the app is open (including hidden in the notification area) |
| Private key permissions | No special requirement | Windows' ssh requires keys only you can read. Imported keys are locked down automatically; if your own key is too open, the jump host details offer **Fix Key Permissions** |
| Signing out | Disconnects when the app quits | Signing out of Windows disconnects the VPN; the background service keeps running, so the app can connect again next time it opens |

## Known limitations

Both:

- Only one `openconnect` connection at a time: connecting another VPN disconnects the current one first.
- Opening the app at login doesn't mean connecting automatically; turn on auto-reconnect on each node for that.
- The installers aren't signed; see [Install](#install).

macOS:

- Only arm64 builds are published, and dependencies default to `/opt/homebrew`. On an Intel Mac, build it yourself and change `openconnectPath` / `autosshPath`.
- Installing dependencies automatically requires Homebrew. Installing Homebrew itself asks for a password interactively, so the app doesn't do it for you.

Windows:

- Only x64 builds are published.
- Local port 80 is often taken by IIS / http.sys (PID 4). If a forward can't start, the message names the program holding the port; move the forward to a port like 8080.
- Uninstalling disconnects everything and removes the background service; the config and accounts in `%APPDATA%\NetLink` are kept.

## Build from source

### macOS

Requires Xcode 16 or later, or its command line tools (`swiftc`). The app still runs on macOS 14: `build.sh` sets the deployment target explicitly.

```bash
./mac/scripts/build.sh          # compile, run the self-test, build NetLink.app
open NetLink.app
```

`NETLINK_OUT` sets the output folder (the repository root by default) and `NETLINK_VERSION` the version written into the app. The self-test can also be run on its own:

```bash
NetLink.app/Contents/MacOS/NetLink --self-test
```

`mac/scripts/make-dmg.sh <NetLink.app> <output.dmg>` packages a built app as a disk image.

### Windows

Requires the .NET 10 SDK, Inno Setup 6 and 7-Zip. On Windows:

```powershell
.\windows\scripts\build.ps1 -Version 0.3.0   # test, publish the app and service, fetch openconnect, build the installer
```

The output is `windows\out\NetLink-0.3.0-x64-setup.exe`. openconnect is pinned to the official v9.12 Windows build and its sha256 is checked; see `windows/scripts/fetch-openconnect.ps1`.

`windows/src` has three projects: `NetLink.Core` (config, import / export, command arguments; no Windows dependencies), `NetLink.Service` (the background service) and `NetLink.App` (the tray app). The core tests run on any system:

```bash
dotnet test windows/tests/NetLink.Tests
```

### UI text

Both versions keep UI text in the code, with Chinese and English side by side: `tr("连接", "Connect")` on macOS (see `mac/L10n.swift`) and `Tr("连接", "Connect")` on Windows (see `windows/src/NetLink.Core/L10n.cs`).

### Release

Push a tag like `v*` and GitHub Actions builds the macOS app, packages it as a dmg and creates the release, then builds the Windows installer and uploads it to the same release:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The outputs are `NetLink-v0.2.0-arm64.dmg`, `NetLink-v0.2.0-x64-setup.exe` and their `.sha256` files; the app version comes from the tag. Every push to `main` and every PR also builds and tests both versions, and PRs offer the Windows installer as a download.

## License

[MIT](LICENSE). Licenses for openconnect and the other third-party components bundled in the Windows installer are in `windows/THIRD-PARTY-NOTICES.txt`.

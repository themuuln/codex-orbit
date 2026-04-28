---
id: menu-daemon
title: Menu Bar and Daemon
---

# Menu Bar and Daemon

Codex Orbit exposes a local daemon that powers the macOS menu bar app and richer account-control surfaces.

## Daemon

```bash
cx daemon status
cx daemon status --json
cx daemon serve --port 8787
cx daemon launchd install
cx daemon launchd status
```

The daemon is the integration point for:

- daemon health and account snapshot inspection
- local account switching
- autoswitch coordination
- menu bar status and notifications

## Hot sessions

```bash
cx
cx hot open
cx hot switch acct_002
cx hot attach
cx hot status
cx hot stop
```

Plain `cx` uses the hot-session path by default, so the app-server can be reused across launches and account switches.

## Menu bar app

Build the Swift package:

```bash
swift build --package-path macos/CodexOrbitMenu
```

Run the daemon first, then launch the app binary from the Swift build output or open the package in Xcode.

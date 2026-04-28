---
id: commands
title: Commands
---

# Command Reference

## Core `cx` commands

```bash
cx
cx list
cx which --show-quota
cx quota
cx doctor
cx resolve
cx current
```

## Account and state operations

```bash
cx alias acct_002 work
cx pin-next
cx cooldown acct_002 5h
cx recover acct_002
cx sync-config
cx sync-agents
```

## Sharing and migration

```bash
cx share export --output ~/Desktop/codex-orbit-share.tar.gz
cx share import ~/Desktop/codex-orbit-share.tar.gz
cx share config export
cx share config import ~/Desktop/codex-orbit-config-share.tar.gz
```

## Daemon and hot session control

```bash
cx daemon status
cx daemon serve --port 8787
cx daemon launchd install
cx hot open
cx hot switch acct_002
cx hot status
cx hot stop
```

## Support

```bash
cx support --output ~/Desktop/codex-orbit-support.tar.gz
```

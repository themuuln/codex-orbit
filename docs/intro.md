---
id: intro
title: Overview
slug: /
---

# Codex Orbit

Codex Orbit is a local multi-account launcher for Codex with a provider-agnostic session router for other CLIs such as VibeProxy.

## Core capabilities

- routes plain `cx` through saved Codex accounts
- keeps a shared Codex history/session substrate while preserving per-account auth
- runs a local hot-session controller so account switches do not require a full restart
- exposes a local daemon for the macOS menu bar app
- ships `cxs` / `clisess` for provider-local mirrored session homes

## Main surfaces

- `cx`: day-to-day account routing, quota, hot sessions, daemon, sharing
- `cxs`: canonical session vault, mirror sync, import, drift inspection
- `CodexOrbitMenu`: menu bar app driven by the daemon snapshot API

## Start here

- [Installation](./installation.md)
- [Command reference](./commands.md)
- [Session router](./session-router.md)
- [Publishing docs](./publishing.md)

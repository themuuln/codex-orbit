---
id: installation
title: Installation
---

# Installation

## Requirements

- macOS or a Unix-like shell environment
- `zsh`
- `python3`
- `ripgrep`
- official `codex` CLI on `PATH`

## Direct install

```bash
./install.sh
```

By default this installs under `~/.local/share/codex-orbit/` and links `cx`, `clisess`, and `cxs` into `~/.local/bin/`.

## Shell setup

```bash
cx init --shell zsh
```

You can also install completions directly:

```bash
cx completions install zsh
```

## First login

```bash
cx login
cx list
```

## Useful follow-ups

```bash
cx doctor
cx daemon status
cx hot status
```

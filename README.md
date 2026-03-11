# codex-orbit

`codex-orbit` is a zsh wrapper for the official Codex CLI that rotates between multiple saved logins.

It is built for people who:

- use multiple Codex accounts or workspaces
- hit `5h` usage limits on one account and want to move on quickly
- want one short command, `cx`, instead of managing `CODEX_HOME` manually

## What It Does

- creates hidden account homes under `~/.codex-accounts/`
- logs each account in once and reuses the saved auth later
- launches Codex through round robin by default
- supports shell-local pinning so different terminals can stay on different accounts
- runs `/status` automatically when you launch bare `cx`

## Requirements

- macOS or Linux
- `zsh`
- official `codex` CLI installed and available in `PATH`
- `fzf` optional, but recommended for interactive pickers
- `rg` optional, used when normalizing copied config files

## Install

Add this to `~/.zshrc`:

```zsh
source /Users/ict/codex-orbit/codex-orbit.zsh
```

Reload your shell:

```zsh
source ~/.zshrc
```

## Quick Start

Create and log in the first account:

```zsh
cx login
```

Create several accounts in one go:

```zsh
cx login-loop
```

Launch Codex with the next routed account:

```zsh
cx
```

`cx` opens Codex and immediately runs `/status` so you can see which account and quota you landed on.

## Commands

- `cx`: open Codex with the next routed account and run `/status`
- `cx login`: create the next hidden account slot and sign in once
- `cx login-loop`: keep creating account slots and rerunning login until stopped
- `cx delete`: interactively pick and remove a saved account
- `cx pin`: pick a logged-in account and pin it to the current shell
- `cx pin-next`: pin the next round-robin logged-in account to the current shell
- `cx unpin`: clear the current shell pin and return to round robin
- `cx current`: show the current shell pin and last launched account
- `cx status`: show login status for all discovered account slots
- `cx list`: list all discovered account slot names

## Examples

Open Codex normally:

```zsh
cx
```

Open Codex with a prompt:

```zsh
cx "fix this bug"
```

Sign in with an API key:

```zsh
cx login --with-api-key
```

Check discovered accounts:

```zsh
cx list
cx status
```

Pin different terminals to different accounts:

Terminal 1:

```zsh
cx pin-next
cx current
cx
```

Terminal 2:

```zsh
cx pin-next
cx current
cx
```

Remove one saved account:

```zsh
cx delete
```

## Data Layout

`codex-orbit` stores state under:

```text
~/.codex-accounts/
```

Important paths:

- `~/.codex-accounts/acct_001/`
- `~/.codex-accounts/acct_002/`
- `~/.codex-accounts/.state/last_account`
- `~/.codex-accounts/.state/round_robin_last_account`

Each account home gets its own:

- `config.toml`
- `auth.json`
- logs
- memories
- temp files

## Notes

- This wrapper does not provide an official Codex quota API.
- Round robin is the default because the Codex CLI does not expose a documented machine-readable quota command.
- If you want a shell to stay on one account, use `cx pin` or `cx pin-next`.

## License

Private for now. Add a license before broad public distribution.

# codex-orbit

`codex-orbit` is a zsh wrapper for the official Codex CLI that rotates between multiple saved logins and can fetch live quota for each saved account.

It is built for people who:

- use multiple Codex accounts or workspaces
- hit `5h` usage limits on one account and want to move on quickly
- want one short command, `cx`, instead of managing `CODEX_HOME` manually

## What It Does

- creates hidden account homes under `~/.codex-accounts/`
- logs each account in once and reuses the saved auth later
- keeps session history shared across all saved accounts while auth stays per-account
- launches Codex through round robin by default
- supports shell-local pinning so different terminals can stay on different accounts
- opens Codex directly with the routed account without injecting a startup command

## Requirements

- macOS or Linux
- `zsh`
- official `codex` CLI installed and available in `PATH`
- `python3` required for shared-session migration, and recommended for `cx list`, `cx which`, and `cx quota`
- `fzf` optional, but recommended for interactive pickers
- `rg` required, used when normalizing copied config files

## Install

Homebrew:

```zsh
brew tap themuuln/tap
brew install codex-orbit
```

Direct install:

```zsh
curl -fsSL https://raw.githubusercontent.com/themuuln/codex-orbit/main/install.sh | sh
```

The direct installer defaults to the latest tagged release. To install a branch or a specific tag instead:

```zsh
curl -fsSL https://raw.githubusercontent.com/themuuln/codex-orbit/main/install.sh | CODEX_ORBIT_INSTALL_REF=main sh
curl -fsSL https://raw.githubusercontent.com/themuuln/codex-orbit/main/install.sh | CODEX_ORBIT_INSTALL_REF=v0.1.0 sh
```

Local checkout install:

```zsh
./install.sh
```

Repo-local usage without installing:

```zsh
./bin/cx --help
```

Optional legacy shell sourcing is still supported if you want the functions in your shell profile:

```zsh
source /path/to/codex-orbit/codex-orbit.zsh
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

Check dependencies and state before using it heavily:

```zsh
cx doctor
```

Launch Codex with the next routed account:

```zsh
cx
```

`cx` opens Codex directly with the routed account.

## Commands

- `cx`: open Codex with the next routed account
- `cx login`: create the next hidden account slot and sign in once
- `cx login-loop`: keep creating account slots and rerunning login until stopped
- `cx delete`: archive a saved account into trash
- `cx doctor`: validate dependencies, state paths, and account health
- `cx pin`: pick a logged-in account and pin it to the current shell
- `cx pin-next`: pin the next round-robin logged-in account to the current shell
- `cx unpin`: clear the current shell pin and return to round robin
- `cx current`: show the current shell pin and last launched account
- `cx status`: show login status for all discovered account slots
- `cx warmup`: send a minimal prompt to start the selected account's current 5h window
- `cx quota`: fetch live quota for one or all saved accounts
  Supports `--refresh` and `--source oauth|auto|rpc|status`
- `cx list`: open an interactive account browser in a TTY, or print saved accounts in non-interactive use
- `cx list --plain`: print only account slot names for scripts
- `cx list --verbose`: include workspace list, auth mode, and short account id
- `cx list --interactive`: force the interactive account browser
- `cx which`: explain which account would launch next
- `cx resolve`: print only the account that would launch next
- `cx cooldown`: list active cooldowns
- `cx cooldown <account> <duration>`: skip an account for `30m`, `5h`, or `1d`
- `cx cooldown clear <account>`: remove an active cooldown

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
cx list --verbose
cx list --interactive
cx status
cx warmup
cx warmup acct_001
cx warmup --show-quota
cx quota
cx quota acct_001
cx quota acct_001 --refresh
cx quota --source auto
cx which
cx resolve
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

Temporarily skip an exhausted account:

```zsh
cx cooldown acct_002 5h
cx cooldown
cx cooldown clear acct_002
```

## Uninstall

Homebrew install:

```zsh
brew uninstall codex-orbit
```

Direct install:

```zsh
./uninstall.sh
```

## Data Layout

`codex-orbit` stores state under:

```text
~/.codex-accounts/
```

Important paths:

- `~/.codex-accounts/acct_001/`
- `~/.codex-accounts/acct_002/`
- `~/.codex-accounts/.shared/`
- `~/.codex-accounts/.state/last_account`
- `~/.codex-accounts/.state/round_robin_last_account`
- `~/.codex-accounts/.state/cooldowns/acct_001.until`
- `~/.codex-accounts/.state/session_<tty>_pinned_account`
- `~/.codex-accounts/.trash/20260312003000_acct_002/`

Each account home keeps its own:

- `config.toml`
- `auth.json`
- temp files

Shared across all accounts:

- `history.jsonl`
- `state_5.sqlite`
- `logs_1.sqlite`
- `sessions/`
- `shell_snapshots/`
- `memories/`

## Notes

- Homebrew installs the `cx` command only. You do not need to add any `source ...` line to your shell profile for normal usage.
- The direct installer places files under `~/.local/share/codex-orbit/` and links `cx` into `~/.local/bin/` by default.
- The direct installer fetches the latest tagged release by default. Set `CODEX_ORBIT_INSTALL_REF=main` if you explicitly want the current branch head instead.
- `cx list` reads email, plan, default workspace, and workspace count from the saved `id_token` when `python3` is available.
- `cx warmup` is manual only. It sends a minimal non-interactive prompt to the selected account to deliberately start that account's current 5h window, and temporarily disables configured MCP servers for that warmup run.
- `cx warmup` skips the post-run quota refresh by default for speed. Use `cx warmup --show-quota` if you want it immediately.
- `cx list` in a terminal opens an interactive menu. Select an account, then choose one of four actions: launch, replace login, disable/enable, or delete. After an action completes, the account list stays open until you cancel it.
- Disabled accounts stay on disk but are skipped by round robin and by pinned-account resolution until re-enabled.
- `cx quota` uses the same sources CodexBar does: `auth.json` -> `https://chatgpt.com/backend-api/wham/usage`, then `codex app-server`, then `/status` as a last fallback.
- `cx quota` defaults to the fast `oauth` source. Use `cx quota --source auto` when you want the old fallback chain, or `--source rpc` / `--source status` for debugging.
- `cx quota` caches TSV snapshots for 30 seconds by default so repeated checks are fast. Set `CODEX_ORBIT_QUOTA_CACHE_TTL_SECONDS=0` to disable that cache, or set a different TTL in seconds.
- On first run after upgrading, `codex-orbit` migrates existing per-account sessions into `~/.codex-accounts/.shared/` and replaces the per-account copies with symlinks.
- One email can belong to multiple workspaces, so `cx list` shows the default workspace plus `(+N)` when more are available. Use `cx list --verbose` to see the full workspace title list.
- Round robin is the default because the Codex CLI does not expose a documented machine-readable quota command.
- If you want a shell to stay on one account, use `cx pin` or `cx pin-next`.
- `cx delete` is a soft delete and archives the account under `~/.codex-accounts/.trash/`.
- Set `CODEX_ORBIT_DEBUG=1` to print account-resolution and cooldown debug logs to stderr.

## License

MIT. See [LICENSE](/Users/ict/codex-orbit/LICENSE).

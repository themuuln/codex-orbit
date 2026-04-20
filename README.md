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
- refreshes managed account `config.toml` files from the shared `~/.codex/config.toml`
- keeps global Codex instructions available in each account home by linking `AGENTS.md` from the base `~/.codex/AGENTS.md` when present
- routes Codex launches automatically with fast round-robin selection by default
- ships `clisess`, a standalone session router that can run Codex and other CLIs (for example `vibeproxy`) using saved per-session homes
- supports shell-local pinning so different terminals can stay on different accounts
- opens Codex with the routed account through a managed local hot session by default

## Requirements

- macOS or Linux
- `zsh`
- official `codex` CLI installed and available in `PATH`
- `python3` required for shared-session migration, and recommended for `cx list`, `cx which`, and `cx quota`
- `fzf` optional, but recommended for interactive pickers
- `rg` required, used when inspecting account config files for MCP handling

## Install

Direct install:

```zsh
curl -fsSL https://raw.githubusercontent.com/themuuln/codex-orbit/main/install.sh | sh
```

The direct installer adds its bin dir to your shell rc automatically when needed. By default that is `~/.zshrc` for zsh users and `~/.bashrc` or `~/.bash_profile` for bash users. Pass `--no-modify-shell` if you want to manage `PATH` yourself.

The direct installer installs `main` by default. To pin a specific branch or tag instead:

```zsh
curl -fsSL https://raw.githubusercontent.com/themuuln/codex-orbit/main/install.sh | CODEX_ORBIT_INSTALL_REF=v0.1.0 sh
curl -fsSL https://raw.githubusercontent.com/themuuln/codex-orbit/main/install.sh | CODEX_ORBIT_INSTALL_REF=my-branch sh
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

`cx` resolves the routed account, starts or reuses the local hot session controller, switches auth if needed, then attaches Codex over `--remote`.

## Commands

- `cx`: open Codex with the next routed account through the managed hot session
- `cxs` (short) / `clisess`: standalone multi-session CLI for Codex + other CLIs
- `cx login`: create the next hidden account slot and sign in once
- `cx login-loop`: keep creating account slots and rerunning login until stopped
- `cx delete`: archive a saved account into trash
- `cx doctor`: validate dependencies, state paths, and account health
  Supports `--json` for machine-readable diagnostics
- `cx sync-agents`: relink per-account `AGENTS.md` files back to the shared `~/.codex/AGENTS.md`
- `cx sync-config`: rewrite per-account `config.toml` files from the shared `~/.codex/config.toml`
- `cx pin`: pick a logged-in account and pin it to the current shell
- `cx pin-next`: pin the next routed logged-in account to the current shell
- `cx unpin`: clear the current shell pin and return to automatic routing
- `cx current`: show the current shell pin and last launched account
- `cx status`: show login status for all discovered account slots
- `cx warmup`: send a minimal prompt to start one or more accounts' current 5h window
- `cx quota`: fetch live quota for one or all saved accounts
  Supports `--refresh` and `--source oauth|auto|rpc|status`
- `cx alias`: assign a shell-friendly alias to an account and use it in other commands
- `cx enable`: re-enable a disabled account
- `cx disable`: disable an account until you recover it
- `cx recover`: clear disabled and cooldown state for an account
- `cx update`: check for updates or update `codex-orbit` based on the current install method
- `cx version`: show the installed version and install metadata
- `cx init`: run first-time setup, optional imports, and optional shell completion setup
- `cx completions`: print or install shell completions for `zsh` or `bash`
- `cx daemon`: run or inspect the local status daemon used by the macOS menu bar app
  Supports `launchd` lifecycle helpers on macOS
- `cx support`: export a redacted diagnostics bundle for debugging
- `cx share export`: export one or more logged-in accounts into a portable archive
- `cx share import`: import accounts from a portable archive
- `cx share push`: copy accounts to another machine over `ssh` and import them there
- `cx share config export`: export the global Codex CLI config
- `cx share config import`: import the global Codex CLI config
- `cx share config push`: copy the global Codex CLI config to another machine over `ssh`
- `cx hot start`: start a persistent local `codex app-server` session
- `cx hot open`: start or reuse that hot session, then open Codex against it
- `cx hot attach`: attach another Codex TUI to the running hot session
- `cx hot switch`: switch the running hot session to another saved account without restarting the app-server
- `cx hot status`: show hot-session status, ports, and active account
- `cx hot stop`: stop the hot session controller and app-server
- `cx list`: open an interactive account browser in a TTY, or print saved accounts in non-interactive use
- `cx list --plain`: print only account slot names for scripts
- `cx list --verbose`: include workspace list, auth mode, and short account id
- `cx list --interactive`: force the interactive account browser
- `cx which`: explain which account would launch next, optionally with quota
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
cx warmup --all --mini --start-at 10:00 --message "Say hi."
cx warmup --show-quota
cx quota
cx quota acct_001
cx quota work
cx quota acct_001 --refresh
cx quota --source auto
cx alias acct_001 work
cx alias clear work
cx doctor --json
cx sync-agents
cx sync-agents acct_001 work
cx sync-config
cx sync-config acct_001 work
cx disable acct_001
cx recover acct_001
cx update --check
cx update
cx version
cx init --shell zsh
cx completions zsh
cx completions install zsh
cx daemon status
cx daemon serve --port 8787
cx daemon launchd plist
cx daemon launchd install
cx support
cx share export
cx share push user@laptop --with-config
cx share export acct_001 --output ~/Desktop/codex-orbit-share.tar.gz
cx share import ~/Desktop/codex-orbit-share.tar.gz
cx share config export
cx share config push user@laptop
cx share config import ~/Desktop/codex-orbit-config-share.tar.gz
cx which
cx resolve
```

Move saved logins to another machine:

Machine A:

```zsh
cx share export --output ~/Desktop/codex-orbit-share.tar.gz
```

Machine B:

```zsh
cx share import ~/Desktop/codex-orbit-share.tar.gz
cx list
```

Use the standalone `cxs` session router:

```zsh
# import existing codex-orbit accounts
cxs import-codex

# inspect extracted workspace + business workspace metadata
cxs list --provider codex

# run codex under a specific saved session
cxs run codex acct_001 -- codex

# add a non-codex CLI session (example: vibeproxy)
cxs add vibeproxy work --home ~/.vibeproxy/work --home-var VIBEPROXY_HOME --exec vibeproxy
cxs run vibeproxy work -- vibeproxy
```

`cxs` automatically exports provider-specific workspace vars when available:
- `CLISESS_WORKSPACE`, `CLISESS_BUSINESS_WORKSPACE`
- `${PROVIDER}_WORKSPACE`, `${PROVIDER}_BUSINESS_WORKSPACE`

For Codex sessions imported from `auth.json`, it also tries to infer the business workspace name from JWT organization claims.

Move saved logins and global config in one step:

```zsh
cx share push user@laptop --with-config
```

Managed account configs:

- New account homes start with a managed `config.toml` headed by `# codex-orbit-managed: shared ~/.codex/config.toml`.
- Managed configs refresh from `~/.codex/config.toml` when `cx` prepares the account home.
- Hand-edited account configs without that header are preserved as custom files and only get the required `cli_auth_credentials_store = "file"` normalization.
- Run `cx sync-config` to convert existing account configs back to managed mode.
- `cx sync-config` keeps timestamped `config.toml.backup-*` files when it replaces a custom config that differs from the shared base config.

Run the local daemon and inspect its snapshot:

```zsh
cx daemon status
cx daemon status --json
cx daemon serve --port 8787
```

Open Codex with zero extra setup and manage the session when needed:

```zsh
cx
cx hot switch acct_002
cx hot status
cx hot stop
```

## macOS Menu Bar App

The first macOS app scaffold lives under `macos/CodexOrbitMenu/`. It is a SwiftUI `MenuBarExtra` app that polls the local daemon at `http://127.0.0.1:8787/v1/status` by default.

Build it with:

```zsh
swift build --package-path macos/CodexOrbitMenu
```

Run the daemon first:

```zsh
cx daemon serve --port 8787
```

Then launch the built app binary from the Swift package build products, or open the package in Xcode if you want to iterate on the UI.

On macOS, you can also install the daemon as a LaunchAgent:

```zsh
cx daemon launchd plist
cx daemon launchd install
cx daemon launchd status
```

Move only the global Codex CLI config:

Machine A:

```zsh
cx share config export --output ~/Desktop/codex-orbit-config-share.tar.gz
```

Machine B:

```zsh
cx share config import ~/Desktop/codex-orbit-config-share.tar.gz
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
- `~/.codex-accounts/.state/schema_version`
- `~/.codex-accounts/.state/locks/`
- `~/.codex-accounts/.state/hot/session.json`
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

- The direct installer places files under `~/.local/share/codex-orbit/` and links `cx` into `~/.local/bin/` by default.
- When `~/.local/bin/` is not already on `PATH`, the direct installer appends a managed PATH block to your shell rc file unless you pass `--no-modify-shell`.
- The direct installer installs `main` by default. Set `CODEX_ORBIT_INSTALL_REF=vX.Y.Z` when you want to pin a release tag explicitly.
- Direct installs now write `install-metadata` under the install root so `cx version` and `cx update --check` can report the installed ref and version.
- `cx share export` includes portable login files only: per-account `auth.json` and `config.toml`. It does not export cooldowns, pins, trash, or other device-local state.
- `cx share config export` includes only `~/.codex/config.toml`. `cx share config import` replaces the target machine's global config after writing a timestamped backup when one already exists.
- `cx share push` and `cx share config push` use `ssh` and `scp` to copy archives to another machine and run the matching import command there.
- Account aliases accept only shell-friendly names made from letters, numbers, dot, underscore, and hyphen.
- `codex-orbit` now serializes state-changing operations with filesystem locks so concurrent shells do not race account creation, routing pointers, aliases, cooldowns, and imports.
- `codex-orbit` now versions its on-disk state under `~/.codex-accounts/.state/schema_version` and migrates older unversioned state forward automatically on first use.
- Bare `cx`, `cx which`, and `cx warmup` use fast round-robin routing by default so startup stays snappy. Set `CODEX_ORBIT_ROUTING=quota` when you want cached quota-aware selection instead.
- Bare interactive `cx` now uses a direct launch path by default to reduce startup overhead. Set `CODEX_ORBIT_FAST_LAUNCH=0` to keep the wrapped launch path, or `CODEX_ORBIT_FAST_LAUNCH=1` to force direct launch outside a TTY too.
- `cx which` now explains the routing strategy, the selected account, and why other saved accounts were skipped. It skips quota by default so the report stays fast; use `cx which --show-quota` when you want the live quota panel too.
- `cx list` reads email, plan, default workspace, and workspace count from the saved `id_token` when `python3` is available.
- `cx warmup` can still target one account directly, but it also supports `--all` for launchable accounts, `--mini` or `--model <name>` to force a cheaper model like `gpt-5.4-mini`, `--message` to override the default prompt, and `--start-at HH:MM` to stagger batch warmups from a local work-start time.
- Plain `cx` and hot-session account switches now auto-warm an account once per fresh 5h window when cached quota says that window is still untouched. Set `CODEX_ORBIT_AUTO_WARMUP=0` to disable that behavior.
- When you combine `cx warmup --all --start-at HH:MM`, the accounts are spread across the next 5 hours so the windows do not all start at once.
- `cx warmup` temporarily disables configured MCP servers for that warmup run.
- `cx warmup` skips the post-run quota refresh by default for speed. Use `cx warmup --show-quota` if you want it immediately.
- `cx quota` shows an interactive loading spinner in TTYs and can reuse cached snapshots for `--json` output unless you pass `--refresh`.
- `cx init --shell zsh` or `cx init --shell bash` adds a managed completion block to your shell rc file. You can also use `cx completions install zsh` or `cx completions install bash` directly.
- `cx daemon serve` runs a lightweight local HTTP service with `/health` and `/v1/status`, intended as the integration point for the macOS menu bar app and future richer clients.
- `cx list` in a terminal opens an interactive menu. Select an account, then choose one of four actions: launch, replace login, disable/enable, or delete. After an action completes, the account list stays open until you cancel it.
- Disabled accounts stay on disk but are skipped by round robin and by pinned-account resolution until re-enabled.
- Accounts that return `{"code":"deactivated_workspace"}` during launch or warmup are auto-disabled so routing stops picking them until you re-enable them.
- `cx recover <account>` clears both the disabled flag and any active cooldown for that account so recovery is a single command.
- `cx quota` uses the same sources CodexBar does: `auth.json` -> `https://chatgpt.com/backend-api/wham/usage`, then `codex app-server`, then `/status` as a last fallback.
- `cx quota` defaults to the fast `oauth` source. Use `cx quota --source auto` when you want the old fallback chain, or `--source rpc` / `--source status` for debugging.
- `cx quota` caches TSV snapshots for 30 seconds by default so repeated checks are fast. Set `CODEX_ORBIT_QUOTA_CACHE_TTL_SECONDS=0` to disable that cache, or set a different TTL in seconds.
- The quota board is still sorted by the chosen quota sort mode, but it now also shows the next round-robin target in the overview line so routing is visible even when the table is sorted by risk.
- Human-facing `cx` output honors `CODEX_ORBIT_COLOR=auto|always|never`. `NO_COLOR` overrides this and disables color.
- `cx doctor --json` emits structured health data, and `cx support` packages redacted diagnostics like doctor output, account status, aliases, cooldowns, and routing state into a tarball.
- Admin-only helpers for daemon, update, init, completions, and share are now loaded lazily so the normal launch path avoids parsing that extra code.
- The CLI now has an explicit bootstrap -> dispatch seam, and loading admin helpers no longer overrides the core runtime account-home preparation path.
- Plain `cx`, `codex_account`, and hot-session switching now share the same runtime account-priming pipeline for home prep, auto-warmup, and launch bookkeeping.
- Plain `cx` now uses the same hot-session path as `cx hot open`, so you do not need extra setup once accounts are saved.
- Round-robin now follows the account you actually launched or switched into, so manual launches and hot switches no longer leave the RR pointer behind on an older account.
- `cx hot` runs a persistent local `codex app-server` plus a small controller process. The controller keeps a dedicated websocket connection open for auth control and token refresh, while your TUI connects with `codex --remote`.
- `cx hot open` reuses the current hot session when one is already running. Add `--account <account>` when you want it to switch first.
- `cx hot` prefers `127.0.0.1:8791` for the app-server websocket and `127.0.0.1:8792` for controller status/switch control, but it now auto-selects free localhost ports when those are busy. You can still set preferred ports with `CODEX_ORBIT_HOT_APP_PORT` and `CODEX_ORBIT_HOT_CONTROL_PORT`.
- Hot sessions now track attached Codex clients and auto-shutdown after `900` idle seconds by default once the last client exits. Override that with `CODEX_ORBIT_HOT_IDLE_SECONDS`, or set it to `0` to disable idle shutdown.
- `cx hot status` now shows a short session summary, including whether the session was freshly started or switched most recently, plus the display account name.
- Set `CODEX_ORBIT_HOT_DEFAULT=0` if you ever want plain `cx` to fall back to the old per-launch behavior.
- `cx doctor` warns when account homes drift away from the shared `~/.codex/AGENTS.md`. Run `cx sync-agents` to relink them, and the command keeps timestamped backups of any standalone per-account `AGENTS.md` it replaces.
- On first run after upgrading, `codex-orbit` migrates existing per-account sessions into `~/.codex-accounts/.shared/` and replaces the per-account copies with symlinks.
- One email can belong to multiple workspaces, so `cx list` shows the default workspace plus `(+N)` when more are available. Use `cx list --verbose` to see the full workspace title list.
- Round robin is the default because it keeps startup fast and the Codex CLI does not expose a documented machine-readable quota command.
- If you want a shell to stay on one account, use `cx pin` or `cx pin-next`.
- `cx delete` is a soft delete and archives the account under `~/.codex-accounts/.trash/`.
- Set `CODEX_ORBIT_DEBUG=1` to print account-resolution and cooldown debug logs to stderr.

## License

MIT. See [LICENSE](/Users/ict/codex-orbit/LICENSE).

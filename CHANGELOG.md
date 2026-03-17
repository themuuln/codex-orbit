## [2026-03-16]

- Added `cx share export` and `cx share import` so saved logins can move between machines without re-running `codex login` on every device.
- Changed the curl installer to install `main` by default so `curl .../main/install.sh | sh` works as a single copy-paste install again; pinned tags remain available through `CODEX_ORBIT_INSTALL_REF=vX.Y.Z`.
- Added managed shell rc PATH updates for direct installs, plus matching uninstall cleanup and opt-out flags.
- Fixed `cx quota` so it prepares the selected account home before probing quota, applying shared-session migration and config normalization consistently with launch and warmup flows.
- Fixed account config normalization to deduplicate repeated `cli_auth_credentials_store` entries instead of rewriting only the first match.

## [2026-03-13]

- Improved `cx quota` list output with fixed-width square meters for the 5-hour and weekly windows.
- Aligned the all-accounts quota view into stable columns so remaining capacity, reset times, and source are easier to scan.

## [2026-03-12]

- Added `MIT` licensing and removed the remaining “private for now” release blocker.
- Added `uninstall.sh` for non-Homebrew installs.
- Changed the curl installer to prefer the latest tagged release by default, with `CODEX_ORBIT_INSTALL_REF` override support.
- Added reusable release scripts and GitHub Actions for macOS/Linux validation, Homebrew install checks, and automated tag-to-release plus tap publishing.
- Added a real `install.sh` so users can install `cx` without hardcoded local paths.
- Fixed wrapper path resolution so packaged and Homebrew installs can find `libexec` correctly through symlinks.
- Restored a root `codex-orbit.zsh` shim for backward-compatible shell sourcing.
- `cx list` now opens an interactive account browser in a TTY, with per-account actions for launch, replace login, disable/enable, and delete.
- Added a persistent disabled-account state so accounts can stay on disk but be skipped by round-robin routing.
- Optimized `cx warmup` by skipping live quota refresh by default; use `cx warmup --show-quota` when you want the follow-up snapshot.
- Added `cx warmup` for manually starting an account's current 5-hour Codex window with a minimal non-interactive prompt.
- Bare `cx` now waits for Codex startup to settle before injecting `/status`, avoiding the MCP-loading race where the command could be ignored.
- Added live quota fetching via `cx quota`, using the same CodexBar-style fallback chain: OpenAI usage API, then `codex app-server`, then `/status`.
- Enriched `cx which` with live quota summaries for the next selected account.
- Added `doctor`, `which`, `resolve`, cooldown management, and soft-delete account archiving to `codex-orbit`.
- Enriched `cx list` and `cx which` with masked email, plan, and workspace metadata, including multi-workspace summaries for a single email.

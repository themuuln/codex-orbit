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

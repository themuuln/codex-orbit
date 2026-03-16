## [2026-03-16 00:00] quota-config-prep-fix

- **Task**: update the `cx quota` wrapper so it stays compatible with current Codex account config handling
- **Changes**:
  - Changed account config normalization to collapse duplicate `cli_auth_credentials_store` entries into one canonical line.
  - Updated `cx quota` snapshot preparation to run `_codex_prepare_account_home` before invoking the quota helper.
  - Added changelog notes for the quota/config fix.
- **Files**:
  - `libexec/codex-orbit.zsh`
  - `CHANGELOG.md`
  - `CHANGELOG_AGENT.md`
- **Verification**:
  - `zsh -n libexec/codex-orbit.zsh`
  - Temporary-home config normalization smoke test for duplicate `cli_auth_credentials_store`
  - Temporary-home `bin/cx quota acct_001` smoke test with a fake `python3` shim asserting account prep ran first

## [2026-03-12 01:25] codexbar-style-quota-fetch

- **Task**: inspect CodexBar quota detection and implement the same live quota path in codex-orbit
- **Changes**:
  - Added `libexec/codex-orbit-quota.py` to fetch quota from the OpenAI usage endpoint, fall back to `codex app-server`, and finally try `/status`.
  - Added `cx quota [account] [--json]` and surfaced live quota summaries in `cx which`.
  - Added `libexec/codex-orbit-launch.py` so bare `cx` waits for Codex startup output to go quiet before injecting `/status`.
  - Added `cx warmup [account]` to deliberately start a 5h window with a minimal non-interactive Codex prompt.
  - Optimized `cx warmup` so it skips the follow-up quota fetch unless `--show-quota` is passed.
  - Added a TTY-first interactive `cx list` browser with account actions for launch, replace login, disable/enable, and delete.
  - Added persistent disabled-account state that excludes disabled accounts from round-robin selection.
  - Updated README and changelog notes to document the new quota behavior and data sources.
- **Files**:
  - `libexec/codex-orbit.zsh`
  - `libexec/codex-orbit-quota.py`
  - `libexec/codex-orbit-launch.py`
  - `README.md`
  - `CHANGELOG.md`
  - `CHANGELOG_AGENT.md`
- **Verification**:
  - `zsh -n libexec/codex-orbit.zsh`
  - `python3 -m py_compile libexec/codex-orbit-launch.py libexec/codex-orbit-quota.py`
  - `bin/cx --help`
  - Fake-`codex` smoke test for `cx list --interactive` disable action using a temporary `HOME`
  - Fake-`codex` smoke test for `cx warmup acct_001` using a temporary `HOME`
  - `bin/cx quota acct_001`
  - `bin/cx quota --json acct_001`
  - `bin/cx which`
  - `python3 libexec/codex-orbit-launch.py --account-dir "$HOME/.codex-accounts/acct_001" --initial-command /status -- python3 -c 'import sys,time; print("booting"); sys.stdout.flush(); time.sleep(1.3); print("ready"); sys.stdout.flush(); line=input(); print("received=" + line)'`

## [2026-03-12 00:39] codex-orbit-command-upgrades

- **Task**: add doctor, which and resolve, add cooldown too, and soft delete
- **Changes**:
  - Added `cx doctor`, `cx which`, `cx resolve`, and `cx cooldown` flows to the zsh wrapper.
  - Changed `cx delete` from hard delete to trash-style archive and cleared pinned/cooldown state during archive.
  - Enriched `cx list` and `cx which` with masked email, plan, default workspace, and multi-workspace summaries derived from saved auth tokens.
  - Updated README command docs, requirements, and state layout notes for the new behavior.
- **Files**:
  - `libexec/codex-orbit.zsh`
  - `README.md`
  - `CHANGELOG.md`
  - `CHANGELOG_AGENT.md`
- **Verification**:
  - `zsh -n libexec/codex-orbit.zsh`
  - `bin/cx --help`
  - Manual smoke test with temporary `HOME` and a fake `codex` binary covering `resolve`, `which`, `cooldown`, `doctor`, and soft delete

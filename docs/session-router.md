---
id: session-router
title: Session Router
---

# Session Router

`cxs` and `clisess` manage a canonical session vault under `~/.clisess/` and mirror sessions into provider-local homes.

## Canonical and mirrored homes

- canonical Codex sessions live under `~/.clisess/homes/codex/<name>/`
- mirrored provider homes live under `~/.clisess/homes/<provider>/<name>/`
- mirrors are copied into local provider homes, not symlinked

## Import and inspect

```bash
cxs import-codex
cxs import-cli-proxy
cxs list --provider codex
cxs status --provider codex
```

## Activate a session

`cxs use` prints shell-safe `export ...` lines so you can evaluate them in your current shell:

```bash
eval "$(cxs use codex acct_001 --to vibeproxy)"
```

That flow:

- selects the canonical session
- creates missing mirror targets from `--to`
- refreshes existing mirror targets before activation
- prints only activation exports

## Run a provider directly

```bash
cxs run codex acct_001 -- codex
cxs run vibeproxy acct_001 -- vibeproxy
```

## Drift inspection and repair

```bash
cxs doctor
cxs doctor --strict
cxs sync codex acct_001 --to vibeproxy
```

`cxs doctor` reports:

- stale mirrors
- missing source sessions
- missing source homes
- missing auth
- home collisions

## Deactivated-workspace cleanup

```bash
cxs cleanup-deactivated --provider codex
```

When a live quota check returns `{"detail":{"code":"deactivated_workspace"}}`, the canonical session and any dependent mirrors are removed from the vault.

#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root_dir"

temp_home=$(mktemp -d)
cleanup() {
  rm -rf "$temp_home"
}
trap cleanup EXIT INT TERM

mkdir -p "$temp_home/.codex-accounts/.state"
printf 'acct_001\n' > "$temp_home/.codex-accounts/.state/last_account"

HOME="$temp_home" ./bin/cx doctor --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["state_schema_version"] == 1'
test -f "$temp_home/.codex-accounts/.state/schema_version"
test "$(cat "$temp_home/.codex-accounts/.state/schema_version")" = "1"
test -d "$temp_home/.codex-accounts/.state/locks"

future_home=$(mktemp -d)
mkdir -p "$future_home/.codex-accounts/.state"
printf '999\n' > "$future_home/.codex-accounts/.state/schema_version"
if HOME="$future_home" ./bin/cx doctor >/dev/null 2>&1; then
  echo "future schema version should fail" >&2
  rm -rf "$future_home"
  exit 1
fi
rm -rf "$future_home"

reserve_home=$(mktemp -d)
mkdir -p "$reserve_home/.codex-accounts"
HOME="$reserve_home" zsh -c 'source ./codex-orbit.zsh; _codex_ensure_state_schema >/dev/null; _codex_reserve_next_account' > "$reserve_home/out.1" &
pid1=$!
HOME="$reserve_home" zsh -c 'source ./codex-orbit.zsh; _codex_ensure_state_schema >/dev/null; _codex_reserve_next_account' > "$reserve_home/out.2" &
pid2=$!
wait "$pid1"
wait "$pid2"
test "$(sort "$reserve_home"/out.* | uniq | wc -l | tr -d ' ')" = "2"
test -d "$reserve_home/.codex-accounts/acct_001"
test -d "$reserve_home/.codex-accounts/acct_002"
rm -rf "$reserve_home"

rr_home=$(mktemp -d)
mkdir -p "$rr_home/.codex-accounts/acct_001" "$rr_home/.codex-accounts/acct_002"
: > "$rr_home/.codex-accounts/acct_001/auth.json"
: > "$rr_home/.codex-accounts/acct_002/auth.json"
: > "$rr_home/.codex-accounts/acct_001/config.toml"
: > "$rr_home/.codex-accounts/acct_002/config.toml"
HOME="$rr_home" zsh -c 'source ./codex-orbit.zsh; _codex_ensure_state_schema >/dev/null; _codex_round_robin_account' > "$rr_home/rr.1" &
pid1=$!
HOME="$rr_home" zsh -c 'source ./codex-orbit.zsh; _codex_ensure_state_schema >/dev/null; _codex_round_robin_account' > "$rr_home/rr.2" &
pid2=$!
wait "$pid1"
wait "$pid2"
test "$(sort "$rr_home"/rr.* | uniq | wc -l | tr -d ' ')" = "2"
rm -rf "$rr_home"

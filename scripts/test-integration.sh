#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root_dir"

./bin/cx --help >/dev/null
zsh -c 'source ./codex-orbit.zsh && cx --help >/dev/null'

temp_home=$(mktemp -d)
cleanup() {
  kill "${occupy_pid:-}" 2>/dev/null || true
  rm -rf "$temp_home" "${import_home:-}" "${config_home:-}"
}
trap cleanup EXIT INT TERM

HOME="$temp_home" ./install.sh --bin-dir "$temp_home/bin" --install-dir "$temp_home/share/codex-orbit"
"$temp_home/bin/cx" --help >/dev/null
"$temp_home/bin/cxr" --help >/dev/null
test -f "$temp_home/share/codex-orbit/install-metadata"
HOME="$temp_home" "$temp_home/bin/cx" version | grep -F 'Install: direct' >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" completions zsh | grep -F '#compdef cx' >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" init --shell zsh >/dev/null
grep -F '# >>> codex-orbit completions >>>' "$temp_home/.zshrc" >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" daemon url | grep -F 'http://127.0.0.1:8787' >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" daemon launchd plist | grep -F '<string>com.codex-orbit.daemon</string>' >/dev/null

mkdir -p "$temp_home/mockbin"
cat > "$temp_home/mockbin/codex" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = "login" ]; then
  test -n "${CODEX_HOME:-}"
  mkdir -p "$CODEX_HOME"
  printf '{"tokens":{"access_token":"YOUR_ACCESS_TOKEN_HERE_LOGIN","account_id":"acct-login"}}\n' > "$CODEX_HOME/auth.json"
  : > "$CODEX_HOME/config.toml"
  exit 0
fi
printf 'codex-home=%s\n' "${CODEX_HOME:-}" >> "$HOME/clisess-codex.log"
printf 'codex %s\n' "$*" >> "$HOME/clisess-codex.log"
exit 0
SH
cat > "$temp_home/mockbin/vibeproxy" <<'SH'
#!/bin/sh
set -eu
printf 'vibeproxy-home=%s\n' "${VIBEPROXY_HOME:-}" >> "$HOME/clisess-vibeproxy.log"
printf 'vibeproxy %s\n' "$*" >> "$HOME/clisess-vibeproxy.log"
exit 0
SH
chmod +x "$temp_home/mockbin/codex" "$temp_home/mockbin/vibeproxy"

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" login codex acct_login_001 >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" login codex acct_login_002 >/dev/null
test -f "$temp_home/.clisess/homes/codex/acct_login_001/auth.json"
test -f "$temp_home/.clisess/homes/codex/acct_login_002/auth.json"
use_output=$(PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" use codex acct_login_002 --to vibeproxy)
test -f "$temp_home/.clisess/homes/vibeproxy/acct_login_002/auth.json"
! printf '%s\n' "$use_output" | grep -F 'added:' >/dev/null
printf '%s\n' "$use_output" | grep -E 'export CODEX_HOME=.*/\.clisess/homes/codex/acct_login_002$' >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" link codex acct_login_001 vibeproxy acct_login_001 --home-var VIBEPROXY_HOME --exec vibeproxy >/dev/null
test -f "$temp_home/.clisess/homes/vibeproxy/acct_login_001/auth.json"
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" status --provider vibeproxy | grep -E 'vibeproxy[[:space:]]+acct_login_001[[:space:]]+mirror[[:space:]]+synced[[:space:]]+file[[:space:]]+codex/acct_login_001' >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" run vibeproxy acct_login_001 -- vibeproxy status >/dev/null
python3 - "$temp_home/clisess-vibeproxy.log" "$temp_home/.clisess/homes/vibeproxy/acct_login_001" <<'PY'
import pathlib
import sys

log = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected = pathlib.Path(sys.argv[2]).resolve()
assert f"vibeproxy-home={expected}" in log, log
PY
printf '{"tokens":{"access_token":"YOUR_ACCESS_TOKEN_HERE_REFRESHED","account_id":"acct-login"}}\n' > "$temp_home/.clisess/homes/codex/acct_login_001/auth.json"
status_json=$(PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" status --json)
python3 - <<'PY' "$status_json"
import json
import sys

rows = {(row["provider"], row["name"]): row for row in json.loads(sys.argv[1])}
assert rows[("codex", "acct_login_001")]["kind"] == "canonical"
assert rows[("codex", "acct_login_001")]["state"] == "ready"
assert rows[("vibeproxy", "acct_login_001")]["kind"] == "mirror"
assert rows[("vibeproxy", "acct_login_001")]["state"] == "stale"
assert rows[("vibeproxy", "acct_login_001")]["source"] == "codex/acct_login_001"
assert rows[("vibeproxy", "acct_login_002")]["kind"] == "mirror"
assert rows[("vibeproxy", "acct_login_002")]["state"] == "synced"
assert rows[("vibeproxy", "acct_login_002")]["source"] == "codex/acct_login_002"
PY
doctor_json=$(PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" doctor --json)
python3 - <<'PY' "$doctor_json"
import json
import sys

report = json.loads(sys.argv[1])
assert report["healthy"] is False
assert report["counts"]["issues"] >= 1
issues = {(item["provider"], item["name"], item["code"]): item for item in report["issues"]}
assert ("vibeproxy", "acct_login_001", "stale-mirror") in issues
assert issues[("vibeproxy", "acct_login_001", "stale-mirror")]["fix"] == "cxs sync codex/acct_login_001 --to vibeproxy:acct_login_001"
PY
if PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" doctor --strict >/dev/null 2>&1; then
  echo "expected doctor strict failure" >&2
  exit 1
fi
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" sync codex acct_login_001 --to vibeproxy >/dev/null
python3 - "$temp_home/.clisess/homes/vibeproxy/acct_login_001/auth.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["tokens"]["access_token"] == "YOUR_ACCESS_TOKEN_HERE_REFRESHED"
PY
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" status --provider vibeproxy | grep -E 'vibeproxy[[:space:]]+acct_login_001[[:space:]]+mirror[[:space:]]+synced[[:space:]]+file[[:space:]]+codex/acct_login_001' >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" doctor --provider vibeproxy --strict >/dev/null
if PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxs" sync codex acct_login_001 --to codex:acct_login_002 >/dev/null 2>"$temp_home/cxs-sync.err"; then
  echo "expected sync guard failure" >&2
  exit 1
fi
grep -F 'target session exists and is not a mirror: codex/acct_login_002' "$temp_home/cxs-sync.err" >/dev/null
mkdir -p "$temp_home/mock-cli-proxy"
cat > "$temp_home/mock-cli-proxy/codex-imported@example.com-plus.json" <<'EOF'
{"access_token":"YOUR_ACCESS_TOKEN_HERE_IMPORTED","refresh_token":"YOUR_REFRESH_TOKEN_HERE_IMPORTED","id_token":"YOUR_ID_TOKEN_HERE_IMPORTED","account_id":"imported-account","email":"imported@example.com","type":"codex"}
EOF
HOME="$temp_home" "$temp_home/bin/cxs" import-cli-proxy --source-dir "$temp_home/mock-cli-proxy" >/dev/null
test -f "$temp_home/.clisess/homes/codex/imported_at_example_com_imported/auth.json"
cat > "$temp_home/mock-clisess-quota.py" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys

account_dir = pathlib.Path(sys.argv[sys.argv.index("--account-dir") + 1])
if account_dir.name == "imported_at_example_com_imported":
    sys.stderr.write('usage request failed: HTTP 402 {"detail":{"code":"deactivated_workspace"}}\n')
    raise SystemExit(1)
print("oauth\x1f\x1f\x1f\x1f0\x1f0\x1f0\x1f100\x1f9999999999\x1f5h\x1f0\x1f100\x1f9999999999\x1fweekly")
PY
chmod +x "$temp_home/mock-clisess-quota.py"
HOME="$temp_home" CLISESS_QUOTA_HELPER="$temp_home/mock-clisess-quota.py" "$temp_home/bin/cxs" cleanup-deactivated --provider codex >/dev/null
test ! -d "$temp_home/.clisess/homes/codex/imported_at_example_com_imported"
python3 - "$temp_home/.clisess/sessions.json" <<'PY'
import json
import pathlib
import sys

store = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rows = {(row["provider"], row["name"]): row for row in store["sessions"]}
assert ("codex", "acct_login_001") in rows
assert ("codex", "acct_login_002") in rows
assert ("vibeproxy", "acct_login_001") in rows
assert rows[("codex", "acct_login_001")]["home"] != rows[("codex", "acct_login_002")]["home"]
assert rows[("vibeproxy", "acct_login_001")]["home"] != rows[("codex", "acct_login_001")]["home"]
assert rows[("vibeproxy", "acct_login_001")]["source_provider"] == "codex"
assert rows[("vibeproxy", "acct_login_001")]["source_name"] == "acct_login_001"
assert ("codex", "imported_at_example_com_imported") not in rows
PY

mkdir -p "$temp_home/.codex-accounts/acct_001"
printf '{"tokens":{"access_token":"YOUR_ACCESS_TOKEN_HERE_MAIN"}}\n' > "$temp_home/.codex-accounts/acct_001/auth.json"
: > "$temp_home/.codex-accounts/acct_001/config.toml"
HOME="$temp_home" "$temp_home/bin/cx" share export --output "$temp_home/share.tar.gz"

import_home=$(mktemp -d)
HOME="$import_home" "$temp_home/bin/cx" share import "$temp_home/share.tar.gz"
test -f "$import_home/.codex-accounts/acct_001/auth.json"
python3 - "$temp_home/share.tar.gz" "$import_home/.codex-accounts/acct_001/auth.json" <<'PY'
import os
import stat
import sys

for path in sys.argv[1:]:
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode != 0o600:
        raise SystemExit(f"{path} has mode {oct(mode)}, expected 0o600")
PY

mkdir -p "$temp_home/.codex"
printf 'model = "gpt-5"\n' > "$temp_home/.codex/config.toml"
HOME="$temp_home" "$temp_home/bin/cx" share config export --output "$temp_home/config-share.tar.gz"

config_home=$(mktemp -d)
HOME="$config_home" "$temp_home/bin/cx" share config import "$temp_home/config-share.tar.gz"
test -f "$config_home/.codex/config.toml"
python3 - "$temp_home/config-share.tar.gz" "$config_home/.codex/config.toml" <<'PY'
import os
import stat
import sys

for path in sys.argv[1:]:
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode != 0o600:
        raise SystemExit(f"{path} has mode {oct(mode)}, expected 0o600")
PY

mkdir -p "$temp_home/.codex-accounts/acct_002"
printf '{"tokens":{"access_token":"YOUR_ACCESS_TOKEN_HERE_ALT"}}\n' > "$temp_home/.codex-accounts/acct_002/auth.json"
: > "$temp_home/.codex-accounts/acct_002/config.toml"
cat > "$temp_home/.codex/config.toml" <<'EOF'
model = "gpt-5"

[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]
EOF
cat > "$temp_home/.codex-accounts/acct_002/config.toml" <<'EOF'
model = "gpt-5"

[mcp_servers.commit_gate]
command = "python3"
args = ["/tmp/commit_gate_server.py"]
EOF
HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh && _codex_ensure_account_config acct_002'
test "$(HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh; before=${functions_source[_codex_prepare_account_home]}; _codex_ensure_admin_loaded; after=${functions_source[_codex_prepare_account_home]}; [[ "$before" == "$after" ]] && printf "%s\n" "$after"' )" = "$root_dir/libexec/codex-orbit.zsh"
python3 - "$temp_home" <<'PY'
import pathlib
import sys

home = pathlib.Path(sys.argv[1])
for acct in ("acct_001", "acct_002"):
    (home / ".codex-accounts" / acct / "config.toml").touch()
PY
runtime_pipeline_output=$(HOME="$temp_home" zsh -c '
  source ./codex-orbit.zsh
  log_file="$HOME/runtime-pipeline.log"
  function _codex_prepare_account_runtime() { printf "prime:%s:%s:%s\n" "$1" "${2:-}" "${3:-}" >> "$log_file"; }
  function _codex_run_codex_for_account() { printf "run:%s:%s\n" "$1" "$2" >> "$log_file"; }
  function _codex_run_codex_direct_for_account() { printf "direct:%s:%s\n" "$1" "$2" >> "$log_file"; }
  function _codex_hot_helper_run() { printf "hot:%s\n" "$*" >> "$log_file"; printf "{}\n"; }
  function _codex_hot_default_enabled() { return 1; }
  function _codex_resolve_account_selection() { printf "acct_001\tmock\n"; }
  function _codex_normalize_launch_args() { printf "%s\n" "$@"; }
  cx probe-runtime
  codex_account acct_001 probe-account
  _codex_ensure_admin_loaded
  function _codex_hot_helper_run() { printf "hot:%s\n" "$*" >> "$log_file"; printf "{}\n"; }
  _codex_hot_switch acct_002 >/dev/null
  cat "$log_file"
')
printf '%s\n' "$runtime_pipeline_output" | grep -F 'prime:acct_001:1:1' >/dev/null
printf '%s\n' "$runtime_pipeline_output" | grep -F 'run:acct_001:probe-runtime' >/dev/null
printf '%s\n' "$runtime_pipeline_output" | grep -F 'run:acct_001:probe-account' >/dev/null
python3 - <<'PY' "$runtime_pipeline_output"
import sys

lines = sys.argv[1].splitlines()
prime_lines = [line for line in lines if line.startswith("prime:")]
assert prime_lines == [
    "prime:acct_001:1:1",
    "prime:acct_001:1:1",
    "prime:acct_002:1:1",
], prime_lines
PY
legacy_runtime_output=$(HOME="$temp_home" zsh -c '
  source ./codex-orbit.zsh
  unset -f _codex_prepare_account_runtime
  log_file="$HOME/runtime-legacy.log"
  function _codex_prepare_account_home() { printf "home:%s\n" "$1" >> "$log_file"; }
  function _codex_maybe_auto_warmup_account() { printf "warm:%s\n" "$1" >> "$log_file"; }
  function _codex_record_launched_account() { printf "record:%s\n" "$1" >> "$log_file"; }
  function _codex_hot_helper_run() { printf "{}\n"; }
  _codex_ensure_admin_loaded
  function _codex_hot_helper_run() { printf "{}\n"; }
  _codex_hot_switch acct_002 >/dev/null
  cat "$log_file"
')
printf '%s\n' "$legacy_runtime_output" | grep -F 'home:acct_002' >/dev/null
printf '%s\n' "$legacy_runtime_output" | grep -F 'warm:acct_002' >/dev/null
printf '%s\n' "$legacy_runtime_output" | grep -F 'record:acct_002' >/dev/null
rg -q 'commit_gate' "$temp_home/.codex-accounts/acct_002/config.toml"
! rg -q 'context7' "$temp_home/.codex-accounts/acct_002/config.toml"
! rg -q 'codex-orbit-managed' "$temp_home/.codex-accounts/acct_002/config.toml"
rg -q '^cli_auth_credentials_store = "file"$' "$temp_home/.codex-accounts/acct_002/config.toml"
HOME="$temp_home" "$temp_home/bin/cx" sync-config acct_002 >/dev/null
! rg -q 'commit_gate' "$temp_home/.codex-accounts/acct_002/config.toml"
rg -q 'context7' "$temp_home/.codex-accounts/acct_002/config.toml"
rg -q 'codex-orbit-managed' "$temp_home/.codex-accounts/acct_002/config.toml"
find "$temp_home/.codex-accounts/acct_002" -maxdepth 1 -name 'config.toml.backup-*' | grep -q .
cat > "$temp_home/.codex/config.toml" <<'EOF'
model = "gpt-5.4"

[mcp_servers.figma]
url = "https://mcp.figma.com/mcp"
EOF
HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh && _codex_ensure_account_config acct_002'
! rg -q 'context7' "$temp_home/.codex-accounts/acct_002/config.toml"
rg -q 'figma' "$temp_home/.codex-accounts/acct_002/config.toml"

python3 - "$temp_home" <<'PY'
import pathlib
import sys

home = pathlib.Path(sys.argv[1])
cache_dir = home / ".codex-accounts" / ".state" / "quota-cache"
cache_dir.mkdir(parents=True, exist_ok=True)
sep = "\x1f"

def write_snapshot(account: str, remaining: int, reset_at: int) -> None:
    fields = [
        "oauth", "", "", "", "0", "0",
        str(100 - remaining), str(remaining), str(reset_at), "5h",
        "0", "100", "9999999999", "weekly",
    ]
    (cache_dir / f"{account}.oauth.tsv").write_text(sep.join(fields) + "\n", encoding="utf-8")

write_snapshot("acct_001", 20, 9999999999)
write_snapshot("acct_002", 80, 9999990000)
PY

test "$(HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh; _codex_ensure_state_schema >/dev/null; _codex_set_round_robin_last_account acct_001; _codex_record_launched_account acct_002; _codex_preview_round_robin_account')" = "acct_001"

printf '# shared agents\n' > "$temp_home/.codex/AGENTS.md"
printf '# standalone profile agents\n' > "$temp_home/.codex-accounts/acct_002/AGENTS.md"

HOME="$temp_home" "$temp_home/bin/cx" alias acct_002 work
test "$(HOME="$temp_home" CODEX_ORBIT_ROUTING=quota "$temp_home/bin/cx" resolve)" = "acct_002"
HOME="$temp_home" CODEX_ORBIT_ROUTING=quota "$temp_home/bin/cx" pin-next >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" current | grep -F 'Pinned: work (acct_002)'
quota_default=$(HOME="$temp_home" "$temp_home/bin/cx" quota)
printf '%s\n' "$quota_default" | grep -F 'next route ' >/dev/null
default_acct_001_line=$(printf '%s\n' "$quota_default" | grep -nE '^[ !]+acct_001[[:space:]]' | head -n 1 | cut -d: -f1)
default_work_line=$(printf '%s\n' "$quota_default" | grep -nE '^[ !]+work[[:space:]]' | head -n 1 | cut -d: -f1)
test "$default_acct_001_line" -lt "$default_work_line"
quota_capacity=$(HOME="$temp_home" "$temp_home/bin/cx" quota --sort capacity)
capacity_acct_001_line=$(printf '%s\n' "$quota_capacity" | grep -nE '^[ !]+acct_001[[:space:]]' | head -n 1 | cut -d: -f1)
capacity_work_line=$(printf '%s\n' "$quota_capacity" | grep -nE '^[ !]+work[[:space:]]' | head -n 1 | cut -d: -f1)
test "$capacity_work_line" -lt "$capacity_acct_001_line"
quota_reset=$(HOME="$temp_home" "$temp_home/bin/cx" quota --sort reset)
reset_acct_001_line=$(printf '%s\n' "$quota_reset" | grep -nE '^[ !]+acct_001[[:space:]]' | head -n 1 | cut -d: -f1)
reset_work_line=$(printf '%s\n' "$quota_reset" | grep -nE '^[ !]+work[[:space:]]' | head -n 1 | cut -d: -f1)
test "$reset_work_line" -lt "$reset_acct_001_line"
which_output=$(HOME="$temp_home" "$temp_home/bin/cx" which)
printf '%s\n' "$which_output" | grep -F "Quota: skipped; run 'cx which --show-quota' or 'cx quota "
! printf '%s\n' "$which_output" | grep -F 'Quota source:' >/dev/null
HOME="$temp_home" NO_COLOR= CODEX_ORBIT_COLOR=always "$temp_home/bin/cx" doctor | python3 -c 'import sys; data=sys.stdin.read(); assert "\x1b[" in data'
HOME="$temp_home" CODEX_ORBIT_COLOR=always NO_COLOR=1 "$temp_home/bin/cx" doctor | python3 -c 'import sys; data=sys.stdin.read(); assert "\x1b[" not in data'
HOME="$temp_home" "$temp_home/bin/cx" which --show-quota | grep -F 'Quota source: oauth'
HOME="$temp_home" "$temp_home/bin/cx" doctor | grep -F 'run: cx sync-agents' >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" doctor --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["counts"]["accounts"] >= 2; assert data["checks"]["state_writable"] is True; assert data["counts"]["agent_drift"] == 2; assert data["checks"]["shared_agents_consistent"] is False; assert sorted(data["shared_agents"]["drift_accounts"]) == ["acct_001", "acct_002"]'
HOME="$temp_home" "$temp_home/bin/cx" sync-agents acct_001 work >/dev/null
test -L "$temp_home/.codex-accounts/acct_001/AGENTS.md"
test -L "$temp_home/.codex-accounts/acct_002/AGENTS.md"
find "$temp_home/.codex-accounts/acct_002" -maxdepth 1 -name 'AGENTS.md.backup-*' | grep -q .
HOME="$temp_home" "$temp_home/bin/cx" doctor --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["counts"]["agent_drift"] == 0; assert data["checks"]["shared_agents_consistent"] is True'
HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh; _codex_prepare_shared_sessions acct_001'
HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh; function _codex_python3 { return 1; }; _codex_prepare_account_home acct_001'
HOME="$temp_home" "$temp_home/bin/cx" daemon status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["counts"]["accounts"] >= 2; assert data["counts"]["logged_in"] >= 2'
HOME="$temp_home" "$temp_home/bin/cx" support --output "$temp_home/support.tar.gz" >/dev/null
tar -tzf "$temp_home/support.tar.gz" | grep -F './doctor.txt' >/dev/null

mkdir -p "$temp_home/mockbin"
cat > "$temp_home/mockbin/script" <<'SH'
#!/bin/sh
printf 'script %s\n' "$*" >> "$HOME/fast-script.log"
exit 99
SH
cat > "$temp_home/mockbin/codex" <<'SH'
#!/bin/sh
printf 'codex %s\n' "$*" >> "$HOME/fast-codex.log"
printf 'CODEX_HOME=%s\n' "$CODEX_HOME" >> "$HOME/fast-codex.log"
exit 0
SH
chmod +x "$temp_home/mockbin/script" "$temp_home/mockbin/codex"

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" CODEX_ORBIT_FAST_LAUNCH=1 "$temp_home/bin/cx" "probe-fast" >/dev/null
test ! -f "$temp_home/fast-script.log"
grep -F 'codex --dangerously-bypass-approvals-and-sandbox probe-fast' "$temp_home/fast-codex.log" >/dev/null
grep -F "CODEX_HOME=$temp_home/.codex-accounts/acct_002" "$temp_home/fast-codex.log" >/dev/null

cat > "$temp_home/mockbin/codex" <<'SH'
#!/bin/sh
out_file=""
printf 'codex %s\n' "$*" >> "$HOME/warmup-codex.log"
printf 'CODEX_HOME=%s\n' "$CODEX_HOME" >> "$HOME/warmup-codex.log"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [ -n "$out_file" ]; then
  printf '%s\n' 'READY' > "$out_file"
fi
exit 0
SH
chmod +x "$temp_home/mockbin/codex"

plan_output=$(PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" warmup --all --mini --message "Say hi." --start-at 10:00 --dry-run)
printf '%s\n' "$plan_output" | grep -F 'Model: gpt-5.4-mini' >/dev/null
printf '%s\n' "$plan_output" | grep -F 'Window strategy: staggered over 5h' >/dev/null
printf '%s\n' "$plan_output" | grep -F 'acct_001' >/dev/null
printf '%s\n' "$plan_output" | grep -F 'work (acct_002)' >/dev/null
test ! -f "$temp_home/warmup-codex.log"

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" warmup --all --mini --message "Say hi." >/dev/null
grep -F -- '-m gpt-5.4-mini' "$temp_home/warmup-codex.log" >/dev/null
grep -F 'Say hi.' "$temp_home/warmup-codex.log" >/dev/null
python3 - "$temp_home/warmup-codex.log" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
homes = [line for line in lines if line.startswith("CODEX_HOME=")]
assert len(homes) == 2, homes
assert homes[0] != homes[1], homes
PY

cat > "$temp_home/mockbin/codex" <<'SH'
#!/bin/sh
out_file=""
printf 'codex %s\n' "$*" >> "$HOME/auto-warmup.log"
printf 'CODEX_HOME=%s\n' "$CODEX_HOME" >> "$HOME/auto-warmup.log"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [ -n "$out_file" ]; then
  printf '%s\n' 'READY' > "$out_file"
fi
exit 0
SH
chmod +x "$temp_home/mockbin/codex"

python3 - "$temp_home" <<'PY'
import pathlib
import sys
import time

home = pathlib.Path(sys.argv[1])
cache_dir = home / ".codex-accounts" / ".state" / "quota-cache"
cache_dir.mkdir(parents=True, exist_ok=True)
sep = "\x1f"
now = int(time.time())

def write_snapshot(account: str, used: int, remaining: int, reset_at: int) -> None:
    fields = [
        "oauth", "", "", "", "0", "0",
        str(used), str(remaining), str(reset_at), "5h",
        "0", "100", "9999999999", "weekly",
    ]
    (cache_dir / f"{account}.oauth.tsv").write_text(sep.join(fields) + "\n", encoding="utf-8")

write_snapshot("acct_001", 0, 100, now + 17950)
write_snapshot("acct_002", 25, 75, now + 7200)
PY
rm -rf "$temp_home/.codex-accounts/.state/auto-warmup"
HOME="$temp_home" "$temp_home/bin/cx" unpin >/dev/null
HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh; _codex_ensure_state_schema >/dev/null; _codex_set_round_robin_last_account acct_002'

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" CODEX_ORBIT_HOT_DEFAULT=0 CODEX_ORBIT_FAST_LAUNCH=1 "$temp_home/bin/cx" "probe-auto" >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh; codex_account acct_001 probe-auto-2' >/dev/null
grep -F -- '-m gpt-5.4-mini' "$temp_home/auto-warmup.log" >/dev/null
grep -F 'Reply with exactly READY and nothing else.' "$temp_home/auto-warmup.log" >/dev/null
grep -F 'probe-auto' "$temp_home/auto-warmup.log" >/dev/null
grep -F 'probe-auto-2' "$temp_home/auto-warmup.log" >/dev/null
python3 - "$temp_home/auto-warmup.log" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
exec_lines = [line for line in lines if line.startswith("codex ") and " exec " in line]
assert len(exec_lines) == 1, exec_lines
prompt_lines = [line for line in lines if "Reply with exactly READY and nothing else." in line]
assert len(prompt_lines) == 1, prompt_lines
PY

cat > "$temp_home/mockbin/codex" <<'SH'
#!/bin/sh
out_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    login)
      if [ "${2:-}" = "status" ]; then
        echo "logged in"
      fi
      exit 0
      ;;
    exec)
      if [ -n "$out_file" ]; then
        printf '%s\n' 'unexpected status 402 Payment Required: {"detail":{"code":"deactivated_workspace"}}, auth error: 402' > "$out_file"
      else
        printf '%s\n' 'unexpected status 402 Payment Required: {"detail":{"code":"deactivated_workspace"}}, auth error: 402' >&2
      fi
      exit 1
      ;;
  esac
  shift
done
printf '%s\n' 'unexpected status 402 Payment Required: {"detail":{"code":"deactivated_workspace"}}, auth error: 402' >&2
exit 1
SH
chmod +x "$temp_home/mockbin/codex"

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh; codex_account acct_002 probe' >/dev/null 2>"$temp_home/auto-disable.err" || true
test -f "$temp_home/.codex-accounts/.state/disabled/acct_002.disabled"
grep -F 'auto:deactivated_workspace' "$temp_home/.codex-accounts/.state/disabled/acct_002.disabled" >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" list | grep -F 'disabled (deactivated workspace)' >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" warmup acct_001 >/dev/null 2>"$temp_home/warmup-disable.err" || true
test -f "$temp_home/.codex-accounts/.state/disabled/acct_001.disabled"
HOME="$temp_home" "$temp_home/bin/cx" cooldown acct_001 5h >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" recover acct_001 >/dev/null
test ! -f "$temp_home/.codex-accounts/.state/disabled/acct_001.disabled"
test ! -f "$temp_home/.codex-accounts/.state/cooldowns/acct_001.until"

cat > "$temp_home/mock_quota.py" <<'PY'
#!/usr/bin/env python3
import sys

sys.stderr.write('usage request failed: HTTP 402 {"detail":{"code":"deactivated_workspace"}}\n')
raise SystemExit(1)
PY
chmod +x "$temp_home/mock_quota.py"
mkdir -p "$temp_home/.codex-accounts/.state/quota-cache"
printf '%s\n' 'cached-quota' > "$temp_home/.codex-accounts/.state/quota-cache/acct_001.oauth.tsv"
HOME="$temp_home" zsh -c '
  source ./codex-orbit.zsh
  function _codex_quota_helper() { printf "%s\n" "$HOME/mock_quota.py"; }
  _codex_account_quota_snapshot acct_001 tsv 1 oauth
' >/dev/null 2>"$temp_home/quota-disable.err" || true
test -f "$temp_home/.codex-accounts/.state/disabled/acct_001.disabled"
grep -F 'auto:deactivated_workspace' "$temp_home/.codex-accounts/.state/disabled/acct_001.disabled" >/dev/null
test ! -f "$temp_home/.codex-accounts/.state/quota-cache/acct_001.oauth.tsv"
HOME="$temp_home" "$temp_home/bin/cx" recover acct_001 >/dev/null
test ! -f "$temp_home/.codex-accounts/.state/disabled/acct_001.disabled"

cat > "$temp_home/mockbin/ssh" <<'SH'
#!/bin/sh
printf 'ssh %s\n' "$*" >> "$HOME/ssh.log"
exit 0
SH
cat > "$temp_home/mockbin/scp" <<'SH'
#!/bin/sh
printf 'scp %s\n' "$*" >> "$HOME/scp.log"
exit 0
SH
chmod +x "$temp_home/mockbin/ssh" "$temp_home/mockbin/scp"

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" share push user@host --with-config >/dev/null
grep -F 'cx share import' "$temp_home/ssh.log" >/dev/null
grep -F 'config import' "$temp_home/ssh.log" >/dev/null
grep -F 'accounts.tar.gz' "$temp_home/scp.log" >/dev/null
grep -F 'config.tar.gz' "$temp_home/scp.log" >/dev/null

HOME="$temp_home" "$temp_home/bin/cx" daemon serve --port 8799 >"$temp_home/daemon.log" 2>&1 &
daemon_pid=$!
trap 'kill "$daemon_pid" 2>/dev/null || true; rm -rf "$temp_home" "${import_home:-}" "${config_home:-}"' EXIT INT TERM
python3 - <<'PY'
import json
import time
import urllib.request

url = "http://127.0.0.1:8799/health"
for _ in range(50):
    try:
        with urllib.request.urlopen(url, timeout=1) as response:
            payload = json.load(response)
            assert payload["ok"] is True
            break
    except Exception:
        time.sleep(0.1)
else:
    raise SystemExit("daemon health endpoint did not become ready")
PY
python3 - <<'PY'
import json
import urllib.request

with urllib.request.urlopen("http://127.0.0.1:8799/v1/status", timeout=2) as response:
    payload = json.load(response)
assert payload["counts"]["accounts"] >= 2
assert any(account["id"] == "acct_002" for account in payload["accounts"])
PY
kill "$daemon_pid" 2>/dev/null || true

cat > "$temp_home/mock_app_server.py" <<'PY'
#!/usr/bin/env python3
import base64
import hashlib
import json
import socketserver
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def read_exact(handle, size):
    data = b""
    while len(data) < size:
        chunk = handle.read(size - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def recv_frame(handle):
    header = read_exact(handle, 2)
    if not header:
        return None
    first, second = header
    opcode = first & 0x0F
    masked = (second & 0x80) != 0
    length = second & 0x7F
    if length == 126:
        length_bytes = read_exact(handle, 2)
        if not length_bytes:
            return None
        length = int.from_bytes(length_bytes, "big")
    elif length == 127:
        length_bytes = read_exact(handle, 8)
        if not length_bytes:
            return None
        length = int.from_bytes(length_bytes, "big")
    mask = read_exact(handle, 4) if masked else b""
    payload = read_exact(handle, length) if length else b""
    if payload is None:
        return None
    if masked:
        payload = bytes(b ^ mask[idx % 4] for idx, b in enumerate(payload))
    return opcode, payload


def send_text(connection, payload):
    encoded = payload.encode("utf-8")
    header = bytearray([0x81])
    length = len(encoded)
    if length < 126:
        header.append(length)
    elif length < (1 << 16):
        header.append(126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(127)
        header.extend(length.to_bytes(8, "big"))
    connection.sendall(bytes(header) + encoded)


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-app-server"
    auth_mode = None

    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path in {"/readyz", "/healthz"}:
            body = json.dumps({"ok": True}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.headers.get("Upgrade", "").lower() != "websocket":
            self.send_error(404)
            return

        key = self.headers.get("Sec-WebSocket-Key")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("utf-8")).digest()).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True

        while True:
            frame = recv_frame(self.rfile)
            if frame is None:
                return
            opcode, payload = frame
            if opcode == 0x8:
                return
            message = json.loads(payload.decode("utf-8"))
            method = message.get("method")
            msg_id = message.get("id")

            if method == "initialize":
                send_text(
                    self.connection,
                    json.dumps(
                        {
                            "id": msg_id,
                            "result": {
                                "userAgent": "mock/0.1.0",
                                "codexHome": "/tmp/mock",
                                "platformFamily": "unix",
                                "platformOs": "linux",
                            },
                        }
                    ),
                )
                continue

            if method == "initialized":
                continue

            if method == "account/logout":
                Handler.auth_mode = None
                send_text(self.connection, json.dumps({"id": msg_id, "result": {}}))
                send_text(
                    self.connection,
                    json.dumps({"method": "account/updated", "params": {"authMode": None, "planType": None}}),
                )
                continue

            if method == "account/login/start":
                Handler.auth_mode = "chatgptAuthTokens"
                send_text(self.connection, json.dumps({"id": msg_id, "result": {"type": "chatgptAuthTokens"}}))
                send_text(
                    self.connection,
                    json.dumps({"method": "account/login/completed", "params": {"loginId": None, "success": True, "error": None}}),
                )
                send_text(
                    self.connection,
                    json.dumps({"method": "account/updated", "params": {"authMode": Handler.auth_mode, "planType": "team"}}),
                )
                continue

            send_text(self.connection, json.dumps({"id": msg_id, "result": {}}))


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


Server(("127.0.0.1", PORT), Handler).serve_forever()
PY
chmod +x "$temp_home/mock_app_server.py"

cat > "$temp_home/mockbin/codex" <<'SH'
#!/bin/sh
if [ "${1:-}" = "app-server" ] && [ "${2:-}" = "--listen" ]; then
  case "${3:-}" in
    ws://127.0.0.1:*)
      port="${3##*:}"
      exec python3 "$HOME/mock_app_server.py" "$port"
      ;;
  esac
fi

printf 'codex %s\n' "$*" >> "$HOME/hot-codex.log"
exit 0
SH
chmod +x "$temp_home/mockbin/codex"

printf '{"tokens":{"access_token":"YOUR_ACCESS_TOKEN_HERE_1","id_token":"YOUR_ID_TOKEN_HERE_1","account_id":"acct-hot-1"}}\n' > "$temp_home/.clisess/homes/codex/acct_login_001/auth.json"
printf '{"tokens":{"access_token":"YOUR_ACCESS_TOKEN_HERE_2","id_token":"YOUR_ID_TOKEN_HERE_2","account_id":"acct-hot-2"}}\n' > "$temp_home/.clisess/homes/codex/acct_login_002/auth.json"
cat > "$temp_home/mock-hot-quota.py" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys

home = pathlib.Path(sys.argv[sys.argv.index("--account-dir") + 1])
remaining = 0 if home.name == "acct_login_001" else 80
print(f"oauth\x1f\x1f\x1f\x1f0\x1f0\x1f{100 - remaining}\x1f{remaining}\x1f9999999999\x1f5h\x1f0\x1f100\x1f9999999999\x1fweekly")
PY
chmod +x "$temp_home/mock-hot-quota.py"

read -r clisess_hot_app_port clisess_hot_control_port <<EOF
$(python3 - <<'PY'
import socket

def reserve():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port

print(reserve(), reserve())
PY
)
EOF

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" CODEX_ROTATOR_QUOTA_HELPER="$temp_home/mock-hot-quota.py" "$temp_home/bin/cxr" start acct_login_001 --app-port "$clisess_hot_app_port" --control-port "$clisess_hot_control_port" >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxr" status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["running"] is True; assert data["account"] == "acct_login_001"; assert data["ready"] is True; assert data["home"].endswith("/.clisess/homes/codex/acct_login_001")'
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxr" switch acct_login_002 >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxr" status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["account"] == "acct_login_002"; assert data["auth_mode"] == "chatgptAuthTokens"; assert data["home"].endswith("/.clisess/homes/codex/acct_login_002")'
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxr" attach -- probe-clisess-hot >/dev/null
grep -F -- "--remote ws://127.0.0.1:$clisess_hot_app_port probe-clisess-hot" "$temp_home/hot-codex.log" >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxr" switch acct_login_001 >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" CODEX_ROTATOR_QUOTA_HELPER="$temp_home/mock-hot-quota.py" "$temp_home/bin/cxr" autoswitch enable --interval 1 >/dev/null
python3 - "$temp_home" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import time

home = pathlib.Path(sys.argv[1])
cmd = [str(home / "bin" / "cxr"), "status", "--json"]
env = {"HOME": str(home), "PATH": f"{home / 'mockbin'}:{os.environ['PATH']}", "CODEX_ROTATOR_QUOTA_HELPER": str(home / "mock-hot-quota.py")}
for _ in range(40):
    payload = json.loads(subprocess.check_output(cmd, text=True, env=env))
    event = (payload.get("auto_switch") or {}).get("event") or {}
    if payload.get("account") == "acct_login_002" and event.get("reason") == "quota_exhausted":
        break
    time.sleep(0.1)
else:
    raise SystemExit("cxr auto-switch did not switch accounts")
PY
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxr" autoswitch status | grep -F 'auto-switch: enabled' >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxr" autoswitch disable >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxr" stop >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cxr" status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["running"] is False'

mkdir -p "$temp_home/.codex-accounts/acct_010" "$temp_home/.codex-accounts/acct_011"
printf '{"tokens":{"access_token":"YOUR_ACCESS_TOKEN_HERE_1","id_token":"YOUR_ID_TOKEN_HERE_1","account_id":"acct-hot-1"}}\n' > "$temp_home/.codex-accounts/acct_010/auth.json"
printf '{"tokens":{"access_token":"YOUR_ACCESS_TOKEN_HERE_2","id_token":"YOUR_ID_TOKEN_HERE_2","account_id":"acct-hot-2"}}\n' > "$temp_home/.codex-accounts/acct_011/auth.json"
: > "$temp_home/.codex-accounts/acct_010/config.toml"
: > "$temp_home/.codex-accounts/acct_011/config.toml"

read -r hot_app_port hot_control_port <<EOF
$(python3 - <<'PY'
import socket

def reserve():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port

print(reserve(), reserve())
PY
)
EOF

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot start --account acct_010 --app-port "$hot_app_port" --control-port "$hot_control_port" >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["running"] is True; assert data["account"] == "acct_010"; assert data["ready"] is True; assert data["last_action"] == "started"'
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot start --account acct_010 --app-port "$hot_app_port" --control-port "$hot_control_port" | grep -F 'Summary: reused' >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot switch acct_011 >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["account"] == "acct_011"; assert data["auth_mode"] == "chatgptAuthTokens"; assert data["last_action"] == "switched"'
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot attach --app-port "$hot_app_port" -- probe-hot >/dev/null
grep -F -- "--remote ws://127.0.0.1:$hot_app_port probe-hot" "$temp_home/hot-codex.log" >/dev/null
: > "$temp_home/hot-codex.log"
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" CODEX_ORBIT_HOT_APP_PORT="$hot_app_port" CODEX_ORBIT_HOT_CONTROL_PORT="$hot_control_port" "$temp_home/bin/cx" probe-default >/dev/null
grep -F -- "--remote ws://127.0.0.1:$hot_app_port --dangerously-bypass-approvals-and-sandbox probe-default" "$temp_home/hot-codex.log" >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot stop >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["running"] is False'

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot start --account acct_010 --app-port "$hot_app_port" --control-port "$hot_control_port" >/dev/null
python3 - "$temp_home" <<'PY'
import pathlib
import time
import sys

home = pathlib.Path(sys.argv[1])
cache_dir = home / ".codex-accounts" / ".state" / "quota-cache"
cache_dir.mkdir(parents=True, exist_ok=True)
sep = "\x1f"
now = int(time.time())

def write_snapshot(account: str, remaining: int) -> None:
    fields = [
        "oauth", "", "", "", "0", "0",
        str(100 - remaining), str(remaining), str(now + 3600), "5h",
        "0", "100", str(now + 86400), "weekly",
    ]
    (cache_dir / f"{account}.oauth.tsv").write_text(sep.join(fields) + "\n", encoding="utf-8")

write_snapshot("acct_010", 0)
write_snapshot("acct_011", 80)
PY
HOME="$temp_home" "$temp_home/bin/cx" daemon autoswitch enable >/dev/null
read -r autoswitch_daemon_port <<EOF
$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)
EOF
PATH="$temp_home/bin:$temp_home/mockbin:$PATH" HOME="$temp_home" CODEX_ORBIT_DAEMON_AUTOSWITCH_INTERVAL=1 CODEX_ORBIT_DAEMON_NOTIFICATIONS=0 CODEX_ORBIT_DAEMON_CX="$temp_home/bin/cx" "$temp_home/bin/cx" daemon serve --port "$autoswitch_daemon_port" >"$temp_home/daemon-autoswitch.log" 2>&1 &
daemon_autoswitch_pid=$!
trap 'kill "$daemon_autoswitch_pid" 2>/dev/null || true; kill "${daemon_pid:-}" 2>/dev/null || true; rm -rf "$temp_home" "${import_home:-}" "${config_home:-}"' EXIT INT TERM
python3 - "$autoswitch_daemon_port" <<'PY'
import json
import sys
import time
import urllib.request
import urllib.error

url = f"http://127.0.0.1:{sys.argv[1]}/v1/status"
for _ in range(80):
    try:
        with urllib.request.urlopen(url, timeout=1) as response:
            payload = json.load(response)
    except Exception:
        time.sleep(0.1)
        continue
    hot = payload.get("hot") or {}
    event = (payload.get("auto_switch") or {}).get("event") or {}
    if hot.get("account") == "acct_011" and event.get("reason") == "quota_exhausted":
        break
    time.sleep(0.1)
else:
    raise SystemExit("daemon autoswitch did not switch accounts")
PY
kill "$daemon_autoswitch_pid" 2>/dev/null || true
wait "$daemon_autoswitch_pid" 2>/dev/null || true
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot stop >/dev/null

read -r occupied_app_port occupied_control_port <<EOF
$(python3 - <<'PY'
import socket

def reserve():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port

print(reserve(), reserve())
PY
)
EOF

python3 - "$occupied_app_port" "$occupied_control_port" <<'PY' &
import socket
import sys
import time

ports = [int(sys.argv[1]), int(sys.argv[2])]
sockets = []
for port in ports:
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen()
    sockets.append(sock)

try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    pass
PY
occupy_pid=$!

: > "$temp_home/hot-codex.log"
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" CODEX_ORBIT_HOT_APP_PORT="$occupied_app_port" CODEX_ORBIT_HOT_CONTROL_PORT="$occupied_control_port" CODEX_ORBIT_HOT_IDLE_SECONDS=2 "$temp_home/bin/cx" probe-fallback >/dev/null
fallback_status=$(PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot status --json)
actual_fallback_app_port=$(printf '%s\n' "$fallback_status" | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["running"] is True; assert data["ready"] is True; assert data["app_port"] != int(sys.argv[1]); assert data["control_port"] != int(sys.argv[2]); print(data["app_port"])' "$occupied_app_port" "$occupied_control_port")
grep -F -- "--remote ws://127.0.0.1:$actual_fallback_app_port --dangerously-bypass-approvals-and-sandbox probe-fallback" "$temp_home/hot-codex.log" >/dev/null
sleep 3
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" hot status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["running"] is False'
kill "$occupy_pid" 2>/dev/null || true
wait "$occupy_pid" 2>/dev/null || true
occupy_pid=""

mkdir -p "$temp_home/mockbin" "$temp_home/.codex-accounts/acct_003"
cat > "$temp_home/mockbin/security" <<'SH'
#!/bin/sh
set -eu
db_dir="$HOME/mock-keychain"
mkdir -p "$db_dir"
command_name="${1:-}"
shift || true
service=""
account=""
password=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -s)
      service="$2"
      shift 2
      ;;
    -a)
      account="$2"
      shift 2
      ;;
    -w)
      if [ "$command_name" = "find-generic-password" ]; then
        shift
      else
        password="$2"
        shift 2
      fi
      ;;
    -U)
      shift
      ;;
    *)
      shift
      ;;
  esac
done
key=$(printf '%s__%s' "$service" "$account" | tr '/: ' '___')
path="$db_dir/$key"
case "$command_name" in
  add-generic-password)
    printf '%s' "$password" > "$path"
    ;;
  find-generic-password)
    test -f "$path"
    cat "$path"
    ;;
  delete-generic-password)
    rm -f "$path"
    ;;
  *)
    echo "unsupported security command: $command_name" >&2
    exit 1
    ;;
esac
SH
chmod +x "$temp_home/mockbin/security"
printf '{"tokens":{"access_token":"YOUR_ACCESS_TOKEN_HERE_KEYCHAIN","refresh_token":"YOUR_REFRESH_TOKEN_HERE_KEYCHAIN","id_token":"YOUR_ID_TOKEN_HERE_KEYCHAIN","account_id":"kc-account"}}\n' > "$temp_home/.codex-accounts/acct_003/auth.json"
: > "$temp_home/.codex-accounts/acct_003/config.toml"
CODEX_ORBIT_SECURITY_BIN="$temp_home/mockbin/security" HOME="$temp_home" "$temp_home/bin/cx" keychain sync --account acct_003 --remove-file >/dev/null
test ! -f "$temp_home/.codex-accounts/acct_003/auth.json"
CODEX_ORBIT_SECURITY_BIN="$temp_home/mockbin/security" HOME="$temp_home" "$temp_home/bin/cx" keychain status --account acct_003 --json | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert rows[0]["mode"] == "keychain"'
CODEX_ORBIT_SECURITY_BIN="$temp_home/mockbin/security" HOME="$temp_home" zsh -c 'source ./codex-orbit.zsh; _codex_prepare_account_home acct_003'
test -f "$temp_home/.codex-accounts/acct_003/auth.json"
python3 - "$temp_home/.codex-accounts/acct_003/auth.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["tokens"]["access_token"] == "YOUR_ACCESS_TOKEN_HERE_KEYCHAIN"
PY

HOME="$temp_home" ./uninstall.sh --bin-dir "$temp_home/bin" --install-dir "$temp_home/share/codex-orbit"
test ! -e "$temp_home/bin/cx"
test ! -e "$temp_home/bin/cxr"

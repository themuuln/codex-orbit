#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root_dir"

./bin/cx --help >/dev/null
zsh -c 'source ./codex-orbit.zsh && cx --help >/dev/null'

temp_home=$(mktemp -d)
cleanup() {
  rm -rf "$temp_home" "${import_home:-}" "${config_home:-}"
}
trap cleanup EXIT INT TERM

HOME="$temp_home" ./install.sh --bin-dir "$temp_home/bin" --install-dir "$temp_home/share/codex-orbit"
"$temp_home/bin/cx" --help >/dev/null
test -f "$temp_home/share/codex-orbit/install-metadata"
HOME="$temp_home" "$temp_home/bin/cx" version | grep -F 'Install: direct' >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" completions zsh | grep -F '#compdef cx' >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" init --shell zsh >/dev/null
grep -F '# >>> codex-orbit completions >>>' "$temp_home/.zshrc" >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" daemon url | grep -F 'http://127.0.0.1:8787' >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" daemon launchd plist | grep -F '<string>com.codex-orbit.daemon</string>' >/dev/null

mkdir -p "$temp_home/.codex-accounts/acct_001"
printf '{"tokens":{"access_token":"test"}}\n' > "$temp_home/.codex-accounts/acct_001/auth.json"
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
printf '{"tokens":{"access_token":"test-2"}}\n' > "$temp_home/.codex-accounts/acct_002/auth.json"
: > "$temp_home/.codex-accounts/acct_002/config.toml"
python3 - "$temp_home" <<'PY'
import pathlib
import sys

home = pathlib.Path(sys.argv[1])
cache_dir = home / ".codex-accounts" / ".state" / "quota-cache"
cache_dir.mkdir(parents=True, exist_ok=True)
sep = "\x1f"

def write_snapshot(account: str, remaining: int) -> None:
    fields = [
        "oauth", "", "", "", "0", "0",
        str(100 - remaining), str(remaining), "9999999999", "5h",
        "0", "100", "9999999999", "weekly",
    ]
    (cache_dir / f"{account}.oauth.tsv").write_text(sep.join(fields) + "\n", encoding="utf-8")

write_snapshot("acct_001", 20)
write_snapshot("acct_002", 80)
PY

HOME="$temp_home" "$temp_home/bin/cx" alias acct_002 work
test "$(HOME="$temp_home" CODEX_ORBIT_ROUTING=quota "$temp_home/bin/cx" resolve)" = "acct_002"
HOME="$temp_home" CODEX_ORBIT_ROUTING=quota "$temp_home/bin/cx" pin-next >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" current | grep -F 'Pinned: work (acct_002)'
HOME="$temp_home" "$temp_home/bin/cx" doctor --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["counts"]["accounts"] >= 2; assert data["checks"]["state_writable"] is True'
HOME="$temp_home" "$temp_home/bin/cx" daemon status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["counts"]["accounts"] >= 2; assert data["counts"]["logged_in"] >= 2'
HOME="$temp_home" "$temp_home/bin/cx" support --output "$temp_home/support.tar.gz" >/dev/null
tar -tzf "$temp_home/support.tar.gz" | grep -F './doctor.txt' >/dev/null

mkdir -p "$temp_home/mockbin"
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

PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" "probe" >/dev/null 2>"$temp_home/auto-disable.err" || true
test -f "$temp_home/.codex-accounts/.state/disabled/acct_002.disabled"
grep -F 'auto:deactivated_workspace' "$temp_home/.codex-accounts/.state/disabled/acct_002.disabled" >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" list | grep -F 'disabled (deactivated workspace)' >/dev/null
PATH="$temp_home/mockbin:$PATH" HOME="$temp_home" "$temp_home/bin/cx" warmup acct_001 >/dev/null 2>"$temp_home/warmup-disable.err" || true
test -f "$temp_home/.codex-accounts/.state/disabled/acct_001.disabled"
HOME="$temp_home" "$temp_home/bin/cx" cooldown acct_001 5h >/dev/null
HOME="$temp_home" "$temp_home/bin/cx" recover acct_001 >/dev/null
test ! -f "$temp_home/.codex-accounts/.state/disabled/acct_001.disabled"
test ! -f "$temp_home/.codex-accounts/.state/cooldowns/acct_001.until"

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

HOME="$temp_home" ./uninstall.sh --bin-dir "$temp_home/bin" --install-dir "$temp_home/share/codex-orbit"
test ! -e "$temp_home/bin/cx"

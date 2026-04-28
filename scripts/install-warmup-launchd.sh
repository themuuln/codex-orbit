#!/bin/zsh
set -euo pipefail

label="com.codex-orbit.warmup"
plist_path="$HOME/Library/LaunchAgents/${label}.plist"
stdout_log="$HOME/Library/Logs/codex-orbit-warmup.out.log"
stderr_log="$HOME/Library/Logs/codex-orbit-warmup.err.log"
domain="gui/$(id -u)"
message="${CODEX_ORBIT_WARMUP_MESSAGE:-Say hi.}"

usage() {
  cat <<'EOF'
Usage: ./scripts/install-warmup-launchd.sh <plist|install|uninstall|start|stop|status>

Defaults:
  09:00 -> cx warmup --all --mini --message "Say hi."
  14:00 -> cx warmup --all --mini --message "Say hi."

Optional env:
  CODEX_ORBIT_WARMUP_MESSAGE   Override the warmup message
  CODEX_ORBIT_ENTRYPOINT       Absolute path to cx
EOF
}

require_macos_launchd() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This script is only supported on macOS." >&2
    exit 1
  fi
  command -v launchctl >/dev/null 2>&1 || {
    echo "launchctl is required." >&2
    exit 1
  }
}

resolve_cx_path() {
  local script_dir repo_root cx_path=""

  if [[ -n "${CODEX_ORBIT_ENTRYPOINT:-}" && -x "${CODEX_ORBIT_ENTRYPOINT:-}" ]]; then
    printf '%s\n' "$CODEX_ORBIT_ENTRYPOINT"
    return 0
  fi

  cx_path="$(command -v cx 2>/dev/null || true)"
  if [[ -n "$cx_path" && "$cx_path" == /* && -x "$cx_path" ]]; then
    printf '%s\n' "$cx_path"
    return 0
  fi

  script_dir="${0:A:h}"
  repo_root="${script_dir:h}"
  cx_path="${repo_root}/bin/cx"
  if [[ -x "$cx_path" ]]; then
    printf '%s\n' "$cx_path"
    return 0
  fi

  echo "Unable to find an executable cx. Set CODEX_ORBIT_ENTRYPOINT=/absolute/path/to/cx." >&2
  exit 1
}

render_plist() {
  local cx_path
  cx_path="$(resolve_cx_path)"

  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>${cx_path}</string>
      <string>warmup</string>
      <string>--all</string>
      <string>--mini</string>
      <string>--message</string>
      <string>${message}</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
      <dict>
        <key>Hour</key>
        <integer>9</integer>
        <key>Minute</key>
        <integer>0</integer>
      </dict>
      <dict>
        <key>Hour</key>
        <integer>14</integer>
        <key>Minute</key>
        <integer>0</integer>
      </dict>
    </array>
    <key>WorkingDirectory</key>
    <string>${HOME}</string>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${stdout_log}</string>
    <key>StandardErrorPath</key>
    <string>${stderr_log}</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key>
      <string>${PATH}</string>
      <key>HOME</key>
      <string>${HOME}</string>
    </dict>
  </dict>
</plist>
EOF
}

install_agent() {
  require_macos_launchd
  mkdir -p "${plist_path:h}" "$HOME/Library/Logs"
  render_plist > "$plist_path"
  launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$plist_path"
  launchctl kickstart -k "$domain/$label" >/dev/null 2>&1 || true
  printf 'Installed launch agent: %s\n' "$plist_path"
}

uninstall_agent() {
  require_macos_launchd
  launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
  rm -f "$plist_path"
  printf 'Removed launch agent: %s\n' "$plist_path"
}

start_agent() {
  require_macos_launchd
  launchctl kickstart -k "$domain/$label"
  printf 'Started launch agent: %s\n' "$label"
}

stop_agent() {
  require_macos_launchd
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
  printf 'Stopped launch agent: %s\n' "$label"
}

status_agent() {
  require_macos_launchd
  launchctl print "$domain/$label"
}

case "${1:-}" in
  plist)
    render_plist
    ;;
  install)
    install_agent
    ;;
  uninstall)
    uninstall_agent
    ;;
  start)
    start_agent
    ;;
  stop)
    stop_agent
    ;;
  status)
    status_agent
    ;;
  ""|--help|-h)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

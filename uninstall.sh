#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--bin-dir <dir>] [--install-dir <dir>] [--force]

Options:
  --bin-dir <dir>         Where the cx symlink was installed.
  --install-dir <dir>     Where codex-orbit files were installed.
  --force                 Remove target paths even if they are not symlinks.
  --help                  Show this help message.

Environment:
  CODEX_ORBIT_BIN_DIR     Same as --bin-dir
  CODEX_ORBIT_INSTALL_DIR Same as --install-dir

Notes:
  Homebrew installs should be removed with: brew uninstall codex-orbit
EOF
}

default_bin_dir() {
  if [ -n "${CODEX_ORBIT_BIN_DIR:-}" ]; then
    printf '%s\n' "$CODEX_ORBIT_BIN_DIR"
    return 0
  fi

  if [ -n "${XDG_BIN_HOME:-}" ]; then
    printf '%s\n' "$XDG_BIN_HOME"
    return 0
  fi

  printf '%s\n' "$HOME/.local/bin"
}

default_install_dir() {
  if [ -n "${CODEX_ORBIT_INSTALL_DIR:-}" ]; then
    printf '%s\n' "$CODEX_ORBIT_INSTALL_DIR"
    return 0
  fi

  if [ -n "${XDG_DATA_HOME:-}" ]; then
    printf '%s\n' "$XDG_DATA_HOME/codex-orbit"
    return 0
  fi

  printf '%s\n' "$HOME/.local/share/codex-orbit"
}

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

bin_dir="$(default_bin_dir)"
install_dir="$(default_install_dir)"
force=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin-dir)
      [ "$#" -ge 2 ] || fail "missing value for --bin-dir"
      bin_dir="$2"
      shift 2
      ;;
    --install-dir)
      [ "$#" -ge 2 ] || fail "missing value for --install-dir"
      install_dir="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

target_bin="$bin_dir/cx"
target_internal_bin="$install_dir/bin/cx"
target_libexec="$install_dir/libexec"

if [ -L "$target_bin" ] || [ "$force" -eq 1 ]; then
  rm -f "$target_bin"
fi

rm -f "$target_internal_bin"
rm -f "$target_libexec/codex-orbit.zsh"
rm -f "$target_libexec/codex-orbit-launch.py"
rm -f "$target_libexec/codex-orbit-quota.py"
rmdir "$target_libexec" 2>/dev/null || true
rmdir "$install_dir/bin" 2>/dev/null || true
rmdir "$install_dir" 2>/dev/null || true

say "Removed codex-orbit from $install_dir"
say "Removed cx from $target_bin"

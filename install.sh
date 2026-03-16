#!/bin/sh
set -eu

REPO_OWNER="themuuln"
REPO_NAME="codex-orbit"

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [--ref <git-ref>] [--bin-dir <dir>] [--install-dir <dir>] [--force]

Options:
  --ref <git-ref>         Git branch or tag to install. Default: latest tagged release
  --bin-dir <dir>         Where the cx symlink should be placed.
  --install-dir <dir>     Where codex-orbit files should live.
  --force                 Replace an existing cx symlink or binary.
  --help                  Show this help message.

Environment:
  CODEX_ORBIT_INSTALL_REF Same as --ref
  CODEX_ORBIT_BIN_DIR     Same as --bin-dir
  CODEX_ORBIT_INSTALL_DIR Same as --install-dir
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

download_source() {
  ref="$1"
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-orbit-install.XXXXXX")"
  tmp_paths="${tmp_paths}${tmp_paths:+ }$tmp_root"

  archive="$tmp_root/codex-orbit.tar.gz"
  case "$ref" in
    v*)
      url="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/${ref}.tar.gz"
      ;;
    *)
      url="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${ref}.tar.gz"
      ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$archive"
  else
    fail "curl is required when install.sh is not run from a local checkout"
  fi

  tar -xzf "$archive" -C "$tmp_root"
  set -- "$tmp_root"/codex-orbit-*
  [ -d "$1" ] || fail "failed to unpack $url"
  printf '%s\n' "$1"
}

resolve_latest_release_ref() {
  api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
  release_json="$(curl -fsSL "$api_url" 2>/dev/null || true)"
  tag="$(printf '%s' "$release_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"

  if [ -n "$tag" ]; then
    printf '%s\n' "$tag"
  else
    printf 'main\n'
  fi
}

cleanup() {
  set +e
  for path in $tmp_paths; do
    [ -n "$path" ] && rm -rf "$path"
  done
}

ref="${CODEX_ORBIT_INSTALL_REF:-}"
bin_dir="$(default_bin_dir)"
install_dir="$(default_install_dir)"
force=0
tmp_paths=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref)
      [ "$#" -ge 2 ] || fail "missing value for --ref"
      ref="$2"
      shift 2
      ;;
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

trap cleanup EXIT INT TERM

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -f "$script_dir/bin/cx" ] && [ -f "$script_dir/libexec/codex-orbit.zsh" ]; then
  source_dir="$script_dir"
else
  if [ -z "$ref" ]; then
    ref="$(resolve_latest_release_ref)"
  fi
  source_dir="$(download_source "$ref")"
fi

[ -f "$source_dir/bin/cx" ] || fail "missing bin/cx in source tree"
[ -f "$source_dir/libexec/codex-orbit.zsh" ] || fail "missing libexec/codex-orbit.zsh in source tree"

target_bin="$bin_dir/cx"
target_libexec="$install_dir/libexec"
target_internal_bin="$install_dir/bin"

mkdir -p "$bin_dir" "$target_internal_bin" "$target_libexec"

if [ -e "$target_bin" ] || [ -L "$target_bin" ]; then
  if [ "$force" -ne 1 ]; then
    fail "$target_bin already exists; rerun with --force to replace it"
  fi
  rm -f "$target_bin"
fi

install -m 0755 "$source_dir/bin/cx" "$target_internal_bin/cx"
install -m 0644 "$source_dir/libexec/codex-orbit.zsh" "$target_libexec/codex-orbit.zsh"
install -m 0644 "$source_dir/libexec/codex-orbit-quota.py" "$target_libexec/codex-orbit-quota.py"
install -m 0644 "$source_dir/libexec/codex-orbit-shared-home.py" "$target_libexec/codex-orbit-shared-home.py"
ln -s "$target_internal_bin/cx" "$target_bin"

say "Installed codex-orbit to $install_dir"
say "Linked cx to $target_bin"

case ":$PATH:" in
  *":$bin_dir:"*)
    ;;
  *)
    say ""
    say "Add $bin_dir to PATH if it is not already there."
    ;;
esac

say ""
say "Next steps:"
say "  1. Ensure the official codex CLI is installed and on PATH."
say "  2. Run: cx doctor"
say "  3. Run: cx login"

typeset -g CODEX_ORBIT_STATE_SCHEMA_VERSION="${CODEX_ORBIT_STATE_SCHEMA_VERSION:-1}"

_codex_debug_enabled() {
  [[ "${CODEX_ORBIT_DEBUG:-}" == "1" || "${CODEX_ORBIT_DEBUG:-}" == "true" ]]
}

_codex_debug() {
  _codex_debug_enabled || return 0
  printf '[codex-orbit] %s\n' "$*" >&2
}

_codex_accounts_dir() {
  printf '%s\n' "$HOME/.codex-accounts"
}

_codex_account_dir() {
  printf '%s/%s\n' "$(_codex_accounts_dir)" "$1"
}

_codex_locks_dir() {
  printf '%s/.state/locks\n' "$(_codex_accounts_dir)"
}

_codex_lock_wait_seconds() {
  printf '%s\n' "${CODEX_ORBIT_LOCK_TIMEOUT_SECONDS:-10}"
}

_codex_lock_name_path() {
  local lock_name="${1//[^A-Za-z0-9._-]/_}"
  printf '%s/%s.lock\n' "$(_codex_locks_dir)" "$lock_name"
}

_codex_lock_is_held() {
  [[ ":${CODEX_ORBIT_HELD_LOCKS:-}:" == *":$1:"* ]]
}

_codex_mark_lock_held() {
  local lock_name="$1"
  if ! _codex_lock_is_held "$lock_name"; then
    CODEX_ORBIT_HELD_LOCKS="${CODEX_ORBIT_HELD_LOCKS:-}:$lock_name"
  fi
}

_codex_unmark_lock_held() {
  local lock_name="$1"
  CODEX_ORBIT_HELD_LOCKS="${CODEX_ORBIT_HELD_LOCKS//:$lock_name/}"
}

_codex_write_file_atomic() {
  emulate -L zsh
  local target="$1"
  local content="${2-}"
  local target_dir="${target:h}"
  local temp_file="${target}.tmp.$$.$RANDOM"

  mkdir -p "$target_dir" || return 1
  umask 077
  print -r -- "$content" > "$temp_file" || {
    rm -f "$temp_file"
    return 1
  }
  mv "$temp_file" "$target"
}

_codex_acquire_lock() {
  local lock_name="$1"
  local lock_dir="$(_codex_lock_name_path "$lock_name")"
  local owner_file="$lock_dir/pid"
  local now=0 start=0 timeout=0 owner_pid=""

  mkdir -p "$(_codex_locks_dir)" || return 1
  timeout="$(_codex_lock_wait_seconds)"
  start=$SECONDS

  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      umask 077
      print -r -- "$$" >| "$owner_file" || {
        rm -rf "$lock_dir"
        return 1
      }
      return 0
    fi

    owner_pid="$(< "$owner_file" 2>/dev/null || true)"
    if [[ -n "$owner_pid" && "$owner_pid" =~ ^[0-9]+$ ]]; then
      if ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -rf "$lock_dir"
        continue
      fi
    elif [[ ! -e "$owner_file" ]]; then
      sleep 0.05
      continue
    fi

    now=$SECONDS
    if (( now - start >= timeout )); then
      echo "Timed out waiting for lock: $lock_name" >&2
      return 1
    fi
    sleep 0.05
  done
}

_codex_release_lock() {
  rm -rf "$(_codex_lock_name_path "$1")"
}

_codex_with_lock() {
  local lock_name="$1"
  shift || true

  if _codex_lock_is_held "$lock_name"; then
    "$@"
    return $?
  fi

  _codex_acquire_lock "$lock_name" || return 1
  _codex_mark_lock_held "$lock_name"
  "$@"
  local rc=$?
  _codex_unmark_lock_held "$lock_name"
  _codex_release_lock "$lock_name"
  return "$rc"
}

_codex_account_auth_file() {
  printf '%s/auth.json\n' "$(_codex_account_dir "$1")"
}

_codex_accounts_list() {
  local accounts_dir="$(_codex_accounts_dir)"
  local entry=""

  mkdir -p "$accounts_dir"
  for entry in "$accounts_dir"/*(/N); do
    [[ "${entry:t}" == .* ]] && continue
    printf '%s\n' "${entry:t}"
  done
}

_codex_account_exists() {
  [[ -d "$(_codex_account_dir "$1")" ]]
}

_codex_is_logged_in() {
  [[ -f "$(_codex_account_auth_file "$1")" ]]
}

_codex_next_account_name() {
  local last_id=0
  local acct num

  while IFS= read -r acct; do
    [[ "$acct" == acct_* ]] || continue
    num="${acct#acct_}"
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    if (( 10#$num > last_id )); then
      last_id=$((10#$num))
    fi
  done < <(_codex_accounts_list)

  printf 'acct_%03d\n' $((last_id + 1))
}

_codex_reserve_next_account() {
  _codex_with_lock state _codex_reserve_next_account_impl
}

_codex_reserve_next_account_impl() {
  local account=""

  account="$(_codex_next_account_name)" || return 1
  mkdir -p "$(_codex_account_dir "$account")" || return 1
  printf '%s\n' "$account"
}

_codex_ensure_account_config() {
  local acct="$1"
  local account_dir="$(_codex_account_dir "$acct")"
  local config_file="$account_dir/config.toml"
  local temp_file=""

  mkdir -p "$account_dir"

  if [[ ! -f "$config_file" ]]; then
    if [[ -f "$HOME/.codex/config.toml" ]]; then
      cp "$HOME/.codex/config.toml" "$config_file"
    else
      : > "$config_file"
    fi
  fi

  temp_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-config.XXXXXX")" || return 1
  if ! awk '
    BEGIN {
      normalized = "cli_auth_credentials_store = \"file\""
      seen = 0
    }
    /^[[:space:]]*cli_auth_credentials_store[[:space:]]*=/ {
      if (!seen) {
        print normalized
        seen = 1
      }
      next
    }
    { print }
    END {
      if (!seen) {
        if (NR > 0) {
          print ""
        }
        print normalized
      }
    }
  ' "$config_file" > "$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi

  mv "$temp_file" "$config_file"
}

_codex_logged_in_accounts() {
  local accounts_dir="$(_codex_accounts_dir)"
  local auth_file=""

  mkdir -p "$accounts_dir"
  for auth_file in "$accounts_dir"/*/auth.json(N); do
    [[ "${auth_file:h:t}" == .* ]] && continue
    printf '%s\n' "${auth_file:h:t}"
  done
}

_codex_state_dir() {
  printf '%s/.state\n' "$(_codex_accounts_dir)"
}

_codex_trash_dir() {
  printf '%s/.trash\n' "$(_codex_accounts_dir)"
}

_codex_cooldown_dir() {
  printf '%s/cooldowns\n' "$(_codex_state_dir)"
}

_codex_disabled_dir() {
  printf '%s/disabled\n' "$(_codex_state_dir)"
}

_codex_alias_dir() {
  printf '%s/aliases\n' "$(_codex_state_dir)"
}

_codex_cooldown_file() {
  printf '%s/%s.until\n' "$(_codex_cooldown_dir)" "$1"
}

_codex_disabled_file() {
  printf '%s/%s.disabled\n' "$(_codex_disabled_dir)" "$1"
}

_codex_alias_file() {
  printf '%s/%s.alias\n' "$(_codex_alias_dir)" "$1"
}

_codex_session_key() {
  local tty_path=""

  tty_path="$(tty 2>/dev/null || true)"
  if [[ -n "$tty_path" && "$tty_path" != "not a tty" ]]; then
    tty_path="${tty_path#/dev/}"
    tty_path="${tty_path//\//_}"
    tty_path="${tty_path// /_}"
    printf '%s\n' "$tty_path"
    return 0
  fi

  printf 'ppid_%s\n' "${PPID:-unknown}"
}

_codex_session_pin_file() {
  local state_dir="$(_codex_state_dir)"
  mkdir -p "$state_dir"
  printf '%s/session_%s_pinned_account\n' "$state_dir" "$(_codex_session_key)"
}

_codex_last_account_file() {
  printf '%s/last_account\n' "$(_codex_state_dir)"
}

_codex_state_schema_version_file() {
  printf '%s/schema_version\n' "$(_codex_state_dir)"
}

_codex_state_schema_current() {
  printf '%s\n' "$CODEX_ORBIT_STATE_SCHEMA_VERSION"
}

_codex_read_state_schema_version() {
  local version_file="$(_codex_state_schema_version_file)"
  [[ -f "$version_file" ]] || {
    printf '0\n'
    return 0
  }
  printf '%s\n' "$(< "$version_file")"
}

_codex_write_state_schema_version() {
  _codex_write_file_atomic "$(_codex_state_schema_version_file)" "$1"
}

_codex_migrate_state_v0_to_v1() {
  mkdir -p \
    "$(_codex_state_dir)" \
    "$(_codex_trash_dir)" \
    "$(_codex_cooldown_dir)" \
    "$(_codex_disabled_dir)" \
    "$(_codex_alias_dir)" \
    "$(_codex_locks_dir)" || return 1
  _codex_write_state_schema_version 1
}

_codex_ensure_state_schema() {
  _codex_with_lock state _codex_ensure_state_schema_impl
}

_codex_ensure_state_schema_impl() {
  local current_version="" target_version=""

  target_version="$(_codex_state_schema_current)"
  current_version="$(_codex_read_state_schema_version 2>/dev/null || printf '0')"

  if [[ ! "$current_version" =~ ^[0-9]+$ ]]; then
    echo "Invalid codex-orbit state schema version: $current_version" >&2
    return 1
  fi

  if (( current_version > target_version )); then
    echo "codex-orbit state schema $current_version is newer than supported $target_version" >&2
    return 1
  fi

  while (( current_version < target_version )); do
    case "$current_version" in
      0)
        _codex_migrate_state_v0_to_v1 || return 1
        current_version=1
        ;;
      *)
        echo "No codex-orbit state migration for schema version: $current_version" >&2
        return 1
        ;;
    esac
  done

  mkdir -p "$(_codex_locks_dir)" || return 1
}

_codex_all_session_pin_files() {
  local state_dir="$(_codex_state_dir)"
  [[ -d "$state_dir" ]] || return 0
  find "$state_dir" -maxdepth 1 -type f -name 'session_*_pinned_account' | sort
}

_codex_get_pinned_account() {
  local pin_file="$(_codex_session_pin_file)"
  [[ -f "$pin_file" ]] || return 1
  printf '%s\n' "$(< "$pin_file")"
}

_codex_set_pinned_account() {
  local pin_file="$(_codex_session_pin_file)"
  _codex_with_lock state _codex_write_file_atomic "$pin_file" "$1"
}

_codex_clear_pinned_account() {
  local pin_file="$(_codex_session_pin_file)"
  _codex_with_lock state rm -f "$pin_file"
}

_codex_clear_account_pins() {
  local acct="$1"
  local pin_file

  while IFS= read -r pin_file; do
    [[ -n "$pin_file" ]] || continue
    [[ -f "$pin_file" ]] || continue
    if [[ "$(< "$pin_file")" == "$acct" ]]; then
      rm -f "$pin_file"
    fi
  done < <(_codex_all_session_pin_files)
}

_codex_set_last_account() {
  _codex_with_lock state _codex_write_file_atomic "$(_codex_last_account_file)" "$1"
}

_codex_account_alias() {
  local alias_file="$(_codex_alias_file "$1")"
  [[ -f "$alias_file" ]] || return 1
  printf '%s\n' "$(< "$alias_file")"
}

_codex_account_display_name() {
  local acct="$1"
  local alias_name=""

  alias_name="$(_codex_account_alias "$acct" 2>/dev/null || true)"
  if [[ -n "$alias_name" ]]; then
    printf '%s (%s)\n' "$alias_name" "$acct"
  else
    printf '%s\n' "$acct"
  fi
}

_codex_account_short_label() {
  local acct="$1"
  local alias_name=""

  alias_name="$(_codex_account_alias "$acct" 2>/dev/null || true)"
  if [[ -n "$alias_name" ]]; then
    printf '%s\n' "$alias_name"
  else
    printf '%s\n' "$acct"
  fi
}

_codex_account_preferred_label() {
  local acct="$1"
  local fallback="${2:-}"
  local alias_name=""

  alias_name="$(_codex_account_alias "$acct" 2>/dev/null || true)"
  if [[ -n "$alias_name" ]]; then
    printf '%s\n' "$alias_name"
  elif [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
  else
    printf '%s\n' "$acct"
  fi
}

_codex_validate_alias_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

_codex_find_account_by_alias() {
  local alias_name="$1"
  local acct=""

  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    if [[ "$(_codex_account_alias "$acct" 2>/dev/null || true)" == "$alias_name" ]]; then
      printf '%s\n' "$acct"
      return 0
    fi
  done < <(_codex_accounts_list)

  return 1
}

_codex_resolve_account_ref() {
  local ref="${1:-}"
  local acct=""

  [[ -n "$ref" ]] || return 1
  if _codex_account_exists "$ref"; then
    printf '%s\n' "$ref"
    return 0
  fi

  acct="$(_codex_find_account_by_alias "$ref" 2>/dev/null || true)"
  [[ -n "$acct" ]] || return 1
  printf '%s\n' "$acct"
}

_codex_set_account_alias() {
  _codex_with_lock state _codex_set_account_alias_impl "$@"
}

_codex_set_account_alias_impl() {
  local acct="$1"
  local alias_name="$2"
  local existing=""

  _codex_validate_alias_name "$alias_name" || {
    echo "Invalid alias: $alias_name"
    echo "Allowed characters: letters, numbers, dot, underscore, hyphen"
    return 1
  }

  if _codex_account_exists "$alias_name"; then
    if [[ "$alias_name" != "$acct" ]]; then
      echo "Alias conflicts with existing account name: $alias_name"
      return 1
    fi
  fi

  existing="$(_codex_find_account_by_alias "$alias_name" 2>/dev/null || true)"
  if [[ -n "$existing" && "$existing" != "$acct" ]]; then
    echo "Alias already in use: $alias_name"
    return 1
  fi

  mkdir -p "$(_codex_alias_dir)"
  _codex_write_file_atomic "$(_codex_alias_file "$acct")" "$alias_name"
}

_codex_clear_account_alias() {
  _codex_with_lock state rm -f "$(_codex_alias_file "$1")"
}

_codex_mask_email() {
  local email="${1:-}"
  local local_part domain

  [[ "$email" == *"@"* ]] || {
    printf '%s\n' "$email"
    return 0
  }

  local_part="${email%@*}"
  domain="${email#*@}"

  if (( ${#local_part} <= 2 )); then
    printf '***@%s\n' "$domain"
  else
    printf '%s***@%s\n' "${local_part[1,2]}" "$domain"
  fi
}

_codex_display_email() {
  local email="${1:-}"
  local fallback="${2:-}"

  if [[ -n "$email" ]]; then
    printf '%s\n' "$email"
  else
    printf '%s\n' "$fallback"
  fi
}

_codex_parse_duration_to_seconds() {
  local duration="${1:-}"
  local number unit

  [[ "$duration" =~ ^([0-9]+)([mhd])$ ]] || return 1

  number="${match[1]}"
  unit="${match[2]}"

  case "$unit" in
    m) printf '%s\n' $((number * 60)) ;;
    h) printf '%s\n' $((number * 60 * 60)) ;;
    d) printf '%s\n' $((number * 60 * 60 * 24)) ;;
    *) return 1 ;;
  esac
}

_codex_format_timestamp() {
  local epoch="$1"

  date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
    date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
    printf '%s\n' "$epoch"
}

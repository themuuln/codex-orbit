typeset -g CODEX_ORBIT_LIBEXEC_DIR="${CODEX_ORBIT_LIBEXEC_DIR:-${${(%):-%N}:P:h}}"

codex_account() {
  local acct="${1:-}"
  local resolved_acct=""
  shift || true

  if [[ -z "$acct" ]]; then
    echo "usage: codex_account <account> [codex args...]"
    return 1
  fi

  _codex_ensure_state_schema || return 1
  resolved_acct="$(_codex_resolve_account_ref "$acct" 2>/dev/null || true)"
  if [[ -z "$resolved_acct" || ! -d "$HOME/.codex-accounts/$resolved_acct" ]]; then
    echo "unknown account: $acct"
    echo "create one with: cx login"
    return 1
  fi

  _codex_prepare_account_home "$resolved_acct" || return 1
  _codex_run_codex_for_account "$resolved_acct" "$@"
}

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
  local account=""

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

_codex_ensure_account_agents() {
  local acct="$1"
  local account_dir="$(_codex_account_dir "$acct")"
  local account_agents="$account_dir/AGENTS.md"
  local base_agents="$HOME/.codex/AGENTS.md"
  local target=""

  mkdir -p "$account_dir" || return 1

  if [[ ! -e "$base_agents" ]]; then
    return 0
  fi

  if [[ -L "$account_agents" ]]; then
    target="$(readlink "$account_agents" 2>/dev/null || true)"
    if [[ -n "$target" && "$(cd "$account_dir" && realpath "$target" 2>/dev/null)" == "$(realpath "$base_agents" 2>/dev/null)" ]]; then
      return 0
    fi
    rm -f "$account_agents" || return 1
  elif [[ -e "$account_agents" ]]; then
    return 0
  fi

  ln -s ../../.codex/AGENTS.md "$account_agents"
}

_codex_account_agents_status() {
  local acct="$1"
  local account_dir="$(_codex_account_dir "$acct")"
  local account_agents="$account_dir/AGENTS.md"
  local base_agents="$HOME/.codex/AGENTS.md"
  local base_real="" target="" target_real=""

  if [[ ! -e "$base_agents" ]]; then
    if [[ -L "$account_agents" ]]; then
      echo "orphan-link"
    elif [[ -e "$account_agents" ]]; then
      echo "custom"
    else
      echo "absent"
    fi
    return 0
  fi

  base_real="$(realpath "$base_agents" 2>/dev/null || true)"

  if [[ -L "$account_agents" ]]; then
    target="$(readlink "$account_agents" 2>/dev/null || true)"
    target_real="$(cd "$account_dir" && realpath "$target" 2>/dev/null || true)"
    if [[ -n "$target_real" && "$target_real" == "$base_real" ]]; then
      echo "linked"
    else
      echo "drift-link"
    fi
  elif [[ -e "$account_agents" ]]; then
    echo "custom"
  else
    echo "missing"
  fi
}

_codex_collect_agents_audit() {
  typeset -gA CODEX_ORBIT_AGENTS_AUDIT
  typeset -ga CODEX_ORBIT_AGENTS_DRIFT_ACCOUNTS
  local acct="" acct_status=""
  local base_present=0 linked=0 custom=0 missing=0 drift_links=0 orphan_links=0 absent=0 drift=0
  local -a drift_accounts=()

  CODEX_ORBIT_AGENTS_AUDIT=()
  CODEX_ORBIT_AGENTS_DRIFT_ACCOUNTS=()

  [[ -e "$HOME/.codex/AGENTS.md" ]] && base_present=1

  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    acct_status="$(_codex_account_agents_status "$acct")"
    case "$acct_status" in
      linked)
        (( linked += 1 ))
        ;;
      custom)
        (( custom += 1 ))
        (( base_present )) && drift_accounts+=("$acct")
        ;;
      missing)
        (( missing += 1 ))
        (( base_present )) && drift_accounts+=("$acct")
        ;;
      drift-link)
        (( drift_links += 1 ))
        (( base_present )) && drift_accounts+=("$acct")
        ;;
      orphan-link)
        (( orphan_links += 1 ))
        ;;
      absent)
        (( absent += 1 ))
        ;;
    esac
  done < <(_codex_accounts_list)

  if (( base_present )); then
    drift=$(( custom + missing + drift_links ))
  else
    drift=$orphan_links
  fi

  CODEX_ORBIT_AGENTS_AUDIT[base_present]="$base_present"
  CODEX_ORBIT_AGENTS_AUDIT[linked]="$linked"
  CODEX_ORBIT_AGENTS_AUDIT[custom]="$custom"
  CODEX_ORBIT_AGENTS_AUDIT[missing]="$missing"
  CODEX_ORBIT_AGENTS_AUDIT[drift_links]="$drift_links"
  CODEX_ORBIT_AGENTS_AUDIT[orphan_links]="$orphan_links"
  CODEX_ORBIT_AGENTS_AUDIT[absent]="$absent"
  CODEX_ORBIT_AGENTS_AUDIT[drift]="$drift"
  CODEX_ORBIT_AGENTS_DRIFT_ACCOUNTS=("${drift_accounts[@]}")
}

_codex_sync_agents() {
  local base_agents="$HOME/.codex/AGENTS.md"
  local ref="" resolved=""
  local -a selected_accounts=()

  if [[ ! -e "$base_agents" ]]; then
    echo "Shared AGENTS file not found: ~/.codex/AGENTS.md"
    return 1
  fi

  if (( $# > 0 )); then
    for ref in "$@"; do
      resolved="$(_codex_resolve_account_ref "$ref" 2>/dev/null || true)"
      if [[ -z "$resolved" || ! -d "$(_codex_account_dir "$resolved")" ]]; then
        echo "Unknown account: $ref"
        return 1
      fi
      selected_accounts+=("$resolved")
    done
  else
    selected_accounts=("${(@f)$(_codex_accounts_list)}")
  fi

  _codex_with_lock state _codex_sync_agents_impl "${selected_accounts[@]}"
}

_codex_sync_agents_impl() {
  local stamp="$(date '+%Y%m%d%H%M%S')"
  local acct="" account_dir="" account_agents="" acct_status="" backup_path=""
  local changed=0 backed_up=0 skipped=0

  for acct in "$@"; do
    [[ -n "$acct" ]] || continue
    account_dir="$(_codex_account_dir "$acct")"
    account_agents="$account_dir/AGENTS.md"
    acct_status="$(_codex_account_agents_status "$acct")"

    case "$acct_status" in
      linked)
        (( skipped += 1 ))
        continue
        ;;
      custom)
        backup_path="$account_dir/AGENTS.md.backup-$stamp"
        mv "$account_agents" "$backup_path" || return 1
        (( backed_up += 1 ))
        ;;
      drift-link)
        rm -f "$account_agents" || return 1
        ;;
      missing)
        mkdir -p "$account_dir" || return 1
        ;;
      *)
        continue
        ;;
    esac

    ln -s ../../.codex/AGENTS.md "$account_agents" || return 1
    (( changed += 1 ))
  done

  printf 'Synced AGENTS.md for %d account(s)' "$changed"
  if (( backed_up > 0 )); then
    printf '; backed up %d standalone file(s)' "$backed_up"
  fi
  if (( skipped > 0 )); then
    printf '; %d already linked' "$skipped"
  fi
  printf '\n'
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

_codex_python3() {
  command -v python3 2>/dev/null || return 1
}

_codex_quota_helper() {
  printf '%s/codex-orbit-quota.py\n' "$CODEX_ORBIT_LIBEXEC_DIR"
}

_codex_shared_home_helper() {
  printf '%s/codex-orbit-shared-home.py\n' "$CODEX_ORBIT_LIBEXEC_DIR"
}

_codex_share_helper() {
  printf '%s/codex-orbit-share.py\n' "$CODEX_ORBIT_LIBEXEC_DIR"
}

_codex_prepare_shared_sessions() {
  local py script

  py="$(_codex_python3)" || {
    echo "python3 is required for shared-session migration"
    return 1
  }
  script="$(_codex_shared_home_helper)"
  [[ -f "$script" ]] || return 1

  "$py" "$script" --accounts-dir "$(_codex_accounts_dir)"
}

_codex_prepare_account_home() {
  local acct="$1"

  _codex_ensure_account_config "$acct" || return 1
  _codex_ensure_account_agents "$acct" || return 1
  _codex_prepare_shared_sessions || return 1
}

_codex_default_share_archive_path() {
  printf '%s/codex-orbit-share-%s.tar.gz\n' "$PWD" "$(date '+%Y%m%d%H%M%S')"
}

_codex_global_config_file() {
  printf '%s/.codex/config.toml\n' "$HOME"
}

_codex_default_config_share_archive_path() {
  printf '%s/codex-orbit-config-share-%s.tar.gz\n' "$PWD" "$(date '+%Y%m%d%H%M%S')"
}

_codex_share_export() {
  _codex_with_lock state _codex_share_export_impl "$@"
}

_codex_share_export_impl() {
  local py script output="" arg acct archive_path="" resolved_acct=""
  local export_all=0
  local -a selected_accounts=() helper_args=()

  py="$(_codex_python3)" || {
    echo "python3 is required for cx share export"
    return 1
  }
  script="$(_codex_share_helper)"
  [[ -f "$script" ]] || {
    echo "share helper not found"
    return 1
  }

  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      --output)
        if (( $# < 2 )); then
          echo "Usage: cx share export [account ...|--all] [--output <archive.tar.gz>]"
          return 1
        fi
        output="$2"
        shift 2
        ;;
      --all)
        export_all=1
        shift
        ;;
      --help|-h)
        echo "Usage: cx share export [account ...|--all] [--output <archive.tar.gz>]"
        echo "Default: exports all logged-in accounts into ./codex-orbit-share-YYYYMMDDHHMMSS.tar.gz"
        return 0
        ;;
      *)
        selected_accounts+=("$arg")
        shift
        ;;
    esac
  done

  if (( export_all )) && (( ${#selected_accounts[@]} > 0 )); then
    echo "Usage: cx share export [account ...|--all] [--output <archive.tar.gz>]"
    return 1
  fi

  if (( export_all )) || (( ${#selected_accounts[@]} == 0 )); then
    while IFS= read -r acct; do
      [[ -n "$acct" ]] || continue
      selected_accounts+=("$acct")
    done < <(_codex_logged_in_accounts)
  fi

  if (( ${#selected_accounts[@]} == 0 )); then
    echo "No logged-in Codex accounts found. Run: cx login"
    return 1
  fi

  local -a resolved_accounts=()
  for acct in "${selected_accounts[@]}"; do
    resolved_acct="$(_codex_resolve_account_ref "$acct" 2>/dev/null || true)"
    if [[ -z "$resolved_acct" ]]; then
      echo "No logged-in Codex account: $acct"
      return 1
    fi
    if ! _codex_is_logged_in "$resolved_acct"; then
      echo "No logged-in Codex account: $acct"
      return 1
    fi
    if (( ${resolved_accounts[(Ie)$resolved_acct]} == 0 )); then
      resolved_accounts+=("$resolved_acct")
    fi
    _codex_ensure_account_config "$resolved_acct" || return 1
  done

  [[ -n "$output" ]] || output="$(_codex_default_share_archive_path)"
  helper_args=(export --accounts-dir "$(_codex_accounts_dir)" --output "$output")
  for acct in "${resolved_accounts[@]}"; do
    helper_args+=(--account "$acct")
  done

  if ! archive_path="$("$py" "$script" "${helper_args[@]}")"; then
    return 1
  fi

  printf 'Exported %d account(s) to %s\n' "${#resolved_accounts[@]}" "$archive_path"
  printf 'Import on the other machine with: cx share import %s\n' "$archive_path"
}

_codex_share_config_export() {
  local py script output="" arg archive_path="" config_file=""

  py="$(_codex_python3)" || {
    echo "python3 is required for cx share config export"
    return 1
  }
  script="$(_codex_share_helper)"
  [[ -f "$script" ]] || {
    echo "share helper not found"
    return 1
  }

  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      --output)
        if (( $# < 2 )); then
          echo "Usage: cx share config export [--output <archive.tar.gz>]"
          return 1
        fi
        output="$2"
        shift 2
        ;;
      --help|-h)
        echo "Usage: cx share config export [--output <archive.tar.gz>]"
        echo "Default: exports ~/.codex/config.toml into ./codex-orbit-config-share-YYYYMMDDHHMMSS.tar.gz"
        return 0
        ;;
      *)
        echo "Usage: cx share config export [--output <archive.tar.gz>]"
        return 1
        ;;
    esac
  done

  config_file="$(_codex_global_config_file)"
  if [[ ! -f "$config_file" ]]; then
    echo "Global Codex config not found: $config_file"
    return 1
  fi

  [[ -n "$output" ]] || output="$(_codex_default_config_share_archive_path)"
  if ! archive_path="$("$py" "$script" export-config --config-file "$config_file" --output "$output")"; then
    return 1
  fi

  printf 'Exported global config to %s\n' "$archive_path"
  printf 'Import on the other machine with: cx share config import %s\n' "$archive_path"
}

_codex_share_import() {
  _codex_with_lock state _codex_share_import_impl "$@"
}

_codex_share_import_impl() {
  local py script archive_path="" mapping="" source_acct="" target_acct=""
  local imported_count=0

  py="$(_codex_python3)" || {
    echo "python3 is required for cx share import"
    return 1
  }
  script="$(_codex_share_helper)"
  [[ -f "$script" ]] || {
    echo "share helper not found"
    return 1
  }

  case "${1:-}" in
    "")
      echo "Usage: cx share import <archive.tar.gz>"
      return 1
      ;;
    --help|-h)
      echo "Usage: cx share import <archive.tar.gz>"
      return 0
      ;;
  esac

  archive_path="$1"
  shift || true
  if (( $# > 0 )); then
    echo "Usage: cx share import <archive.tar.gz>"
    return 1
  fi

  if ! mapping="$("$py" "$script" import --accounts-dir "$(_codex_accounts_dir)" --input "$archive_path")"; then
    return 1
  fi

  while IFS=$'\t' read -r source_acct target_acct; do
    [[ -n "$target_acct" ]] || continue
    _codex_prepare_account_home "$target_acct" || return 1
    imported_count=$((imported_count + 1))
    if [[ "$source_acct" == "$target_acct" ]]; then
      printf 'Imported: %s\n' "$target_acct"
    else
      printf 'Imported: %s -> %s\n' "$source_acct" "$target_acct"
    fi
  done <<< "$mapping"

  printf 'Imported %d account(s). Run: cx list\n' "$imported_count"
}

_codex_share_config_import() {
  local py script archive_path="" backup_path=""
  local config_file=""

  py="$(_codex_python3)" || {
    echo "python3 is required for cx share config import"
    return 1
  }
  script="$(_codex_share_helper)"
  [[ -f "$script" ]] || {
    echo "share helper not found"
    return 1
  }

  case "${1:-}" in
    "")
      echo "Usage: cx share config import <archive.tar.gz>"
      return 1
      ;;
    --help|-h)
      echo "Usage: cx share config import <archive.tar.gz>"
      return 0
      ;;
  esac

  archive_path="$1"
  shift || true
  if (( $# > 0 )); then
    echo "Usage: cx share config import <archive.tar.gz>"
    return 1
  fi

  config_file="$(_codex_global_config_file)"
  if ! backup_path="$("$py" "$script" import-config --config-file "$config_file" --input "$archive_path")"; then
    return 1
  fi

  if [[ -n "$backup_path" ]]; then
    printf 'Backed up existing global config to %s\n' "$backup_path"
  fi
  printf 'Imported global config to %s\n' "$config_file"
}

_codex_list_account_aliases() {
  local acct="" alias_name=""
  local found=0

  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    alias_name="$(_codex_account_alias "$acct" 2>/dev/null || true)"
    [[ -n "$alias_name" ]] || continue
    printf '%s\t%s\n' "$alias_name" "$acct"
    found=1
  done < <(_codex_accounts_list)

  (( found )) || return 1
}

_codex_repo_checkout_root() {
  local root="${CODEX_ORBIT_LIBEXEC_DIR:h}"
  [[ -d "$root/.git" && -f "$root/bin/cx" ]] || return 1
  printf '%s\n' "$root"
}

_codex_current_install_method() {
  local repo_root=""

  if repo_root="$(_codex_repo_checkout_root 2>/dev/null)"; then
    printf 'repo\n'
    return 0
  fi

  printf 'direct\n'
}

_codex_update_repo_checkout() {
  local repo_root=""

  repo_root="$(_codex_repo_checkout_root)" || {
    echo "Repo checkout not detected."
    return 1
  }

  if ! command -v git >/dev/null 2>&1; then
    echo "git is required for cx update in a repo checkout"
    return 1
  fi

  if ! git -C "$repo_root" diff --quiet --ignore-submodules -- || ! git -C "$repo_root" diff --cached --quiet --ignore-submodules --; then
    echo "Repo checkout has local changes. Commit or stash them before cx update."
    return 1
  fi

  git -C "$repo_root" pull --ff-only
}

_codex_update_direct_install() {
  local cx_path="" bin_dir="" install_dir=""

  command -v curl >/dev/null 2>&1 || {
    echo "curl is required for cx update"
    return 1
  }

  cx_path="$(command -v cx 2>/dev/null || true)"
  [[ -n "$cx_path" ]] || cx_path="$0"
  bin_dir="${cx_path:h}"
  install_dir="${CODEX_ORBIT_LIBEXEC_DIR:h}"

  curl -fsSL "https://raw.githubusercontent.com/themuuln/codex-orbit/main/install.sh" | \
    CODEX_ORBIT_BIN_DIR="$bin_dir" \
    CODEX_ORBIT_INSTALL_DIR="$install_dir" \
    sh -s -- --force
}

_codex_update_self() {
  local method=""

  method="$(_codex_current_install_method)"
  case "$method" in
    repo)
      echo "Update method: repo checkout"
      _codex_update_repo_checkout
      ;;
    direct)
      echo "Update method: direct install"
      _codex_update_direct_install
      ;;
    *)
      echo "Unknown install method."
      return 1
      ;;
  esac
}

_codex_count_lines() {
  local count=0 line=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

_codex_accounts_total() {
  _codex_accounts_list | _codex_count_lines
}

_codex_logged_in_accounts_total() {
  _codex_logged_in_accounts | _codex_count_lines
}

_codex_active_cooldowns_total() {
  _codex_active_cooldowns | _codex_count_lines
}

_codex_disabled_accounts_total() {
  local acct="" count=0
  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    _codex_account_disabled "$acct" || continue
    count=$((count + 1))
  done < <(_codex_accounts_list)
  printf '%s\n' "$count"
}

_codex_aliases_total() {
  local alias_name="" acct="" count=0

  while IFS=$'\t' read -r alias_name acct; do
    [[ -n "$alias_name" && -n "$acct" ]] || continue
    count=$((count + 1))
  done < <(_codex_list_account_aliases 2>/dev/null || true)

  printf '%s\n' "$count"
}

_codex_archived_accounts_total() {
  find "$(_codex_trash_dir)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | _codex_count_lines
}

_codex_support_bundle_default_path() {
  printf '%s/codex-orbit-support-%s.tar.gz\n' "$PWD" "$(date '+%Y%m%d%H%M%S')"
}

_codex_doctor_text() {
  local doctor_exit=0
  local accounts_count logged_in_count cooldown_count archived_count
  local agents_drift=0
  local drift_preview=""

  if command -v codex >/dev/null 2>&1; then
    printf '[ok] codex: %s\n' "$(command -v codex)"
  else
    echo "[fail] codex: missing from PATH"
    doctor_exit=1
  fi

  if command -v rg >/dev/null 2>&1; then
    printf '[ok] rg: %s\n' "$(command -v rg)"
  else
    echo "[fail] rg: missing from PATH"
    doctor_exit=1
  fi

  if command -v fzf >/dev/null 2>&1; then
    printf '[ok] fzf: %s\n' "$(command -v fzf)"
  else
    echo "[warn] fzf: optional, picker falls back to numbered prompts"
  fi

  if _codex_python3 >/dev/null 2>&1; then
    printf '[ok] python3: %s\n' "$(_codex_python3)"
  else
    echo "[warn] python3: required for shared-session migration, plus email/workspace metadata and live quota in cx list/cx which/cx quota"
  fi

  mkdir -p "$(_codex_accounts_dir)" "$(_codex_state_dir)" "$(_codex_trash_dir)" "$(_codex_cooldown_dir)"
  if [[ -w "$(_codex_accounts_dir)" && -w "$(_codex_state_dir)" ]]; then
    printf '[ok] state: %s\n' "$(_codex_accounts_dir)"
  else
    echo "[fail] state: ~/.codex-accounts is not writable"
    doctor_exit=1
  fi

  accounts_count="$(_codex_accounts_total)"
  logged_in_count="$(_codex_logged_in_accounts_total)"
  cooldown_count="$(_codex_active_cooldowns_total)"
  archived_count="$(_codex_archived_accounts_total)"

  printf '[info] accounts: %s total, %s logged in\n' "$accounts_count" "$logged_in_count"
  printf '[info] cooldowns: %s active\n' "$cooldown_count"
  printf '[info] routing: %s\n' "$(_codex_routing_strategy)"
  printf '[info] install: %s\n' "$(_codex_current_install_method)"
  printf '[info] archived: %s\n' "$archived_count"

  if [[ -f "$HOME/.codex/config.toml" ]]; then
    echo "[ok] base config: ~/.codex/config.toml found"
  else
    echo "[warn] base config: ~/.codex/config.toml not found, new accounts start with an empty config"
  fi

  _codex_collect_agents_audit
  agents_drift="${CODEX_ORBIT_AGENTS_AUDIT[drift]:-0}"
  if [[ "${CODEX_ORBIT_AGENTS_AUDIT[base_present]:-0}" == "1" ]]; then
    if (( agents_drift == 0 )); then
      echo "[ok] shared agents: all account homes link to ~/.codex/AGENTS.md"
    else
      drift_preview="${(j:, :)CODEX_ORBIT_AGENTS_DRIFT_ACCOUNTS[1,3]}"
      printf '[warn] shared agents: %s account home(s) are not linked to ~/.codex/AGENTS.md (run: cx sync-agents)\n' "$agents_drift"
      [[ -n "$drift_preview" ]] && printf '[info] shared agents drift: %s\n' "$drift_preview"
    fi
  else
    echo "[info] shared agents: ~/.codex/AGENTS.md not found, account homes will not auto-link AGENTS.md"
  fi

  return "$doctor_exit"
}

_codex_doctor_json() {
  local py=""
  local codex_path="" rg_path="" fzf_path="" python_path=""
  local accounts_count logged_in_count cooldown_count disabled_count alias_count archived_count
  local base_config_present=0 state_writable=0
  local agent_drift=0 agent_linked=0 agent_custom=0 agent_missing=0 agent_drift_links=0 agent_orphan_links=0
  local agent_drift_accounts=""

  py="$(_codex_python3)" || {
    echo "python3 is required for cx doctor --json"
    return 1
  }

  mkdir -p "$(_codex_accounts_dir)" "$(_codex_state_dir)" "$(_codex_trash_dir)" "$(_codex_cooldown_dir)"
  accounts_count="$(_codex_accounts_total)"
  logged_in_count="$(_codex_logged_in_accounts_total)"
  cooldown_count="$(_codex_active_cooldowns_total)"
  disabled_count="$(_codex_disabled_accounts_total)"
  alias_count="$(_codex_aliases_total)"
  archived_count="$(_codex_archived_accounts_total)"

  [[ -f "$HOME/.codex/config.toml" ]] && base_config_present=1
  [[ -w "$(_codex_accounts_dir)" && -w "$(_codex_state_dir)" ]] && state_writable=1

  codex_path="$(command -v codex 2>/dev/null || true)"
  rg_path="$(command -v rg 2>/dev/null || true)"
  fzf_path="$(command -v fzf 2>/dev/null || true)"
  python_path="$(_codex_python3 2>/dev/null || true)"

  _codex_collect_agents_audit
  agent_drift="${CODEX_ORBIT_AGENTS_AUDIT[drift]:-0}"
  agent_linked="${CODEX_ORBIT_AGENTS_AUDIT[linked]:-0}"
  agent_custom="${CODEX_ORBIT_AGENTS_AUDIT[custom]:-0}"
  agent_missing="${CODEX_ORBIT_AGENTS_AUDIT[missing]:-0}"
  agent_drift_links="${CODEX_ORBIT_AGENTS_AUDIT[drift_links]:-0}"
  agent_orphan_links="${CODEX_ORBIT_AGENTS_AUDIT[orphan_links]:-0}"
  agent_drift_accounts="${(j:,:)CODEX_ORBIT_AGENTS_DRIFT_ACCOUNTS}"

  DOCTOR_GENERATED_AT="$(_codex_now_epoch)" \
  DOCTOR_INSTALL_METHOD="$(_codex_current_install_method)" \
  DOCTOR_ROUTING="$(_codex_routing_strategy)" \
  DOCTOR_ACCOUNTS="$accounts_count" \
  DOCTOR_LOGGED_IN="$logged_in_count" \
  DOCTOR_COOLDOWNS="$cooldown_count" \
  DOCTOR_DISABLED="$disabled_count" \
  DOCTOR_ALIASES="$alias_count" \
  DOCTOR_ARCHIVED="$archived_count" \
  DOCTOR_BASE_CONFIG="$base_config_present" \
  DOCTOR_STATE_WRITABLE="$state_writable" \
  DOCTOR_AGENTS_BASE_PRESENT="${CODEX_ORBIT_AGENTS_AUDIT[base_present]:-0}" \
  DOCTOR_AGENTS_DRIFT="$agent_drift" \
  DOCTOR_AGENTS_LINKED="$agent_linked" \
  DOCTOR_AGENTS_CUSTOM="$agent_custom" \
  DOCTOR_AGENTS_MISSING="$agent_missing" \
  DOCTOR_AGENTS_DRIFT_LINKS="$agent_drift_links" \
  DOCTOR_AGENTS_ORPHAN_LINKS="$agent_orphan_links" \
  DOCTOR_AGENTS_DRIFT_ACCOUNTS="$agent_drift_accounts" \
  DOCTOR_ACCOUNTS_DIR="$(_codex_accounts_dir)" \
  DOCTOR_STATE_DIR="$(_codex_state_dir)" \
  DOCTOR_CODEX_PATH="$codex_path" \
  DOCTOR_RG_PATH="$rg_path" \
  DOCTOR_FZF_PATH="$fzf_path" \
  DOCTOR_PYTHON_PATH="$python_path" \
  "$py" - <<'PY'
import json
import os

def env_int(name: str) -> int:
    return int(os.environ.get(name, "0") or "0")

payload = {
    "generated_at_epoch": env_int("DOCTOR_GENERATED_AT"),
    "install_method": os.environ.get("DOCTOR_INSTALL_METHOD", ""),
    "routing_strategy": os.environ.get("DOCTOR_ROUTING", ""),
    "paths": {
        "accounts_dir": os.environ.get("DOCTOR_ACCOUNTS_DIR", ""),
        "state_dir": os.environ.get("DOCTOR_STATE_DIR", ""),
        "codex": os.environ.get("DOCTOR_CODEX_PATH", ""),
        "ripgrep": os.environ.get("DOCTOR_RG_PATH", ""),
        "fzf": os.environ.get("DOCTOR_FZF_PATH", ""),
        "python3": os.environ.get("DOCTOR_PYTHON_PATH", ""),
    },
    "counts": {
        "accounts": env_int("DOCTOR_ACCOUNTS"),
        "logged_in": env_int("DOCTOR_LOGGED_IN"),
        "cooldowns": env_int("DOCTOR_COOLDOWNS"),
        "disabled": env_int("DOCTOR_DISABLED"),
        "aliases": env_int("DOCTOR_ALIASES"),
        "archived": env_int("DOCTOR_ARCHIVED"),
        "agent_drift": env_int("DOCTOR_AGENTS_DRIFT"),
        "agent_linked": env_int("DOCTOR_AGENTS_LINKED"),
        "agent_custom": env_int("DOCTOR_AGENTS_CUSTOM"),
        "agent_missing": env_int("DOCTOR_AGENTS_MISSING"),
        "agent_drift_links": env_int("DOCTOR_AGENTS_DRIFT_LINKS"),
        "agent_orphan_links": env_int("DOCTOR_AGENTS_ORPHAN_LINKS"),
    },
    "checks": {
        "base_config_present": bool(env_int("DOCTOR_BASE_CONFIG")),
        "state_writable": bool(env_int("DOCTOR_STATE_WRITABLE")),
        "codex_in_path": bool(os.environ.get("DOCTOR_CODEX_PATH")),
        "ripgrep_in_path": bool(os.environ.get("DOCTOR_RG_PATH")),
        "fzf_in_path": bool(os.environ.get("DOCTOR_FZF_PATH")),
        "python3_in_path": bool(os.environ.get("DOCTOR_PYTHON_PATH")),
        "shared_agents_present": bool(env_int("DOCTOR_AGENTS_BASE_PRESENT")),
        "shared_agents_consistent": env_int("DOCTOR_AGENTS_DRIFT") == 0,
    },
    "shared_agents": {
        "drift_accounts": [item for item in os.environ.get("DOCTOR_AGENTS_DRIFT_ACCOUNTS", "").split(",") if item],
    },
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY
}

_codex_write_support_bundle() {
  local output="${1:-}"
  local temp_dir="" doctor_path="" aliases_path="" cooldowns_path="" accounts_path="" routing_path="" install_path="" doctor_json=""
  local rc=0

  command -v tar >/dev/null 2>&1 || {
    echo "tar is required for cx support"
    return 1
  }

  [[ -n "$output" ]] || output="$(_codex_support_bundle_default_path)"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-orbit-support.XXXXXX")" || return 1
  doctor_path="$temp_dir/doctor.txt"
  aliases_path="$temp_dir/aliases.tsv"
  cooldowns_path="$temp_dir/cooldowns.tsv"
  accounts_path="$temp_dir/accounts.tsv"
  routing_path="$temp_dir/routing.txt"
  install_path="$temp_dir/install.txt"

  _codex_doctor_text > "$doctor_path" || rc=$?
  if doctor_json="$(_codex_doctor_json 2>/dev/null || true)"; then
    if [[ -n "$doctor_json" ]]; then
      print -r -- "$doctor_json" > "$temp_dir/doctor.json"
    fi
  fi

  _codex_list_account_aliases > "$aliases_path" 2>/dev/null || : > "$aliases_path"
  _codex_active_cooldowns > "$cooldowns_path" 2>/dev/null || : > "$cooldowns_path"
  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    printf '%s\t%s\n' "$acct" "$(_codex_account_status_value "$acct")"
  done > "$accounts_path" < <(_codex_accounts_list)
  {
    printf 'routing=%s\n' "$(_codex_routing_strategy)"
    printf 'resolve=%s\n' "$(_codex_resolve_account_selection 0 2>/dev/null || printf 'unavailable')"
  } > "$routing_path"
  {
    printf 'install_method=%s\n' "$(_codex_current_install_method)"
    printf 'libexec_dir=%s\n' "$CODEX_ORBIT_LIBEXEC_DIR"
    printf 'cx_path=%s\n' "$(command -v cx 2>/dev/null || true)"
  } > "$install_path"

  tar -czf "$output" -C "$temp_dir" . || {
    rm -rf "$temp_dir"
    return 1
  }
  rm -rf "$temp_dir"
  printf '%s\n' "$output"
  return "$rc"
}

source "$CODEX_ORBIT_LIBEXEC_DIR/codex-orbit-state.zsh"
source "$CODEX_ORBIT_LIBEXEC_DIR/codex-orbit-admin.zsh"

_codex_wait_for_pids() {
  local message="${1:-Working}"
  shift || true
  local -a pids=("$@")
  local locale_hint="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  local -a frames=()
  local frame_idx=1
  local interactive=0
  local pid="" running=0

  (( ${#pids[@]} > 0 )) || return 0
  [[ -t 2 ]] && interactive=1
  if [[ "${locale_hint:l}" == *utf-8* || "${locale_hint:l}" == *utf8* ]]; then
    frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  else
    frames=('|' '/' '-' '\')
  fi

  while true; do
    running=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        running=1
        break
      fi
    done

    (( running )) || break

    if (( interactive )); then
      printf '\r%s %s' "$message" "${frames[$frame_idx]}" >&2
      frame_idx=$((frame_idx + 1))
      (( frame_idx > ${#frames[@]} )) && frame_idx=1
    fi
    sleep 0.1
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  if (( interactive )); then
    printf '\r%s done\n' "$message" >&2
  fi
}

_codex_quota_cache_dir() {
  printf '%s/quota-cache\n' "$(_codex_state_dir)"
}

_codex_quota_cache_file() {
  local acct="$1"
  local source="${2:-auto}"
  printf '%s/%s.%s.tsv\n' "$(_codex_quota_cache_dir)" "$acct" "$source"
}

_codex_quota_routing_cache_file() {
  local source="${1:-auto}"
  printf '%s/routing.%s.txt\n' "$(_codex_quota_cache_dir)" "$source"
}

_codex_file_mtime() {
  local path="$1"
  local -A stat=()

  if zmodload -F zsh/stat b:zstat 2>/dev/null; then
    if zstat -H stat +mtime -- "$path" 2>/dev/null; then
      printf '%s\n' "$stat[mtime]"
      return 0
    fi
  fi

  /usr/bin/stat -f '%m' "$path" 2>/dev/null ||
    /usr/bin/stat -c '%Y' "$path" 2>/dev/null ||
    return 1
}

_codex_quota_cache_ttl() {
  local ttl="${CODEX_ORBIT_QUOTA_CACHE_TTL_SECONDS:-30}"

  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=30
  printf '%s\n' "$ttl"
}

_codex_read_cached_quota_snapshot() {
  local acct="$1"
  local ttl="${2:-0}"
  local source="${3:-auto}"
  local cache_file="$(_codex_quota_cache_file "$acct" "$source")"
  local cache_mtime="" now_epoch=""

  (( ttl > 0 )) || return 1
  [[ -f "$cache_file" ]] || return 1
  cache_mtime="$(_codex_file_mtime "$cache_file")" || return 1
  now_epoch="$(_codex_now_epoch)"
  (( now_epoch - cache_mtime <= ttl )) || return 1
  printf '%s\n' "$(< "$cache_file")"
}

_codex_read_cached_quota_routing() {
  local ttl="${1:-0}"
  local source="${2:-auto}"
  local cache_file="$(_codex_quota_routing_cache_file "$source")"
  local cache_mtime="" now_epoch="" acct=""

  (( ttl > 0 )) || return 1
  [[ -f "$cache_file" ]] || return 1
  cache_mtime="$(_codex_file_mtime "$cache_file")" || return 1
  now_epoch="$(_codex_now_epoch)"
  (( now_epoch - cache_mtime <= ttl )) || return 1

  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    printf '%s\n' "$acct"
  done < "$cache_file"
}

_codex_write_cached_quota_snapshot() {
  local acct="$1"
  local source="${2:-auto}"
  local snapshot="$3"
  local cache_dir="$(_codex_quota_cache_dir)"
  local cache_file="$(_codex_quota_cache_file "$acct" "$source")"
  local temp_file=""

  mkdir -p "$cache_dir"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-quota-cache.XXXXXX")" || return 1
  printf '%s\n' "$snapshot" > "$temp_file"
  mv "$temp_file" "$cache_file"
}

_codex_write_cached_quota_routing() {
  local source="${1:-auto}"
  local cache_dir="$(_codex_quota_cache_dir)"
  local cache_file="$(_codex_quota_routing_cache_file "$source")"
  local temp_file="" acct=""
  shift || true

  (( $# > 0 )) || return 1
  mkdir -p "$cache_dir"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-quota-routing.XXXXXX")" || return 1
  for acct in "$@"; do
    [[ -n "$acct" ]] || continue
    printf '%s\n' "$acct" >> "$temp_file"
  done
  mv "$temp_file" "$cache_file"
}

_codex_quota_default_source() {
  local source="${1:-${CODEX_ORBIT_QUOTA_SOURCE:-oauth}}"

  case "$source" in
    oauth|auto|rpc|status) printf '%s\n' "$source" ;;
    *) printf 'oauth\n' ;;
  esac
}

_codex_quota_source_is_valid() {
  case "${1:-}" in
    oauth|auto|rpc|status) return 0 ;;
    *) return 1 ;;
  esac
}

_codex_quota_snapshot_json_from_tsv() {
  local snapshot="${1:-}"
  local py=""

  py="$(_codex_python3)" || return 1
  SNAPSHOT_TSV="$snapshot" "$py" - <<'PY'
import json
import os

sep = "\x1f"
fields = (os.environ.get("SNAPSHOT_TSV", "").rstrip("\n").split(sep) + [""] * 14)[:14]
(
    source,
    email,
    plan_type,
    credits_balance,
    credits_has,
    credits_unlimited,
    primary_used,
    primary_remaining,
    primary_reset,
    primary_window,
    secondary_used,
    secondary_remaining,
    secondary_reset,
    secondary_window,
) = fields

def maybe_int(value):
    if value == "":
        return None
    try:
        return int(value)
    except ValueError:
        return None

def maybe_float(value):
    if value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None

def maybe_bool(value):
    if value == "":
        return None
    return value == "1"

def window(used, remaining, reset_at, limit_seconds):
    if used == remaining == reset_at == limit_seconds == "":
        return None
    return {
        "used_percent": maybe_int(used),
        "remaining_percent": maybe_int(remaining),
        "reset_at": maybe_int(reset_at),
        "limit_window_seconds": maybe_int(limit_seconds),
    }

payload = {
    "source": source or "",
    "email": email or "",
    "plan_type": plan_type or "",
    "credits": {
        "balance": maybe_float(credits_balance),
        "has_credits": maybe_bool(credits_has),
        "unlimited": maybe_bool(credits_unlimited),
    },
    "primary_window": window(primary_used, primary_remaining, primary_reset, primary_window),
    "secondary_window": window(secondary_used, secondary_remaining, secondary_reset, secondary_window),
}

print(json.dumps(payload, sort_keys=True))
PY
}

_codex_account_quota_snapshot() {
  local acct="$1"
  local format="${2:-tsv}"
  local refresh="${3:-0}"
  local source="${4:-auto}"
  local py script result="" cache_ttl=0 cached_tsv=""

  if [[ "$refresh" != "1" ]]; then
    cache_ttl="$(_codex_quota_cache_ttl)"
    if cached_tsv="$(_codex_read_cached_quota_snapshot "$acct" "$cache_ttl" "$source" 2>/dev/null)"; then
      if [[ "$format" == "json" ]]; then
        _codex_quota_snapshot_json_from_tsv "$cached_tsv"
      else
        printf '%s\n' "$cached_tsv"
      fi
      return 0
    fi
  fi

  _codex_ensure_account_config "$acct" || return 1

  py="$(_codex_python3)" || return 1
  script="$(_codex_quota_helper)"
  [[ -f "$script" ]] || return 1

  result="$("$py" "$script" snapshot \
    --account-dir "$(_codex_account_dir "$acct")" \
    --format "$format" \
    --source "$source")" || return 1

  if [[ "$format" == "tsv" && -n "$result" ]]; then
    _codex_write_cached_quota_snapshot "$acct" "$source" "$result" || true
  fi

  printf '%s\n' "$result"
}

_codex_warmup_prompt() {
  printf '%s\n' "Reply with exactly READY and nothing else. Do not inspect files, run commands, or use any tools."
}

_codex_mcp_disable_args() {
  local acct="$1"
  local config_file="$(_codex_account_dir "$acct")/config.toml"
  local section="" server=""

  [[ -f "$config_file" ]] || return 0

  while IFS= read -r section; do
    server="${section#\[mcp_servers.}"
    server="${server%\]}"
    [[ -n "$server" ]] || continue
    printf '%s\n' "-c"
    printf '%s\n' "mcp_servers.${server}.enabled=false"
  done < <(rg -o '^\[mcp_servers\.[^]]+\]' "$config_file" 2>/dev/null || true)
}

_codex_warmup_account() {
  local acct="$1"
  local output_file error_file capture_file result prompt
  local -a mcp_disable_args=()

  _codex_prepare_account_home "$acct" || return 1
  prompt="$(_codex_warmup_prompt)"
  output_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-warmup.XXXXXX")" || return 1
  error_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-warmup-err.XXXXXX")" || {
    rm -f "$output_file"
    return 1
  }
  capture_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-warmup-capture.XXXXXX")" || {
    rm -f "$output_file" "$error_file"
    return 1
  }
  mcp_disable_args=("${(@f)$(_codex_mcp_disable_args "$acct")}")

  if ! CODEX_HOME="$(_codex_account_dir "$acct")" codex "${mcp_disable_args[@]}" -a never -s read-only exec \
    --skip-git-repo-check \
    --ephemeral \
    --color never \
    -C "$HOME" \
    -o "$output_file" \
    "$prompt" 2>"$error_file"; then
    cat "$output_file" "$error_file" > "$capture_file"
    _codex_maybe_auto_disable_account_from_capture "$acct" "$capture_file" || true
    [[ -s "$output_file" ]] && cat "$output_file" >&2
    [[ -s "$error_file" ]] && cat "$error_file" >&2
    rm -f "$output_file" "$error_file" "$capture_file"
    return 1
  fi

  result="$(tr -d '\r' < "$output_file" | tail -n 1)"
  rm -f "$output_file" "$error_file" "$capture_file"

  if [[ -n "$result" ]]; then
    printf '%s\n' "$result"
  fi
}

_codex_quota_window_pretty_label() {
  local seconds="${1:-}"
  local bullet=$'\u25a0'

  case "$seconds" in
    18000) printf '%s 5h limit\n' "$bullet" ;;
    604800) printf '%s Weekly limit\n' "$bullet" ;;
    *)
      if [[ -z "$seconds" ]]; then
        printf '%s Quota\n' "$bullet"
      else
        printf '%s %ss limit\n' "$bullet" "$seconds"
      fi
      ;;
  esac
}

_codex_now_epoch() {
  printf '%s\n' "${EPOCHSECONDS:-$(date +%s)}"
}

_codex_day_stamp() {
  local epoch="$1"

  date -r "$epoch" '+%Y-%m-%d' 2>/dev/null ||
    date -d "@$epoch" '+%Y-%m-%d' 2>/dev/null ||
    printf '%s\n' "$epoch"
}

_codex_format_timestamp_compact() {
  local epoch="$1"
  local now_epoch="${2:-$(_codex_now_epoch)}"
  local target_day now_day

  [[ -n "$epoch" ]] || {
    printf '%s\n' "-"
    return 0
  }

  target_day="$(_codex_day_stamp "$epoch")"
  now_day="$(_codex_day_stamp "$now_epoch")"

  if [[ "$target_day" == "$now_day" ]]; then
    date -r "$epoch" '+%H:%M' 2>/dev/null ||
      date -d "@$epoch" '+%H:%M' 2>/dev/null ||
      printf '%s\n' "$epoch"
    return 0
  fi

  date -r "$epoch" '+%b %d %H:%M' 2>/dev/null ||
    date -d "@$epoch" '+%b %d %H:%M' 2>/dev/null ||
    printf '%s\n' "$epoch"
}

_codex_format_duration_short() {
  local seconds="${1:-0}"
  local days hours minutes

  (( seconds <= 0 )) && {
    printf 'now\n'
    return 0
  }

  days=$(( seconds / 86400 ))
  hours=$(( (seconds % 86400) / 3600 ))
  minutes=$(( (seconds % 3600) / 60 ))

  if (( days > 0 )); then
    if (( hours > 0 )); then
      printf '%sd %sh\n' "$days" "$hours"
    else
      printf '%sd\n' "$days"
    fi
    return 0
  fi

  if (( hours > 0 )); then
    if (( minutes > 0 )); then
      printf '%sh %sm\n' "$hours" "$minutes"
    else
      printf '%sh\n' "$hours"
    fi
    return 0
  fi

  if (( minutes > 0 )); then
    printf '%sm\n' "$minutes"
  else
    printf '<1m\n'
  fi
}

_codex_quota_used_value() {
  local remaining="${1:-}"
  local used="${2:-}"
  local value=""

  if [[ -n "$used" ]]; then
    value="$used"
  elif [[ -n "$remaining" ]]; then
    value=$((100 - remaining))
  else
    return 1
  fi

  (( value < 0 )) && value=0
  (( value > 100 )) && value=100
  printf '%s\n' "$value"
}

_codex_quota_left_value() {
  local remaining="${1:-}"
  local used="${2:-}"
  local value=""

  if [[ -n "$remaining" ]]; then
    value="$remaining"
  elif [[ -n "$used" ]]; then
    value=$((100 - used))
  else
    return 1
  fi

  (( value < 0 )) && value=0
  (( value > 100 )) && value=100
  printf '%s\n' "$value"
}

_codex_repeat_char() {
  local char="$1"
  local count="${2:-0}"
  local out=""
  local i

  for (( i = 0; i < count; i++ )); do
    out+="$char"
  done

  printf '%s' "$out"
}

_codex_quota_box_bar() {
  local remaining="${1:-0}"
  local width="${2:-10}"
  local filled=0 empty=0
  local full_box=$'\u25a0'
  local empty_box=$'\u25a1'

  (( remaining < 0 )) && remaining=0
  (( remaining > 100 )) && remaining=100

  filled=$(( (remaining * width + 50) / 100 ))
  (( filled > width )) && filled=$width
  empty=$(( width - filled ))

  printf '%s%s' \
    "$(_codex_repeat_char "$full_box" "$filled")" \
    "$(_codex_repeat_char "$empty_box" "$empty")"
}

_codex_quota_meter_cell() {
  local remaining="${1:-}"
  local used="${2:-}"
  local value=""

  if ! value="$(_codex_quota_left_value "$remaining" "$used" 2>/dev/null)"; then
    printf '%s\n' "-"
    return 0
  fi

  printf '%s %s%%\n' "$(_codex_quota_box_bar "$value" 10)" "$value"
}

_codex_print_quota_meter_line() {
  local label="$1"
  local remaining="$2"
  local reset_at="${3:-}"
  local show_reset="${4:-0}"
  local note=""
  local meter=""

  if [[ -n "$reset_at" && "$show_reset" == "1" ]]; then
    note=" (resets $(_codex_format_timestamp_compact "$reset_at"))"
  fi

  meter="$(_codex_quota_meter_cell "$remaining" "")"
  printf '%-14s %s left%s\n' "${label}:" "$meter" "$note"
}

_codex_print_quota_meter() {
  local primary_remaining="$1"
  local primary_reset="$2"
  local primary_window="$3"
  local secondary_remaining="$4"
  local secondary_reset="$5"
  local secondary_window="$6"

  [[ -n "$primary_remaining" ]] && _codex_print_quota_meter_line \
    "$(_codex_quota_window_pretty_label "$primary_window")" \
    "$primary_remaining" \
    "$primary_reset" \
    "1"

  [[ -n "$secondary_remaining" ]] && _codex_print_quota_meter_line \
    "$(_codex_quota_window_pretty_label "$secondary_window")" \
    "$secondary_remaining" \
    "$secondary_reset" \
    "0"
}

_codex_account_metadata() {
  local acct="$1"
  local auth_file="$(_codex_account_auth_file "$acct")"
  local py

  [[ -f "$auth_file" ]] || return 1
  py="$(_codex_python3)" || return 1

  "$py" - "$auth_file" <<'PY'
import base64
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
obj = json.loads(path.read_text())

claims = {}
id_token = (obj.get("tokens") or {}).get("id_token")
if id_token:
    try:
        payload = id_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        claims = {}

auth = claims.get("https://api.openai.com/auth") or {}
email = claims.get("email") or ""
plan = auth.get("chatgpt_plan_type") or ""
account_id = auth.get("chatgpt_account_id") or (obj.get("tokens") or {}).get("account_id") or ""
last_refresh = obj.get("last_refresh") or ""
auth_mode = obj.get("auth_mode") or ""

org_titles = []
default_title = ""
for org in auth.get("organizations") or []:
    title = org.get("title") or org.get("id") or "unknown"
    if title not in org_titles:
        org_titles.append(title)
    if org.get("is_default") and not default_title:
        default_title = title

if not default_title and org_titles:
    default_title = org_titles[0]

sep = "\x1f"
print(sep.join([
    email,
    plan,
    default_title,
    str(len(org_titles)),
    ",".join(org_titles),
    account_id,
    last_refresh,
    auth_mode,
]))
PY
}

_codex_workspace_summary() {
  local default_title="${1:-}"
  local workspace_count="${2:-0}"

  if [[ -z "$default_title" ]]; then
    if (( workspace_count > 0 )); then
      printf '%s workspaces\n' "$workspace_count"
    else
      printf 'unknown\n'
    fi
    return 0
  fi

  if (( workspace_count > 1 )); then
    printf '%s (+%d)\n' "$default_title" $((workspace_count - 1))
  else
    printf '%s\n' "$default_title"
  fi
}

_codex_cooldown_until() {
  local file="$(_codex_cooldown_file "$1")"
  [[ -f "$file" ]] || return 1
  printf '%s\n' "$(< "$file")"
}

_codex_clear_cooldown() {
  _codex_with_lock state rm -f "$(_codex_cooldown_file "$1")"
}

_codex_account_disabled() {
  [[ -f "$(_codex_disabled_file "$1")" ]]
}

_codex_account_disabled_reason() {
  local file="$(_codex_disabled_file "$1")"
  [[ -s "$file" ]] || return 1
  printf '%s\n' "$(< "$file")"
}

_codex_disable_account() {
  local acct="$1"
  local reason="${2:-}"
  local file="$(_codex_disabled_file "$acct")"
  mkdir -p "$(_codex_disabled_dir)"
  if [[ -n "$reason" ]]; then
    _codex_with_lock state _codex_write_file_atomic "$file" "$reason"
  else
    _codex_with_lock state _codex_write_file_atomic "$file" ""
  fi
}

_codex_enable_account() {
  _codex_with_lock state rm -f "$(_codex_disabled_file "$1")"
}

_codex_toggle_account_disabled() {
  local acct="$1"

  if _codex_account_disabled "$acct"; then
    _codex_enable_account "$acct"
    printf 'enabled\n'
  else
    _codex_disable_account "$acct"
    printf 'disabled\n'
  fi
}

_codex_set_cooldown() {
  local acct="$1"
  local duration="$2"
  local seconds until

  seconds="$(_codex_parse_duration_to_seconds "$duration")" || return 1
  mkdir -p "$(_codex_cooldown_dir)"
  until=$(( $(date +%s) + seconds ))
  _codex_with_lock state _codex_write_file_atomic "$(_codex_cooldown_file "$acct")" "$until" || return 1
  _codex_debug "cooldown_set account=$acct until=$until duration=$duration"
  printf '%s\n' "$until"
}

_codex_capture_contains_deactivated_workspace() {
  local capture_file="$1"

  [[ -f "$capture_file" ]] || return 1

  if command -v rg >/dev/null 2>&1; then
    rg -q --fixed-strings 'deactivated_workspace' "$capture_file"
  else
    grep -q -- 'deactivated_workspace' "$capture_file"
  fi
}

_codex_maybe_auto_disable_account_from_capture() {
  local acct="$1"
  local capture_file="$2"

  _codex_capture_contains_deactivated_workspace "$capture_file" || return 1

  _codex_disable_account "$acct" "auto:deactivated_workspace"
  _codex_debug "account_auto_disabled account=$acct reason=deactivated_workspace"
  printf '\nAccount auto-disabled: %s\n' "$(_codex_account_display_name "$acct")" >&2
  printf 'Reason: received 402 deactivated_workspace from the Codex backend.\n' >&2
  printf 'Re-enable it after fixing workspace billing/access via cx list.\n' >&2
  return 0
}

_codex_run_codex_for_account() {
  local acct="$1"
  shift || true

  local capture_file="" stdout_file="" stderr_file="" rc=0 command_string=""
  local -a command=()

  capture_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-launch.XXXXXX")" || return 1

  if command -v script >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    if script --version >/dev/null 2>&1; then
      command=(env "CODEX_HOME=$(_codex_account_dir "$acct")" codex "$@")
      command_string="${(j: :)${(q)command[@]}}"
      if script -q -e -c "$command_string" "$capture_file"; then
        rc=0
      else
        rc=$?
      fi
    else
      if script -q "$capture_file" env "CODEX_HOME=$(_codex_account_dir "$acct")" codex "$@"; then
        rc=0
      else
        rc=$?
      fi
    fi
  else
    stdout_file="${capture_file}.stdout"
    stderr_file="${capture_file}.stderr"
    if CODEX_HOME="$(_codex_account_dir "$acct")" codex "$@" >"$stdout_file" 2>"$stderr_file"; then
      rc=0
    else
      rc=$?
    fi
    cat "$stdout_file" "$stderr_file" > "$capture_file"
    [[ -s "$stdout_file" ]] && cat "$stdout_file"
    [[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
  fi

  _codex_maybe_auto_disable_account_from_capture "$acct" "$capture_file" || true
  rm -f "$capture_file"
  return "$rc"
}

_codex_account_in_cooldown() {
  local acct="$1"
  local until now

  until="$(_codex_cooldown_until "$acct")" || return 1
  now="$(_codex_now_epoch)"

  if (( until <= now )); then
    _codex_clear_cooldown "$acct"
    _codex_debug "cooldown_expired account=$acct"
    return 1
  fi

  return 0
}

_codex_cooldown_note() {
  local acct="$1"
  local until

  until="$(_codex_cooldown_until "$acct")" || return 1
  _codex_account_in_cooldown "$acct" || return 1
  printf 'cooldown until %s\n' "$(_codex_format_timestamp "$until")"
}

_codex_active_cooldowns() {
  local cooldown_dir="$(_codex_cooldown_dir)"
  local file acct until

  [[ -d "$cooldown_dir" ]] || return 0

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    acct="${file:t:r}"
    until="$(_codex_cooldown_until "$acct" 2>/dev/null)" || continue
    if _codex_account_in_cooldown "$acct"; then
      printf '%s\t%s\n' "$acct" "$until"
    fi
  done < <(find "$cooldown_dir" -maxdepth 1 -type f -name '*.until' | sort)
}

_codex_eligible_logged_in_accounts() {
  local acct

  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    _codex_account_disabled "$acct" && continue
    _codex_account_in_cooldown "$acct" && continue
    printf '%s\n' "$acct"
  done < <(_codex_logged_in_accounts)
}

_codex_routing_strategy() {
  case "${CODEX_ORBIT_ROUTING:-round-robin}" in
    quota|round-robin) printf '%s\n' "${CODEX_ORBIT_ROUTING:-round-robin}" ;;
    *) printf 'round-robin\n' ;;
  esac
}

_codex_select_account_from_list() {
  local persist="${1:-0}"

  if (( persist )); then
    _codex_with_lock state _codex_select_account_from_list_impl "$@"
  else
    _codex_select_account_from_list_impl "$@"
  fi
}

_codex_select_account_from_list_impl() {
  local persist="${1:-0}"
  local state_dir="$(_codex_state_dir)"
  local rr_file="$state_dir/round_robin_last_account"
  local last_account="" account=""
  shift || true
  local -a accounts=("$@")
  local idx

  mkdir -p "$state_dir"

  (( ${#accounts[@]} > 0 )) || return 1

  if (( ${#accounts[@]} == 1 )); then
    account="${accounts[1]}"
    if (( persist )); then
      _codex_write_file_atomic "$rr_file" "$account" || return 1
    fi
    printf '%s\n' "$account"
    return 0
  fi

  if [[ -f "$rr_file" ]]; then
    last_account="$(<"$rr_file")"
  fi

  if [[ -n "$last_account" ]]; then
    for (( idx = 1; idx <= ${#accounts[@]}; idx++ )); do
      if [[ "${accounts[idx]}" == "$last_account" ]]; then
        if (( idx < ${#accounts[@]} )); then
          account="${accounts[idx + 1]}"
        else
          account="${accounts[1]}"
        fi
        break
      fi
    done
  fi

  if [[ -z "$account" ]]; then
    account="${accounts[1]}"
  fi

  if (( persist )); then
    _codex_write_file_atomic "$rr_file" "$account" || return 1
  fi

  printf '%s\n' "$account"
}

_codex_next_round_robin_account() {
  local persist="${1:-0}"
  local -a accounts=("${(@f)$(_codex_eligible_logged_in_accounts)}")

  _codex_select_account_from_list "$persist" "${accounts[@]}"
}

_codex_round_robin_account() {
  _codex_next_round_robin_account 1
}

_codex_preview_round_robin_account() {
  _codex_next_round_robin_account 0
}

_codex_account_quota_rank() {
  local acct="$1"
  local cache_ttl="${2:-0}"
  local quota_source_mode="${3:-}"
  local quota_snapshot=""
  local credits_balance="" credits_has="" credits_unlimited=""
  local primary_used="" primary_remaining="" primary_reset="" primary_window=""
  local secondary_used="" secondary_remaining="" secondary_reset="" secondary_window=""
  local primary_left="" secondary_left=""
  local sep=$'\x1f'

  [[ -n "$quota_source_mode" ]] || quota_source_mode="$(_codex_quota_default_source)"
  (( cache_ttl > 0 )) || cache_ttl="$(_codex_quota_cache_ttl)"
  quota_snapshot="$(_codex_read_cached_quota_snapshot "$acct" "$cache_ttl" "$quota_source_mode" 2>/dev/null || true)"
  [[ -n "$quota_snapshot" ]] || return 1

  IFS="$sep" read -r \
    quota_source \
    quota_email \
    quota_plan \
    credits_balance \
    credits_has \
    credits_unlimited \
    primary_used \
    primary_remaining \
    primary_reset \
    primary_window \
    secondary_used \
    secondary_remaining \
    secondary_reset \
    secondary_window <<<"$quota_snapshot"

  primary_left="$(_codex_quota_left_value "$primary_remaining" "$primary_used" 2>/dev/null || true)"
  secondary_left="$(_codex_quota_left_value "$secondary_remaining" "$secondary_used" 2>/dev/null || true)"

  [[ -n "$primary_left" ]] || primary_left=-1
  [[ -n "$secondary_left" ]] || secondary_left=-1
  printf '%s\t%s\n' "$primary_left" "$secondary_left"
}

_codex_quota_aware_account() {
  local persist="${1:-0}"
  local acct="" rank="" primary_left="" secondary_left="" cached_acct=""
  local best_primary=-1 best_secondary=-1
  local cache_ttl=0 quota_source_mode="" cached_routing=""
  local -a accounts=("${(@f)$(_codex_eligible_logged_in_accounts)}")
  local -a best_accounts=()
  local -a cached_best_accounts=()

  (( ${#accounts[@]} > 0 )) || return 1
  if (( ${#accounts[@]} == 1 )); then
    _codex_select_account_from_list "$persist" "${accounts[@]}"
    return $?
  fi
  cache_ttl="$(_codex_quota_cache_ttl)"
  quota_source_mode="$(_codex_quota_default_source)"
  cached_routing="$(_codex_read_cached_quota_routing "$cache_ttl" "$quota_source_mode" 2>/dev/null || true)"
  if [[ -n "$cached_routing" ]]; then
    while IFS= read -r cached_acct; do
      [[ -n "$cached_acct" ]] || continue
      if (( ${accounts[(Ie)$cached_acct]} > 0 )); then
        cached_best_accounts+=("$cached_acct")
      fi
    done <<< "$cached_routing"
    if (( ${#cached_best_accounts[@]} > 0 )); then
      _codex_select_account_from_list "$persist" "${cached_best_accounts[@]}"
      return $?
    fi
  fi

  for acct in "${accounts[@]}"; do
    rank="$(_codex_account_quota_rank "$acct" "$cache_ttl" "$quota_source_mode" 2>/dev/null || true)"
    [[ -n "$rank" ]] || continue
    IFS=$'\t' read -r primary_left secondary_left <<<"$rank"
    (( primary_left > best_primary || (primary_left == best_primary && secondary_left > best_secondary) )) && {
      best_primary=$primary_left
      best_secondary=$secondary_left
      best_accounts=("$acct")
      continue
    }
    if (( primary_left == best_primary && secondary_left == best_secondary )); then
      best_accounts+=("$acct")
    fi
  done

  (( ${#best_accounts[@]} > 0 )) || return 1
  _codex_write_cached_quota_routing "$quota_source_mode" "${best_accounts[@]}" || true
  _codex_select_account_from_list "$persist" "${best_accounts[@]}"
}

_codex_next_launchable_account() {
  local persist="${1:-0}"

  if [[ "$(_codex_routing_strategy)" == "quota" ]]; then
    _codex_quota_aware_account "$persist" 2>/dev/null && return 0
  fi

  _codex_next_round_robin_account "$persist"
}

_codex_resolve_account_selection() {
  local persist="${1:-0}"
  local account="" source="" pinned_account=""

  if pinned_account="$(_codex_get_pinned_account 2>/dev/null)"; then
    if ! _codex_account_exists "$pinned_account"; then
      _codex_debug "pinned_missing account=$pinned_account"
    elif ! _codex_is_logged_in "$pinned_account"; then
      _codex_debug "pinned_not_logged_in account=$pinned_account"
    elif _codex_account_disabled "$pinned_account"; then
      _codex_debug "pinned_disabled account=$pinned_account"
    elif _codex_account_in_cooldown "$pinned_account"; then
      _codex_debug "pinned_in_cooldown account=$pinned_account"
    else
      printf '%s\t%s\n' "$pinned_account" "pinned"
      return 0
    fi
  fi

  if [[ "$(_codex_routing_strategy)" == "quota" ]]; then
    if account="$(_codex_quota_aware_account "$persist" 2>/dev/null)"; then
      source="quota-aware"
      printf '%s\t%s\n' "$account" "$source"
      return 0
    fi
  fi

  if (( persist )); then
    account="$(_codex_round_robin_account)" || return 1
  else
    account="$(_codex_preview_round_robin_account)" || return 1
  fi

  source="round-robin"
  printf '%s\t%s\n' "$account" "$source"
}

_codex_pick_account() {
  local prompt="${1:-Codex account> }"
  local -a accounts=("${(@f)$(_codex_accounts_list)}")
  local account="" option="" idx=1
  local display_name=""
  local -a display_entries=()

  if (( ${#accounts[@]} == 0 )); then
    return 1
  fi

  if (( ${#accounts[@]} == 1 )); then
    printf '%s\n' "${accounts[1]}"
    return 0
  fi

  if command -v fzf >/dev/null 2>&1; then
    for option in "${accounts[@]}"; do
      display_name="$(_codex_account_display_name "$option")"
      display_entries+=("$option"$'\t'"$display_name")
    done
    account="$(printf '%s\n' "${display_entries[@]}" | fzf --prompt="$prompt" --height=10 --reverse --delimiter=$'\t' --with-nth=2..)"
    account="${account%%$'\t'*}"
  else
    printf '%s\n' "Select account:"
    for option in "${accounts[@]}"; do
      printf '  %d) %s\n' "$idx" "$(_codex_account_display_name "$option")"
      idx=$((idx + 1))
    done
    echo -n "Choice: "
    account=""
    if ! read -r idx; then
      return 1
    fi
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#accounts[@]} )); then
      account="${accounts[idx]}"
    fi
  fi

  [[ -n "$account" ]] || return 1
  printf '%s\n' "$account"
}

_codex_pick_line() {
  local prompt="${1:-Select> }"
  shift || true
  local -a options=("$@")
  local choice="" option="" idx=1

  (( ${#options[@]} > 0 )) || return 1

  if (( ${#options[@]} == 1 )); then
    printf '%s\n' "${options[1]}"
    return 0
  fi

  if command -v fzf >/dev/null 2>&1; then
    choice="$(printf '%s\n' "${options[@]}" | fzf --prompt="$prompt" --height=12 --reverse)"
  else
    printf '%s\n' "${prompt% }" >&2
    for option in "${options[@]}"; do
      printf '  %d) %s\n' "$idx" "$option" >&2
      idx=$((idx + 1))
    done
    echo -n "Choice: " >&2
    choice=""
    if ! read -r idx; then
      return 1
    fi
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#options[@]} )); then
      choice="${options[idx]}"
    fi
  fi

  [[ -n "$choice" ]] || return 1
  printf '%s\n' "$choice"
}

_codex_pick_account_summary() {
  local prompt="${1:-Account> }"
  local sep=$'\x1f'
  local acct="" record="" account="" account_display="" email="" plan="" workspace="" state_label="" choice=""
  local account_width=7 email_width=5 plan_width=4 workspace_width=9
  local idx=1
  local -a entries=()
  local -a numbered_accounts=()

  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    record="$(_codex_account_summary_record "$acct")" || continue
    IFS="$sep" read -r account account_display email plan workspace state_label <<<"$record"
    (( ${#account_display} > account_width )) && account_width=${#account_display}
    (( ${#email} > email_width )) && email_width=${#email}
    (( ${#plan} > plan_width )) && plan_width=${#plan}
    (( ${#workspace} > workspace_width )) && workspace_width=${#workspace}
    entries+=("$record")
  done < <(_codex_accounts_list)

  (( ${#entries[@]} > 0 )) || return 1

  if (( ${#entries[@]} == 1 )); then
    IFS="$sep" read -r account account_display email plan workspace state_label <<<"${entries[1]}"
    printf '%s\n' "$account"
    return 0
  fi

  if command -v fzf >/dev/null 2>&1; then
    local header=""
    local -a display_entries=()

    header="$(printf '%-*s  %-*s  %-*s  %-*s  %s' \
      "$account_width" 'ACCOUNT' \
      "$email_width" 'EMAIL' \
      "$plan_width" 'PLAN' \
      "$workspace_width" 'WORKSPACE' \
      'STATUS')"

    for record in "${entries[@]}"; do
      IFS="$sep" read -r account account_display email plan workspace state_label <<<"$record"
      display_entries+=(
        "$account"$'\t'"$(printf '%-*s  %-*s  %-*s  %-*s  %s' \
          "$account_width" "$account_display" \
          "$email_width" "$email" \
          "$plan_width" "$plan" \
          "$workspace_width" "$workspace" \
          "$state_label")"
      )
    done

    choice="$(printf '%s\n' "${display_entries[@]}" | fzf \
      --prompt="$prompt" \
      --height=12 \
      --reverse \
      --delimiter=$'\t' \
      --with-nth=2.. \
      --header="$header")"
    [[ -n "$choice" ]] || return 1
    printf '%s\n' "${choice%%$'\t'*}"
    return 0
  fi

  printf '%s\n' "Select account:"
  for record in "${entries[@]}"; do
    IFS="$sep" read -r account account_display email plan workspace state_label <<<"$record"
    printf '  %d) %-*s  %-*s  %-*s  %-*s  %s\n' \
      "$idx" \
      "$account_width" "$account_display" \
      "$email_width" "$email" \
      "$plan_width" "$plan" \
      "$workspace_width" "$workspace" \
      "$state_label"
    numbered_accounts+=("$account")
    idx=$((idx + 1))
  done
  echo -n "Choice: "
  if ! read -r idx; then
    return 1
  fi
  if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#numbered_accounts[@]} )); then
    printf '%s\n' "${numbered_accounts[idx]}"
    return 0
  fi

  return 1
}

_codex_pick_logged_in_account() {
  local prompt="${1:-Logged-in account> }"
  local -a accounts=("${(@f)$(_codex_logged_in_accounts)}")
  local account="" option="" idx=1
  local display_name=""
  local -a display_entries=()

  if (( ${#accounts[@]} == 0 )); then
    return 1
  fi

  if (( ${#accounts[@]} == 1 )); then
    printf '%s\n' "${accounts[1]}"
    return 0
  fi

  if command -v fzf >/dev/null 2>&1; then
    for option in "${accounts[@]}"; do
      display_name="$(_codex_account_display_name "$option")"
      display_entries+=("$option"$'\t'"$display_name")
    done
    account="$(printf '%s\n' "${display_entries[@]}" | fzf --prompt="$prompt" --height=10 --reverse --delimiter=$'\t' --with-nth=2..)"
    account="${account%%$'\t'*}"
  else
    printf '%s\n' "Select logged-in account:"
    for option in "${accounts[@]}"; do
      printf '  %d) %s\n' "$idx" "$(_codex_account_display_name "$option")"
      idx=$((idx + 1))
    done
    echo -n "Choice: "
    account=""
    if ! read -r idx; then
      return 1
    fi
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#accounts[@]} )); then
      account="${accounts[idx]}"
    fi
  fi

  [[ -n "$account" ]] || return 1
  printf '%s\n' "$account"
}

_codex_account_status_value() {
  local acct="$1"
  local disabled_reason=""

  if _codex_account_disabled "$acct"; then
    disabled_reason="$(_codex_account_disabled_reason "$acct" 2>/dev/null || true)"
    case "$disabled_reason" in
      auto:deactivated_workspace)
        printf 'disabled (deactivated workspace)\n'
        ;;
      *)
        printf 'disabled\n'
        ;;
    esac
  elif _codex_is_logged_in "$acct"; then
    if _codex_account_in_cooldown "$acct"; then
      _codex_cooldown_note "$acct" 2>/dev/null || printf 'cooldown\n'
    else
      printf 'ready\n'
    fi
  else
    printf 'not logged in\n'
  fi
}

_codex_account_summary_record() {
  local acct="$1"
  local metadata="" email="" email_display="" plan="" default_workspace="" workspace_count=""
  local workspace_titles="" account_id="" last_refresh="" auth_mode="" status_value=""
  local account_display=""
  local sep=$'\x1f'

  status_value="$(_codex_account_status_value "$acct")"
  account_display="$(_codex_account_display_name "$acct")"

  metadata="$(_codex_account_metadata "$acct" 2>/dev/null || true)"
  if [[ -n "$metadata" ]]; then
    local sep=$'\x1f'
    IFS="$sep" read -r email plan default_workspace workspace_count workspace_titles account_id last_refresh auth_mode <<<"$metadata"
    email_display="$(_codex_display_email "$email" "-")"
  else
    email_display="-"
    plan="-"
    default_workspace=""
    workspace_count=0
  fi

  printf '%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$acct" "$sep" \
    "$account_display" "$sep" \
    "${email_display:--}" "$sep" \
    "${plan:--}" "$sep" \
    "$(_codex_workspace_summary "$default_workspace" "${workspace_count:-0}")" "$sep" \
    "$status_value"
}

_codex_launch_selected_account() {
  local acct="$1"

  if ! _codex_is_logged_in "$acct"; then
    echo "No logged-in Codex account: $acct"
    return 1
  fi

  _codex_set_last_account "$acct" || return 1
  _codex_prepare_account_home "$acct" || return 1
  _codex_run_codex_for_account "$acct" --yolo
}

_codex_replace_account_login() {
  local acct="$1"

  _codex_prepare_account_home "$acct" || return 1
  _codex_set_last_account "$acct" || return 1
  echo "Replacing login for: $acct"
  CODEX_HOME="$(_codex_account_dir "$acct")" codex login
}

_codex_account_action_menu() {
  local acct="$1"
  local action="" toggle_label=""
  local -a actions=()

  if _codex_account_disabled "$acct"; then
    toggle_label="enable"
  else
    toggle_label="disable"
  fi

  actions=("launch" "replace login" "$toggle_label" "delete" "back")
  action="$(_codex_pick_line "Action for ${acct}> " "${actions[@]}")" || return 10

  case "$action" in
    launch)
      _codex_launch_selected_account "$acct" || true
      return 10
      ;;
    "replace login")
      _codex_replace_account_login "$acct" || true
      return 10
      ;;
    disable|enable)
      printf '%s: %s\n' "$acct" "$(_codex_toggle_account_disabled "$acct")"
      return 10
      ;;
    delete)
      echo "Archive $acct to trash? [y/N]"
      local confirm
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local archive_path=""
        archive_path="$(_codex_archive_account "$acct")" || return 1
        echo "Archived: $acct -> $archive_path"
      else
        echo "Cancelled."
        return 10
      fi
      return 10
      ;;
    back)
      return 10
      ;;
    *)
      return 10
      ;;
  esac
}

_codex_list_interactive() {
  local account=""
  local action_exit=0

  while true; do
    account="$(_codex_pick_account_summary 'Account> ')" || return 0

    _codex_account_action_menu "$account"
    action_exit=$?
    case "$action_exit" in
      10) continue ;;
      *) continue ;;
    esac
  done
}

_codex_clear_account_state() {
  local acct="$1"
  local state_dir="$(_codex_state_dir)"
  local state_file="$state_dir/last_account"
  local rr_file="$state_dir/round_robin_last_account"

  if [[ -f "$state_file" && "$(< "$state_file")" == "$acct" ]]; then
    rm -f "$state_file"
  fi

  if [[ -f "$rr_file" && "$(< "$rr_file")" == "$acct" ]]; then
    rm -f "$rr_file"
  fi

  _codex_clear_cooldown "$acct"
  _codex_enable_account "$acct"
  _codex_clear_account_pins "$acct"
  _codex_clear_account_alias "$acct"
}

_codex_archive_account() {
  _codex_with_lock state _codex_archive_account_impl "$1"
}

_codex_archive_account_impl() {
  local acct="$1"
  local trash_dir="$(_codex_trash_dir)"
  local timestamp target suffix=0

  mkdir -p "$trash_dir"
  timestamp="$(date '+%Y%m%d%H%M%S')"
  target="$trash_dir/${timestamp}_${acct}"

  while [[ -e "$target" ]]; do
    suffix=$((suffix + 1))
    target="$trash_dir/${timestamp}_${acct}_$suffix"
  done

  mv "$(_codex_account_dir "$acct")" "$target"
  _codex_clear_account_state "$acct"
  _codex_debug "account_archived account=$acct path=$target"
  printf '%s\n' "$target"
}

_codex_no_launchable_accounts_message() {
  if [[ -n "$(_codex_logged_in_accounts)" ]]; then
    echo "All logged-in accounts are disabled or in cooldown. Run: cx list or cx cooldown clear <account>"
  else
    echo "No logged-in Codex accounts found. Run: cx login"
  fi
}

_codex_account_routing_note() {
  local acct="$1"
  local disabled_reason=""

  if ! _codex_account_exists "$acct"; then
    printf 'missing\n'
  elif ! _codex_is_logged_in "$acct"; then
    printf 'not logged in\n'
  elif _codex_account_disabled "$acct"; then
    disabled_reason="$(_codex_account_disabled_reason "$acct" 2>/dev/null || true)"
    case "$disabled_reason" in
      auto:deactivated_workspace)
        printf 'disabled: deactivated workspace\n'
        ;;
      *)
        printf 'disabled\n'
        ;;
    esac
  elif _codex_account_in_cooldown "$acct"; then
    _codex_cooldown_note "$acct" 2>/dev/null || printf 'cooldown\n'
  else
    printf 'ready\n'
  fi
}

_codex_print_routing_report() {
  local selected="$1"
  local source="$2"
  local pinned_account=""
  local acct="" note=""

  printf 'Routing strategy: %s\n' "$(_codex_routing_strategy)"
  printf 'Selected: %s\n' "$(_codex_account_display_name "$selected")"
  case "$source" in
    pinned)
      echo "Reason: pinned account is eligible."
      ;;
    quota-aware)
      echo "Reason: selected from cached quota-aware routing."
      ;;
    round-robin)
      echo "Reason: next eligible account in round-robin order."
      ;;
    *)
      printf 'Reason: %s\n' "$source"
      ;;
  esac

  if pinned_account="$(_codex_get_pinned_account 2>/dev/null)"; then
    if [[ "$pinned_account" == "$selected" ]]; then
      printf 'Pinned: %s (active)\n' "$(_codex_account_display_name "$pinned_account")"
    else
      printf 'Pinned: %s (%s, skipped)\n' \
        "$(_codex_account_display_name "$pinned_account")" \
        "$(_codex_account_routing_note "$pinned_account")"
    fi
  else
    echo "Pinned: none"
  fi

  echo "Candidates:"
  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    if [[ "$acct" == "$selected" ]]; then
      printf '  %s -> selected via %s\n' "$(_codex_account_display_name "$acct")" "$source"
      continue
    fi
    note="$(_codex_account_routing_note "$acct")"
    printf '  %s -> %s\n' "$(_codex_account_display_name "$acct")" "$note"
  done < <(_codex_logged_in_accounts)
}

cx() {
  local state_dir="$(_codex_state_dir)"
  local state_file="$state_dir/last_account"
  local account="" source="" pinned_account="" archive_path="" cooldown_note=""
  local mode="launch"
  local selection="" doctor_exit=0
  local accounts_count=0 logged_in_count=0 cooldown_count=0 until=""
  local metadata="" email="" email_display="" plan="" default_workspace="" workspace_count=""
  local workspace_titles="" account_id="" last_refresh="" auth_mode="" status_value=""
  local quota_snapshot=""
  local quota_source="" quota_email="" quota_plan="" credits_balance="" credits_has="" credits_unlimited=""
  local primary_used="" primary_remaining="" primary_reset="" primary_window=""
  local secondary_used="" secondary_remaining="" secondary_reset="" secondary_window=""
  local list_mode="rich"
  local -a codex_args=()
  local arg acct idx=1 status_line

  mkdir -p "$state_dir"
  _codex_ensure_state_schema || return 1

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      login)
        mode="login"
        shift
        ;;
      login-loop)
        mode="login-loop"
        shift
        ;;
      delete|remove|rm)
        mode="delete"
        shift
        ;;
      pin)
        mode="pin"
        shift
        ;;
      pin-next)
        mode="pin-next"
        shift
        ;;
      unpin)
        mode="unpin"
        shift
        ;;
      current)
        mode="current"
        shift
        ;;
      status|--status)
        mode="status"
        shift
        ;;
      list)
        mode="list"
        shift
        ;;
      doctor)
        mode="doctor"
        shift
        ;;
      sync-agents)
        mode="sync-agents"
        shift
        ;;
      which)
        mode="which"
        shift
        ;;
      explain)
        mode="which"
        shift
        ;;
      warmup)
        mode="warmup"
        shift
        ;;
      quota)
        mode="quota"
        shift
        ;;
      alias)
        mode="alias"
        shift
        ;;
      enable)
        mode="enable"
        shift
        ;;
      disable)
        mode="disable"
        shift
        ;;
      recover)
        mode="recover"
        shift
        ;;
      update)
        mode="update"
        shift
        ;;
      version)
        mode="version"
        shift
        ;;
      init)
        mode="init"
        shift
        ;;
      completions)
        mode="completions"
        shift
        ;;
      daemon)
        mode="daemon"
        shift
        codex_args+=("$@")
        break
        ;;
      support)
        mode="support"
        shift
        ;;
      share)
        mode="share"
        shift
        codex_args+=("$@")
        break
        ;;
      resolve)
        mode="resolve"
        shift
        ;;
      cooldown)
        mode="cooldown"
        shift
        ;;
      --help|-h)
        cat <<'EOF'
Usage: cx [codex args...]
       cx login [codex login args...]
       cx login-loop [codex login args...]
       cx delete [account]
       cx pin [account]
       cx pin-next
       cx unpin
       cx current
       cx status
       cx list [--plain|--verbose|--interactive]
       cx doctor [--json]
       cx sync-agents [account ...]
       cx which
       cx explain
       cx warmup [account] [--show-quota]
       cx quota [account] [--json] [--refresh] [--source oauth|auto|rpc|status]
       cx alias [account <alias>|clear <account|alias>]
       cx enable [account]
       cx disable [account]
       cx recover [account]
       cx update [--check]
       cx version
       cx init [--import <accounts.tar.gz>] [--import-config <config.tar.gz>] [--login] [--shell <zsh|bash>] [--shell-rc <path>] [--no-shell-changes]
       cx completions <zsh|bash>
       cx completions install [zsh|bash] [--shell-rc <path>]
       cx daemon serve [--host <host>] [--port <port>]
       cx daemon status [--json]
       cx daemon url
       cx daemon launchd <plist|install|uninstall|start|stop|status>
       cx support [--output <bundle.tar.gz>]
       cx share export [account ...|--all] [--output <archive.tar.gz>]
       cx share import <archive.tar.gz>
       cx share push <ssh-host> [account ...|--all] [--with-config] [--remote-dir <dir>]
       cx share config export [--output <archive.tar.gz>]
       cx share config import <archive.tar.gz>
       cx share config push <ssh-host> [--remote-dir <dir>]
       cx resolve
       cx cooldown
       cx cooldown <account> <duration>
       cx cooldown clear <account>

Commands:
  cx                   Open Codex with the next routed account.
  cx login             Create the next hidden account slot and sign in once.
  cx login-loop        Keep creating account slots and rerunning login until stopped.
  cx delete            Archive a saved account into trash.
  cx pin               Pick a logged-in account and pin it to the current shell.
  cx pin-next          Pin the next routed logged-in account to the current shell.
  cx unpin             Clear the current shell pin and return to automatic routing.
  cx current           Show the current shell pin and last launched account.
  cx status            Show login status for all discovered account slots.
  cx list              Browse accounts interactively in a TTY, or print saved accounts in scripts.
  cx doctor            Validate dependencies, state paths, and account health.
  cx sync-agents       Relink account AGENTS.md files to the shared ~/.codex/AGENTS.md.
  cx which             Explain which account would launch next.
  cx explain           Alias for cx which.
  cx warmup            Send a minimal prompt to start the selected account's current 5h window.
  cx quota             Fetch live Codex quota. Defaults to the fast OAuth path unless overridden.
  cx alias             Set, clear, or list account aliases.
  cx enable            Re-enable a saved account.
  cx disable           Disable a saved account until you recover it.
  cx recover           Clear disabled and cooldown state for an account.
  cx update            Check for or apply updates based on the current install method.
  cx version           Show installed version and install metadata.
  cx init              Run first-time setup, optional imports, and optional shell completion setup.
  cx completions       Print or install shell completions for zsh or bash.
  cx daemon            Run or inspect the local daemon used by the macOS menu bar app.
  cx daemon launchd    Manage the macOS LaunchAgent for the local daemon.
  cx support           Export a redacted diagnostics bundle for debugging and support.
  cx share export      Export one or more logged-in accounts into a portable archive.
  cx share import      Import accounts from a portable archive created by cx share export.
  cx share push        Copy accounts to another machine over ssh and import them there.
  cx share config      Export or import the global Codex CLI config (~/.codex/config.toml).
  cx resolve           Print only the account that would launch next.
  cx cooldown          List active cooldowns.
  cx cooldown <acct>   Put an account on cooldown using durations like 30m, 5h, 1d.

Examples:
  cx
  cx "fix this bug"
  cx login
  cx list
  cx list --verbose
  cx list --interactive
  cx pin acct_002
  cx sync-agents
  cx sync-agents acct_001 work
  cx which
  cx warmup
  cx warmup acct_001
  cx warmup --show-quota
  cx quota
  cx quota acct_001
  cx quota acct_001 --refresh
  cx quota --source auto
  cx alias acct_001 work
  cx alias clear work
  cx enable acct_001
  cx recover acct_001
  cx update --check
  cx update
  cx version
  cx init --shell zsh
  cx daemon status
  cx daemon serve --port 8787
  cx daemon launchd plist
  cx support
  cx share export
  cx share push user@laptop --with-config
  cx share export acct_001 --output ~/Desktop/codex-orbit-share.tar.gz
  cx share import ~/Desktop/codex-orbit-share.tar.gz
  cx share config export
  cx share config push user@laptop
  cx share config import ~/Desktop/codex-orbit-config-share.tar.gz
  cx completions zsh
  cx completions install zsh
  cx resolve
  cx cooldown acct_001 5h
  cx cooldown clear acct_001
  cx delete acct_003
EOF
        return 0
        ;;
      --)
        shift
        codex_args+=("$@")
        break
        ;;
      *)
        codex_args+=("$arg")
        shift
        ;;
    esac
  done

  if [[ "$mode" == "login" ]]; then
    account="$(_codex_reserve_next_account)"
    _codex_prepare_account_home "$account" || return 1
    _codex_set_last_account "$account" || return 1
    echo "Using internal account: $account"
    CODEX_HOME="$(_codex_account_dir "$account")" codex login "${codex_args[@]}"
    return $?
  fi

  if [[ "$mode" == "login-loop" ]]; then
    emulate -L zsh -o localtraps
    local stop_login_loop=0 login_status=0
    trap 'stop_login_loop=1' INT

    while true; do
      (( stop_login_loop )) && return 130
      account="$(_codex_reserve_next_account)"
      _codex_prepare_account_home "$account" || return 1
      _codex_set_last_account "$account" || return 1
      echo "Using internal account: $account"
      if CODEX_HOME="$(_codex_account_dir "$account")" codex login "${codex_args[@]}"; then
        login_status=0
      else
        login_status=$?
      fi
      if (( stop_login_loop )); then
        return 130
      fi
      if (( login_status != 0 )); then
        return "$login_status"
      fi
      echo "Logged in: $account"
      echo "Press Ctrl-C to stop, or complete the next login."
    done
  fi

  if [[ "$mode" == "doctor" ]]; then
    if (( ${#codex_args[@]} > 1 )) || { (( ${#codex_args[@]} == 1 )) && [[ "${codex_args[1]}" != "--json" ]]; }; then
      echo "Usage: cx doctor [--json]"
      return 1
    fi
    if (( ${#codex_args[@]} == 1 )); then
      _codex_doctor_json
    else
      _codex_doctor_text
    fi
    return $?
  fi

  if [[ "$mode" == "sync-agents" ]]; then
    _codex_sync_agents "${codex_args[@]}"
    return $?
  fi

  if [[ "$mode" == "status" ]]; then
    if ! _codex_accounts_list >/dev/null 2>&1 || [[ -z "$(_codex_accounts_list)" ]]; then
      echo "No Codex accounts found. Run: cx login"
      return 1
    fi
    while IFS= read -r acct; do
      [[ -n "$acct" ]] || continue
      status_line="$(CODEX_HOME="$(_codex_account_dir "$acct")" codex login status 2>&1 || true)"
      cooldown_note="$(_codex_cooldown_note "$acct" 2>/dev/null || true)"
      if [[ -n "$cooldown_note" ]]; then
        printf '#%d %s: %s [%s]\n' "$idx" "$(_codex_account_display_name "$acct")" "${status_line:-Unknown}" "$cooldown_note"
      else
        printf '#%d %s: %s\n' "$idx" "$(_codex_account_display_name "$acct")" "${status_line:-Unknown}"
      fi
      idx=$((idx + 1))
    done < <(_codex_accounts_list)
    return 0
  fi

  if [[ "$mode" == "delete" ]]; then
    if [[ -z "$(_codex_accounts_list)" ]]; then
      echo "No Codex accounts found."
      return 1
    fi

    if (( ${#codex_args[@]} > 0 )); then
      account="$(_codex_resolve_account_ref "${codex_args[1]}" 2>/dev/null || true)"
      if [[ -z "$account" ]]; then
        echo "Unknown account: ${codex_args[1]}"
        return 1
      fi
    elif ! account="$(_codex_pick_account 'Archive account> ')"; then
      return 1
    fi

    echo "Archive $account to trash? [y/N]"
    local confirm
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      return 1
    fi

    archive_path="$(_codex_archive_account "$account")" || return 1
    echo "Archived: $account -> $archive_path"
    return 0
  fi

  if [[ "$mode" == "pin" ]]; then
    if (( ${#codex_args[@]} > 0 )); then
      account="$(_codex_resolve_account_ref "${codex_args[1]}" 2>/dev/null || true)"
      if [[ -z "$account" ]]; then
        echo "No logged-in Codex account: ${codex_args[1]}"
        return 1
      fi
      if ! _codex_is_logged_in "$account"; then
        echo "No logged-in Codex account: ${codex_args[1]}"
        return 1
      fi
    elif ! account="$(_codex_pick_logged_in_account 'Pin account> ')"; then
      echo "No logged-in Codex accounts found. Run: cx login"
      return 1
    fi

    if _codex_account_in_cooldown "$account"; then
      echo "Account is in cooldown: $(_codex_account_display_name "$account")"
      return 1
    fi

    if _codex_account_disabled "$account"; then
      echo "Account is disabled: $(_codex_account_display_name "$account")"
      return 1
    fi

    _codex_set_pinned_account "$account"
    _codex_set_last_account "$account" || return 1
    _codex_debug "pin_set account=$account"
    echo "Pinned for this shell: $(_codex_account_display_name "$account")"
    return 0
  fi

  if [[ "$mode" == "pin-next" ]]; then
    if ! account="$(_codex_next_launchable_account 1)"; then
      _codex_no_launchable_accounts_message
      return 1
    fi
    _codex_set_pinned_account "$account"
    _codex_set_last_account "$account" || return 1
    _codex_debug "pin_next account=$account"
    echo "Pinned for this shell: $(_codex_account_display_name "$account")"
    return 0
  fi

  if [[ "$mode" == "unpin" ]]; then
    _codex_clear_pinned_account
    _codex_debug "pin_cleared"
    echo "Pin cleared for this shell."
    return 0
  fi

  if [[ "$mode" == "current" ]]; then
    if account="$(_codex_get_pinned_account 2>/dev/null)"; then
      cooldown_note="$(_codex_cooldown_note "$account" 2>/dev/null || true)"
      if [[ -n "$cooldown_note" ]]; then
        echo "Pinned: $(_codex_account_display_name "$account") ($cooldown_note)"
      else
        echo "Pinned: $(_codex_account_display_name "$account")"
      fi
    else
      echo "Pinned: none"
    fi
    local last_launch=""
    last_launch="$(cat "$state_file" 2>/dev/null || true)"
    if [[ -n "$last_launch" && "$last_launch" != "none" && -d "$(_codex_account_dir "$last_launch")" ]]; then
      echo "Last launch: $(_codex_account_display_name "$last_launch")"
    else
      echo "Last launch: none"
    fi
    return 0
  fi

  if [[ "$mode" == "list" ]]; then
    local interactive_list=0

    if (( ${#codex_args[@]} > 0 )); then
      case "${codex_args[1]}" in
        --plain)
          list_mode="plain"
          ;;
        --verbose)
          list_mode="verbose"
          ;;
        --interactive)
          interactive_list=1
          ;;
        *)
          echo "Usage: cx list [--plain|--verbose|--interactive]"
          return 1
          ;;
      esac
    fi

    if (( interactive_list )) || { [[ "$list_mode" == "rich" ]] && [[ -t 0 && -t 1 ]]; }; then
      _codex_list_interactive
      return $?
    fi

    if [[ "$list_mode" == "rich" ]]; then
      printf '%-24s  %-24s  %-12s  %-18s  %s\n' "ACCOUNT" "EMAIL" "PLAN" "WORKSPACE" "STATUS"
      printf '%-24s  %-24s  %-12s  %-18s  %s\n' "-------" "-----" "----" "---------" "------"
    fi

    while IFS= read -r acct; do
      [[ -n "$acct" ]] || continue

      if [[ "$list_mode" == "plain" ]]; then
        printf '%s\n' "$acct"
        continue
      fi

      status_value="$(_codex_account_status_value "$acct")"

      metadata="$(_codex_account_metadata "$acct" 2>/dev/null || true)"
      if [[ -n "$metadata" ]]; then
        local sep=$'\x1f'
        IFS="$sep" read -r email plan default_workspace workspace_count workspace_titles account_id last_refresh auth_mode <<<"$metadata"
        email_display="$(_codex_display_email "$email" "-")"
      else
        email_display="-"
        plan="-"
        default_workspace=""
        workspace_count=0
        workspace_titles=""
        account_id=""
        last_refresh=""
        auth_mode=""
      fi

      if [[ "$list_mode" == "verbose" ]]; then
        printf '%s\talias=%s\temail=%s\tplan=%s\tworkspace=%s\tworkspaces=%s\tstatus=%s' \
          "$acct" \
          "$(_codex_account_alias "$acct" 2>/dev/null || printf '-')" \
          "${email_display:--}" \
          "${plan:--}" \
          "$(_codex_workspace_summary "$default_workspace" "${workspace_count:-0}")" \
          "${workspace_titles:--}" \
          "$status_value"
        if [[ -n "$auth_mode" ]]; then
          printf '\tauth=%s' "$auth_mode"
        fi
        if [[ -n "$account_id" ]]; then
          printf '\taccount_id=%s' "${account_id[1,8]}..."
        fi
        printf '\n'
      else
        printf '%-24s  %-24s  %-12s  %-18s  %s\n' \
          "$(_codex_account_display_name "$acct")" \
          "${email_display:--}" \
          "${plan:--}" \
          "$(_codex_workspace_summary "$default_workspace" "${workspace_count:-0}")" \
          "$status_value"
      fi
    done < <(_codex_accounts_list)
    return 0
  fi

  if [[ "$mode" == "cooldown" ]]; then
    if (( ${#codex_args[@]} == 0 )); then
      local line found=0 until
      printf '%-24s  %s\n' "ACCOUNT" "UNTIL"
      printf '%-24s  %s\n' "-------" "-----"
      while IFS=$'\t' read -r acct until; do
        [[ -n "$acct" ]] || continue
        printf '%-24s  %s\n' "$(_codex_account_display_name "$acct")" "$(_codex_format_timestamp "$until")"
        found=1
      done < <(_codex_active_cooldowns)
      if (( ! found )); then
        echo "No active cooldowns."
      fi
      return 0
    fi

    if [[ "${codex_args[1]}" == "clear" ]]; then
      account="${codex_args[2]:-}"
      if [[ -z "$account" ]]; then
        echo "Usage: cx cooldown clear <account>"
        return 1
      fi
      account="$(_codex_resolve_account_ref "$account" 2>/dev/null || true)"
      if [[ -z "$account" ]]; then
        echo "Unknown account: ${codex_args[2]}"
        return 1
      fi
      _codex_clear_cooldown "$account"
      _codex_debug "cooldown_cleared account=$account"
      echo "Cooldown cleared: $(_codex_account_display_name "$account")"
      return 0
    fi

    account="${codex_args[1]}"
    arg="${codex_args[2]:-}"
    if [[ -z "$account" || -z "$arg" ]]; then
      echo "Usage: cx cooldown <account> <duration>"
      echo "Durations: 30m, 5h, 1d"
      return 1
    fi

    account="$(_codex_resolve_account_ref "$account" 2>/dev/null || true)"
    if [[ -z "$account" ]]; then
      echo "Unknown account: ${codex_args[1]}"
      return 1
    fi

    if ! cooldown_note="$(_codex_set_cooldown "$account" "$arg" 2>/dev/null)"; then
      echo "Invalid duration: $arg"
      echo "Durations: 30m, 5h, 1d"
      return 1
    fi

    echo "Cooldown set: $(_codex_account_display_name "$account") until $(_codex_format_timestamp "$cooldown_note")"
    return 0
  fi

  if [[ "$mode" == "alias" ]]; then
    local alias_ref="" alias_name="" alias_account="" alias_display_name=""

    if (( ${#codex_args[@]} == 0 )); then
      printf '%-20s  %s\n' "ALIAS" "ACCOUNT"
      printf '%-20s  %s\n' "-----" "-------"
      if ! _codex_list_account_aliases | while IFS=$'\t' read -r alias_name alias_account; do
        [[ -n "$alias_name" && -n "$alias_account" ]] || continue
        printf '%-20s  %s\n' "$alias_name" "$alias_account"
      done; then
        echo "No account aliases set."
      fi
      return 0
    fi

    if [[ "${codex_args[1]}" == "clear" ]]; then
      alias_ref="${codex_args[2]:-}"
      if [[ -z "$alias_ref" || ${#codex_args[@]} -ne 2 ]]; then
        echo "Usage: cx alias [account <alias>|clear <account|alias>]"
        return 1
      fi
      alias_account="$(_codex_resolve_account_ref "$alias_ref" 2>/dev/null || true)"
      if [[ -z "$alias_account" ]]; then
        echo "Unknown account or alias: $alias_ref"
        return 1
      fi
      alias_display_name="$(_codex_account_display_name "$alias_account")"
      _codex_clear_account_alias "$alias_account"
      echo "Alias cleared: $alias_display_name"
      return 0
    fi

    if (( ${#codex_args[@]} != 2 )); then
      echo "Usage: cx alias [account <alias>|clear <account|alias>]"
      return 1
    fi

    alias_account="$(_codex_resolve_account_ref "${codex_args[1]}" 2>/dev/null || true)"
    alias_name="${codex_args[2]}"
    if [[ -z "$alias_account" ]]; then
      echo "Unknown account: ${codex_args[1]}"
      return 1
    fi
    _codex_set_account_alias "$alias_account" "$alias_name" || return 1
    echo "Alias set: $(_codex_account_display_name "$alias_account")"
    return 0
  fi

  if [[ "$mode" == "enable" || "$mode" == "disable" || "$mode" == "recover" ]]; then
    local action_account_ref="${codex_args[1]:-}"
    local action_account=""

    if [[ -z "$(_codex_accounts_list)" ]]; then
      echo "No Codex accounts found."
      return 1
    fi

    if [[ -n "$action_account_ref" ]]; then
      action_account="$(_codex_resolve_account_ref "$action_account_ref" 2>/dev/null || true)"
      if [[ -z "$action_account" ]]; then
        echo "Unknown account: $action_account_ref"
        return 1
      fi
    elif ! action_account="$(_codex_pick_account "${mode^} account> ")"; then
      return 1
    fi

    case "$mode" in
      enable)
        _codex_enable_account "$action_account"
        echo "Enabled: $(_codex_account_display_name "$action_account")"
        ;;
      disable)
        _codex_disable_account "$action_account" "manual"
        echo "Disabled: $(_codex_account_display_name "$action_account")"
        ;;
      recover)
        _codex_enable_account "$action_account"
        _codex_clear_cooldown "$action_account"
        echo "Recovered: $(_codex_account_display_name "$action_account")"
        echo "State cleared: disabled flag and cooldown"
        ;;
    esac
    return 0
  fi

  if [[ "$mode" == "version" ]]; then
    if (( ${#codex_args[@]} > 0 )); then
      echo "Usage: cx version"
      return 1
    fi
    _codex_print_version
    return $?
  fi

  if [[ "$mode" == "init" ]]; then
    _codex_init_command "${codex_args[@]}"
    return $?
  fi

  if [[ "$mode" == "completions" ]]; then
    _codex_handle_completions "${codex_args[@]}"
    return $?
  fi

  if [[ "$mode" == "daemon" ]]; then
    local daemon_subcommand="${codex_args[1]:-}"
    local -a daemon_args=()

    for (( idx = 2; idx <= ${#codex_args[@]}; idx++ )); do
      daemon_args+=("${codex_args[idx]}")
    done

    case "$daemon_subcommand" in
      serve)
        _codex_daemon_serve "${daemon_args[@]}"
        return $?
        ;;
      status)
        if (( ${#codex_args[@]} > 2 )) || { (( ${#codex_args[@]} == 2 )) && [[ "${codex_args[2]}" != "--json" ]]; }; then
          echo "Usage: cx daemon status [--json]"
          return 1
        fi
        if (( ${#codex_args[@]} == 2 )); then
          _codex_daemon_snapshot_json
        else
          _codex_daemon_status_text
        fi
        return $?
        ;;
      url)
        if (( ${#codex_args[@]} > 1 )); then
          echo "Usage: cx daemon url"
          return 1
        fi
        _codex_daemon_default_url
        return $?
        ;;
      launchd)
        _codex_daemon_launchd "${daemon_args[@]}"
        return $?
        ;;
      ""|--help|-h)
        echo "Usage: cx daemon serve [--host <host>] [--port <port>]"
        echo "       cx daemon status [--json]"
        echo "       cx daemon url"
        echo "       cx daemon launchd <plist|install|uninstall|start|stop|status>"
        return 0
        ;;
      *)
        echo "Usage: cx daemon serve [--host <host>] [--port <port>]"
        echo "       cx daemon status [--json]"
        echo "       cx daemon url"
        echo "       cx daemon launchd <plist|install|uninstall|start|stop|status>"
        return 1
        ;;
    esac
  fi

  if [[ "$mode" == "update" ]]; then
    if (( ${#codex_args[@]} > 1 )) || { (( ${#codex_args[@]} == 1 )) && [[ "${codex_args[1]}" != "--check" ]]; }; then
      echo "Usage: cx update [--check]"
      return 1
    fi
    if (( ${#codex_args[@]} == 1 )); then
      _codex_update_check
      return $?
    fi
    _codex_update_self
    return $?
  fi

  if [[ "$mode" == "support" ]]; then
    local output_path=""

    while (( ${#codex_args[@]} > 0 )); do
      arg="${codex_args[1]}"
      case "$arg" in
        --output)
          if (( ${#codex_args[@]} < 2 )); then
            echo "Usage: cx support [--output <bundle.tar.gz>]"
            return 1
          fi
          output_path="${codex_args[2]}"
          codex_args=("${codex_args[@]:3}")
          ;;
        --help|-h)
          echo "Usage: cx support [--output <bundle.tar.gz>]"
          echo "Default: exports a redacted diagnostics bundle into ./codex-orbit-support-YYYYMMDDHHMMSS.tar.gz"
          return 0
          ;;
        *)
          echo "Usage: cx support [--output <bundle.tar.gz>]"
          return 1
          ;;
      esac
    done

    output_path="$(_codex_write_support_bundle "$output_path")" || return 1
    printf 'Support bundle written to %s\n' "$output_path"
    return 0
  fi

  if [[ "$mode" == "share" ]]; then
    local -a share_args=()
    local -a config_share_args=()
    local share_idx=0
    local share_submode=""

    arg="${codex_args[1]:-}"
    for (( share_idx = 2; share_idx <= ${#codex_args[@]}; share_idx++ )); do
      share_args+=("${codex_args[$share_idx]}")
    done

    if [[ "$arg" == "config" ]]; then
      share_submode="${share_args[1]:-}"
      for (( share_idx = 2; share_idx <= ${#share_args[@]}; share_idx++ )); do
        config_share_args+=("${share_args[$share_idx]}")
      done
      case "$share_submode" in
        export)
          _codex_share_config_export "${config_share_args[@]}"
          return $?
          ;;
        import)
          _codex_share_config_import "${config_share_args[@]}"
          return $?
          ;;
        push)
          _codex_share_config_push "${config_share_args[@]}"
          return $?
          ;;
        ""|--help|-h)
          echo "Usage: cx share config export [--output <archive.tar.gz>]"
          echo "       cx share config import <archive.tar.gz>"
          echo "       cx share config push <ssh-host> [--remote-dir <dir>]"
          return 0
          ;;
        *)
          echo "Usage: cx share config export [--output <archive.tar.gz>]"
          echo "       cx share config import <archive.tar.gz>"
          echo "       cx share config push <ssh-host> [--remote-dir <dir>]"
          return 1
          ;;
      esac
    fi

    case "$arg" in
      export)
        _codex_share_export "${share_args[@]}"
        return $?
        ;;
      import)
        _codex_share_import "${share_args[@]}"
        return $?
        ;;
      push)
        _codex_share_push "${share_args[@]}"
        return $?
        ;;
      ""|--help|-h)
        echo "Usage: cx share export [account ...|--all] [--output <archive.tar.gz>]"
        echo "       cx share import <archive.tar.gz>"
        echo "       cx share push <ssh-host> [account ...|--all] [--with-config] [--remote-dir <dir>]"
        echo "       cx share config export [--output <archive.tar.gz>]"
        echo "       cx share config import <archive.tar.gz>"
        echo "       cx share config push <ssh-host> [--remote-dir <dir>]"
        return 0
        ;;
      *)
        echo "Usage: cx share export [account ...|--all] [--output <archive.tar.gz>]"
        echo "       cx share import <archive.tar.gz>"
        echo "       cx share push <ssh-host> [account ...|--all] [--with-config] [--remote-dir <dir>]"
        echo "       cx share config export [--output <archive.tar.gz>]"
        echo "       cx share config import <archive.tar.gz>"
        echo "       cx share config push <ssh-host> [--remote-dir <dir>]"
        return 1
        ;;
    esac
  fi

  if [[ "$mode" == "resolve" || "$mode" == "which" ]]; then
    if (( ${#codex_args[@]} > 0 )); then
      echo "Usage: cx $mode"
      return 1
    fi

    if ! selection="$(_codex_resolve_account_selection 0)"; then
      _codex_no_launchable_accounts_message
      return 1
    fi

    account="${selection%%$'\t'*}"
    source="${selection#*$'\t'}"

    if [[ "$mode" == "resolve" ]]; then
      printf '%s\n' "$account"
      return 0
    fi

    _codex_print_routing_report "$account" "$source"
    metadata="$(_codex_account_metadata "$account" 2>/dev/null || true)"
    if [[ -n "$metadata" ]]; then
      local sep=$'\x1f'
      IFS="$sep" read -r email plan default_workspace workspace_count workspace_titles account_id last_refresh auth_mode <<<"$metadata"
      echo "Selected account details:"
      printf 'Email: %s\n' "$(_codex_display_email "$email" "-")"
      if [[ -n "$plan" ]]; then
        printf 'Plan: %s\n' "$plan"
      fi
      printf 'Workspace: %s\n' "$(_codex_workspace_summary "$default_workspace" "${workspace_count:-0}")"
    fi
    quota_snapshot="$(_codex_account_quota_snapshot "$account" tsv 2>/dev/null || true)"
    if [[ -n "$quota_snapshot" ]]; then
      local sep=$'\x1f'
      IFS="$sep" read -r \
        quota_source \
        quota_email \
        quota_plan \
        credits_balance \
        credits_has \
        credits_unlimited \
        primary_used \
        primary_remaining \
        primary_reset \
        primary_window \
        secondary_used \
        secondary_remaining \
        secondary_reset \
        secondary_window <<<"$quota_snapshot"
      _codex_print_quota_meter \
        "$primary_remaining" \
        "$primary_reset" \
        "$primary_window" \
        "$secondary_remaining" \
        "$secondary_reset" \
        "$secondary_window"
      printf 'Quota source: %s\n' "${quota_source:-unknown}"
    fi
    if pinned_account="$(_codex_get_pinned_account 2>/dev/null)"; then
      :
    fi
    return 0
  fi

  if [[ "$mode" == "warmup" ]]; then
    local target_account="" target_account_ref="" warmup_source=""
    local warmup_result=""
    local show_quota_after=0

    for arg in "${codex_args[@]}"; do
      case "$arg" in
        --show-quota)
          show_quota_after=1
          ;;
        *)
          if [[ -n "$target_account" ]]; then
            echo "Usage: cx warmup [account] [--show-quota]"
            return 1
          fi
          target_account="$arg"
          ;;
      esac
    done

    if [[ -n "$target_account" ]]; then
      target_account_ref="$target_account"
      target_account="$(_codex_resolve_account_ref "$target_account" 2>/dev/null || true)"
      if [[ -z "$target_account" ]]; then
        echo "Unknown account: $target_account_ref"
        return 1
      fi
      if ! _codex_is_logged_in "$target_account"; then
        echo "No logged-in Codex account: $target_account_ref"
        return 1
      fi
      if _codex_account_in_cooldown "$target_account"; then
        echo "Account is in cooldown: $(_codex_account_display_name "$target_account")"
        return 1
      fi
      warmup_source="explicit"
    else
      if ! selection="$(_codex_resolve_account_selection 0)"; then
        _codex_no_launchable_accounts_message
        return 1
      fi
      target_account="${selection%%$'\t'*}"
      warmup_source="${selection#*$'\t'}"
    fi

    printf 'Warming up: %s\n' "$(_codex_account_display_name "$target_account")"
    printf 'Source: %s\n' "$warmup_source"

    if ! warmup_result="$(_codex_warmup_account "$target_account")"; then
      echo "Warmup failed: $target_account"
      return 1
    fi

    if [[ -n "$warmup_result" ]]; then
      printf 'Response: %s\n' "$warmup_result"
    fi

    if (( show_quota_after )); then
      quota_snapshot="$(_codex_account_quota_snapshot "$target_account" tsv 2>/dev/null || true)"
      if [[ -n "$quota_snapshot" ]]; then
        local sep=$'\x1f'
        IFS="$sep" read -r \
          quota_source \
          quota_email \
          quota_plan \
          credits_balance \
          credits_has \
          credits_unlimited \
          primary_used \
          primary_remaining \
          primary_reset \
          primary_window \
          secondary_used \
          secondary_remaining \
          secondary_reset \
          secondary_window <<<"$quota_snapshot"
        _codex_print_quota_meter \
          "$primary_remaining" \
          "$primary_reset" \
          "$primary_window" \
          "$secondary_remaining" \
          "$secondary_reset" \
          "$secondary_window"
        printf 'Quota source: %s\n' "${quota_source:-unknown}"
      fi
    else
      echo "Quota: skipped; run 'cx quota $target_account' if you want a live refresh."
    fi

    return 0
  fi

  if [[ "$mode" == "quota" ]]; then
    local output_format="text"
    local target_account="" target_account_ref=""
    local refresh_quota=0
    local quota_source_mode=""
    local rows_dir="" snapshot_file="" pid=""
    local -a quota_pids=()

    quota_source_mode="$(_codex_quota_default_source)"

    idx=1
    while (( idx <= ${#codex_args[@]} )); do
      arg="${codex_args[idx]}"
      case "$arg" in
        --json)
          output_format="json"
          ;;
        --refresh)
          refresh_quota=1
          ;;
        --source)
          idx=$((idx + 1))
          arg="${codex_args[idx]:-}"
          if ! _codex_quota_source_is_valid "$arg"; then
            echo "Usage: cx quota [account] [--json] [--refresh] [--source oauth|auto|rpc|status]"
            return 1
          fi
          quota_source_mode="$arg"
          ;;
        --source=*)
          arg="${arg#--source=}"
          if ! _codex_quota_source_is_valid "$arg"; then
            echo "Usage: cx quota [account] [--json] [--refresh] [--source oauth|auto|rpc|status]"
            return 1
          fi
          quota_source_mode="$arg"
          ;;
        *)
          if [[ -n "$target_account" ]]; then
            echo "Usage: cx quota [account] [--json] [--refresh] [--source oauth|auto|rpc|status]"
            return 1
          fi
          target_account="$arg"
          ;;
      esac
      idx=$((idx + 1))
    done

    if [[ -n "$target_account" ]]; then
      target_account_ref="$target_account"
      target_account="$(_codex_resolve_account_ref "$target_account" 2>/dev/null || true)"
      if [[ -z "$target_account" ]]; then
        echo "Unknown account: $target_account_ref"
        return 1
      fi

      if [[ "$output_format" == "json" ]]; then
        _codex_account_quota_snapshot "$target_account" json "$refresh_quota" "$quota_source_mode"
        return $?
      fi

      snapshot_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-quota-single.XXXXXX")" || return 1
      (
        _codex_account_quota_snapshot "$target_account" tsv "$refresh_quota" "$quota_source_mode"
      ) > "$snapshot_file" 2>/dev/null &
      pid="$!"
      _codex_wait_for_pids "Loading quota for $(_codex_account_display_name "$target_account")" "$pid"

      if [[ ! -s "$snapshot_file" ]]; then
        rm -f "$snapshot_file"
        echo "Quota unavailable for $target_account"
        return 1
      fi
      quota_snapshot="$(< "$snapshot_file")"
      rm -f "$snapshot_file"

      local sep=$'\x1f'
      IFS="$sep" read -r \
        quota_source \
        quota_email \
        quota_plan \
        credits_balance \
        credits_has \
        credits_unlimited \
        primary_used \
        primary_remaining \
        primary_reset \
        primary_window \
        secondary_used \
        secondary_remaining \
        secondary_reset \
        secondary_window <<<"$quota_snapshot"

      printf 'Account: %s\n' "$(_codex_account_display_name "$target_account")"
      [[ -n "$quota_email" ]] && printf 'Email: %s\n' "$quota_email"
      [[ -n "$quota_plan" ]] && printf 'Plan: %s\n' "$quota_plan"
      printf 'Source: %s\n' "${quota_source:-unknown}"
      _codex_print_quota_meter \
        "$primary_remaining" \
        "$primary_reset" \
        "$primary_window" \
        "$secondary_remaining" \
        "$secondary_reset" \
        "$secondary_window"

      if [[ "$credits_unlimited" == "1" ]]; then
        echo "Credits: unlimited"
      elif [[ "$credits_has" == "1" && -n "$credits_balance" ]]; then
        printf 'Credits: %s\n' "$credits_balance"
      fi
      return 0
    fi

    if [[ -n "$(_codex_logged_in_accounts)" ]]; then
      setopt localoptions no_monitor
      local -a accounts=("${(@f)$(_codex_logged_in_accounts)}")
      local account_width=7
      local rows_file now_epoch account_count=0 unavailable_count=0
      local primary_critical=0 primary_warning=0 secondary_critical=0 secondary_warning=0
      local next_primary_reset=""
      local acct="" primary_used_value="" secondary_used_value="" sort_reset="" quota_label=""

      now_epoch="$(_codex_now_epoch)"
      rows_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-quota-board.XXXXXX")" || return 1
      rows_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-orbit-quota-snapshots.XXXXXX")" || {
        rm -f "$rows_file"
        return 1
      }

      for acct in "${accounts[@]}"; do
        [[ -n "$acct" ]] || continue
        (( ++account_count ))
        (
          _codex_account_quota_snapshot "$acct" tsv "$refresh_quota" "$quota_source_mode"
        ) > "$rows_dir/$acct.snapshot" 2>/dev/null &
        quota_pids+=("$!")
      done

      _codex_wait_for_pids "Loading quota for ${account_count} account(s)" "${quota_pids[@]}"

      for acct in "${accounts[@]}"; do
        [[ -n "$acct" ]] || continue
        snapshot_file="$rows_dir/$acct.snapshot"
        if [[ ! -s "$snapshot_file" ]]; then
          (( ++unavailable_count ))
          (( ${#acct} > account_width )) && account_width=${#acct}
          printf '0\t-1\t-1\t9999999999\t%s\t%s\tunavailable\t\t\t\t\t\t\n' "$acct" "$acct" >> "$rows_file"
          continue
        fi
        quota_snapshot="$(< "$snapshot_file")"

        local sep=$'\x1f'
        IFS="$sep" read -r \
          quota_source \
          quota_email \
          quota_plan \
          credits_balance \
          credits_has \
          credits_unlimited \
          primary_used \
          primary_remaining \
          primary_reset \
          primary_window \
          secondary_used \
          secondary_remaining \
          secondary_reset \
          secondary_window <<<"$quota_snapshot"

        quota_label="$(_codex_account_preferred_label "$acct" "$(_codex_display_email "$quota_email" "$acct")")"
        (( ${#quota_label} > account_width )) && account_width=${#quota_label}

        if primary_used_value="$(_codex_quota_used_value "$primary_remaining" "$primary_used" 2>/dev/null)"; then
          if (( primary_used_value >= 85 )); then
            (( ++primary_critical ))
          elif (( primary_used_value >= 70 )); then
            (( ++primary_warning ))
          fi
        else
          primary_used_value=-1
        fi

        if secondary_used_value="$(_codex_quota_used_value "$secondary_remaining" "$secondary_used" 2>/dev/null)"; then
          if (( secondary_used_value >= 85 )); then
            (( ++secondary_critical ))
          elif (( secondary_used_value >= 70 )); then
            (( ++secondary_warning ))
          fi
        else
          secondary_used_value=-1
        fi

        if [[ -n "$primary_reset" ]]; then
          if [[ -z "$next_primary_reset" || "$primary_reset" -lt "$next_primary_reset" ]]; then
            next_primary_reset="$primary_reset"
          fi
          sort_reset="$primary_reset"
        else
          sort_reset=9999999999
        fi

        printf '1\t%s\t%s\t%010d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$primary_used_value" \
          "$secondary_used_value" \
          "$sort_reset" \
          "$acct" \
          "$quota_label" \
          "$primary_remaining" \
          "$primary_used" \
          "$primary_reset" \
          "$secondary_remaining" \
          "$secondary_used" \
          "$secondary_reset" >> "$rows_file"
      done

      printf 'Quota Overview\n'

      local summary_line=""
      summary_line+="${account_count} accounts"
      if (( unavailable_count > 0 )); then
        summary_line+=" | ${unavailable_count} unavailable"
      fi
      summary_line+=" | 5h: ${primary_critical} critical"
      if (( primary_warning > 0 )); then
        summary_line+=", ${primary_warning} warning"
      fi
      summary_line+=" | weekly: ${secondary_critical} critical"
      if (( secondary_warning > 0 )); then
        summary_line+=", ${secondary_warning} warning"
      fi
      if [[ -n "$next_primary_reset" ]]; then
        summary_line+=" | next 5h reset in $(_codex_format_duration_short $((next_primary_reset - now_epoch)))"
      fi
      printf '%s\n\n' "$summary_line"

      local reset_width=12
      local meter_width=15
      printf '%-*s  %-*s  %-*s  %-*s  %-*s\n' \
        "$account_width" 'ACCOUNT' \
        "$meter_width" '5H LEFT' \
        "$reset_width" '5H RESET' \
        "$meter_width" 'WEEKLY' \
        "$reset_width" 'WK RESET'

      while IFS=$'\t' read -r \
        available_flag \
        primary_used_sort \
        secondary_used_sort \
        sort_reset \
        acct \
        account_label \
        primary_remaining \
        primary_used \
        primary_reset \
        secondary_remaining \
        secondary_used \
        secondary_reset; do
        if [[ "$available_flag" == "1" ]]; then
          printf '%-*s  %-*s  %-*s  %-*s  %-*s\n' \
            "$account_width" "$account_label" \
            "$meter_width" "$(_codex_quota_meter_cell "$primary_remaining" "$primary_used")" \
            "$reset_width" "$(_codex_format_timestamp_compact "$primary_reset" "$now_epoch")" \
            "$meter_width" "$(_codex_quota_meter_cell "$secondary_remaining" "$secondary_used")" \
            "$reset_width" "$(_codex_format_timestamp_compact "$secondary_reset" "$now_epoch")"
        else
          printf '%-*s  %-*s  %-*s  %-*s  %-*s\n' \
            "$account_width" "$account_label" \
            "$meter_width" '-' \
            "$reset_width" '-' \
            "$meter_width" '-' \
            "$reset_width" '-'
        fi
      done < <(sort -t $'\t' -k1,1nr -k2,2nr -k3,3nr -k4,4n -k5,5 "$rows_file")

      rm -f "$rows_file"
      rm -rf "$rows_dir"
      return 0
    fi

    echo "No logged-in Codex accounts found. Run: cx login"
    return 1
  fi

  if ! selection="$(_codex_resolve_account_selection 1)"; then
    _codex_no_launchable_accounts_message
    return 1
  fi

  account="${selection%%$'\t'*}"
  source="${selection#*$'\t'}"
  _codex_set_last_account "$account" || return 1
  _codex_debug "launch account=$account source=$source arg_count=${#codex_args[@]}"

  _codex_prepare_account_home "$account" || return 1
  _codex_run_codex_for_account "$account" --yolo "${codex_args[@]}"
}

cx_custom() {
  cx "$@"
}

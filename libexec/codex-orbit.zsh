typeset -g CODEX_ORBIT_LIBEXEC_DIR="${CODEX_ORBIT_LIBEXEC_DIR:-${${(%):-%N}:P:h}}"

codex_account() {
  local acct="${1:-}"
  shift || true

  if [[ -z "$acct" ]]; then
    echo "usage: codex_account <account> [codex args...]"
    return 1
  fi

  if [[ ! -d "$HOME/.codex-accounts/$acct" ]]; then
    echo "unknown account: $acct"
    echo "create one with: cx login"
    return 1
  fi

  _codex_prepare_account_home "$acct" || return 1
  CODEX_HOME="$HOME/.codex-accounts/$acct" codex "$@"
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

_codex_account_auth_file() {
  printf '%s/auth.json\n' "$(_codex_account_dir "$1")"
}

_codex_accounts_list() {
  local accounts_dir="$(_codex_accounts_dir)"

  mkdir -p "$accounts_dir"
  find "$accounts_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; | sort
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
  local acct

  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    _codex_is_logged_in "$acct" && printf '%s\n' "$acct"
  done < <(_codex_accounts_list)
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

_codex_cooldown_file() {
  printf '%s/%s.until\n' "$(_codex_cooldown_dir)" "$1"
}

_codex_disabled_file() {
  printf '%s/%s.disabled\n' "$(_codex_disabled_dir)" "$1"
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

_codex_all_session_pin_files() {
  local state_dir="$(_codex_state_dir)"
  [[ -d "$state_dir" ]] || return 0
  find "$state_dir" -maxdepth 1 -type f -name 'session_*_pinned_account' | sort
}

_codex_get_pinned_account() {
  local pin_file="$(_codex_session_pin_file)"
  [[ -f "$pin_file" ]] || return 1
  cat "$pin_file"
}

_codex_set_pinned_account() {
  local pin_file="$(_codex_session_pin_file)"
  print -r -- "$1" > "$pin_file"
}

_codex_clear_pinned_account() {
  local pin_file="$(_codex_session_pin_file)"
  rm -f "$pin_file"
}

_codex_clear_account_pins() {
  local acct="$1"
  local pin_file

  while IFS= read -r pin_file; do
    [[ -n "$pin_file" ]] || continue
    [[ -f "$pin_file" ]] || continue
    if [[ "$(cat "$pin_file")" == "$acct" ]]; then
      rm -f "$pin_file"
    fi
  done < <(_codex_all_session_pin_files)
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
  _codex_prepare_shared_sessions || return 1
}

_codex_default_share_archive_path() {
  printf '%s/codex-orbit-share-%s.tar.gz\n' "$PWD" "$(date '+%Y%m%d%H%M%S')"
}

_codex_share_export() {
  local py script output="" arg acct archive_path=""
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

  for acct in "${selected_accounts[@]}"; do
    if ! _codex_is_logged_in "$acct"; then
      echo "No logged-in Codex account: $acct"
      return 1
    fi
    _codex_ensure_account_config "$acct" || return 1
  done

  [[ -n "$output" ]] || output="$(_codex_default_share_archive_path)"
  helper_args=(export --accounts-dir "$(_codex_accounts_dir)" --output "$output")
  for acct in "${selected_accounts[@]}"; do
    helper_args+=(--account "$acct")
  done

  if ! archive_path="$("$py" "$script" "${helper_args[@]}")"; then
    return 1
  fi

  printf 'Exported %d account(s) to %s\n' "${#selected_accounts[@]}" "$archive_path"
  printf 'Import on the other machine with: cx share import %s\n' "$archive_path"
}

_codex_share_import() {
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

_codex_quota_cache_dir() {
  printf '%s/quota-cache\n' "$(_codex_state_dir)"
}

_codex_quota_cache_file() {
  local acct="$1"
  local source="${2:-auto}"
  printf '%s/%s.%s.tsv\n' "$(_codex_quota_cache_dir)" "$acct" "$source"
}

_codex_file_mtime() {
  local path="$1"

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
  cat "$cache_file"
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

_codex_account_quota_snapshot() {
  local acct="$1"
  local format="${2:-tsv}"
  local refresh="${3:-0}"
  local source="${4:-auto}"
  local py script result="" cache_ttl=0

  _codex_ensure_account_config "$acct" || return 1

  if [[ "$format" == "tsv" && "$refresh" != "1" ]]; then
    cache_ttl="$(_codex_quota_cache_ttl)"
    if result="$(_codex_read_cached_quota_snapshot "$acct" "$cache_ttl" "$source" 2>/dev/null)"; then
      printf '%s\n' "$result"
      return 0
    fi
  fi

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
  local output_file result prompt
  local -a mcp_disable_args=()

  _codex_prepare_account_home "$acct" || return 1
  prompt="$(_codex_warmup_prompt)"
  output_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-warmup.XXXXXX")" || return 1
  mcp_disable_args=("${(@f)$(_codex_mcp_disable_args "$acct")}")

  if ! CODEX_HOME="$(_codex_account_dir "$acct")" codex "${mcp_disable_args[@]}" -a never -s read-only exec \
    --skip-git-repo-check \
    --ephemeral \
    --color never \
    -C "$HOME" \
    -o "$output_file" \
    "$prompt"; then
    rm -f "$output_file"
    return 1
  fi

  result="$(tr -d '\r' < "$output_file" | tail -n 1)"
  rm -f "$output_file"

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
  cat "$file"
}

_codex_clear_cooldown() {
  rm -f "$(_codex_cooldown_file "$1")"
}

_codex_account_disabled() {
  [[ -f "$(_codex_disabled_file "$1")" ]]
}

_codex_disable_account() {
  mkdir -p "$(_codex_disabled_dir)"
  : > "$(_codex_disabled_file "$1")"
}

_codex_enable_account() {
  rm -f "$(_codex_disabled_file "$1")"
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
  print -r -- "$until" > "$(_codex_cooldown_file "$acct")"
  _codex_debug "cooldown_set account=$acct until=$until duration=$duration"
  printf '%s\n' "$until"
}

_codex_account_in_cooldown() {
  local acct="$1"
  local until now

  until="$(_codex_cooldown_until "$acct")" || return 1
  now="$(date +%s)"

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

_codex_next_round_robin_account() {
  local persist="${1:-0}"
  local state_dir="$(_codex_state_dir)"
  local rr_file="$state_dir/round_robin_last_account"
  local last_account="" account=""
  local -a accounts=("${(@f)$(_codex_eligible_logged_in_accounts)}")
  local idx

  mkdir -p "$state_dir"

  (( ${#accounts[@]} > 0 )) || return 1

  if (( ${#accounts[@]} == 1 )); then
    account="${accounts[1]}"
    if (( persist )); then
      print -r -- "$account" > "$rr_file"
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
    print -r -- "$account" > "$rr_file"
  fi

  printf '%s\n' "$account"
}

_codex_round_robin_account() {
  _codex_next_round_robin_account 1
}

_codex_preview_round_robin_account() {
  _codex_next_round_robin_account 0
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

  if (( ${#accounts[@]} == 0 )); then
    return 1
  fi

  if (( ${#accounts[@]} == 1 )); then
    printf '%s\n' "${accounts[1]}"
    return 0
  fi

  if command -v fzf >/dev/null 2>&1; then
    account="$(printf '%s\n' "${accounts[@]}" | fzf --prompt="$prompt" --height=10 --reverse)"
  else
    printf '%s\n' "Select account:"
    for option in "${accounts[@]}"; do
      printf '  %d) %s\n' "$idx" "$option"
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
  local acct="" record="" account="" email="" plan="" workspace="" state_label="" choice=""
  local account_width=7 email_width=5 plan_width=4 workspace_width=9
  local idx=1
  local -a entries=()
  local -a numbered_accounts=()

  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    record="$(_codex_account_summary_record "$acct")" || continue
    IFS="$sep" read -r account email plan workspace state_label <<<"$record"
    (( ${#account} > account_width )) && account_width=${#account}
    (( ${#email} > email_width )) && email_width=${#email}
    (( ${#plan} > plan_width )) && plan_width=${#plan}
    (( ${#workspace} > workspace_width )) && workspace_width=${#workspace}
    entries+=("$record")
  done < <(_codex_accounts_list)

  (( ${#entries[@]} > 0 )) || return 1

  if (( ${#entries[@]} == 1 )); then
    IFS="$sep" read -r account email plan workspace state_label <<<"${entries[1]}"
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
      IFS="$sep" read -r account email plan workspace state_label <<<"$record"
      display_entries+=(
        "$account"$'\t'"$(printf '%-*s  %-*s  %-*s  %-*s  %s' \
          "$account_width" "$account" \
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
    IFS="$sep" read -r account email plan workspace state_label <<<"$record"
    printf '  %d) %-*s  %-*s  %-*s  %-*s  %s\n' \
      "$idx" \
      "$account_width" "$account" \
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

  if (( ${#accounts[@]} == 0 )); then
    return 1
  fi

  if (( ${#accounts[@]} == 1 )); then
    printf '%s\n' "${accounts[1]}"
    return 0
  fi

  if command -v fzf >/dev/null 2>&1; then
    account="$(printf '%s\n' "${accounts[@]}" | fzf --prompt="$prompt" --height=10 --reverse)"
  else
    printf '%s\n' "Select logged-in account:"
    for option in "${accounts[@]}"; do
      printf '  %d) %s\n' "$idx" "$option"
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

  if _codex_account_disabled "$acct"; then
    printf 'disabled\n'
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
  local sep=$'\x1f'

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
  fi

  printf '%s%s%s%s%s%s%s%s%s\n' \
    "$acct" "$sep" \
    "${email_display:--}" "$sep" \
    "${plan:--}" "$sep" \
    "$(_codex_workspace_summary "$default_workspace" "${workspace_count:-0}")" "$sep" \
    "$status_value"
}

_codex_launch_selected_account() {
  local acct="$1"
  local state_file="$(_codex_state_dir)/last_account"

  if ! _codex_is_logged_in "$acct"; then
    echo "No logged-in Codex account: $acct"
    return 1
  fi

  print -r -- "$acct" > "$state_file"

  _codex_prepare_account_home "$acct" || return 1
  CODEX_HOME="$(_codex_account_dir "$acct")" codex --yolo
}

_codex_replace_account_login() {
  local acct="$1"
  local state_file="$(_codex_state_dir)/last_account"

  _codex_prepare_account_home "$acct" || return 1
  print -r -- "$acct" > "$state_file"
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

  if [[ -f "$state_file" && "$(cat "$state_file")" == "$acct" ]]; then
    rm -f "$state_file"
  fi

  if [[ -f "$rr_file" && "$(cat "$rr_file")" == "$acct" ]]; then
    rm -f "$rr_file"
  fi

  _codex_clear_cooldown "$acct"
  _codex_enable_account "$acct"
  _codex_clear_account_pins "$acct"
}

_codex_archive_account() {
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
    echo "All logged-in accounts are disabled or in cooldown. Run: cx list, cx enable, or cx cooldown clear <account>"
  else
    echo "No logged-in Codex accounts found. Run: cx login"
  fi
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
      which)
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
       cx doctor
       cx which
       cx warmup [account] [--show-quota]
       cx quota [account] [--json] [--refresh] [--source oauth|auto|rpc|status]
       cx share export [account ...|--all] [--output <archive.tar.gz>]
       cx share import <archive.tar.gz>
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
  cx pin-next          Pin the next round-robin logged-in account to the current shell.
  cx unpin             Clear the current shell pin and return to round robin.
  cx current           Show the current shell pin and last launched account.
  cx status            Show login status for all discovered account slots.
  cx list              Browse accounts interactively in a TTY, or print saved accounts in scripts.
  cx doctor            Validate dependencies, state paths, and account health.
  cx which             Explain which account would launch next.
  cx warmup            Send a minimal prompt to start the selected account's current 5h window.
  cx quota             Fetch live Codex quota. Defaults to the fast OAuth path unless overridden.
  cx share export      Export one or more logged-in accounts into a portable archive.
  cx share import      Import accounts from a portable archive created by cx share export.
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
  cx which
  cx warmup
  cx warmup acct_001
  cx warmup --show-quota
  cx quota
  cx quota acct_001
  cx quota acct_001 --refresh
  cx quota --source auto
  cx share export
  cx share export acct_001 --output ~/Desktop/codex-orbit-share.tar.gz
  cx share import ~/Desktop/codex-orbit-share.tar.gz
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
    account="$(_codex_next_account_name)"
    _codex_prepare_account_home "$account" || return 1
    print -r -- "$account" > "$state_file"
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
      account="$(_codex_next_account_name)"
      _codex_prepare_account_home "$account" || return 1
      print -r -- "$account" > "$state_file"
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

    mkdir -p "$(_codex_accounts_dir)" "$state_dir" "$(_codex_trash_dir)" "$(_codex_cooldown_dir)"
    if [[ -w "$(_codex_accounts_dir)" && -w "$state_dir" ]]; then
      printf '[ok] state: %s\n' "$(_codex_accounts_dir)"
    else
      echo "[fail] state: ~/.codex-accounts is not writable"
      doctor_exit=1
    fi

    while IFS= read -r acct; do
      [[ -n "$acct" ]] || continue
      accounts_count=$((accounts_count + 1))
    done < <(_codex_accounts_list)

    while IFS= read -r acct; do
      [[ -n "$acct" ]] || continue
      logged_in_count=$((logged_in_count + 1))
    done < <(_codex_logged_in_accounts)

    while IFS=$'\t' read -r acct until; do
      [[ -n "$acct" ]] || continue
      cooldown_count=$((cooldown_count + 1))
    done < <(_codex_active_cooldowns)

    printf '[info] accounts: %d total, %d logged in\n' \
      "$accounts_count" \
      "$logged_in_count"
    printf '[info] cooldowns: %d active\n' "$cooldown_count"
    printf '[info] archived: %d\n' "$(find "$(_codex_trash_dir)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"

    if [[ -f "$HOME/.codex/config.toml" ]]; then
      echo "[ok] base config: ~/.codex/config.toml found"
    else
      echo "[warn] base config: ~/.codex/config.toml not found, new accounts start with an empty config"
    fi

    return "$doctor_exit"
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
        printf '#%d %s: %s [%s]\n' "$idx" "$acct" "${status_line:-Unknown}" "$cooldown_note"
      else
        printf '#%d %s: %s\n' "$idx" "$acct" "${status_line:-Unknown}"
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
      account="${codex_args[1]}"
      if ! _codex_account_exists "$account"; then
        echo "Unknown account: $account"
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
      account="${codex_args[1]}"
      if ! _codex_is_logged_in "$account"; then
        echo "No logged-in Codex account: $account"
        return 1
      fi
    elif ! account="$(_codex_pick_logged_in_account 'Pin account> ')"; then
      echo "No logged-in Codex accounts found. Run: cx login"
      return 1
    fi

    if _codex_account_in_cooldown "$account"; then
      echo "Account is in cooldown: $account"
      return 1
    fi

    if _codex_account_disabled "$account"; then
      echo "Account is disabled: $account"
      return 1
    fi

    _codex_set_pinned_account "$account"
    print -r -- "$account" > "$state_file"
    _codex_debug "pin_set account=$account"
    echo "Pinned for this shell: $account"
    return 0
  fi

  if [[ "$mode" == "pin-next" ]]; then
    if ! account="$(_codex_round_robin_account)"; then
      _codex_no_launchable_accounts_message
      return 1
    fi
    _codex_set_pinned_account "$account"
    print -r -- "$account" > "$state_file"
    _codex_debug "pin_next account=$account"
    echo "Pinned for this shell: $account"
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
        echo "Pinned: $account ($cooldown_note)"
      else
        echo "Pinned: $account"
      fi
    else
      echo "Pinned: none"
    fi
    echo "Last launch: $(cat "$state_file" 2>/dev/null || echo none)"
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
        printf '%s\temail=%s\tplan=%s\tworkspace=%s\tworkspaces=%s\tstatus=%s' \
          "$acct" \
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
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$acct" \
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
      while IFS=$'\t' read -r acct until; do
        [[ -n "$acct" ]] || continue
        printf '%s\t%s\n' "$acct" "$(_codex_format_timestamp "$until")"
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
      _codex_clear_cooldown "$account"
      _codex_debug "cooldown_cleared account=$account"
      echo "Cooldown cleared: $account"
      return 0
    fi

    account="${codex_args[1]}"
    arg="${codex_args[2]:-}"
    if [[ -z "$account" || -z "$arg" ]]; then
      echo "Usage: cx cooldown <account> <duration>"
      echo "Durations: 30m, 5h, 1d"
      return 1
    fi

    if ! _codex_account_exists "$account"; then
      echo "Unknown account: $account"
      return 1
    fi

    if ! cooldown_note="$(_codex_set_cooldown "$account" "$arg" 2>/dev/null)"; then
      echo "Invalid duration: $arg"
      echo "Durations: 30m, 5h, 1d"
      return 1
    fi

    echo "Cooldown set: $account until $(_codex_format_timestamp "$cooldown_note")"
    return 0
  fi

  if [[ "$mode" == "share" ]]; then
    local -a share_args=()
    local share_idx=0

    arg="${codex_args[1]:-}"
    for (( share_idx = 2; share_idx <= ${#codex_args[@]}; share_idx++ )); do
      share_args+=("${codex_args[$share_idx]}")
    done

    case "$arg" in
      export)
        _codex_share_export "${share_args[@]}"
        return $?
        ;;
      import)
        _codex_share_import "${share_args[@]}"
        return $?
        ;;
      ""|--help|-h)
        echo "Usage: cx share export [account ...|--all] [--output <archive.tar.gz>]"
        echo "       cx share import <archive.tar.gz>"
        return 0
        ;;
      *)
        echo "Usage: cx share export [account ...|--all] [--output <archive.tar.gz>]"
        echo "       cx share import <archive.tar.gz>"
        return 1
        ;;
    esac
  fi

  if [[ "$mode" == "resolve" || "$mode" == "which" ]]; then
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

    printf 'Account: %s\n' "$account"
    printf 'Source: %s\n' "$source"
    metadata="$(_codex_account_metadata "$account" 2>/dev/null || true)"
    if [[ -n "$metadata" ]]; then
      local sep=$'\x1f'
      IFS="$sep" read -r email plan default_workspace workspace_count workspace_titles account_id last_refresh auth_mode <<<"$metadata"
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
      if [[ "$source" != "pinned" ]]; then
        cooldown_note="$(_codex_cooldown_note "$pinned_account" 2>/dev/null || true)"
        if [[ -n "$cooldown_note" ]]; then
          printf 'Pinned: %s (%s, skipped)\n' "$pinned_account" "$cooldown_note"
        elif ! _codex_account_exists "$pinned_account"; then
          printf 'Pinned: %s (missing, skipped)\n' "$pinned_account"
        elif ! _codex_is_logged_in "$pinned_account"; then
          printf 'Pinned: %s (not logged in, skipped)\n' "$pinned_account"
        elif _codex_account_disabled "$pinned_account"; then
          printf 'Pinned: %s (disabled, skipped)\n' "$pinned_account"
        fi
      else
        printf 'Pinned: %s\n' "$pinned_account"
      fi
    else
      echo "Pinned: none"
    fi
    return 0
  fi

  if [[ "$mode" == "warmup" ]]; then
    local target_account="" warmup_source=""
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
      if ! _codex_account_exists "$target_account"; then
        echo "Unknown account: $target_account"
        return 1
      fi
      if ! _codex_is_logged_in "$target_account"; then
        echo "No logged-in Codex account: $target_account"
        return 1
      fi
      if _codex_account_in_cooldown "$target_account"; then
        echo "Account is in cooldown: $target_account"
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

    printf 'Warming up: %s\n' "$target_account"
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
    local target_account=""
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
      if ! _codex_account_exists "$target_account"; then
        echo "Unknown account: $target_account"
        return 1
      fi

      if [[ "$output_format" == "json" ]]; then
        _codex_account_quota_snapshot "$target_account" json "$refresh_quota" "$quota_source_mode"
        return $?
      fi

      if ! quota_snapshot="$(_codex_account_quota_snapshot "$target_account" tsv "$refresh_quota" "$quota_source_mode" 2>/dev/null)"; then
        echo "Quota unavailable for $target_account"
        return 1
      fi

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

      printf 'Account: %s\n' "$(_codex_display_email "$quota_email" "$target_account")"
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

      for pid in "${quota_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
      done

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

        quota_label="$(_codex_display_email "$quota_email" "$acct")"
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
        "$account_width" 'EMAIL' \
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
  print -r -- "$account" > "$state_file"
  _codex_debug "launch account=$account source=$source arg_count=${#codex_args[@]}"

  _codex_prepare_account_home "$account" || return 1
  CODEX_HOME="$(_codex_account_dir "$account")" codex --yolo "${codex_args[@]}"
}

cx_custom() {
  cx "$@"
}

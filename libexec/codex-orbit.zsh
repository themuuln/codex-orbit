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

  mkdir -p "$account_dir"

  if [[ ! -f "$config_file" ]]; then
    if [[ -f "$HOME/.codex/config.toml" ]]; then
      cp "$HOME/.codex/config.toml" "$config_file"
    else
      : > "$config_file"
    fi
  fi

  if rg -n '^cli_auth_credentials_store\\s*=' "$config_file" >/dev/null 2>&1; then
    perl -0pi -e 's/^cli_auth_credentials_store\\s*=.*$/cli_auth_credentials_store = "file"/m' "$config_file"
  else
    printf '\ncli_auth_credentials_store = "file"\n' >> "$config_file"
  fi
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

_codex_launch_helper() {
  printf '%s/codex-orbit-launch.py\n' "$CODEX_ORBIT_LIBEXEC_DIR"
}

_codex_account_quota_snapshot() {
  local acct="$1"
  local format="${2:-tsv}"
  local py script

  py="$(_codex_python3)" || return 1
  script="$(_codex_quota_helper)"
  [[ -f "$script" ]] || return 1

  "$py" "$script" snapshot \
    --account-dir "$(_codex_account_dir "$acct")" \
    --format "$format"
}

_codex_launch_codex_ready() {
  local acct="$1"
  local initial_command="${2:-}"
  shift 2 || true

  local py script
  py="$(_codex_python3)" || return 1
  script="$(_codex_launch_helper)"
  [[ -f "$script" ]] || return 1

  "$py" "$script" \
    --account-dir "$(_codex_account_dir "$acct")" \
    --initial-command "$initial_command" \
    -- \
    codex "$@"
}

_codex_warmup_prompt() {
  printf '%s\n' "Reply with exactly READY and nothing else. Do not inspect files, run commands, or use any tools."
}

_codex_warmup_account() {
  local acct="$1"
  local output_file result prompt

  prompt="$(_codex_warmup_prompt)"
  output_file="$(mktemp "${TMPDIR:-/tmp}/codex-orbit-warmup.XXXXXX")" || return 1

  if ! CODEX_HOME="$(_codex_account_dir "$acct")" codex -a never -s read-only exec \
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

_codex_quota_window_label() {
  local seconds="${1:-}"

  case "$seconds" in
    18000) printf '5h\n' ;;
    604800) printf 'weekly\n' ;;
    *)
      if [[ -z "$seconds" ]]; then
        printf 'quota\n'
      else
        printf '%ss\n' "$seconds"
      fi
      ;;
  esac
}

_codex_quota_window_pretty_label() {
  local seconds="${1:-}"

  case "$seconds" in
    18000) printf '■ 5h limit\n' ;;
    604800) printf '■ Weekly limit\n' ;;
    *)
      if [[ -z "$seconds" ]]; then
        printf '■ Quota\n'
      else
        printf '■ %ss limit\n' "$seconds"
      fi
      ;;
  esac
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

_codex_format_time_short() {
  local epoch="$1"

  date -r "$epoch" '+%H:%M' 2>/dev/null ||
    date -d "@$epoch" '+%H:%M' 2>/dev/null ||
    printf '%s' "$epoch"
}

_codex_quota_bar() {
  local remaining="${1:-0}"
  local width="${2:-20}"
  local filled empty
  local block=$'\u2588'

  (( remaining < 0 )) && remaining=0
  (( remaining > 100 )) && remaining=100

  filled=$(( (remaining * width + 50) / 100 ))
  (( filled > width )) && filled=$width
  empty=$(( width - filled ))

  printf '[%s%s]' \
    "$(_codex_repeat_char "$block" "$filled")" \
    "$(_codex_repeat_char ' ' "$empty")"
}

_codex_quota_box_bar() {
  local remaining="${1:-0}"
  local width="${2:-10}"
  local filled empty
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

_codex_quota_remaining_value() {
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

_codex_quota_list_segment() {
  local label="$1"
  local remaining="${2:-}"
  local used="${3:-}"
  local reset_at="${4:-}"
  local value="" meter="" pct="" reset_display="-"

  if ! value="$(_codex_quota_remaining_value "$remaining" "$used" 2>/dev/null)"; then
    printf '%-6s %s %4s  %-19s' "$label" "$(_codex_quota_box_bar 0 10)" "-" "-"
    return 0
  fi

  meter="$(_codex_quota_box_bar "$value" 10)"
  pct="${value}%"
  [[ -n "$reset_at" ]] && reset_display="$(_codex_format_timestamp "$reset_at")"
  printf '%-6s %s %4s  %-19s' "$label" "$meter" "$pct" "$reset_display"
}

_codex_print_quota_meter_line() {
  local label="$1"
  local remaining="$2"
  local reset_at="${3:-}"
  local show_reset="${4:-0}"
  local border=$'\u2502'
  local note=""
  local content=""
  local inner_width=74
  local padding=1

  if [[ -n "$reset_at" && "$show_reset" == "1" ]]; then
    note=" (resets $(_codex_format_time_short "$reset_at"))"
  fi

  content="$(printf '  %-21s %s %s%% left%s' "${label}:" "$(_codex_quota_bar "$remaining")" "$remaining" "$note")"
  padding=$(( inner_width - ${#content} ))
  (( padding < 1 )) && padding=1

  printf '%s%s%s %s\n' \
    "$border" \
    "$content" \
    "$(_codex_repeat_char ' ' "$padding")" \
    "$border"
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

_codex_quota_window_summary() {
  local label="${1:-quota}"
  local remaining="${2:-}"
  local used="${3:-}"
  local reset_at="${4:-}"
  local summary=""

  if [[ -n "$remaining" ]]; then
    summary="$label ${remaining}% left"
  elif [[ -n "$used" ]]; then
    summary="$label ${used}% used"
  else
    return 1
  fi

  if [[ -n "$reset_at" ]]; then
    summary="$summary until $(_codex_format_timestamp "$reset_at")"
  fi

  printf '%s\n' "$summary"
}

_codex_print_quota_brief() {
  local snapshot="$1"
  local sep=$'\x1f'
  local source="" email="" plan="" credits_balance="" credits_has="" credits_unlimited=""
  local primary_used="" primary_remaining="" primary_reset="" primary_window=""
  local secondary_used="" secondary_remaining="" secondary_reset="" secondary_window=""
  local primary_segment="" secondary_segment="" credits_display="-"

  [[ -n "$snapshot" ]] || return 1

  IFS="$sep" read -r \
    source \
    email \
    plan \
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
    secondary_window <<<"$snapshot"

  if [[ "$credits_unlimited" == "1" ]]; then
    credits_display="unlimited"
  elif [[ "$credits_has" == "1" && -n "$credits_balance" ]]; then
    credits_display="$credits_balance"
  fi

  primary_segment="$(_codex_quota_list_segment "$(_codex_quota_window_label "$primary_window")" "$primary_remaining" "$primary_used" "$primary_reset" 2>/dev/null || true)"
  secondary_segment="$(_codex_quota_list_segment "$(_codex_quota_window_label "$secondary_window")" "$secondary_remaining" "$secondary_used" "$secondary_reset" 2>/dev/null || true)"

  [[ -n "$primary_segment" || -n "$secondary_segment" || -n "$source" || "$credits_display" != "-" ]] || return 1
  printf '%s  %s  %-8s  %s\n' \
    "$primary_segment" \
    "$secondary_segment" \
    "${source:-unknown}" \
    "$credits_display"
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
  local metadata="" email="" email_masked="" plan="" default_workspace="" workspace_count=""
  local workspace_titles="" account_id="" last_refresh="" auth_mode="" status_value=""
  local sep=$'\x1f'

  status_value="$(_codex_account_status_value "$acct")"

  metadata="$(_codex_account_metadata "$acct" 2>/dev/null || true)"
  if [[ -n "$metadata" ]]; then
    local sep=$'\x1f'
    IFS="$sep" read -r email plan default_workspace workspace_count workspace_titles account_id last_refresh auth_mode <<<"$metadata"
    email_masked="$(_codex_mask_email "$email")"
  else
    email_masked="-"
    plan="-"
    default_workspace=""
    workspace_count=0
  fi

  printf '%s%s%s%s%s%s%s%s%s\n' \
    "$acct" "$sep" \
    "${email_masked:--}" "$sep" \
    "${plan:--}" "$sep" \
    "$(_codex_workspace_summary "$default_workspace" "${workspace_count:-0}")" "$sep" \
    "$status_value"
}

_codex_account_summary_line() {
  local acct="$1"
  local sep=$'\x1f'
  local record="" account="" email="" plan="" workspace="" state_label=""

  record="$(_codex_account_summary_record "$acct")" || return 1
  IFS="$sep" read -r account email plan workspace state_label <<<"$record"
  printf '%s\t%s\t%s\t%s\t%s\n' "$account" "$email" "$plan" "$workspace" "$state_label"
}

_codex_launch_selected_account() {
  local acct="$1"
  local state_file="$(_codex_state_dir)/last_account"

  if ! _codex_is_logged_in "$acct"; then
    echo "No logged-in Codex account: $acct"
    return 1
  fi

  print -r -- "$acct" > "$state_file"

  if _codex_python3 >/dev/null 2>&1 && [[ -f "$(_codex_launch_helper)" ]]; then
    _codex_launch_codex_ready "$acct" "/status" --yolo
    return $?
  fi

  CODEX_HOME="$(_codex_account_dir "$acct")" codex --yolo "/status"
}

_codex_replace_account_login() {
  local acct="$1"
  local state_file="$(_codex_state_dir)/last_account"

  _codex_ensure_account_config "$acct"
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
  local acct="" choice="" account=""
  local -a lines=()
  local action_exit=0

  while true; do
    lines=()

    while IFS= read -r acct; do
      [[ -n "$acct" ]] || continue
      lines+=("$(_codex_account_summary_line "$acct")")
    done < <(_codex_accounts_list)

    (( ${#lines[@]} > 0 )) || {
      echo "No Codex accounts found. Run: cx login"
      return 1
    }

    choice="$(_codex_pick_line 'Account> ' "${lines[@]}")" || return 0
    account="${choice%%$'\t'*}"

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
  local metadata="" email="" email_masked="" plan="" default_workspace="" workspace_count=""
  local workspace_titles="" account_id="" last_refresh="" auth_mode="" status_value=""
  local quota_snapshot="" quota_brief="" quota_error=""
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
       cx quota [account] [--json]
       cx resolve
       cx cooldown
       cx cooldown <account> <duration>
       cx cooldown clear <account>

Commands:
  cx                   Open Codex with the next routed account and run /status once startup settles.
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
  cx quota             Fetch live Codex quota using the same API/RPC path CodexBar uses.
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
    _codex_ensure_account_config "$account"
    print -r -- "$account" > "$state_file"
    echo "Using internal account: $account"
    CODEX_HOME="$(_codex_account_dir "$account")" codex login "${codex_args[@]}"
    return $?
  fi

  if [[ "$mode" == "login-loop" ]]; then
    while true; do
      account="$(_codex_next_account_name)"
      _codex_ensure_account_config "$account"
      print -r -- "$account" > "$state_file"
      echo "Using internal account: $account"
      if ! CODEX_HOME="$(_codex_account_dir "$account")" codex login "${codex_args[@]}"; then
        return $?
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
      echo "[warn] python3: optional, required for email/workspace metadata and live quota in cx list/cx which/cx quota"
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
        email_masked="$(_codex_mask_email "$email")"
      else
        email_masked="-"
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
          "${email_masked:--}" \
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
          "${email_masked:--}" \
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
      printf 'Email: %s\n' "$(_codex_mask_email "$email")"
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

    for arg in "${codex_args[@]}"; do
      case "$arg" in
        --json)
          output_format="json"
          ;;
        *)
          if [[ -n "$target_account" ]]; then
            echo "Usage: cx quota [account] [--json]"
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

      if [[ "$output_format" == "json" ]]; then
        _codex_account_quota_snapshot "$target_account" json
        return $?
      fi

      if ! quota_snapshot="$(_codex_account_quota_snapshot "$target_account" tsv 2>/dev/null)"; then
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

      printf 'Account: %s\n' "$target_account"
      [[ -n "$quota_email" ]] && printf 'Email: %s\n' "$(_codex_mask_email "$quota_email")"
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
      local -a accounts=("${(@f)$(_codex_logged_in_accounts)}")
      local account_width=7

      for acct in "${accounts[@]}"; do
        (( ${#acct} > account_width )) && account_width=${#acct}
      done

      for acct in "${accounts[@]}"; do
        [[ -n "$acct" ]] || continue
        if ! quota_snapshot="$(_codex_account_quota_snapshot "$acct" tsv 2>/dev/null)"; then
          printf '%-*s  quota unavailable\n' "$account_width" "$acct"
          continue
        fi
        quota_brief="$(_codex_print_quota_brief "$quota_snapshot" 2>/dev/null || true)"
        if [[ -n "$quota_brief" ]]; then
          printf '%-*s  %s\n' "$account_width" "$acct" "$quota_brief"
        else
          printf '%-*s  quota available\n' "$account_width" "$acct"
        fi
      done
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

  if (( ${#codex_args[@]} == 0 )); then
    if _codex_python3 >/dev/null 2>&1 && [[ -f "$(_codex_launch_helper)" ]]; then
      _codex_debug "launch_delayed_initial_command account=$account initial_command=/status"
      _codex_launch_codex_ready "$account" "/status" --yolo
      return $?
    fi

    codex_args=("/status")
  fi

  CODEX_HOME="$(_codex_account_dir "$account")" codex --yolo "${codex_args[@]}"
}

cx_custom() {
  cx "$@"
}

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

_codex_accounts_list() {
  local accounts_dir="$HOME/.codex-accounts"

  mkdir -p "$accounts_dir"
  find "$accounts_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.state' -exec basename {} \; | sort
}

_codex_account_exists() {
  [[ -d "$HOME/.codex-accounts/$1" ]]
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
  local accounts_dir="$HOME/.codex-accounts"
  local account_dir="$accounts_dir/$acct"
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
    [[ -f "$HOME/.codex-accounts/$acct/auth.json" ]] && printf '%s\n' "$acct"
  done < <(_codex_accounts_list)
}

_codex_round_robin_account() {
  local state_dir="$HOME/.codex-accounts/.state"
  local rr_file="$state_dir/round_robin_last_account"
  local last_account="" account=""
  local -a accounts=("${(@f)$(_codex_logged_in_accounts)}")
  local idx

  mkdir -p "$state_dir"

  (( ${#accounts[@]} > 0 )) || return 1

  if (( ${#accounts[@]} == 1 )); then
    print -r -- "${accounts[1]}" > "$rr_file"
    printf '%s\n' "${accounts[1]}"
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

  print -r -- "$account" > "$rr_file"
  printf '%s\n' "$account"
}

_codex_resolve_account_for_launch() {
  local state_file="$HOME/.codex-accounts/.state/last_account"
  local account=""

  if [[ -n "${CX_CUSTOM_PINNED_ACCOUNT:-}" ]]; then
    account="$CX_CUSTOM_PINNED_ACCOUNT"
    if _codex_account_exists "$account" && [[ -f "$HOME/.codex-accounts/$account/auth.json" ]]; then
      print -r -- "$account" > "$state_file"
      printf '%s\n' "$account"
      return 0
    fi
  fi

  account="$(_codex_round_robin_account)" || return 1
  print -r -- "$account" > "$state_file"
  printf '%s\n' "$account"
}

_codex_pick_account() {
  local prompt="${1:-Codex account> }"
  local -a accounts=("${(@f)$(_codex_accounts_list)}")
  local account="" idx=1

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
    for account in "${accounts[@]}"; do
      printf '  %d) %s\n' "$idx" "$account"
      idx=$((idx + 1))
    done
    echo -n "Choice: "
    read -r idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#accounts[@]} )); then
      account="${accounts[idx]}"
    fi
  fi

  [[ -n "$account" ]] || return 1
  printf '%s\n' "$account"
}

_codex_pick_logged_in_account() {
  local prompt="${1:-Logged-in account> }"
  local -a accounts=("${(@f)$(_codex_logged_in_accounts)}")
  local account="" idx=1

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
    for account in "${accounts[@]}"; do
      printf '  %d) %s\n' "$idx" "$account"
      idx=$((idx + 1))
    done
    echo -n "Choice: "
    read -r idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#accounts[@]} )); then
      account="${accounts[idx]}"
    fi
  fi

  [[ -n "$account" ]] || return 1
  printf '%s\n' "$account"
}

cx() {
  local state_dir="$HOME/.codex-accounts/.state"
  local state_file="$state_dir/last_account"
  local account=""
  local mode="launch"
  local -a codex_args=()
  local arg

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
      --help|-h)
        cat <<'EOF'
Usage: cx [codex args...]
       cx login [codex login args...]
       cx login-loop [codex login args...]
       cx delete
       cx pin
       cx pin-next
       cx unpin
       cx current
       cx status
       cx list

Commands:
  cx                   Open Codex with the next routed account and run /status.
  cx login             Create the next hidden account slot and sign in once.
  cx login-loop        Keep creating account slots and rerunning login until stopped.
  cx delete            Interactively pick and remove a saved account.
  cx pin               Pick a logged-in account and pin it to the current shell.
  cx pin-next          Pin the next round-robin logged-in account to the current shell.
  cx unpin             Clear the current shell pin and return to round robin.
  cx current           Show the current shell pin and last launched account.
  cx status            Show login status for all discovered account slots.
  cx list              List all discovered account slot names.

Examples:
  cx
  cx            # opens Codex and runs /status
  cx "fix this bug"
  cx login
  cx login-loop
  cx delete
  cx pin
  cx pin-next
  cx unpin
  cx login --with-api-key
  cx status
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
    CODEX_HOME="$HOME/.codex-accounts/$account" codex login "${codex_args[@]}"
    return $?
  fi

  if [[ "$mode" == "login-loop" ]]; then
    while true; do
      account="$(_codex_next_account_name)"
      _codex_ensure_account_config "$account"
      print -r -- "$account" > "$state_file"
      echo "Using internal account: $account"
      if ! CODEX_HOME="$HOME/.codex-accounts/$account" codex login "${codex_args[@]}"; then
        return $?
      fi
      echo "Logged in: $account"
      echo "Press Ctrl-C to stop, or complete the next login."
    done
  fi

  if [[ "$mode" == "status" ]]; then
    local acct idx=1 status_line
    if ! _codex_accounts_list >/dev/null 2>&1 || [[ -z "$(_codex_accounts_list)" ]]; then
      echo "No Codex accounts found. Run: cx login"
      return 1
    fi
    while IFS= read -r acct; do
      [[ -n "$acct" ]] || continue
      status_line="$(CODEX_HOME="$HOME/.codex-accounts/$acct" codex login status 2>&1 || true)"
      printf '#%d %s: %s\n' "$idx" "$acct" "${status_line:-Unknown}"
      idx=$((idx + 1))
    done < <(_codex_accounts_list)
    return 0
  fi

  if [[ "$mode" == "delete" ]]; then
    if [[ -z "$(_codex_accounts_list)" ]]; then
      echo "No Codex accounts found."
      return 1
    fi

    if ! account="$(_codex_pick_account 'Delete account> ')"; then
      return 1
    fi

    echo "Delete $account? [y/N]"
    local confirm
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Cancelled."
      return 1
    fi

    rm -rf "$HOME/.codex-accounts/$account"
    if [[ -f "$state_file" && "$(cat "$state_file")" == "$account" ]]; then
      rm -f "$state_file"
    fi
    echo "Deleted: $account"
    return 0
  fi

  if [[ "$mode" == "pin" ]]; then
    if ! account="$(_codex_pick_logged_in_account 'Pin account> ')"; then
      echo "No logged-in Codex accounts found. Run: cx login"
      return 1
    fi
    export CX_CUSTOM_PINNED_ACCOUNT="$account"
    print -r -- "$account" > "$state_file"
    echo "Pinned for this shell: $account"
    return 0
  fi

  if [[ "$mode" == "pin-next" ]]; then
    if ! account="$(_codex_round_robin_account)"; then
      echo "No logged-in Codex accounts found. Run: cx login"
      return 1
    fi
    export CX_CUSTOM_PINNED_ACCOUNT="$account"
    print -r -- "$account" > "$state_file"
    echo "Pinned for this shell: $account"
    return 0
  fi

  if [[ "$mode" == "unpin" ]]; then
    unset CX_CUSTOM_PINNED_ACCOUNT
    echo "Pin cleared for this shell."
    return 0
  fi

  if [[ "$mode" == "current" ]]; then
    if [[ -n "${CX_CUSTOM_PINNED_ACCOUNT:-}" ]]; then
      echo "Pinned: $CX_CUSTOM_PINNED_ACCOUNT"
    else
      echo "Pinned: none"
    fi
    echo "Last launch: $(cat "$state_file" 2>/dev/null || echo none)"
    return 0
  fi

  if [[ "$mode" == "list" ]]; then
    _codex_accounts_list
    return 0
  fi

  if ! account="$(_codex_resolve_account_for_launch)"; then
    echo "No logged-in Codex accounts found. Run: cx login"
    return 1
  fi

  print -r -- "$account" > "$state_file"
  if (( ${#codex_args[@]} == 0 )); then
    codex_args=("/status")
  fi
  CODEX_HOME="$HOME/.codex-accounts/$account" codex --yolo "${codex_args[@]}"
}

cx_custom() {
  cx "$@"
}

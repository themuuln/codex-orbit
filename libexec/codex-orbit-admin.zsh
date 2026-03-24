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
  local accounts_count logged_in_count cooldown_count archived_count schema_version=""
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

  schema_version="$(_codex_read_state_schema_version 2>/dev/null || printf 'unknown')"
  accounts_count="$(_codex_accounts_total)"
  logged_in_count="$(_codex_logged_in_accounts_total)"
  cooldown_count="$(_codex_active_cooldowns_total)"
  archived_count="$(_codex_archived_accounts_total)"

  printf '[info] state schema: %s\n' "$schema_version"
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
  local codex_path="" rg_path="" fzf_path="" python_path="" schema_version=""
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
  schema_version="$(_codex_read_state_schema_version 2>/dev/null || printf '0')"

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
  DOCTOR_SCHEMA_VERSION="$schema_version" \
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
    "state_schema_version": env_int("DOCTOR_SCHEMA_VERSION"),
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
    printf 'state_schema_version=%s\n' "$(_codex_read_state_schema_version 2>/dev/null || printf '0')"
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

_codex_install_root() {
  printf '%s\n' "${CODEX_ORBIT_LIBEXEC_DIR:h}"
}

_codex_install_metadata_file() {
  printf '%s/install-metadata\n' "$(_codex_install_root)"
}

_codex_read_install_metadata_field() {
  local key="$1"
  local file="$(_codex_install_metadata_file)"
  local name="" value=""

  [[ -f "$file" ]] || return 1
  while IFS='=' read -r name value; do
    [[ "$name" == "$key" ]] || continue
    printf '%s\n' "$value"
    return 0
  done < "$file"
  return 1
}

_codex_current_version() {
  local repo_root="" version=""

  if repo_root="$(_codex_repo_checkout_root 2>/dev/null)"; then
    if command -v git >/dev/null 2>&1; then
      git -C "$repo_root" rev-parse HEAD 2>/dev/null && return 0
    fi
  fi

  version="$(_codex_read_install_metadata_field version 2>/dev/null || true)"
  [[ -n "$version" ]] || version="unknown"
  printf '%s\n' "$version"
}

_codex_version_short() {
  local version="$(_codex_current_version)"

  if [[ "$version" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "${version[1,12]}"
  else
    printf '%s\n' "$version"
  fi
}

_codex_print_version() {
  local method="" version="" ref="" installed_at=""

  method="$(_codex_current_install_method)"
  version="$(_codex_current_version)"
  ref="$(_codex_read_install_metadata_field ref 2>/dev/null || true)"
  installed_at="$(_codex_read_install_metadata_field installed_at 2>/dev/null || true)"

  printf 'Version: %s\n' "$(_codex_version_short)"
  printf 'Install: %s\n' "$method"
  [[ -n "$ref" ]] && printf 'Ref: %s\n' "$ref"
  [[ -n "$installed_at" ]] && printf 'Installed: %s\n' "$installed_at"
  printf 'Libexec: %s\n' "$CODEX_ORBIT_LIBEXEC_DIR"
}

_codex_remote_ref_commit() {
  local ref="${1:-main}"
  local remote_sha=""

  if command -v git >/dev/null 2>&1; then
    remote_sha="$(git ls-remote "https://github.com/themuuln/codex-orbit.git" "$ref" "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}" 2>/dev/null | awk 'NR==1 { print $1 }')"
    [[ -n "$remote_sha" ]] && {
      printf '%s\n' "$remote_sha"
      return 0
    }
  fi

  if command -v curl >/dev/null 2>&1; then
    remote_sha="$(curl -fsSL "https://api.github.com/repos/themuuln/codex-orbit/commits/$ref" 2>/dev/null | sed -n 's/^[[:space:]]*\"sha\":[[:space:]]*\"\([0-9a-f]\{40\}\)\".*/\1/p' | head -n 1)"
    [[ -n "$remote_sha" ]] && {
      printf '%s\n' "$remote_sha"
      return 0
    }
  fi

  return 1
}

_codex_update_check_repo_checkout() {
  local repo_root="" local_sha="" remote_sha=""

  repo_root="$(_codex_repo_checkout_root)" || {
    echo "Repo checkout not detected."
    return 1
  }

  if ! command -v git >/dev/null 2>&1; then
    echo "git is required for cx update --check in a repo checkout"
    return 1
  fi

  if ! git -C "$repo_root" fetch origin main --quiet; then
    echo "Unable to fetch origin/main for update check."
    return 1
  fi

  local_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  remote_sha="$(git -C "$repo_root" rev-parse refs/remotes/origin/main 2>/dev/null || true)"

  printf 'Current version: %s\n' "${local_sha[1,12]}"
  printf 'Remote version: %s\n' "${remote_sha[1,12]}"
  if [[ -n "$local_sha" && "$local_sha" == "$remote_sha" ]]; then
    echo "Status: up to date"
  else
    echo "Status: update available"
  fi
}

_codex_update_check_direct_install() {
  local ref="" local_version="" remote_version=""

  ref="$(_codex_read_install_metadata_field ref 2>/dev/null || printf 'main')"
  local_version="$(_codex_current_version)"

  printf 'Current version: %s\n' "$(_codex_version_short)"
  printf 'Ref: %s\n' "$ref"

  if [[ "$ref" == v* ]]; then
    echo "Status: pinned release"
    echo "Next: rerun the installer with a newer tag when you want to upgrade."
    return 0
  fi

  if ! remote_version="$(_codex_remote_ref_commit "$ref" 2>/dev/null)"; then
    echo "Status: unable to check remote"
    return 1
  fi

  printf 'Remote version: %s\n' "${remote_version[1,12]}"
  if [[ "$local_version" == "$remote_version" ]]; then
    echo "Status: up to date"
  else
    echo "Status: update available"
  fi
}

_codex_update_check() {
  local method=""

  method="$(_codex_current_install_method)"
  case "$method" in
    repo)
      _codex_update_check_repo_checkout
      ;;
    direct)
      _codex_update_check_direct_install
      ;;
    *)
      echo "Unknown install method."
      return 1
      ;;
  esac
}

_codex_update_self() {
  local method="" before_version="" after_version=""

  method="$(_codex_current_install_method)"
  before_version="$(_codex_version_short)"

  case "$method" in
    repo)
      echo "Update method: repo checkout"
      echo "Current version: $before_version"
      _codex_update_repo_checkout || return 1
      ;;
    direct)
      echo "Update method: direct install"
      echo "Current version: $before_version"
      _codex_update_direct_install || return 1
      ;;
    *)
      echo "Unknown install method."
      return 1
      ;;
  esac

  after_version="$(_codex_version_short)"
  echo "Updated version: $after_version"
}

_codex_default_shell_name() {
  local shell_name="${1:-${SHELL##*/}}"

  case "$shell_name" in
    zsh|bash)
      printf '%s\n' "$shell_name"
      ;;
    *)
      printf 'zsh\n'
      ;;
  esac
}

_codex_default_shell_rc() {
  local shell_name="$(_codex_default_shell_name "${1:-}")"

  case "$shell_name" in
    zsh)
      printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    bash)
      if [[ -f "$HOME/.bashrc" || ! -f "$HOME/.bash_profile" ]]; then
        printf '%s\n' "$HOME/.bashrc"
      else
        printf '%s\n' "$HOME/.bash_profile"
      fi
      ;;
  esac
}

_codex_completion_begin_marker() {
  printf '# >>> codex-orbit completions >>>\n'
}

_codex_completion_end_marker() {
  printf '# <<< codex-orbit completions <<<\n'
}

_codex_completion_source_line() {
  local shell_name="$(_codex_default_shell_name "${1:-}")"
  printf 'source <(cx completions %s)\n' "$shell_name"
}

_codex_install_completion_block() {
  local shell_name="$(_codex_default_shell_name "${1:-}")"
  local shell_rc="${2:-$(_codex_default_shell_rc "$shell_name")}"
  local begin_marker="" end_marker="" source_line=""

  begin_marker="$(_codex_completion_begin_marker)"
  end_marker="$(_codex_completion_end_marker)"
  source_line="$(_codex_completion_source_line "$shell_name")"

  mkdir -p "${shell_rc:h}" || return 1
  [[ -f "$shell_rc" ]] || : > "$shell_rc"

  if grep -Fq "$begin_marker" "$shell_rc" 2>/dev/null; then
    return 0
  fi

  if (( $(wc -c < "$shell_rc" 2>/dev/null || printf '0') > 0 )); then
    printf '\n' >> "$shell_rc"
  fi

  {
    printf '%s\n' "$begin_marker"
    printf '%s\n' "$source_line"
    printf '%s\n' "$end_marker"
  } >> "$shell_rc"
}

_codex_print_completions_zsh() {
  cat <<'EOF'
#compdef cx
local -a _cx_commands _cx_accounts
_cx_commands=(
  'login:sign into a new saved account'
  'login-loop:create accounts repeatedly'
  'delete:archive an account'
  'pin:pin an account to this shell'
  'pin-next:pin the next routed account'
  'unpin:clear the shell pin'
  'current:show pin and last launch'
  'status:show login status'
  'list:list saved accounts'
  'doctor:run health checks'
  'sync-agents:relink AGENTS.md to the shared file'
  'which:explain the next account choice'
  'warmup:start the current 5h window'
  'quota:show quota'
  'alias:manage aliases'
  'enable:enable an account'
  'disable:disable an account'
  'recover:clear disabled/cooldown state'
  'update:update codex-orbit'
  'version:show installed version'
  'init:run first-time setup'
  'support:write a support bundle'
  'share:share accounts and config'
  'resolve:print the next account id'
  'cooldown:manage cooldowns'
  'completions:print or install shell completions'
)
_cx_accounts=(${(f)"$(cx list --plain 2>/dev/null)"})
_arguments -C \
  '1:command:->command' \
  '*::arg:->arg'
case $state in
  command)
    _describe -t commands 'cx command' _cx_commands
    ;;
  arg)
    case $words[2] in
      list)
        _values 'list option' --plain --verbose --interactive
        ;;
      doctor)
        _values 'doctor option' --json
        ;;
      sync-agents)
        _describe -t accounts 'account' _cx_accounts
        ;;
      quota)
        _values 'quota option' --json --refresh --source oauth auto rpc status ${_cx_accounts[@]}
        ;;
      pin|delete|warmup|enable|disable|recover)
        _describe -t accounts 'account' _cx_accounts
        ;;
      alias)
        _values 'alias action' clear ${_cx_accounts[@]}
        ;;
      cooldown)
        _values 'cooldown action' clear ${_cx_accounts[@]}
        ;;
      update)
        _values 'update option' --check
        ;;
      init)
        _values 'init option' --login --shell --shell-rc --no-shell-changes --import --import-config
        ;;
      completions)
        if (( CURRENT == 3 )); then
          _values 'completions command' zsh bash install
        else
          _values 'shell' zsh bash --shell-rc
        fi
        ;;
      share)
        if (( CURRENT == 3 )); then
          _values 'share command' export import push config
        elif [[ "$words[3]" == "config" && CURRENT == 4 ]]; then
          _values 'config share command' export import push
        fi
        ;;
    esac
    ;;
esac
EOF
}

_codex_print_completions_bash() {
  cat <<'EOF'
_cx_complete() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  local commands="login login-loop delete pin pin-next unpin current status list doctor sync-agents which warmup quota alias enable disable recover update version init support share resolve cooldown completions"
  local accounts
  accounts="$(cx list --plain 2>/dev/null)"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    list)
      COMPREPLY=( $(compgen -W "--plain --verbose --interactive" -- "$cur") )
      ;;
    doctor)
      COMPREPLY=( $(compgen -W "--json" -- "$cur") )
      ;;
    sync-agents)
      COMPREPLY=( $(compgen -W "$accounts" -- "$cur") )
      ;;
    quota)
      COMPREPLY=( $(compgen -W "--json --refresh --source oauth auto rpc status $accounts" -- "$cur") )
      ;;
    pin|delete|warmup|enable|disable|recover)
      COMPREPLY=( $(compgen -W "$accounts" -- "$cur") )
      ;;
    alias)
      COMPREPLY=( $(compgen -W "clear $accounts" -- "$cur") )
      ;;
    cooldown)
      COMPREPLY=( $(compgen -W "clear $accounts" -- "$cur") )
      ;;
    update)
      COMPREPLY=( $(compgen -W "--check" -- "$cur") )
      ;;
    init)
      COMPREPLY=( $(compgen -W "--login --shell --shell-rc --no-shell-changes --import --import-config" -- "$cur") )
      ;;
    completions)
      COMPREPLY=( $(compgen -W "zsh bash install --shell-rc" -- "$cur") )
      ;;
    share)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "export import push config" -- "$cur") )
      elif [[ "${COMP_WORDS[2]}" == "config" && $COMP_CWORD -eq 3 ]]; then
        COMPREPLY=( $(compgen -W "export import push" -- "$cur") )
      fi
      ;;
  esac
}
complete -F _cx_complete cx
EOF
}

_codex_handle_completions() {
  local subcommand="${1:-}"
  local shell_name="" shell_rc=""

  case "$subcommand" in
    zsh)
      _codex_print_completions_zsh
      ;;
    bash)
      _codex_print_completions_bash
      ;;
    install)
      shift || true
      shell_name="$(_codex_default_shell_name)"
      while (( $# > 0 )); do
        case "$1" in
          zsh|bash)
            shell_name="$1"
            shift
            ;;
          --shell-rc)
            [[ $# -ge 2 ]] || {
              echo "Usage: cx completions install [zsh|bash] [--shell-rc <path>]"
              return 1
            }
            shell_rc="$2"
            shift 2
            ;;
          --help|-h)
            echo "Usage: cx completions install [zsh|bash] [--shell-rc <path>]"
            return 0
            ;;
          *)
            echo "Usage: cx completions install [zsh|bash] [--shell-rc <path>]"
            return 1
            ;;
        esac
      done
      [[ -n "$shell_rc" ]] || shell_rc="$(_codex_default_shell_rc "$shell_name")"
      _codex_install_completion_block "$shell_name" "$shell_rc" || return 1
      printf 'Installed %s completions in %s\n' "$shell_name" "$shell_rc"
      ;;
    ""|--help|-h)
      echo "Usage: cx completions <zsh|bash>"
      echo "       cx completions install [zsh|bash] [--shell-rc <path>]"
      ;;
    *)
      echo "Usage: cx completions <zsh|bash>"
      echo "       cx completions install [zsh|bash] [--shell-rc <path>]"
      return 1
      ;;
  esac
}

_codex_share_push() {
  local host="" remote_dir="/tmp/codex-orbit-transfer" arg=""
  local with_config=0
  local temp_dir="" accounts_archive="" config_archive="" remote_accounts="" remote_config=""
  local -a export_args=()

  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      --with-config)
        with_config=1
        shift
        ;;
      --remote-dir)
        [[ $# -ge 2 ]] || {
          echo "Usage: cx share push <ssh-host> [account ...|--all] [--with-config] [--remote-dir <dir>]"
          return 1
        }
        remote_dir="$2"
        shift 2
        ;;
      --help|-h)
        echo "Usage: cx share push <ssh-host> [account ...|--all] [--with-config] [--remote-dir <dir>]"
        return 0
        ;;
      *)
        if [[ -z "$host" ]]; then
          host="$arg"
        else
          export_args+=("$arg")
        fi
        shift
        ;;
    esac
  done

  [[ -n "$host" ]] || {
    echo "Usage: cx share push <ssh-host> [account ...|--all] [--with-config] [--remote-dir <dir>]"
    return 1
  }

  command -v ssh >/dev/null 2>&1 || {
    echo "ssh is required for cx share push"
    return 1
  }
  command -v scp >/dev/null 2>&1 || {
    echo "scp is required for cx share push"
    return 1
  }

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-orbit-push.XXXXXX")" || return 1
  accounts_archive="$temp_dir/accounts.tar.gz"
  remote_accounts="${remote_dir%/}/codex-orbit-accounts-$(_codex_now_epoch)-$$.tar.gz"

  _codex_share_export_impl "${export_args[@]}" --output "$accounts_archive" >/dev/null || {
    rm -rf "$temp_dir"
    return 1
  }

  ssh "$host" "mkdir -p ${(q)remote_dir}" || {
    rm -rf "$temp_dir"
    return 1
  }
  scp "$accounts_archive" "$host:$remote_accounts" || {
    rm -rf "$temp_dir"
    return 1
  }
  ssh "$host" "cx share import ${(q)remote_accounts}; rc=\$?; rm -f ${(q)remote_accounts}; exit \$rc" || {
    rm -rf "$temp_dir"
    return 1
  }

  if (( with_config )); then
    config_archive="$temp_dir/config.tar.gz"
    remote_config="${remote_dir%/}/codex-orbit-config-$(_codex_now_epoch)-$$.tar.gz"
    _codex_share_config_export --output "$config_archive" >/dev/null || {
      rm -rf "$temp_dir"
      return 1
    }
    scp "$config_archive" "$host:$remote_config" || {
      rm -rf "$temp_dir"
      return 1
    }
    ssh "$host" "cx share config import ${(q)remote_config}; rc=\$?; rm -f ${(q)remote_config}; exit \$rc" || {
      rm -rf "$temp_dir"
      return 1
    }
  fi

  rm -rf "$temp_dir"
  printf 'Pushed account archive to %s and imported it remotely.\n' "$host"
  if (( with_config )); then
    printf 'Pushed global config to %s and imported it remotely.\n' "$host"
  fi
}

_codex_share_config_push() {
  local host="${1:-}"
  local remote_dir="/tmp/codex-orbit-transfer"
  local temp_dir="" config_archive="" remote_config=""

  shift || true
  while (( $# > 0 )); do
    case "$1" in
      --remote-dir)
        [[ $# -ge 2 ]] || {
          echo "Usage: cx share config push <ssh-host> [--remote-dir <dir>]"
          return 1
        }
        remote_dir="$2"
        shift 2
        ;;
      --help|-h)
        echo "Usage: cx share config push <ssh-host> [--remote-dir <dir>]"
        return 0
        ;;
      *)
        echo "Usage: cx share config push <ssh-host> [--remote-dir <dir>]"
        return 1
        ;;
    esac
  done

  [[ -n "$host" ]] || {
    echo "Usage: cx share config push <ssh-host> [--remote-dir <dir>]"
    return 1
  }

  command -v ssh >/dev/null 2>&1 || {
    echo "ssh is required for cx share config push"
    return 1
  }
  command -v scp >/dev/null 2>&1 || {
    echo "scp is required for cx share config push"
    return 1
  }

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-orbit-push-config.XXXXXX")" || return 1
  config_archive="$temp_dir/config.tar.gz"
  remote_config="${remote_dir%/}/codex-orbit-config-$(_codex_now_epoch)-$$.tar.gz"

  _codex_share_config_export --output "$config_archive" >/dev/null || {
    rm -rf "$temp_dir"
    return 1
  }

  ssh "$host" "mkdir -p ${(q)remote_dir}" || {
    rm -rf "$temp_dir"
    return 1
  }
  scp "$config_archive" "$host:$remote_config" || {
    rm -rf "$temp_dir"
    return 1
  }
  ssh "$host" "cx share config import ${(q)remote_config}; rc=\$?; rm -f ${(q)remote_config}; exit \$rc" || {
    rm -rf "$temp_dir"
    return 1
  }

  rm -rf "$temp_dir"
  printf 'Pushed global config to %s and imported it remotely.\n' "$host"
}

_codex_init_command() {
  local import_archive="" import_config_archive="" shell_name="" shell_rc=""
  local run_login=0 allow_shell_changes=1 doctor_rc=0

  while (( $# > 0 )); do
    case "$1" in
      --import)
        [[ $# -ge 2 ]] || {
          echo "Usage: cx init [--import <accounts.tar.gz>] [--import-config <config.tar.gz>] [--login] [--shell <zsh|bash>] [--shell-rc <path>] [--no-shell-changes]"
          return 1
        }
        import_archive="$2"
        shift 2
        ;;
      --import-config)
        [[ $# -ge 2 ]] || {
          echo "Usage: cx init [--import <accounts.tar.gz>] [--import-config <config.tar.gz>] [--login] [--shell <zsh|bash>] [--shell-rc <path>] [--no-shell-changes]"
          return 1
        }
        import_config_archive="$2"
        shift 2
        ;;
      --login)
        run_login=1
        shift
        ;;
      --shell)
        [[ $# -ge 2 ]] || {
          echo "Usage: cx init [--import <accounts.tar.gz>] [--import-config <config.tar.gz>] [--login] [--shell <zsh|bash>] [--shell-rc <path>] [--no-shell-changes]"
          return 1
        }
        shell_name="$(_codex_default_shell_name "$2")"
        shift 2
        ;;
      --shell-rc)
        [[ $# -ge 2 ]] || {
          echo "Usage: cx init [--import <accounts.tar.gz>] [--import-config <config.tar.gz>] [--login] [--shell <zsh|bash>] [--shell-rc <path>] [--no-shell-changes]"
          return 1
        }
        shell_rc="$2"
        shift 2
        ;;
      --no-shell-changes)
        allow_shell_changes=0
        shift
        ;;
      --help|-h)
        echo "Usage: cx init [--import <accounts.tar.gz>] [--import-config <config.tar.gz>] [--login] [--shell <zsh|bash>] [--shell-rc <path>] [--no-shell-changes]"
        return 0
        ;;
      *)
        echo "Usage: cx init [--import <accounts.tar.gz>] [--import-config <config.tar.gz>] [--login] [--shell <zsh|bash>] [--shell-rc <path>] [--no-shell-changes]"
        return 1
        ;;
    esac
  done

  if [[ -n "$import_config_archive" ]]; then
    _codex_share_config_import "$import_config_archive" || return 1
  fi
  if [[ -n "$import_archive" ]]; then
    _codex_share_import "$import_archive" || return 1
  fi

  if [[ -n "$shell_name" && "$allow_shell_changes" == "1" ]]; then
    [[ -n "$shell_rc" ]] || shell_rc="$(_codex_default_shell_rc "$shell_name")"
    _codex_install_completion_block "$shell_name" "$shell_rc" || return 1
    printf 'Installed %s completions in %s\n' "$shell_name" "$shell_rc"
  fi

  _codex_doctor_text || doctor_rc=$?

  if (( run_login )); then
    local account=""
    account="$(_codex_reserve_next_account)" || return 1
    _codex_prepare_account_home "$account" || return 1
    _codex_set_last_account "$account" || return 1
    echo "Using internal account: $account"
    CODEX_HOME="$(_codex_account_dir "$account")" codex login || return $?
  fi

  printf 'Version: %s\n' "$(_codex_version_short)"
  printf 'Accounts: %s logged in\n' "$(_codex_logged_in_accounts_total)"
  if (( $(_codex_logged_in_accounts_total) == 0 )); then
    echo "Next: run 'cx login' or import accounts with 'cx share import <archive>'."
  else
    echo "Next: run 'cx which' to inspect routing, or just run 'cx'."
  fi
  if [[ -n "$shell_name" && "$allow_shell_changes" != "1" ]]; then
    printf 'Completions: run %s\n' "$(_codex_completion_source_line "$shell_name")"
  fi

  return "$doctor_rc"
}

_codex_daemon_helper() {
  printf '%s/codex-orbit-daemon.py\n' "$CODEX_ORBIT_LIBEXEC_DIR"
}

_codex_daemon_default_host() {
  printf '%s\n' "${CODEX_ORBIT_DAEMON_HOST:-127.0.0.1}"
}

_codex_daemon_default_port() {
  printf '%s\n' "${CODEX_ORBIT_DAEMON_PORT:-8787}"
}

_codex_daemon_default_url() {
  printf 'http://%s:%s\n' "$(_codex_daemon_default_host)" "$(_codex_daemon_default_port)"
}

_codex_daemon_snapshot_json() {
  local py="" script=""

  py="$(_codex_python3)" || {
    echo "python3 is required for cx daemon status"
    return 1
  }
  script="$(_codex_daemon_helper)"
  [[ -f "$script" ]] || {
    echo "daemon helper not found"
    return 1
  }

  "$py" "$script" --accounts-dir "$(_codex_accounts_dir)" snapshot --pretty
}

_codex_daemon_status_text() {
  local py="" snapshot=""

  py="$(_codex_python3)" || {
    echo "python3 is required for cx daemon status"
    return 1
  }
  snapshot="$(_codex_daemon_snapshot_json)" || return 1

  SNAPSHOT_JSON="$snapshot" "$py" - <<'PY'
import json
import os

payload = json.loads(os.environ["SNAPSHOT_JSON"])
counts = payload.get("counts", {})
print(f"Daemon URL: http://127.0.0.1:{os.environ.get('CODEX_ORBIT_DAEMON_PORT', '8787')}")
print(f"Accounts: {counts.get('accounts', 0)} total, {counts.get('logged_in', 0)} logged in")
print(f"Ready: {counts.get('ready', 0)}")
print(f"Disabled: {counts.get('disabled', 0)}")
print(f"Cooldowns: {counts.get('cooldowns', 0)}")
last_account = payload.get("last_account")
if last_account:
    print(f"Last account: {last_account}")
PY
}

_codex_daemon_serve() {
  local py="" script=""
  local host="$(_codex_daemon_default_host)"
  local port="$(_codex_daemon_default_port)"
  local arg=""

  py="$(_codex_python3)" || {
    echo "python3 is required for cx daemon serve"
    return 1
  }
  script="$(_codex_daemon_helper)"
  [[ -f "$script" ]] || {
    echo "daemon helper not found"
    return 1
  }

  while (( $# > 0 )); do
    arg="$1"
    case "$arg" in
      --host)
        [[ $# -ge 2 ]] || {
          echo "Usage: cx daemon serve [--host <host>] [--port <port>]"
          return 1
        }
        host="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || {
          echo "Usage: cx daemon serve [--host <host>] [--port <port>]"
          return 1
        }
        port="$2"
        shift 2
        ;;
      --help|-h)
        echo "Usage: cx daemon serve [--host <host>] [--port <port>]"
        return 0
        ;;
      *)
        echo "Usage: cx daemon serve [--host <host>] [--port <port>]"
        return 1
        ;;
    esac
  done

  CODEX_ORBIT_DAEMON_HOST="$host" CODEX_ORBIT_DAEMON_PORT="$port" \
    exec "$py" "$script" --accounts-dir "$(_codex_accounts_dir)" serve --host "$host" --port "$port"
}

_codex_daemon_launch_agent_label() {
  printf 'com.codex-orbit.daemon\n'
}

_codex_daemon_launch_agent_file() {
  printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$(_codex_daemon_launch_agent_label)"
}

_codex_daemon_launchctl_domain() {
  printf 'gui/%s\n' "$(id -u)"
}

_codex_daemon_cx_path() {
  local cx_path=""
  local repo_root=""

  if [[ -n "${CODEX_ORBIT_ENTRYPOINT:-}" && -x "${CODEX_ORBIT_ENTRYPOINT:-}" ]]; then
    printf '%s\n' "$CODEX_ORBIT_ENTRYPOINT"
    return 0
  fi

  cx_path="$(command -v cx 2>/dev/null || true)"
  if [[ -n "$cx_path" && "$cx_path" == /* ]]; then
    printf '%s\n' "$cx_path"
    return 0
  fi

  if repo_root="$(_codex_repo_checkout_root 2>/dev/null)"; then
    printf '%s/bin/cx\n' "$repo_root"
    return 0
  fi

  printf '%s/bin/cx\n' "$(_codex_install_root)"
}

_codex_daemon_launchd_plist() {
  local cx_path="$(_codex_daemon_cx_path)"
  local label="$(_codex_daemon_launch_agent_label)"
  local stdout_log="$HOME/Library/Logs/codex-orbit-daemon.out.log"
  local stderr_log="$HOME/Library/Logs/codex-orbit-daemon.err.log"
  local host="$(_codex_daemon_default_host)"
  local port="$(_codex_daemon_default_port)"

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
      <string>daemon</string>
      <string>serve</string>
      <string>--host</string>
      <string>${host}</string>
      <string>--port</string>
      <string>${port}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>${HOME}</string>
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
      <key>CODEX_ORBIT_DAEMON_HOST</key>
      <string>${host}</string>
      <key>CODEX_ORBIT_DAEMON_PORT</key>
      <string>${port}</string>
    </dict>
  </dict>
</plist>
EOF
}

_codex_require_macos_launchd() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "cx daemon launchd is only supported on macOS"
    return 1
  fi
  command -v launchctl >/dev/null 2>&1 || {
    echo "launchctl is required for cx daemon launchd"
    return 1
  }
}

_codex_daemon_launchd() {
  local subcommand="${1:-}"
  local plist_path="$(_codex_daemon_launch_agent_file)"
  local label="$(_codex_daemon_launch_agent_label)"
  local domain="$(_codex_daemon_launchctl_domain)"

  case "$subcommand" in
    plist)
      _codex_daemon_launchd_plist
      ;;
    install)
      _codex_require_macos_launchd || return 1
      mkdir -p "${plist_path:h}" "$HOME/Library/Logs" || return 1
      _codex_daemon_launchd_plist > "$plist_path" || return 1
      launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
      launchctl bootstrap "$domain" "$plist_path" || return 1
      launchctl kickstart -k "$domain/$label" >/dev/null 2>&1 || true
      printf 'Installed launch agent: %s\n' "$plist_path"
      ;;
    uninstall)
      _codex_require_macos_launchd || return 1
      launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
      rm -f "$plist_path"
      printf 'Removed launch agent: %s\n' "$plist_path"
      ;;
    start)
      _codex_require_macos_launchd || return 1
      launchctl kickstart -k "$domain/$label" || return 1
      printf 'Started launch agent: %s\n' "$label"
      ;;
    stop)
      _codex_require_macos_launchd || return 1
      launchctl bootout "$domain/$label" >/dev/null 2>&1 || launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 || true
      printf 'Stopped launch agent: %s\n' "$label"
      ;;
    status)
      _codex_require_macos_launchd || return 1
      launchctl print "$domain/$label"
      ;;
    ""|--help|-h)
      echo "Usage: cx daemon launchd plist"
      echo "       cx daemon launchd install"
      echo "       cx daemon launchd uninstall"
      echo "       cx daemon launchd start"
      echo "       cx daemon launchd stop"
      echo "       cx daemon launchd status"
      ;;
    *)
      echo "Usage: cx daemon launchd plist"
      echo "       cx daemon launchd install"
      echo "       cx daemon launchd uninstall"
      echo "       cx daemon launchd start"
      echo "       cx daemon launchd stop"
      echo "       cx daemon launchd status"
      return 1
      ;;
  esac
}

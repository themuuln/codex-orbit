#!/usr/bin/env python3

import argparse
import base64
import json
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
from codex_orbit_auth import auth_storage_status, load_auth_payload

from datetime import datetime, timezone

DEFAULT_STORE_DIR = pathlib.Path.home() / ".clisess"
DEFAULT_STORE_FILE = DEFAULT_STORE_DIR / "sessions.json"

PROVIDER_PRESETS = {
    "codex": {"home_var": "CODEX_HOME", "exec": "codex"},
    "vibeproxy": {"home_var": "VIBEPROXY_HOME", "exec": "vibeproxy"},
}
MIRROR_FILES = ("auth.json", "config.toml")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def load_store(path: pathlib.Path) -> dict:
    if not path.exists():
        return {"version": 1, "sessions": []}
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception as exc:
        raise SystemExit(f"failed to read store: {exc}")
    if not isinstance(data, dict):
        return {"version": 1, "sessions": []}
    data.setdefault("version", 1)
    data.setdefault("sessions", [])
    if not isinstance(data["sessions"], list):
        data["sessions"] = []
    return data


def save_store(path: pathlib.Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def ensure_parent(path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def write_json(path: pathlib.Path, payload: dict) -> None:
    ensure_parent(path)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_json(path: pathlib.Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def find_session(data: dict, provider: str, name: str):
    for item in data.get("sessions", []):
        if item.get("provider") == provider and item.get("name") == name:
            return item
    return None


def is_mirror_session(row: dict) -> bool:
    return bool(row.get("source_provider") and row.get("source_name"))


def decode_id_token(id_token: str) -> dict:
    if not id_token or "." not in id_token:
        return {}
    try:
        payload = id_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload.encode("ascii")).decode("utf-8"))
    except Exception:
        return {}


def is_business_org(org: dict) -> bool:
    if not isinstance(org, dict):
        return False
    checks = [
        org.get("is_business"),
        org.get("isBusiness"),
        org.get("business"),
        org.get("is_enterprise"),
    ]
    if any(bool(v) for v in checks):
        return True
    org_type = str(org.get("type") or org.get("workspace_type") or org.get("plan_type") or "").lower()
    return org_type in {"business", "enterprise", "team"}


def metadata_from_account_home(account_home: pathlib.Path) -> dict:
    try:
        obj = load_auth_payload(account_home)
    except Exception:
        return {}

    tokens = obj.get("tokens") or {}
    claims = decode_id_token(tokens.get("id_token") or "")
    auth_claims = claims.get("https://api.openai.com/auth") or {}
    orgs = auth_claims.get("organizations") or []

    workspace_titles = []
    default_workspace = ""
    business_workspace = ""

    for org in orgs:
        if not isinstance(org, dict):
            continue
        title = org.get("title") or org.get("name") or org.get("id") or ""
        if title and title not in workspace_titles:
            workspace_titles.append(title)
        if org.get("is_default") and not default_workspace:
            default_workspace = title
        if is_business_org(org) and not business_workspace:
            business_workspace = title

    if not default_workspace and workspace_titles:
        default_workspace = workspace_titles[0]

    return {
        "email": claims.get("email") or "",
        "plan": auth_claims.get("chatgpt_plan_type") or "",
        "workspace": default_workspace,
        "business_workspace": business_workspace,
        "workspace_count": len(workspace_titles),
        "workspace_titles": workspace_titles,
        "account_id": auth_claims.get("chatgpt_account_id") or tokens.get("account_id") or "",
    }


def resolve_provider_defaults(provider: str, home_var: str | None, exec_cmd: str | None) -> tuple[str, str]:
    preset = PROVIDER_PRESETS.get(provider, {})
    resolved_home_var = home_var or preset.get("home_var") or "CLI_HOME"
    resolved_exec = exec_cmd or preset.get("exec") or provider
    return resolved_home_var, resolved_exec


def resolve_home_path(store_path: pathlib.Path, provider: str, name: str, home: str | None) -> pathlib.Path:
    base = pathlib.Path(home).expanduser() if home else store_path.parent / "homes" / provider / name
    return base.resolve()


def record_metadata(home_path: pathlib.Path, *, extract_auth: bool, fallback: dict | None = None) -> dict:
    metadata = dict(fallback or {})
    if extract_auth and auth_storage_status(home_path)["mode"] != "missing":
        metadata.update(metadata_from_account_home(home_path))
    return metadata


def build_record(
    *,
    provider: str,
    name: str,
    home_path: pathlib.Path,
    home_var: str,
    exec_cmd: str,
    workspace: str | None,
    business_workspace: str | None,
    metadata: dict,
    source_provider: str | None = None,
    source_name: str | None = None,
) -> dict:
    return {
        "provider": provider,
        "name": name,
        "home": str(home_path),
        "home_var": home_var,
        "exec": exec_cmd,
        "workspace": workspace if workspace is not None else metadata.get("workspace", ""),
        "business_workspace": (
            business_workspace if business_workspace is not None else metadata.get("business_workspace", "")
        ),
        "email": metadata.get("email", ""),
        "plan": metadata.get("plan", ""),
        "account_id": metadata.get("account_id", ""),
        "workspace_count": metadata.get("workspace_count", 0),
        "workspace_titles": metadata.get("workspace_titles", []),
        "source_provider": source_provider or "",
        "source_name": source_name or "",
        "updated_at": now_iso(),
    }


def upsert_session(store: dict, record: dict) -> str:
    existing = find_session(store, record["provider"], record["name"])
    if existing:
        created = existing.get("created_at") or now_iso()
        existing.clear()
        existing.update(record)
        existing["created_at"] = created
        return "updated"
    record["created_at"] = now_iso()
    store["sessions"].append(record)
    return "added"


def mirror_session_home(source_home: pathlib.Path, target_home: pathlib.Path) -> None:
    target_home.mkdir(parents=True, exist_ok=True)
    for file_name in MIRROR_FILES:
        source_path = source_home / file_name
        target_path = target_home / file_name
        if source_path.exists():
            ensure_parent(target_path)
            shutil.copy2(source_path, target_path)
            try:
                os.chmod(target_path, 0o600)
            except OSError:
                pass
        elif target_path.exists():
            target_path.unlink()


def resolve_source_session(store: dict, provider: str, name: str) -> dict:
    row = find_session(store, provider, name)
    if not row:
        raise SystemExit(f"unknown session: {provider}/{name}")
    if is_mirror_session(row):
        parent = find_session(store, row.get("source_provider", ""), row.get("source_name", ""))
        if not parent:
            raise SystemExit(
                f"mirror source missing: {row.get('source_provider', '')}/{row.get('source_name', '')}"
            )
        return parent
    return row


def remove_session_home(path: str) -> None:
    home = pathlib.Path(path)
    if home.exists():
        shutil.rmtree(home)


def cmd_add(args):
    store = load_store(args.store)
    home_var, exec_cmd = resolve_provider_defaults(args.provider, args.home_var, args.exec)
    home_path = resolve_home_path(args.store, args.provider, args.name, args.home)
    metadata = record_metadata(home_path, extract_auth=args.extract_auth)
    record = build_record(
        provider=args.provider,
        name=args.name,
        home_path=home_path,
        home_var=home_var,
        exec_cmd=exec_cmd,
        workspace=args.workspace,
        business_workspace=args.business_workspace,
        metadata=metadata,
    )
    action = upsert_session(store, record)

    save_store(args.store, store)
    print(f"{action}: {args.provider}/{args.name}")


def cmd_login(args):
    store = load_store(args.store)
    home_var, exec_cmd = resolve_provider_defaults(args.provider, args.home_var, args.exec)
    home_path = resolve_home_path(args.store, args.provider, args.name, args.home)
    home_path.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env[home_var] = str(home_path)
    env["CLISESS_PROVIDER"] = args.provider
    env["CLISESS_SESSION"] = args.name

    command = args.login_command if args.login_command else [exec_cmd, "login"]
    if not command:
        raise SystemExit("no login command configured")

    result = subprocess.run(command, env=env)
    if result.returncode != 0:
        raise SystemExit(result.returncode)

    metadata = record_metadata(home_path, extract_auth=args.extract_auth)
    record = build_record(
        provider=args.provider,
        name=args.name,
        home_path=home_path,
        home_var=home_var,
        exec_cmd=exec_cmd,
        workspace=args.workspace,
        business_workspace=args.business_workspace,
        metadata=metadata,
    )
    action = upsert_session(store, record)
    save_store(args.store, store)
    print(f"{action}: {args.provider}/{args.name} ({home_path})")


def cmd_import_codex(args):
    accounts_dir = pathlib.Path(args.accounts_dir).expanduser()
    if not accounts_dir.exists():
        raise SystemExit(f"accounts dir not found: {accounts_dir}")

    imported = 0
    for entry in sorted(accounts_dir.iterdir()):
        if not entry.is_dir():
            continue
        if not entry.name.startswith("acct_"):
            continue
        if auth_storage_status(entry)["mode"] == "missing":
            continue
        add_ns = argparse.Namespace(
            store=args.store,
            provider=args.provider,
            name=entry.name,
            home=str(entry),
            home_var=args.home_var,
            exec=args.exec,
            workspace=None,
            business_workspace=None,
            extract_auth=True,
        )
        cmd_add(add_ns)
        imported += 1
    print(f"imported {imported} codex sessions")


def cli_proxy_payload_to_auth(payload: dict) -> dict:
    tokens = {
        "access_token": payload.get("access_token") or "",
        "refresh_token": payload.get("refresh_token") or "",
        "id_token": payload.get("id_token") or "",
        "account_id": payload.get("account_id") or "",
    }
    return {
        "tokens": {key: value for key, value in tokens.items() if value},
        "last_refresh": payload.get("last_refresh") or payload.get("expired") or "",
        "auth_mode": "chatgptAuthTokens",
    }


def make_import_name(payload: dict, fallback: str) -> str:
    email = (payload.get("email") or "").replace("@", "_at_").replace(".", "_")
    account_id = payload.get("account_id") or fallback
    short_id = account_id.split("-")[0]
    if email:
        return f"{email}_{short_id}"
    return fallback.replace(".", "_")


def quota_helper_path() -> pathlib.Path:
    override = os.environ.get("CLISESS_QUOTA_HELPER")
    if override:
        return pathlib.Path(override).expanduser()
    return pathlib.Path(__file__).with_name("codex-orbit-quota.py")


def session_is_deactivated(home_path: pathlib.Path) -> bool:
    helper = quota_helper_path()
    if not helper.exists():
        return False
    result = subprocess.run(
        [
            sys.executable,
            str(helper),
            "snapshot",
            "--account-dir",
            str(home_path),
            "--format",
            "tsv",
            "--source",
            "oauth",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return False
    text = f"{result.stdout}\n{result.stderr}"
    return "deactivated_workspace" in text


def remove_deactivated_sessions(store_path: pathlib.Path, provider: str | None = None) -> int:
    store = load_store(store_path)
    removed = []
    for row in list(store.get("sessions", [])):
        if provider and row.get("provider") != provider:
            continue
        if is_mirror_session(row):
            continue
        if not session_is_deactivated(pathlib.Path(row.get("home", ""))):
            continue
        removed.append((row.get("provider", ""), row.get("name", "")))

    if not removed:
        return 0

    removed_set = set(removed)
    survivors = []
    for row in store.get("sessions", []):
        key = (row.get("provider", ""), row.get("name", ""))
        source_key = (row.get("source_provider", ""), row.get("source_name", ""))
        if key in removed_set or source_key in removed_set:
            remove_session_home(row.get("home", ""))
            continue
        survivors.append(row)
    store["sessions"] = survivors
    save_store(store_path, store)
    return len(removed)


def cmd_import_cli_proxy(args):
    store = load_store(args.store)
    source_dir = pathlib.Path(args.source_dir).expanduser()
    if not source_dir.exists():
        raise SystemExit(f"source dir not found: {source_dir}")

    imported = 0
    for path in sorted(source_dir.glob("codex-*.json")):
        payload = read_json(path)
        name = args.name_prefix + make_import_name(payload, path.stem)
        home_var, exec_cmd = resolve_provider_defaults("codex", None, None)
        home_path = resolve_home_path(args.store, "codex", name, None)
        home_path.mkdir(parents=True, exist_ok=True)
        write_json(home_path / "auth.json", cli_proxy_payload_to_auth(payload))
        metadata = record_metadata(home_path, extract_auth=True, fallback={"email": payload.get("email", "")})
        record = build_record(
            provider="codex",
            name=name,
            home_path=home_path,
            home_var=home_var,
            exec_cmd=exec_cmd,
            workspace=None,
            business_workspace=None,
            metadata=metadata,
        )
        upsert_session(store, record)
        imported += 1

    save_store(args.store, store)
    print(f"imported {imported} cli-proxy account(s)")


def cmd_cleanup_deactivated(args):
    removed = remove_deactivated_sessions(args.store, args.provider)
    print(f"removed {removed} deactivated session(s)")


def sessions_filtered(store: dict, provider: str | None):
    rows = store.get("sessions", [])
    if provider:
        rows = [r for r in rows if r.get("provider") == provider]
    return sorted(rows, key=lambda r: (r.get("provider", ""), r.get("name", "")))


def files_match(path_a: pathlib.Path, path_b: pathlib.Path) -> bool:
    try:
        return path_a.read_bytes() == path_b.read_bytes()
    except OSError:
        return False


def session_status_row(store: dict, row: dict) -> dict:
    home_path = pathlib.Path(row.get("home", ""))
    home_exists = home_path.exists()
    auth_mode = auth_storage_status(home_path)["mode"] if home_exists else "missing"
    kind = "mirror" if is_mirror_session(row) else "canonical"
    source = ""

    if not home_exists:
        state = "home-missing"
    elif kind == "canonical":
        state = "ready" if auth_mode != "missing" else "auth-missing"
    else:
        source = f"{row.get('source_provider', '')}/{row.get('source_name', '')}"
        parent = find_session(store, row.get("source_provider", ""), row.get("source_name", ""))
        if not parent:
            state = "source-missing"
        else:
            source_home = pathlib.Path(parent.get("home", ""))
            if not source_home.exists():
                state = "source-home-missing"
            else:
                state = "synced"
                for file_name in MIRROR_FILES:
                    source_path = source_home / file_name
                    target_path = home_path / file_name
                    if source_path.exists() != target_path.exists():
                        state = "stale"
                        break
                    if source_path.exists() and not files_match(source_path, target_path):
                        state = "stale"
                        break
                if state == "synced" and auth_mode == "missing":
                    state = "auth-missing"

    status = dict(row)
    status.update(
        {
            "kind": kind,
            "state": state,
            "auth_mode": auth_mode,
            "source": source,
            "home_exists": home_exists,
        }
    )
    return status


def render_env_lines(row: dict) -> list[str]:
    env_lines = [
        f'export {row.get("home_var", "CLI_HOME")}={shlex.quote(row.get("home", ""))}',
        f'export CLISESS_PROVIDER={shlex.quote(row.get("provider", ""))}',
        f'export CLISESS_SESSION={shlex.quote(row.get("name", ""))}',
    ]
    workspace = row.get("workspace") or ""
    business = row.get("business_workspace") or ""
    provider_prefix = row.get("provider", "").upper().replace("-", "_")
    if workspace:
        env_lines.append(f'export CLISESS_WORKSPACE={shlex.quote(workspace)}')
        env_lines.append(f'export {provider_prefix}_WORKSPACE={shlex.quote(workspace)}')
    if business:
        env_lines.append(f'export CLISESS_BUSINESS_WORKSPACE={shlex.quote(business)}')
        env_lines.append(f'export {provider_prefix}_BUSINESS_WORKSPACE={shlex.quote(business)}')
    return env_lines


def sync_source_targets(store_path: pathlib.Path, source: dict, target_specs: list[str]) -> list[dict]:
    store = load_store(store_path)
    requested_targets = []
    if target_specs:
        for entry in target_specs:
            provider, _, name = entry.partition(":")
            provider = provider.strip()
            name = (name or source.get("name", "")).strip()
            if not provider or not name:
                raise SystemExit(f"invalid target spec: {entry}")
            requested_targets.append((provider, name))

    targets = []
    if requested_targets:
        for provider, name in requested_targets:
            if provider == source.get("provider") and name == source.get("name"):
                raise SystemExit(f"target cannot be the same as the source session: {provider}/{name}")
            row = find_session(store, provider, name)
            if not row:
                link_session(
                    store_path=store_path,
                    source=source,
                    provider=provider,
                    name=name,
                    home=None,
                    home_var=None,
                    exec_cmd=None,
                    workspace=None,
                    business_workspace=None,
                    extract_auth=True,
                )
                store = load_store(store_path)
                row = find_session(store, provider, name)
            if not row:
                raise SystemExit(f"failed to resolve target session: {provider}/{name}")
            if not is_mirror_session(row):
                raise SystemExit(f"target session exists and is not a mirror: {provider}/{name}")
            if row.get("source_provider") != source.get("provider") or row.get("source_name") != source.get("name"):
                raise SystemExit(
                    "target mirror points at "
                    f"{row.get('source_provider', '')}/{row.get('source_name', '')}, "
                    f"not {source.get('provider', '')}/{source.get('name', '')}"
                )
            targets.append(row)
    else:
        targets = [
            row
            for row in store.get("sessions", [])
            if row.get("source_provider") == source.get("provider") and row.get("source_name") == source.get("name")
        ]

    for row in targets:
        mirror_session_home(pathlib.Path(source.get("home", "")), pathlib.Path(row.get("home", "")))
    return targets


def cmd_list(args):
    store = load_store(args.store)
    rows = sessions_filtered(store, args.provider)
    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
        return
    if not rows:
        print("no sessions")
        return

    headers = ["PROVIDER", "SESSION", "HOME_VAR", "WORKSPACE", "BUSINESS_WS", "HOME"]
    widths = [len(h) for h in headers]
    rendered = []
    for r in rows:
        row = [
            r.get("provider", ""),
            r.get("name", ""),
            r.get("home_var", ""),
            r.get("workspace", "") or "-",
            r.get("business_workspace", "") or "-",
            r.get("home", ""),
        ]
        rendered.append(row)
        widths = [max(widths[i], len(str(row[i]))) for i in range(len(headers))]

    fmt = "  ".join([f"{{:{w}}}" for w in widths])
    print(fmt.format(*headers))
    for row in rendered:
        print(fmt.format(*row))


def cmd_status(args):
    store = load_store(args.store)
    rows = [session_status_row(store, row) for row in sessions_filtered(store, args.provider)]
    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
        return
    if not rows:
        print("no sessions")
        return

    headers = ["PROVIDER", "SESSION", "KIND", "STATE", "AUTH", "SOURCE", "HOME"]
    widths = [len(h) for h in headers]
    rendered = []
    for r in rows:
        row = [
            r.get("provider", ""),
            r.get("name", ""),
            r.get("kind", ""),
            r.get("state", ""),
            r.get("auth_mode", ""),
            r.get("source", "") or "-",
            r.get("home", ""),
        ]
        rendered.append(row)
        widths = [max(widths[i], len(str(row[i]))) for i in range(len(headers))]

    fmt = "  ".join([f"{{:{w}}}" for w in widths])
    print(fmt.format(*headers))
    for row in rendered:
        print(fmt.format(*row))


def doctor_issue_for_status(row: dict) -> dict | None:
    key = f"{row.get('provider', '')}/{row.get('name', '')}"
    state = row.get("state", "")
    if state == "stale":
        source = row.get("source", "")
        target = f"{row.get('provider', '')}:{row.get('name', '')}"
        return {
            "provider": row.get("provider", ""),
            "name": row.get("name", ""),
            "code": "stale-mirror",
            "message": f"{key} is stale vs {source}",
            "fix": f"cxs sync {source} --to {target}",
        }
    if state == "source-missing":
        return {
            "provider": row.get("provider", ""),
            "name": row.get("name", ""),
            "code": "source-missing",
            "message": f"{key} points to a missing source session",
            "fix": f"cxs remove {row.get('provider', '')} {row.get('name', '')}",
        }
    if state == "source-home-missing":
        source = row.get("source", "")
        provider, _, name = source.partition("/")
        return {
            "provider": row.get("provider", ""),
            "name": row.get("name", ""),
            "code": "source-home-missing",
            "message": f"{key} points to a source home that is missing on disk",
            "fix": f"cxs login {provider} {name}",
        }
    if state == "home-missing":
        return {
            "provider": row.get("provider", ""),
            "name": row.get("name", ""),
            "code": "home-missing",
            "message": f"{key} home directory is missing",
            "fix": f"cxs remove {row.get('provider', '')} {row.get('name', '')}",
        }
    if state == "auth-missing":
        return {
            "provider": row.get("provider", ""),
            "name": row.get("name", ""),
            "code": "auth-missing",
            "message": f"{key} has no usable auth payload",
            "fix": f"cxs login {row.get('provider', '')} {row.get('name', '')}",
        }
    return None


def collect_doctor_report(store: dict, provider: str | None) -> dict:
    rows = [session_status_row(store, row) for row in sessions_filtered(store, provider)]
    issues = []
    home_index: dict[str, list[tuple[str, str]]] = {}

    for row in rows:
        issue = doctor_issue_for_status(row)
        if issue:
            issues.append(issue)
        home = row.get("home", "")
        if home:
            home_index.setdefault(home, []).append((row.get("provider", ""), row.get("name", "")))

    for home, sessions in sorted(home_index.items()):
        if len(sessions) < 2:
            continue
        labels = [f"{provider_name}/{session_name}" for provider_name, session_name in sessions]
        for provider_name, session_name in sessions:
            issues.append(
                {
                    "provider": provider_name,
                    "name": session_name,
                    "code": "home-collision",
                    "message": f"{provider_name}/{session_name} shares home {home} with {', '.join(labels)}",
                    "fix": f"cxs remove {provider_name} {session_name}",
                }
            )

    issues.sort(key=lambda item: (item.get("provider", ""), item.get("name", ""), item.get("code", "")))
    return {
        "healthy": not issues,
        "counts": {
            "sessions": len(rows),
            "canonical": sum(1 for row in rows if row.get("kind") == "canonical"),
            "mirrors": sum(1 for row in rows if row.get("kind") == "mirror"),
            "issues": len(issues),
        },
        "issues": issues,
        "sessions": rows,
    }


def cmd_doctor(args):
    store = load_store(args.store)
    report = collect_doctor_report(store, args.provider)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        counts = report["counts"]
        print(
            "sessions={sessions} canonical={canonical} mirrors={mirrors} issues={issues}".format(
                **counts,
            )
        )
        if report["healthy"]:
            print("healthy")
        else:
            for issue in report["issues"]:
                print(
                    f"{issue.get('code', '')}: {issue.get('message', '')} | fix: {issue.get('fix', '')}"
                )
    if args.strict and not report["healthy"]:
        raise SystemExit(1)


def get_session_or_exit(args):
    store = load_store(args.store)
    row = find_session(store, args.provider, args.name)
    if not row:
        raise SystemExit(f"unknown session: {args.provider}/{args.name}")
    return row


def cmd_env(args):
    store = load_store(args.store)
    row = get_session_or_exit(args)
    if is_mirror_session(row):
        source = resolve_source_session(store, row.get("source_provider", ""), row.get("source_name", ""))
        mirror_session_home(pathlib.Path(source.get("home", "")), pathlib.Path(row.get("home", "")))
    print("\n".join(render_env_lines(row)))


def cmd_use(args):
    store = load_store(args.store)
    row = find_session(store, args.provider, args.name)
    if not row:
        raise SystemExit(f"unknown session: {args.provider}/{args.name}")

    if is_mirror_session(row):
        source = resolve_source_session(store, row.get("source_provider", ""), row.get("source_name", ""))
        mirror_session_home(pathlib.Path(source.get("home", "")), pathlib.Path(row.get("home", "")))
        if args.targets:
            sync_source_targets(args.store, source, args.targets)
    else:
        sync_source_targets(args.store, row, args.targets)

    print("\n".join(render_env_lines(row)))


def cmd_run(args):
    row = get_session_or_exit(args)
    if is_mirror_session(row):
        store = load_store(args.store)
        source = resolve_source_session(store, row.get("source_provider", ""), row.get("source_name", ""))
        mirror_session_home(pathlib.Path(source.get("home", "")), pathlib.Path(row.get("home", "")))
    env = os.environ.copy()
    env[row.get("home_var", "CLI_HOME")] = row.get("home", "")
    env["CLISESS_PROVIDER"] = row.get("provider", "")
    env["CLISESS_SESSION"] = row.get("name", "")

    workspace = row.get("workspace") or ""
    business = row.get("business_workspace") or ""
    provider_prefix = row.get("provider", "").upper().replace("-", "_")
    if workspace:
        env["CLISESS_WORKSPACE"] = workspace
        env[f"{provider_prefix}_WORKSPACE"] = workspace
    if business:
        env["CLISESS_BUSINESS_WORKSPACE"] = business
        env[f"{provider_prefix}_BUSINESS_WORKSPACE"] = business

    command = args.run_command if args.run_command else [row.get("exec") or row.get("provider")]
    if not command:
        raise SystemExit("no command configured")

    result = subprocess.run(command, env=env)
    raise SystemExit(result.returncode)


def cmd_remove(args):
    store = load_store(args.store)
    target = find_session(store, args.provider, args.name)
    if not target:
        raise SystemExit(f"unknown session: {args.provider}/{args.name}")
    before = len(store.get("sessions", []))
    store["sessions"] = [
        r
        for r in store.get("sessions", [])
        if not (
            (r.get("provider") == args.provider and r.get("name") == args.name)
            or (r.get("source_provider") == args.provider and r.get("source_name") == args.name)
        )
    ]
    if len(store["sessions"]) == before:
        raise SystemExit(f"unknown session: {args.provider}/{args.name}")
    remove_session_home(target.get("home", ""))
    save_store(args.store, store)
    print(f"removed: {args.provider}/{args.name}")


def link_session(
    *,
    store_path: pathlib.Path,
    source: dict,
    provider: str,
    name: str,
    home: str | None,
    home_var: str | None,
    exec_cmd: str | None,
    workspace: str | None,
    business_workspace: str | None,
    extract_auth: bool,
) -> str:
    store = load_store(store_path)
    home_var, exec_cmd = resolve_provider_defaults(provider, home_var, exec_cmd)
    home_path = resolve_home_path(store_path, provider, name, home)
    mirror_session_home(pathlib.Path(source.get("home", "")), home_path)
    metadata = record_metadata(
        home_path,
        extract_auth=extract_auth,
        fallback={
            "email": source.get("email", ""),
            "plan": source.get("plan", ""),
            "account_id": source.get("account_id", ""),
            "workspace": source.get("workspace", ""),
            "business_workspace": source.get("business_workspace", ""),
            "workspace_count": source.get("workspace_count", 0),
            "workspace_titles": source.get("workspace_titles", []),
        },
    )
    record = build_record(
        provider=provider,
        name=name,
        home_path=home_path,
        home_var=home_var,
        exec_cmd=exec_cmd,
        workspace=workspace,
        business_workspace=business_workspace,
        metadata=metadata,
        source_provider=source.get("provider", ""),
        source_name=source.get("name", ""),
    )
    action = upsert_session(store, record)
    save_store(store_path, store)
    return action


def cmd_link(args):
    store = load_store(args.store)
    source = resolve_source_session(store, args.source_provider, args.source_name)
    action = link_session(
        store_path=args.store,
        source=source,
        provider=args.provider,
        name=args.name,
        home=args.home,
        home_var=args.home_var,
        exec_cmd=args.exec,
        workspace=args.workspace,
        business_workspace=args.business_workspace,
        extract_auth=args.extract_auth,
    )
    print(f"{action}: {args.provider}/{args.name} -> {args.source_provider}/{args.source_name}")


def cmd_sync(args):
    store = load_store(args.store)
    source = resolve_source_session(store, args.source_provider, args.source_name)
    targets = sync_source_targets(args.store, source, args.targets)
    if not targets:
        print(f"no mirror targets for {source.get('provider')}/{source.get('name')}")
        return

    print(f"synced {len(targets)} target(s) from {source.get('provider')}/{source.get('name')}")


def build_parser():
    parser = argparse.ArgumentParser(
        prog=os.environ.get("CLISESS_PROG") or pathlib.Path(sys.argv[0]).name,
        description="Standalone multi-session launcher for Codex and other CLIs (e.g. vibeproxy).",
    )
    parser.add_argument(
        "--store",
        type=pathlib.Path,
        default=DEFAULT_STORE_FILE,
        help=f"session store path (default: {DEFAULT_STORE_FILE})",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    add = sub.add_parser("add", help="add or update a saved session")
    add.add_argument("provider", help="provider name (codex, vibeproxy, or custom)")
    add.add_argument("name", help="session name")
    add.add_argument("--home", required=True, help="session home directory")
    add.add_argument("--home-var", help="home env var name (defaults by provider)")
    add.add_argument("--exec", help="default executable (defaults by provider)")
    add.add_argument("--workspace", help="workspace name override")
    add.add_argument("--business-workspace", help="business workspace name override")
    add.add_argument("--extract-auth", action="store_true", help="extract metadata from <home>/auth.json")
    add.set_defaults(func=cmd_add)

    login = sub.add_parser("login", help="create a session home, run login, and save the session")
    login.add_argument("provider", help="provider name (codex, vibeproxy, or custom)")
    login.add_argument("name", help="session name")
    login.add_argument("--home", help="session home directory (default: <store-dir>/homes/<provider>/<name>)")
    login.add_argument("--home-var", help="home env var name (defaults by provider)")
    login.add_argument("--exec", help="default executable (defaults by provider)")
    login.add_argument("--workspace", help="workspace name override")
    login.add_argument("--business-workspace", help="business workspace name override")
    login.add_argument(
        "--extract-auth",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="extract metadata from provider auth after login (default: true)",
    )
    login.add_argument("login_command", nargs=argparse.REMAINDER, help="login command override (use -- <cmd ...>)")
    login.set_defaults(func=cmd_login)

    imp = sub.add_parser("import-codex", help="import sessions from ~/.codex-accounts")
    imp.add_argument("--accounts-dir", default=str(pathlib.Path.home() / ".codex-accounts"))
    imp.add_argument("--provider", default="codex")
    imp.add_argument("--home-var", help="override home env var")
    imp.add_argument("--exec", help="override executable")
    imp.set_defaults(func=cmd_import_codex)

    imp_proxy = sub.add_parser("import-cli-proxy", help="import codex auth exports from ~/.cli-proxy-api")
    imp_proxy.add_argument("--source-dir", default=str(pathlib.Path.home() / ".cli-proxy-api"))
    imp_proxy.add_argument("--name-prefix", default="")
    imp_proxy.set_defaults(func=cmd_import_cli_proxy)

    ls = sub.add_parser("list", help="list saved sessions")
    ls.add_argument("--provider", help="filter by provider")
    ls.add_argument("--json", action="store_true")
    ls.set_defaults(func=cmd_list)

    status = sub.add_parser("status", help="show session health, auth mode, and mirror sync state")
    status.add_argument("--provider", help="filter by provider")
    status.add_argument("--json", action="store_true")
    status.set_defaults(func=cmd_status)

    doctor = sub.add_parser("doctor", help="summarize broken sessions and mirror drift")
    doctor.add_argument("--provider", help="filter by provider")
    doctor.add_argument("--json", action="store_true")
    doctor.add_argument("--strict", action="store_true", help="exit 1 when issues are found")
    doctor.set_defaults(func=cmd_doctor)

    env = sub.add_parser("env", help="print export lines for a session")
    env.add_argument("provider")
    env.add_argument("name")
    env.set_defaults(func=cmd_env)

    use = sub.add_parser("use", help="sync linked targets for a session and print export lines to activate it")
    use.add_argument("provider")
    use.add_argument("name")
    use.add_argument(
        "--to",
        dest="targets",
        action="append",
        default=[],
        help="target provider or provider:name to create/update before activation (can be repeated)",
    )
    use.set_defaults(func=cmd_use)

    run = sub.add_parser("run", help="run a CLI with selected session env")
    run.add_argument("provider")
    run.add_argument("name")
    run.add_argument("run_command", nargs=argparse.REMAINDER, help="command override (use -- <cmd ...>)")
    run.set_defaults(func=cmd_run)

    link = sub.add_parser("link", help="reuse one saved session home under another provider/session name")
    link.add_argument("source_provider")
    link.add_argument("source_name")
    link.add_argument("provider")
    link.add_argument("name")
    link.add_argument("--home", help="target home directory (defaults to <store-dir>/homes/<provider>/<name>)")
    link.add_argument("--home-var", help="home env var name for the linked provider")
    link.add_argument("--exec", help="default executable for the linked provider")
    link.add_argument("--workspace", help="workspace name override")
    link.add_argument("--business-workspace", help="business workspace name override")
    link.add_argument(
        "--extract-auth",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="extract metadata from the shared home when available (default: true)",
    )
    link.set_defaults(func=cmd_link)

    sync = sub.add_parser("sync", help="sync a source session into linked provider homes")
    sync.add_argument("source_provider")
    sync.add_argument("source_name")
    sync.add_argument(
        "--to",
        dest="targets",
        action="append",
        default=[],
        help="target provider or provider:name (can be repeated)",
    )
    sync.set_defaults(func=cmd_sync)

    cleanup = sub.add_parser("cleanup-deactivated", help="remove sessions that now return deactivated_workspace")
    cleanup.add_argument("--provider", help="limit cleanup to one provider")
    cleanup.set_defaults(func=cmd_cleanup_deactivated)

    rm = sub.add_parser("remove", help="remove a saved session")
    rm.add_argument("provider")
    rm.add_argument("name")
    rm.set_defaults(func=cmd_remove)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if getattr(args, "subcommand", None) == "run" and args.run_command and args.run_command[0] == "--":
        args.run_command = args.run_command[1:]
    if getattr(args, "subcommand", None) == "login" and args.login_command and args.login_command[0] == "--":
        args.login_command = args.login_command[1:]

    args.func(args)


if __name__ == "__main__":
    main()

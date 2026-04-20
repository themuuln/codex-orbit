#!/usr/bin/env python3

import argparse
import base64
import json
import os
import pathlib
import shlex
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


def find_session(data: dict, provider: str, name: str):
    for item in data.get("sessions", []):
        if item.get("provider") == provider and item.get("name") == name:
            return item
    return None


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


def metadata_from_auth(auth_path: pathlib.Path) -> dict:
    try:
        obj = load_auth_payload(auth_path.parent)
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


def cmd_add(args):
    store = load_store(args.store)
    existing = find_session(store, args.provider, args.name)

    home_var, exec_cmd = resolve_provider_defaults(args.provider, args.home_var, args.exec)
    home_path = str(pathlib.Path(args.home).expanduser().resolve())

    metadata = {}
    auth_file = pathlib.Path(home_path) / "auth.json"
    if args.extract_auth:
        metadata = metadata_from_auth(auth_file)

    record = {
        "provider": args.provider,
        "name": args.name,
        "home": home_path,
        "home_var": home_var,
        "exec": exec_cmd,
        "workspace": args.workspace if args.workspace is not None else metadata.get("workspace", ""),
        "business_workspace": (
            args.business_workspace
            if args.business_workspace is not None
            else metadata.get("business_workspace", "")
        ),
        "email": metadata.get("email", ""),
        "plan": metadata.get("plan", ""),
        "account_id": metadata.get("account_id", ""),
        "workspace_count": metadata.get("workspace_count", 0),
        "workspace_titles": metadata.get("workspace_titles", []),
        "updated_at": now_iso(),
    }

    if existing:
        created = existing.get("created_at") or now_iso()
        existing.clear()
        existing.update(record)
        existing["created_at"] = created
        action = "updated"
    else:
        record["created_at"] = now_iso()
        store["sessions"].append(record)
        action = "added"

    save_store(args.store, store)
    print(f"{action}: {args.provider}/{args.name}")


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


def sessions_filtered(store: dict, provider: str | None):
    rows = store.get("sessions", [])
    if provider:
        rows = [r for r in rows if r.get("provider") == provider]
    return sorted(rows, key=lambda r: (r.get("provider", ""), r.get("name", "")))


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


def get_session_or_exit(args):
    store = load_store(args.store)
    row = find_session(store, args.provider, args.name)
    if not row:
        raise SystemExit(f"unknown session: {args.provider}/{args.name}")
    return row


def cmd_env(args):
    row = get_session_or_exit(args)
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

    print("\n".join(env_lines))


def cmd_run(args):
    row = get_session_or_exit(args)
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
    before = len(store.get("sessions", []))
    store["sessions"] = [
        r for r in store.get("sessions", []) if not (r.get("provider") == args.provider and r.get("name") == args.name)
    ]
    if len(store["sessions"]) == before:
        raise SystemExit(f"unknown session: {args.provider}/{args.name}")
    save_store(args.store, store)
    print(f"removed: {args.provider}/{args.name}")


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

    imp = sub.add_parser("import-codex", help="import sessions from ~/.codex-accounts")
    imp.add_argument("--accounts-dir", default=str(pathlib.Path.home() / ".codex-accounts"))
    imp.add_argument("--provider", default="codex")
    imp.add_argument("--home-var", help="override home env var")
    imp.add_argument("--exec", help="override executable")
    imp.set_defaults(func=cmd_import_codex)

    ls = sub.add_parser("list", help="list saved sessions")
    ls.add_argument("--provider", help="filter by provider")
    ls.add_argument("--json", action="store_true")
    ls.set_defaults(func=cmd_list)

    env = sub.add_parser("env", help="print export lines for a session")
    env.add_argument("provider")
    env.add_argument("name")
    env.set_defaults(func=cmd_env)

    run = sub.add_parser("run", help="run a CLI with selected session env")
    run.add_argument("provider")
    run.add_argument("name")
    run.add_argument("run_command", nargs=argparse.REMAINDER, help="command override (use -- <cmd ...>)")
    run.set_defaults(func=cmd_run)

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

    args.func(args)


if __name__ == "__main__":
    main()

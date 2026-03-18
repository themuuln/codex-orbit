#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


SEP = "\x1f"


def read_text(path: pathlib.Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None


def list_accounts(accounts_dir: pathlib.Path) -> list[str]:
    if not accounts_dir.exists():
        return []
    return sorted(
        entry.name
        for entry in accounts_dir.iterdir()
        if entry.is_dir() and not entry.name.startswith(".")
    )


def read_aliases(state_dir: pathlib.Path) -> dict[str, str]:
    alias_dir = state_dir / "aliases"
    aliases: dict[str, str] = {}
    if not alias_dir.exists():
        return aliases
    for path in sorted(alias_dir.glob("*.alias")):
        value = read_text(path)
        if value:
            aliases[path.stem] = value
    return aliases


def read_disabled(state_dir: pathlib.Path) -> dict[str, str]:
    disabled_dir = state_dir / "disabled"
    disabled: dict[str, str] = {}
    if not disabled_dir.exists():
        return disabled
    for path in sorted(disabled_dir.glob("*.disabled")):
        disabled[path.stem] = read_text(path) or ""
    return disabled


def read_cooldowns(state_dir: pathlib.Path, now_epoch: int) -> dict[str, int]:
    cooldown_dir = state_dir / "cooldowns"
    cooldowns: dict[str, int] = {}
    if not cooldown_dir.exists():
        return cooldowns
    for path in sorted(cooldown_dir.glob("*.until")):
        raw = read_text(path)
        if not raw:
            continue
        try:
            until = int(raw)
        except ValueError:
            continue
        if until > now_epoch:
            cooldowns[path.stem] = until
    return cooldowns


def load_quota_snapshot(state_dir: pathlib.Path, account: str) -> dict[str, Any] | None:
    cache_dir = state_dir / "quota-cache"
    if not cache_dir.exists():
        return None

    snapshot_path: pathlib.Path | None = None
    for candidate in sorted(cache_dir.glob(f"{account}.*.tsv")):
        snapshot_path = candidate
        break
    if snapshot_path is None:
        return None

    raw = read_text(snapshot_path)
    if not raw:
        return None

    fields = raw.split(SEP)
    if len(fields) < 14:
        return None

    return {
        "source": fields[0],
        "email": fields[1],
        "plan": fields[2],
        "credits_balance": fields[3],
        "credits_has": fields[4] == "1",
        "credits_unlimited": fields[5] == "1",
        "primary_used": fields[6],
        "primary_remaining": fields[7],
        "primary_reset": fields[8],
        "primary_window": fields[9],
        "secondary_used": fields[10],
        "secondary_remaining": fields[11],
        "secondary_reset": fields[12],
        "secondary_window": fields[13],
        "cache_file": snapshot_path.name,
    }


def account_status(
    account: str,
    account_dir: pathlib.Path,
    aliases: dict[str, str],
    disabled: dict[str, str],
    cooldowns: dict[str, int],
    state_dir: pathlib.Path,
) -> dict[str, Any]:
    logged_in = (account_dir / "auth.json").is_file()
    alias = aliases.get(account)
    disabled_reason = disabled.get(account)
    cooldown_until = cooldowns.get(account)

    if disabled_reason is not None:
        status = "disabled"
    elif cooldown_until is not None:
        status = "cooldown"
    elif logged_in:
        status = "ready"
    else:
        status = "not_logged_in"

    return {
        "id": account,
        "alias": alias,
        "display_name": f"{alias} ({account})" if alias else account,
        "logged_in": logged_in,
        "disabled": disabled_reason is not None,
        "disabled_reason": disabled_reason,
        "cooldown_until": cooldown_until,
        "status": status,
        "quota": load_quota_snapshot(state_dir, account),
    }


def build_snapshot(accounts_dir: pathlib.Path) -> dict[str, Any]:
    now_epoch = int(time.time())
    state_dir = accounts_dir / ".state"
    aliases = read_aliases(state_dir)
    disabled = read_disabled(state_dir)
    cooldowns = read_cooldowns(state_dir, now_epoch)
    accounts: list[dict[str, Any]] = []

    for account in list_accounts(accounts_dir):
        accounts.append(
            account_status(
                account,
                accounts_dir / account,
                aliases,
                disabled,
                cooldowns,
                state_dir,
            )
        )

    counts = {
        "accounts": len(accounts),
        "logged_in": sum(1 for account in accounts if account["logged_in"]),
        "ready": sum(1 for account in accounts if account["status"] == "ready"),
        "disabled": sum(1 for account in accounts if account["disabled"]),
        "cooldowns": sum(1 for account in accounts if account["cooldown_until"] is not None),
    }

    return {
        "generated_at_epoch": now_epoch,
        "accounts_dir": str(accounts_dir),
        "state_dir": str(state_dir),
        "routing_strategy": os.environ.get("CODEX_ORBIT_ROUTING", "round-robin"),
        "last_account": read_text(state_dir / "last_account"),
        "schema_version": read_text(state_dir / "schema_version"),
        "counts": counts,
        "accounts": accounts,
    }


class StatusHandler(BaseHTTPRequestHandler):
    accounts_dir: pathlib.Path

    def _write_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._write_json({"ok": True, "service": "codex-orbitd"})
            return
        if self.path == "/v1/status":
            self._write_json(build_snapshot(self.accounts_dir))
            return
        self._write_json(
            {"error": "not_found", "path": self.path},
            status=HTTPStatus.NOT_FOUND,
        )

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        return


def command_snapshot(args: argparse.Namespace) -> int:
    payload = build_snapshot(pathlib.Path(args.accounts_dir).expanduser())
    print(json.dumps(payload, indent=2 if args.pretty else None, sort_keys=True))
    return 0


def command_serve(args: argparse.Namespace) -> int:
    accounts_dir = pathlib.Path(args.accounts_dir).expanduser()

    class BoundStatusHandler(StatusHandler):
        pass

    BoundStatusHandler.accounts_dir = accounts_dir
    server = ThreadingHTTPServer((args.host, args.port), BoundStatusHandler)
    print(
        json.dumps(
            {
                "service": "codex-orbitd",
                "host": args.host,
                "port": args.port,
                "accounts_dir": str(accounts_dir),
            },
            sort_keys=True,
        ),
        flush=True,
    )
    server.serve_forever()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="codex-orbit-daemon.py")
    parser.add_argument(
        "--accounts-dir",
        default=os.path.expanduser("~/.codex-accounts"),
        help="Path to the codex-orbit accounts directory",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot", help="Print the current daemon snapshot")
    snapshot.add_argument("--pretty", action="store_true", help="Pretty-print the JSON output")
    snapshot.set_defaults(func=command_snapshot)

    serve = subparsers.add_parser("serve", help="Run the local status daemon")
    serve.add_argument("--host", default="127.0.0.1", help="Bind host")
    serve.add_argument("--port", type=int, default=8787, help="Bind port")
    serve.set_defaults(func=command_serve)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())

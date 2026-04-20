#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from codex_orbit_auth import auth_storage_status


SEP = "\x1f"


def debug_log(message: str) -> None:
    if os.environ.get("CODEX_ORBIT_DEBUG", "").lower() not in {"1", "true", "yes", "on"}:
        return
    print(f"[codex-orbitd] {message}", file=sys.stderr, flush=True)


def read_text(path: pathlib.Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None


def read_json(path: pathlib.Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        return None


def write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f"{path.name}.tmp.{os.getpid()}.{int(time.time() * 1000)}")
    temp_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temp_path, 0o600)
    os.replace(temp_path, path)


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


def read_hot_state(state_dir: pathlib.Path) -> dict[str, Any] | None:
    return read_json(state_dir / "hot" / "session.json")


def daemon_state_dir(state_dir: pathlib.Path) -> pathlib.Path:
    return state_dir / "daemon"


def auto_switch_config_file(state_dir: pathlib.Path) -> pathlib.Path:
    return daemon_state_dir(state_dir) / "auto-switch.json"


def auto_switch_event_file(state_dir: pathlib.Path) -> pathlib.Path:
    return daemon_state_dir(state_dir) / "auto-switch-event.json"


def load_auto_switch_settings(state_dir: pathlib.Path) -> dict[str, Any]:
    payload = read_json(auto_switch_config_file(state_dir)) or {}
    enabled = bool(payload.get("enabled", False))
    interval = int(payload.get("interval_seconds", int(os.environ.get("CODEX_ORBIT_DAEMON_AUTOSWITCH_INTERVAL", "15"))))
    return {
        "enabled": enabled,
        "interval_seconds": max(interval, 5),
        "event": read_json(auto_switch_event_file(state_dir)),
    }


def save_auto_switch_settings(state_dir: pathlib.Path, *, enabled: bool, interval_seconds: int | None = None) -> dict[str, Any]:
    payload = {
        "enabled": bool(enabled),
        "interval_seconds": max(int(interval_seconds or int(os.environ.get("CODEX_ORBIT_DAEMON_AUTOSWITCH_INTERVAL", "15"))), 5),
        "updated_at_epoch": int(time.time()),
    }
    write_json(auto_switch_config_file(state_dir), payload)
    payload["event"] = read_json(auto_switch_event_file(state_dir))
    return payload


def store_auto_switch_event(state_dir: pathlib.Path, payload: dict[str, Any]) -> dict[str, Any]:
    write_json(auto_switch_event_file(state_dir), payload)
    return payload


def quota_remaining_value(account: dict[str, Any]) -> int | None:
    quota = account.get("quota")
    if not isinstance(quota, dict):
        return None
    raw = quota.get("primary_remaining")
    try:
        return int(str(raw))
    except (TypeError, ValueError):
        return None


def next_switch_target(snapshot: dict[str, Any]) -> str | None:
    hot = snapshot.get("hot") or {}
    current = hot.get("account")
    accounts = [account for account in snapshot.get("accounts", []) if account.get("status") == "ready"]
    if len(accounts) <= 1:
        return None

    indexed = {account["id"]: idx for idx, account in enumerate(accounts)}
    start_idx = indexed.get(current, -1)
    ordered = accounts[start_idx + 1 :] + accounts[: start_idx + 1] if start_idx >= 0 else accounts
    ordered = [account for account in ordered if account["id"] != current]
    if not ordered:
        return None

    quota_ready = [account for account in ordered if (quota_remaining_value(account) or 0) > 0]
    return (quota_ready[0] if quota_ready else ordered[0])["id"]


def account_status(
    account: str,
    account_dir: pathlib.Path,
    aliases: dict[str, str],
    disabled: dict[str, str],
    cooldowns: dict[str, int],
    state_dir: pathlib.Path,
    hot_state: dict[str, Any] | None,
) -> dict[str, Any]:
    auth_storage = auth_storage_status(account_dir)
    logged_in = auth_storage["mode"] != "missing"
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
        "auth_storage": auth_storage["mode"],
        "hot_active": bool(hot_state and hot_state.get("account") == account and hot_state.get("running")),
    }


def build_snapshot(accounts_dir: pathlib.Path) -> dict[str, Any]:
    now_epoch = int(time.time())
    state_dir = accounts_dir / ".state"
    hot_state = read_hot_state(state_dir)
    auto_switch = load_auto_switch_settings(state_dir)
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
                hot_state,
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
        "hot": hot_state,
        "auto_switch": auto_switch,
    }


class DaemonController:
    def __init__(self, accounts_dir: pathlib.Path, *, cx_path: str, auto_switch_interval: int) -> None:
        self.accounts_dir = accounts_dir
        self.state_dir = accounts_dir / ".state"
        self.cx_path = cx_path
        self.stop_event = threading.Event()
        self.auto_switch_interval = max(auto_switch_interval, 5)
        self.monitor_thread: threading.Thread | None = None

    def build_snapshot(self) -> dict[str, Any]:
        return build_snapshot(self.accounts_dir)

    def run_cx(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        return subprocess.run(
            [self.cx_path, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=env,
        )

    def switch_account(self, account: str) -> dict[str, Any]:
        hot = read_hot_state(self.state_dir)
        if hot and hot.get("running"):
            result = self.run_cx("hot", "switch", account)
        else:
            result = self.run_cx("hot", "start", "--account", account)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "").strip() or f"failed to switch to {account}"
            raise RuntimeError(detail)
        time.sleep(0.2)
        return self.build_snapshot()

    def set_auto_switch_enabled(self, enabled: bool) -> dict[str, Any]:
        return save_auto_switch_settings(self.state_dir, enabled=enabled, interval_seconds=self.auto_switch_interval)

    def notify(self, title: str, message: str) -> None:
        if os.environ.get("CODEX_ORBIT_DAEMON_NOTIFICATIONS", "1").lower() in {"0", "false", "no", "off"}:
            return
        if os.uname().sysname != "Darwin":
            return
        subprocess.run(
            [
                "osascript",
                "-e",
                f'display notification "{message.replace(chr(34), chr(39))}" with title "{title.replace(chr(34), chr(39))}"',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )

    def maybe_auto_switch(self) -> None:
        snapshot = self.build_snapshot()
        auto_switch = snapshot.get("auto_switch") or {}
        if not auto_switch.get("enabled"):
            debug_log("auto-switch disabled")
            return
        hot = snapshot.get("hot") or {}
        if not hot.get("running") or not hot.get("account"):
            debug_log("no running hot session")
            return
        current_account = hot["account"]
        current = next((account for account in snapshot["accounts"] if account["id"] == current_account), None)
        if not current:
            debug_log(f"hot account missing from snapshot: {current_account}")
            return
        remaining = quota_remaining_value(current)
        if remaining is None or remaining > 0:
            debug_log(f"current account {current_account} remaining={remaining}")
            return
        target = next_switch_target(snapshot)
        if not target or target == current_account:
            debug_log(f"no switch target from {current_account}")
            return
        debug_log(f"auto-switching from {current_account} to {target}")
        updated = self.switch_account(target)
        event = {
            "id": f"{int(time.time())}:{current_account}:{target}",
            "from_account": current_account,
            "to_account": target,
            "reason": "quota_exhausted",
            "created_at_epoch": int(time.time()),
        }
        store_auto_switch_event(self.state_dir, event)
        self.notify("Codex Orbit", f"Switched from {current_account} to {target} after quota exhaustion")
        updated.get("auto_switch", {})["event"] = event

    def start_monitor(self) -> None:
        if self.monitor_thread is not None:
            return

        def run() -> None:
            while not self.stop_event.wait(self.auto_switch_interval):
                try:
                    self.maybe_auto_switch()
                except Exception as exc:
                    debug_log(f"auto-switch error: {exc}")
                    continue

        self.monitor_thread = threading.Thread(target=run, name="codex-orbitd-monitor", daemon=True)
        self.monitor_thread.start()

    def stop(self) -> None:
        self.stop_event.set()


class StatusHandler(BaseHTTPRequestHandler):
    controller: DaemonController

    def _write_json(self, payload: dict[str, Any], status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._write_json({"ok": True, "service": "codex-orbitd", "ready": True})
            return
        if self.path == "/v1/status":
            try:
                self.controller.maybe_auto_switch()
            except Exception as exc:
                debug_log(f"status-triggered auto-switch error: {exc}")
            self._write_json(self.controller.build_snapshot())
            return
        self._write_json(
            {"error": "not_found", "path": self.path},
            status=HTTPStatus.NOT_FOUND,
        )

    def do_POST(self) -> None:  # noqa: N802
        try:
            if self.path == "/v1/switch":
                body = self._read_json_body()
                account = str(body.get("account") or "").strip()
                if not account:
                    self._write_json({"error": "missing_account"}, status=HTTPStatus.BAD_REQUEST)
                    return
                self._write_json(self.controller.switch_account(account))
                return
            if self.path == "/v1/auto-switch":
                body = self._read_json_body()
                enabled = bool(body.get("enabled"))
                payload = self.controller.set_auto_switch_enabled(enabled)
                self._write_json({"ok": True, **payload})
                return
        except RuntimeError as exc:
            self._write_json({"error": str(exc)}, status=HTTPStatus.BAD_GATEWAY)
            return
        except Exception as exc:
            self._write_json({"error": str(exc)}, status=HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        self._write_json({"error": "not_found", "path": self.path}, status=HTTPStatus.NOT_FOUND)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        return


def command_snapshot(args: argparse.Namespace) -> int:
    payload = build_snapshot(pathlib.Path(args.accounts_dir).expanduser())
    print(json.dumps(payload, indent=2 if args.pretty else None, sort_keys=True))
    return 0


def command_serve(args: argparse.Namespace) -> int:
    accounts_dir = pathlib.Path(args.accounts_dir).expanduser()
    controller = DaemonController(
        accounts_dir,
        cx_path=args.cx_path,
        auto_switch_interval=args.auto_switch_interval,
    )
    controller.start_monitor()

    class BoundStatusHandler(StatusHandler):
        pass

    BoundStatusHandler.controller = controller
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
    try:
        server.serve_forever()
    finally:
        controller.stop()
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
    serve.add_argument("--cx-path", default=os.environ.get("CODEX_ORBIT_DAEMON_CX", "cx"))
    serve.add_argument(
        "--auto-switch-interval",
        type=int,
        default=int(os.environ.get("CODEX_ORBIT_DAEMON_AUTOSWITCH_INTERVAL", "15")),
    )
    serve.set_defaults(func=command_serve)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())

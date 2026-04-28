#!/usr/bin/env python3

import argparse
import json
import os
import pathlib
import subprocess
import sys

from datetime import datetime, timezone

from clisess import (
    DEFAULT_STORE_FILE,
    find_session,
    is_mirror_session,
    load_store,
    mirror_session_home,
    resolve_source_session,
)


def session_rows(store: dict, provider: str | None = None) -> list[dict]:
    rows = store.get("sessions", [])
    if provider:
        rows = [row for row in rows if row.get("provider") == provider]
    return rows


def ensure_session_home_ready(store: dict, row: dict) -> dict:
    if is_mirror_session(row):
        source = resolve_source_session(store, row.get("source_provider", ""), row.get("source_name", ""))
        mirror_session_home(pathlib.Path(source.get("home", "")), pathlib.Path(row.get("home", "")))
    return row


def hot_runtime_dir(store_path: pathlib.Path) -> pathlib.Path:
    return store_path.parent / "hot" / "codex"


def hot_state_file(store_path: pathlib.Path) -> pathlib.Path:
    return hot_runtime_dir(store_path) / "state.json"


def hot_log_file(store_path: pathlib.Path) -> pathlib.Path:
    return hot_runtime_dir(store_path) / "controller.log"


def hot_app_log_file(store_path: pathlib.Path) -> pathlib.Path:
    return hot_runtime_dir(store_path) / "app-server.log"


def hot_helper_path() -> pathlib.Path:
    return pathlib.Path(__file__).with_name("codex-orbit-hot.js")


def hot_default_app_port() -> str:
    return os.environ.get("CODEX_ORBIT_HOT_APP_PORT", "8791")


def hot_default_control_port() -> str:
    return os.environ.get("CODEX_ORBIT_HOT_CONTROL_PORT", "8792")


def hot_default_idle_seconds() -> str:
    return os.environ.get("CODEX_ORBIT_HOT_IDLE_SECONDS", "900")


def hot_default_auto_switch_enabled() -> bool:
    return os.environ.get("CODEX_ROTATOR_AUTOSWITCH", "").lower() in {"1", "true", "yes", "on"}


def hot_default_auto_switch_interval() -> str:
    return os.environ.get("CODEX_ROTATOR_AUTOSWITCH_INTERVAL", "15")


def run_hot_helper(argv: list[str], *, expect_json: bool = False) -> str | dict:
    command = ["node", str(hot_helper_path()), *argv]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise SystemExit(detail or "hot helper failed")
    output = result.stdout.strip()
    if expect_json:
        return json.loads(output or "{}")
    return output


def current_hot_state(store_path: pathlib.Path) -> dict:
    return run_hot_helper(["status", "--state-file", str(hot_state_file(store_path)), "--json"], expect_json=True)


def resolve_hot_row(store_path: pathlib.Path, name: str | None) -> dict:
    store = load_store(store_path)
    if name:
        row = find_session(store, "codex", name)
        if not row:
            raise SystemExit(f"unknown session: codex/{name}")
        return ensure_session_home_ready(store, row)

    rows = session_rows(store, "codex")
    if len(rows) == 1:
        return ensure_session_home_ready(store, rows[0])
    if not rows:
        raise SystemExit("no codex sessions saved; run: cxs login codex <name>")

    names = ", ".join(sorted(row.get("name", "") for row in rows))
    raise SystemExit(f"multiple codex sessions saved; specify one: {names}")


def hot_codex_command(store_path: pathlib.Path, account: str | None = None) -> list[str]:
    if account:
        row = find_session(load_store(store_path), "codex", account)
        if row and row.get("exec"):
            return [row["exec"]]
    return ["codex"]


def hot_attach(store_path: pathlib.Path, codex_args: list[str]) -> None:
    state = current_hot_state(store_path)
    if not state.get("running") or not state.get("app_url"):
        raise SystemExit("hot session is not running")

    client_id = f"cxr-{os.getpid()}-{int(datetime.now(timezone.utc).timestamp())}"
    run_hot_helper(
        [
            "attach-start",
            "--state-file",
            str(hot_state_file(store_path)),
            "--client-id",
            client_id,
            "--pid",
            str(os.getpid()),
        ]
    )
    command = [*hot_codex_command(store_path, state.get("account")), "--remote", state["app_url"], *codex_args]
    env = os.environ.copy()
    if state.get("account"):
        env["CLISESS_PROVIDER"] = "codex"
        env["CLISESS_SESSION"] = state["account"]
        env["CODEX_ROTATOR_SESSION"] = state["account"]
    try:
        result = subprocess.run(command, env=env)
    finally:
        try:
            run_hot_helper(
                [
                    "attach-stop",
                    "--state-file",
                    str(hot_state_file(store_path)),
                    "--client-id",
                    client_id,
                ]
            )
        except SystemExit:
            pass
    raise SystemExit(result.returncode)


def hot_start_helper_args(args, row: dict, state: dict) -> list[str]:
    helper_args = [
        "start",
        "--sessions-file",
        str(args.store),
        "--provider",
        "codex",
        "--account",
        row.get("name", ""),
        "--app-port",
        str(args.app_port),
        "--control-port",
        str(args.control_port),
        "--state-file",
        str(hot_state_file(args.store)),
        "--log-file",
        str(hot_log_file(args.store)),
        "--app-log-file",
        str(hot_app_log_file(args.store)),
        "--allow-port-fallback",
        "1",
        "--idle-seconds",
        str(args.idle_seconds),
        "--codex-bin",
        row.get("exec") or "codex",
    ]
    if args.auto_switch is not None or args.auto_switch_interval is not None or not state.get("running"):
        helper_args.extend(
            [
                "--auto-switch",
                "1" if (hot_default_auto_switch_enabled() if args.auto_switch is None else args.auto_switch) else "0",
                "--auto-switch-interval",
                str(args.auto_switch_interval or hot_default_auto_switch_interval()),
            ]
        )
    return helper_args


def cmd_start(args):
    state = current_hot_state(args.store)
    row = resolve_hot_row(args.store, args.name or state.get("account"))
    payload = run_hot_helper(hot_start_helper_args(args, row, state), expect_json=True)
    print(f"ready: codex/{payload.get('account', row.get('name', ''))}")


def cmd_open(args):
    state = current_hot_state(args.store)
    if args.name or not state.get("running"):
        row = resolve_hot_row(args.store, args.name)
        run_hot_helper(hot_start_helper_args(args, row, state), expect_json=True)
    hot_attach(args.store, args.codex_args)


def cmd_attach(args):
    hot_attach(args.store, args.codex_args)


def cmd_switch(args):
    row = resolve_hot_row(args.store, args.name)
    payload = run_hot_helper(
        [
            "switch",
            "--state-file",
            str(hot_state_file(args.store)),
            "--account",
            row.get("name", ""),
        ],
        expect_json=True,
    )
    print(f"switched: codex/{payload.get('account', row.get('name', ''))}")


def cmd_status(args):
    output = run_hot_helper(
        ["status", "--state-file", str(hot_state_file(args.store)), *(["--json"] if args.json else [])]
    )
    print(output)


def cmd_stop(args):
    print(run_hot_helper(["stop", "--state-file", str(hot_state_file(args.store))]))


def cmd_autoswitch_enable(args):
    payload = run_hot_helper(
        [
            "autoswitch",
            "--state-file",
            str(hot_state_file(args.store)),
            "--enabled",
            "1",
            "--interval",
            str(args.interval),
        ],
        expect_json=True,
    )
    print(
        f"auto-switch enabled: every {payload.get('auto_switch', {}).get('interval_seconds', args.interval)}s"
    )


def cmd_autoswitch_disable(args):
    run_hot_helper(
        [
            "autoswitch",
            "--state-file",
            str(hot_state_file(args.store)),
            "--enabled",
            "0",
        ],
        expect_json=True,
    )
    print("auto-switch disabled")


def cmd_autoswitch_status(args):
    payload = current_hot_state(args.store)
    auto_switch = payload.get("auto_switch") or {}
    if args.json:
        print(json.dumps(auto_switch, indent=2, sort_keys=True))
        return
    status = "enabled" if auto_switch.get("enabled") else "disabled"
    print(f"auto-switch: {status}")
    print(f"interval: {auto_switch.get('interval_seconds', '-')}")
    event = auto_switch.get("event") or {}
    if event.get("from_account") and event.get("to_account"):
        print(
            f"last switch: {event['from_account']} -> {event['to_account']} ({event.get('reason', 'unknown')})"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=os.environ.get("ROTATOR_PROG") or pathlib.Path(sys.argv[0]).name,
        description="Codex hot-session rotator for saved cxs codex accounts.",
    )
    parser.add_argument(
        "--store",
        type=pathlib.Path,
        default=DEFAULT_STORE_FILE,
        help=f"session store path (default: {DEFAULT_STORE_FILE})",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    start = sub.add_parser("start", help="start a hot Codex session for a saved codex account")
    start.add_argument("name", nargs="?", help="saved codex session name")
    start.add_argument("--app-port", default=hot_default_app_port())
    start.add_argument("--control-port", default=hot_default_control_port())
    start.add_argument("--idle-seconds", default=hot_default_idle_seconds())
    start.add_argument(
        "--auto-switch",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="monitor quota in the background and switch when the current account is exhausted",
    )
    start.add_argument("--auto-switch-interval")
    start.set_defaults(func=cmd_start)

    open_cmd = sub.add_parser("open", help="start or reuse the hot Codex session, then attach Codex")
    open_cmd.add_argument("name", nargs="?", help="saved codex session name")
    open_cmd.add_argument("--app-port", default=hot_default_app_port())
    open_cmd.add_argument("--control-port", default=hot_default_control_port())
    open_cmd.add_argument("--idle-seconds", default=hot_default_idle_seconds())
    open_cmd.add_argument(
        "--auto-switch",
        action=argparse.BooleanOptionalAction,
        default=None,
        help="monitor quota in the background and switch when the current account is exhausted",
    )
    open_cmd.add_argument("--auto-switch-interval")
    open_cmd.add_argument("codex_args", nargs=argparse.REMAINDER, help="codex args (use -- <args ...>)")
    open_cmd.set_defaults(func=cmd_open)

    attach = sub.add_parser("attach", help="attach Codex to the running hot session")
    attach.add_argument("codex_args", nargs=argparse.REMAINDER, help="codex args (use -- <args ...>)")
    attach.set_defaults(func=cmd_attach)

    switch = sub.add_parser("switch", help="switch the running hot session to another saved codex account")
    switch.add_argument("name", help="saved codex session name")
    switch.set_defaults(func=cmd_switch)

    status = sub.add_parser("status", help="show hot session status")
    status.add_argument("--json", action="store_true")
    status.set_defaults(func=cmd_status)

    autoswitch = sub.add_parser("autoswitch", help="manage background auto-switching")
    autoswitch_sub = autoswitch.add_subparsers(dest="autoswitch_command", required=True)

    autoswitch_enable = autoswitch_sub.add_parser("enable", help="enable background auto-switching")
    autoswitch_enable.add_argument("--interval", default=hot_default_auto_switch_interval())
    autoswitch_enable.set_defaults(func=cmd_autoswitch_enable)

    autoswitch_disable = autoswitch_sub.add_parser("disable", help="disable background auto-switching")
    autoswitch_disable.set_defaults(func=cmd_autoswitch_disable)

    autoswitch_status = autoswitch_sub.add_parser("status", help="show background auto-switch settings")
    autoswitch_status.add_argument("--json", action="store_true")
    autoswitch_status.set_defaults(func=cmd_autoswitch_status)

    stop = sub.add_parser("stop", help="stop the running hot session")
    stop.set_defaults(func=cmd_stop)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if hasattr(args, "codex_args") and args.codex_args and args.codex_args[0] == "--":
        args.codex_args = args.codex_args[1:]

    args.func(args)


if __name__ == "__main__":
    main()

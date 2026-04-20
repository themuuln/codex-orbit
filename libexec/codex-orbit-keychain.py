#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import pathlib
import sys

from codex_orbit_auth import (
    auth_file_for_account,
    auth_storage_status,
    ensure_auth_file_from_keychain,
    keychain_delete_auth,
    keychain_supported,
    keychain_write_auth,
    load_auth_payload,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="codex-orbit-keychain.py")
    parser.add_argument("--accounts-dir", required=True)
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name in ("status", "sync", "restore", "clear"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("--account", action="append", default=[])
        subparser.add_argument("--json", action="store_true")
        if name == "sync":
            subparser.add_argument("--remove-file", action="store_true")

    return parser.parse_args()


def selected_accounts(accounts_dir: pathlib.Path, names: list[str]) -> list[pathlib.Path]:
    if names:
        account_dirs = [accounts_dir / name for name in names]
    else:
        account_dirs = [
            path
            for path in sorted(accounts_dir.iterdir())
            if path.is_dir() and not path.name.startswith(".")
        ]
    return [path for path in account_dirs if path.is_dir()]


def command_status(accounts_dir: pathlib.Path, args: argparse.Namespace) -> int:
    rows = []
    for account_dir in selected_accounts(accounts_dir, args.account):
        row = {"id": account_dir.name, **auth_storage_status(account_dir)}
        rows.append(row)

    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
    else:
        if not rows:
            print("no accounts")
            return 0
        for row in rows:
            print(
                "\t".join(
                    [
                        row["id"],
                        row["mode"],
                        "file" if row["file_exists"] else "-",
                        "keychain" if row["keychain_exists"] else "-",
                    ]
                )
            )
    return 0


def command_sync(accounts_dir: pathlib.Path, args: argparse.Namespace) -> int:
    if not keychain_supported():
        raise SystemExit("macOS keychain is not available")

    synced = 0
    for account_dir in selected_accounts(accounts_dir, args.account):
        payload = load_auth_payload(account_dir, allow_keychain=False)
        keychain_write_auth(account_dir, payload)
        synced += 1
        if args.remove_file:
            auth_file_for_account(account_dir).unlink(missing_ok=True)

    print(f"synced {synced} account(s) to keychain")
    return 0


def command_restore(accounts_dir: pathlib.Path, args: argparse.Namespace) -> int:
    restored = 0
    for account_dir in selected_accounts(accounts_dir, args.account):
        restored_path = ensure_auth_file_from_keychain(account_dir)
        if restored_path:
            restored += 1

    print(f"restored {restored} account(s) from keychain")
    return 0


def command_clear(accounts_dir: pathlib.Path, args: argparse.Namespace) -> int:
    cleared = 0
    for account_dir in selected_accounts(accounts_dir, args.account):
        if auth_storage_status(account_dir)["keychain_exists"]:
            keychain_delete_auth(account_dir)
            cleared += 1

    print(f"cleared {cleared} keychain item(s)")
    return 0


def main() -> int:
    args = parse_args()
    accounts_dir = pathlib.Path(args.accounts_dir).expanduser()
    accounts_dir.mkdir(parents=True, exist_ok=True)

    if args.command == "status":
        return command_status(accounts_dir, args)
    if args.command == "sync":
        return command_sync(accounts_dir, args)
    if args.command == "restore":
        return command_restore(accounts_dir, args)
    if args.command == "clear":
        return command_clear(accounts_dir, args)
    raise SystemExit(f"unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())

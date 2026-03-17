#!/usr/bin/env python3

import argparse
import datetime as dt
import io
import json
import os
import pathlib
import shutil
import socket
import tarfile
import tempfile


FORMAT_VERSION = 1
ALLOWED_ACCOUNT_FILES = {"auth.json", "config.toml"}
ALLOWED_GLOBAL_FILES = {"config.toml"}


class ShareError(RuntimeError):
    pass


def parse_args():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("--accounts-dir", required=True)
    export_parser.add_argument("--output", required=True)
    export_parser.add_argument("--account", action="append", default=[])

    import_parser = subparsers.add_parser("import")
    import_parser.add_argument("--accounts-dir", required=True)
    import_parser.add_argument("--input", required=True)

    export_config_parser = subparsers.add_parser("export-config")
    export_config_parser.add_argument("--config-file", required=True)
    export_config_parser.add_argument("--output", required=True)

    import_config_parser = subparsers.add_parser("import-config")
    import_config_parser.add_argument("--config-file", required=True)
    import_config_parser.add_argument("--input", required=True)

    return parser.parse_args()


def write_json_bytes(obj):
    return json.dumps(obj, indent=2, sort_keys=True).encode("utf-8") + b"\n"


def ensure_parent(path):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)


def add_bytes_to_tar(handle, arcname, payload):
    info = tarfile.TarInfo(name=arcname)
    info.size = len(payload)
    info.mtime = int(dt.datetime.now(dt.timezone.utc).timestamp())
    info.mode = 0o644
    handle.addfile(info, io.BytesIO(payload))


def write_bytes_atomic(path, payload, mode=None):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=str(path.parent), delete=False) as temp_handle:
        temp_handle.write(payload)
        temp_path = pathlib.Path(temp_handle.name)
    if mode is not None:
        os.chmod(temp_path, mode)
    os.replace(temp_path, path)


def export_accounts(accounts_dir, output_path, account_names):
    accounts_root = pathlib.Path(accounts_dir).expanduser()
    if not account_names:
        raise ShareError("no accounts selected")

    export_accounts = []
    manifest_accounts = []
    for account_name in account_names:
        account_dir = accounts_root / account_name
        auth_file = account_dir / "auth.json"
        config_file = account_dir / "config.toml"
        if not account_dir.is_dir():
            raise ShareError(f"unknown account: {account_name}")
        if not auth_file.is_file():
            raise ShareError(f"account is not logged in: {account_name}")
        export_accounts.append((account_name, auth_file, config_file))
        manifest_accounts.append(
            {
                "name": account_name,
                "files": ["auth.json"] + (["config.toml"] if config_file.is_file() else []),
            }
        )

    manifest = {
        "format_version": FORMAT_VERSION,
        "kind": "accounts",
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "source_hostname": socket.gethostname(),
        "account_count": len(export_accounts),
        "accounts": manifest_accounts,
    }

    output = pathlib.Path(output_path).expanduser()
    ensure_parent(output)
    with tempfile.NamedTemporaryFile(
        dir=str(output.parent),
        prefix="codex-orbit-share.",
        suffix=".tar.gz",
        delete=False,
    ) as temp_handle:
        temp_path = pathlib.Path(temp_handle.name)

    try:
        with tarfile.open(temp_path, "w:gz") as archive:
            add_bytes_to_tar(archive, "manifest.json", write_json_bytes(manifest))
            for account_name, auth_file, config_file in export_accounts:
                archive.add(auth_file, arcname=f"accounts/{account_name}/auth.json")
                if config_file.is_file():
                    archive.add(config_file, arcname=f"accounts/{account_name}/config.toml")
        os.replace(temp_path, output)
        os.chmod(output, 0o600)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def export_global_config(config_path, output_path):
    config_file = pathlib.Path(config_path).expanduser()
    if not config_file.is_file():
        raise ShareError(f"global config not found: {config_file}")

    manifest = {
        "format_version": FORMAT_VERSION,
        "kind": "global_config",
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "source_hostname": socket.gethostname(),
        "files": ["config.toml"],
    }

    output = pathlib.Path(output_path).expanduser()
    ensure_parent(output)
    with tempfile.NamedTemporaryFile(
        dir=str(output.parent),
        prefix="codex-orbit-config-share.",
        suffix=".tar.gz",
        delete=False,
    ) as temp_handle:
        temp_path = pathlib.Path(temp_handle.name)

    try:
        with tarfile.open(temp_path, "w:gz") as archive:
            add_bytes_to_tar(archive, "manifest.json", write_json_bytes(manifest))
            archive.add(config_file, arcname="global/config.toml")
        os.replace(temp_path, output)
        os.chmod(output, 0o600)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def normalize_member_path(name):
    path = pathlib.PurePosixPath(name)
    if path.is_absolute():
        raise ShareError(f"invalid archive entry: {name}")
    if any(part in ("", ".", "..") for part in path.parts):
        raise ShareError(f"invalid archive entry: {name}")
    return path


def next_account_name(existing_names):
    last_id = 0
    for name in existing_names:
        if not name.startswith("acct_"):
            continue
        try:
            value = int(name.split("_", 1)[1], 10)
        except (IndexError, ValueError):
            continue
        if value > last_id:
            last_id = value
    while True:
        last_id += 1
        candidate = f"acct_{last_id:03d}"
        if candidate not in existing_names:
            existing_names.add(candidate)
            return candidate


def import_accounts(accounts_dir, input_path):
    accounts_root = pathlib.Path(accounts_dir).expanduser()
    accounts_root.mkdir(parents=True, exist_ok=True)
    archive_path = pathlib.Path(input_path).expanduser()
    if not archive_path.is_file():
        raise ShareError(f"archive not found: {archive_path}")

    manifest = None
    incoming = {}

    with tarfile.open(archive_path, "r:*") as archive:
        for member in archive.getmembers():
            if not member.isfile():
                continue
            member_path = normalize_member_path(member.name)
            if member_path == pathlib.PurePosixPath("manifest.json"):
                with archive.extractfile(member) as handle:
                    manifest = json.load(handle)
                continue
            if len(member_path.parts) != 3 or member_path.parts[0] != "accounts":
                raise ShareError(f"unsupported archive entry: {member.name}")
            _, account_name, file_name = member_path.parts
            if file_name not in ALLOWED_ACCOUNT_FILES:
                raise ShareError(f"unsupported archive entry: {member.name}")
            with archive.extractfile(member) as handle:
                payload = handle.read()
            incoming.setdefault(account_name, {})[file_name] = payload

    if manifest is None:
        raise ShareError("manifest.json missing")
    if manifest.get("format_version") != FORMAT_VERSION:
        raise ShareError(f"unsupported share format: {manifest.get('format_version')}")
    if not incoming:
        raise ShareError("archive contains no accounts")

    for account_name, files in incoming.items():
        if "auth.json" not in files:
            raise ShareError(f"auth.json missing for {account_name}")

    ordered_names = []
    for account_entry in manifest.get("accounts", []):
        name = account_entry.get("name")
        if name in incoming and name not in ordered_names:
            ordered_names.append(name)
    for account_name in sorted(incoming):
        if account_name not in ordered_names:
            ordered_names.append(account_name)

    existing_names = {
        path.name
        for path in accounts_root.iterdir()
        if path.is_dir() and not path.name.startswith(".")
    }
    mapping = []
    staging_root = pathlib.Path(
        tempfile.mkdtemp(prefix="codex-orbit-share-import.", dir=str(accounts_root))
    )

    try:
        for source_name in ordered_names:
            target_name = source_name
            if target_name in existing_names:
                target_name = next_account_name(existing_names)
            else:
                existing_names.add(target_name)

            target_dir = staging_root / target_name
            target_dir.mkdir(parents=True, exist_ok=True)
            for file_name, payload in incoming[source_name].items():
                write_bytes_atomic(target_dir / file_name, payload, mode=0o600)
            mapping.append((source_name, target_name))

        for _, target_name in mapping:
            os.replace(staging_root / target_name, accounts_root / target_name)
    except Exception:
        shutil.rmtree(staging_root, ignore_errors=True)
        raise
    else:
        shutil.rmtree(staging_root, ignore_errors=True)

    return mapping


def backup_path(path):
    path = pathlib.Path(path)
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d%H%M%S")
    candidate = path.with_name(f"{path.name}.bak.{timestamp}")
    index = 2
    while candidate.exists():
        candidate = path.with_name(f"{path.name}.bak.{timestamp}.{index}")
        index += 1
    return candidate


def import_global_config(config_path, input_path):
    config_file = pathlib.Path(config_path).expanduser()
    archive_path = pathlib.Path(input_path).expanduser()
    if not archive_path.is_file():
        raise ShareError(f"archive not found: {archive_path}")

    manifest = None
    payload = None

    with tarfile.open(archive_path, "r:*") as archive:
        for member in archive.getmembers():
            if not member.isfile():
                continue
            member_path = normalize_member_path(member.name)
            if member_path == pathlib.PurePosixPath("manifest.json"):
                with archive.extractfile(member) as handle:
                    manifest = json.load(handle)
                continue
            if member_path != pathlib.PurePosixPath("global/config.toml"):
                raise ShareError(f"unsupported archive entry: {member.name}")
            with archive.extractfile(member) as handle:
                payload = handle.read()

    if manifest is None:
        raise ShareError("manifest.json missing")
    if manifest.get("format_version") != FORMAT_VERSION:
        raise ShareError(f"unsupported share format: {manifest.get('format_version')}")
    if manifest.get("kind") not in (None, "global_config"):
        raise ShareError("archive does not contain global config")
    if payload is None:
        raise ShareError("config.toml missing from archive")

    backup = None
    config_file.parent.mkdir(parents=True, exist_ok=True)
    if config_file.exists():
        backup = backup_path(config_file)
        shutil.copy2(config_file, backup)
    write_bytes_atomic(config_file, payload, mode=0o600)
    return backup


def main():
    args = parse_args()
    try:
        if args.command == "export":
            export_accounts(args.accounts_dir, args.output, args.account)
            print(str(pathlib.Path(args.output).expanduser()))
            return 0

        if args.command == "import":
            mapping = import_accounts(args.accounts_dir, args.input)
            for source_name, target_name in mapping:
                print(f"{source_name}\t{target_name}")
            return 0

        if args.command == "export-config":
            export_global_config(args.config_file, args.output)
            print(str(pathlib.Path(args.output).expanduser()))
            return 0

        if args.command == "import-config":
            backup = import_global_config(args.config_file, args.input)
            if backup is not None:
                print(str(backup))
            return 0
    except ShareError as exc:
        print(f"error: {exc}", file=os.sys.stderr)
        return 1

    raise AssertionError("unreachable")


if __name__ == "__main__":
    raise SystemExit(main())

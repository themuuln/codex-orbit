#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
from typing import Any


KEYCHAIN_SERVICE = os.environ.get("CODEX_ORBIT_KEYCHAIN_SERVICE", "ai.factory.codex-orbit.auth")
KEYCHAIN_ENABLED = os.environ.get("CODEX_ORBIT_KEYCHAIN_ENABLED", "1").lower() not in {
    "0",
    "false",
    "no",
    "off",
}


def security_binary() -> str | None:
    override = os.environ.get("CODEX_ORBIT_SECURITY_BIN")
    if override:
        return override
    return shutil.which("security")


def keychain_supported() -> bool:
    return KEYCHAIN_ENABLED and sys_platform_is_darwin() and bool(security_binary())


def sys_platform_is_darwin() -> bool:
    return os.uname().sysname == "Darwin"


def auth_file_for_account(account_dir: pathlib.Path) -> pathlib.Path:
    return pathlib.Path(account_dir) / "auth.json"


def keychain_account_name(account_dir: pathlib.Path) -> str:
    return str(pathlib.Path(account_dir).expanduser().resolve())


def read_json_file(path: pathlib.Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json_file(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(path.parent), delete=False) as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temp_name = handle.name
    os.chmod(temp_name, 0o600)
    os.replace(temp_name, path)


def write_auth_file(account_dir: pathlib.Path, payload: dict[str, Any]) -> pathlib.Path:
    path = auth_file_for_account(account_dir)
    write_json_file(path, payload)
    return path


def store_auth_payload(account_dir: pathlib.Path, payload: dict[str, Any]) -> None:
    status = auth_storage_status(account_dir)
    if status["file_exists"] or not status["keychain_exists"]:
        write_auth_file(account_dir, payload)
    if status["keychain_exists"]:
        keychain_write_auth(account_dir, payload)


def _run_security(args: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    binary = security_binary()
    if not binary:
        raise RuntimeError("macOS security tool not available")
    return subprocess.run(
        [binary, *args],
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def keychain_has_auth(account_dir: pathlib.Path) -> bool:
    if not keychain_supported():
        return False
    result = _run_security(
        [
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            keychain_account_name(account_dir),
            "-w",
        ]
    )
    return result.returncode == 0


def keychain_read_auth(account_dir: pathlib.Path) -> dict[str, Any]:
    if not keychain_supported():
        raise RuntimeError("macOS keychain not available")
    result = _run_security(
        [
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            keychain_account_name(account_dir),
            "-w",
        ]
    )
    if result.returncode != 0:
        raise FileNotFoundError(f"keychain auth not found for {account_dir}")
    return json.loads(result.stdout)


def keychain_write_auth(account_dir: pathlib.Path, payload: dict[str, Any]) -> None:
    if not keychain_supported():
        raise RuntimeError("macOS keychain not available")
    serialized = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    result = _run_security(
        [
            "add-generic-password",
            "-U",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            keychain_account_name(account_dir),
            "-w",
            serialized,
        ]
    )
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "").strip() or "keychain write failed"
        raise RuntimeError(message)


def keychain_delete_auth(account_dir: pathlib.Path) -> None:
    if not keychain_supported():
        return
    result = _run_security(
        [
            "delete-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            keychain_account_name(account_dir),
        ]
    )
    if result.returncode != 0 and "could not be found" not in (result.stderr or "").lower():
        message = (result.stderr or result.stdout or "").strip() or "keychain delete failed"
        raise RuntimeError(message)


def load_auth_payload(account_dir: pathlib.Path, *, allow_keychain: bool = True) -> dict[str, Any]:
    auth_file = auth_file_for_account(account_dir)
    if auth_file.is_file():
        return read_json_file(auth_file)
    if allow_keychain and keychain_has_auth(account_dir):
        return keychain_read_auth(account_dir)
    raise FileNotFoundError(f"auth.json not found for {account_dir}")


def ensure_auth_file_from_keychain(account_dir: pathlib.Path) -> pathlib.Path | None:
    auth_file = auth_file_for_account(account_dir)
    if auth_file.is_file():
        return auth_file
    if not keychain_has_auth(account_dir):
        return None
    payload = keychain_read_auth(account_dir)
    return write_auth_file(account_dir, payload)


def auth_storage_status(account_dir: pathlib.Path) -> dict[str, Any]:
    auth_file = auth_file_for_account(account_dir)
    file_exists = auth_file.is_file()
    keychain_exists = keychain_has_auth(account_dir)
    if file_exists and keychain_exists:
        mode = "file+keychain"
    elif keychain_exists:
        mode = "keychain"
    elif file_exists:
        mode = "file"
    else:
        mode = "missing"
    return {
        "mode": mode,
        "file_exists": file_exists,
        "keychain_exists": keychain_exists,
        "keychain_supported": keychain_supported(),
        "service": KEYCHAIN_SERVICE,
        "account": keychain_account_name(account_dir),
        "auth_file": str(auth_file),
    }

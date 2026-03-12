#!/usr/bin/env python3

import argparse
import datetime as dt
import json
import os
import pathlib
import pty
import re
import select
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


REFRESH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
REFRESH_URL = "https://auth.openai.com/oauth/token"
DEFAULT_BASE_URL = "https://chatgpt.com/backend-api/"
SHELL_FIELD_SEP = "\x1f"


class QuotaError(RuntimeError):
    pass


def parse_args():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot")
    snapshot.add_argument("--account-dir", required=True)
    snapshot.add_argument("--format", choices=("tsv", "json"), default="tsv")
    snapshot.add_argument("--source", choices=("auto", "oauth", "rpc", "status"), default="auto")
    return parser.parse_args()


def account_paths(account_dir):
    root = pathlib.Path(account_dir)
    return {
        "account_dir": root,
        "auth_file": root / "auth.json",
        "config_file": root / "config.toml",
    }


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def parse_last_refresh(value):
    if not value or not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return dt.datetime.fromisoformat(text)
    except ValueError:
        return None


def needs_refresh(auth_obj):
    last_refresh = parse_last_refresh(auth_obj.get("last_refresh"))
    if last_refresh is None:
        return True
    if last_refresh.tzinfo is None:
        last_refresh = last_refresh.replace(tzinfo=dt.timezone.utc)
    age = dt.datetime.now(dt.timezone.utc) - last_refresh.astimezone(dt.timezone.utc)
    return age.total_seconds() > 8 * 24 * 60 * 60


def write_auth_file(path, obj):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(path.parent), delete=False) as handle:
        json.dump(obj, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temp_name = handle.name
    os.replace(temp_name, path)


def refresh_tokens(auth_path, auth_obj):
    tokens = auth_obj.get("tokens") or {}
    refresh_token = tokens.get("refresh_token")
    if not refresh_token:
        raise QuotaError("refresh token missing")

    body = json.dumps(
        {
            "client_id": REFRESH_CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "scope": "openid profile email",
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        REFRESH_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read().decode("utf-8", "ignore"))
        except Exception:
            payload = {}
        error = payload.get("error") if isinstance(payload, dict) else None
        if isinstance(error, dict):
            code = error.get("code") or error.get("message") or exc.reason
        else:
            code = error or exc.reason
        raise QuotaError(f"token refresh failed: {code}") from exc
    except Exception as exc:
        raise QuotaError(f"token refresh failed: {exc}") from exc

    tokens["access_token"] = payload.get("access_token") or tokens.get("access_token")
    tokens["refresh_token"] = payload.get("refresh_token") or tokens.get("refresh_token")
    if payload.get("id_token"):
        tokens["id_token"] = payload["id_token"]
    auth_obj["tokens"] = tokens
    auth_obj["last_refresh"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    write_auth_file(auth_path, auth_obj)
    return auth_obj


def load_config_base_url(config_path):
    path = pathlib.Path(config_path)
    if not path.is_file():
        return DEFAULT_BASE_URL
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError:
        return DEFAULT_BASE_URL
    for raw_line in contents.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() != "chatgpt_base_url":
            continue
        value = value.strip().strip("\"'")
        if value:
            return value
    return DEFAULT_BASE_URL


def resolve_usage_url(config_path):
    base = load_config_base_url(config_path).strip() or DEFAULT_BASE_URL
    while base.endswith("/"):
        base = base[:-1]
    if (
        (base.startswith("https://chatgpt.com") or base.startswith("https://chat.openai.com"))
        and "/backend-api" not in base
    ):
        base = f"{base}/backend-api"
    if "/backend-api" in base:
        return f"{base}/wham/usage"
    return f"{base}/api/codex/usage"


def parse_jwt_claims(id_token):
    if not id_token or "." not in id_token:
        return {}
    try:
        payload = id_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(
            __import__("base64").urlsafe_b64decode(payload.encode("ascii")).decode("utf-8")
        )
    except Exception:
        return {}


def snapshot_from_usage_payload(payload, source):
    rate_limit = payload.get("rate_limit") or {}
    credits = payload.get("credits") or {}
    return {
        "source": source,
        "email": payload.get("email") or "",
        "plan_type": payload.get("plan_type") or "",
        "credits": {
            "balance": coerce_float(credits.get("balance")),
            "has_credits": bool(credits.get("has_credits")),
            "unlimited": bool(credits.get("unlimited")),
        },
        "primary_window": window_from_usage_payload(rate_limit.get("primary_window")),
        "secondary_window": window_from_usage_payload(rate_limit.get("secondary_window")),
    }


def window_from_usage_payload(window):
    if not isinstance(window, dict):
        return None
    used = coerce_int(window.get("used_percent"))
    reset_at = coerce_int(window.get("reset_at"))
    seconds = coerce_int(window.get("limit_window_seconds"))
    if used is None and reset_at is None and seconds is None:
        return None
    return {
        "used_percent": used,
        "remaining_percent": None if used is None else max(0, 100 - used),
        "reset_at": reset_at,
        "limit_window_seconds": seconds,
    }


def fetch_oauth(paths):
    auth_path = paths["auth_file"]
    if not auth_path.is_file():
        raise QuotaError("auth.json not found")

    auth_obj = read_json(auth_path)
    tokens = auth_obj.get("tokens") or {}
    access_token = tokens.get("access_token")
    if not access_token:
        raise QuotaError("access token missing")

    if needs_refresh(auth_obj):
        auth_obj = refresh_tokens(auth_path, auth_obj)
        tokens = auth_obj.get("tokens") or {}
        access_token = tokens.get("access_token")

    url = resolve_usage_url(paths["config_file"])
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Accept": "application/json",
        "User-Agent": "codex-orbit",
    }
    account_id = tokens.get("account_id")
    if account_id:
        headers["ChatGPT-Account-Id"] = account_id

    def do_request(token_value):
        request = urllib.request.Request(url, headers={**headers, "Authorization": f"Bearer {token_value}"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    try:
        payload = do_request(access_token)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403) and tokens.get("refresh_token"):
            auth_obj = refresh_tokens(auth_path, auth_obj)
            tokens = auth_obj.get("tokens") or {}
            payload = do_request(tokens.get("access_token", ""))
        else:
            body = exc.read().decode("utf-8", "ignore")
            raise QuotaError(f"usage request failed: HTTP {exc.code} {body}".strip()) from exc
    except Exception as exc:
        raise QuotaError(f"usage request failed: {exc}") from exc

    snapshot = snapshot_from_usage_payload(payload, "oauth")
    if not snapshot.get("email") or not snapshot.get("plan_type"):
        claims = parse_jwt_claims(tokens.get("id_token"))
        auth_claims = claims.get("https://api.openai.com/auth") or {}
        snapshot["email"] = snapshot.get("email") or claims.get("email") or ""
        snapshot["plan_type"] = snapshot.get("plan_type") or auth_claims.get("chatgpt_plan_type") or ""
    return snapshot


def read_rpc_message(proc, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([proc.stdout, proc.stderr], [], [], 0.2)
        for handle in ready:
            line = handle.readline()
            if not line:
                continue
            if handle is proc.stderr:
                continue
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    raise QuotaError("timed out waiting for codex app-server")


def rpc_request(proc, request_id, method, params=None, timeout=8):
    payload = {"id": request_id, "method": method, "params": params or {}}
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()
    while True:
        message = read_rpc_message(proc, timeout)
        if message.get("id") is None:
            continue
        if int(message.get("id")) != request_id:
            continue
        if "error" in message:
            error = message["error"]
            if isinstance(error, dict):
                detail = error.get("message") or json.dumps(error, sort_keys=True)
            else:
                detail = str(error)
            raise QuotaError(f"codex app-server error: {detail}")
        return message.get("result") or {}


def fetch_rpc(paths):
    env = os.environ.copy()
    env["CODEX_HOME"] = str(paths["account_dir"])
    proc = subprocess.Popen(
        ["codex", "-s", "read-only", "-a", "never", "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )
    try:
        _ = rpc_request(proc, 1, "initialize", {"clientInfo": {"name": "codex-orbit", "version": "0.1.0"}})
        proc.stdin.write(json.dumps({"method": "initialized", "params": {}}) + "\n")
        proc.stdin.flush()
        rate_limits_result = rpc_request(proc, 2, "account/rateLimits/read")
        account_result = rpc_request(proc, 3, "account/read")
    except Exception:
        proc.terminate()
        try:
            proc.wait(timeout=1)
        except Exception:
            proc.kill()
        raise
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except Exception:
                proc.kill()

    snapshot = rate_limits_result.get("rateLimits") or {}
    account = account_result.get("account") or {}
    if not isinstance(account, dict):
        account = {}
    return {
        "source": "rpc",
        "email": account.get("email") or "",
        "plan_type": account.get("planType") or snapshot.get("planType") or "",
        "credits": {
            "balance": coerce_float((snapshot.get("credits") or {}).get("balance")),
            "has_credits": bool((snapshot.get("credits") or {}).get("hasCredits")),
            "unlimited": bool((snapshot.get("credits") or {}).get("unlimited")),
        },
        "primary_window": window_from_rpc_payload(snapshot.get("primary")),
        "secondary_window": window_from_rpc_payload(snapshot.get("secondary")),
    }


def window_from_rpc_payload(window):
    if not isinstance(window, dict):
        return None
    used = coerce_int(window.get("usedPercent"))
    reset_at = coerce_int(window.get("resetsAt"))
    minutes = coerce_int(window.get("windowDurationMins"))
    seconds = None if minutes is None else minutes * 60
    if used is None and reset_at is None and seconds is None:
        return None
    return {
        "used_percent": used,
        "remaining_percent": None if used is None else max(0, 100 - used),
        "reset_at": reset_at,
        "limit_window_seconds": seconds,
    }


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def fetch_status(paths):
    env = os.environ.copy()
    env["CODEX_HOME"] = str(paths["account_dir"])
    master_fd, slave_fd = pty.openpty()
    proc = subprocess.Popen(
        ["codex", "-s", "read-only", "-a", "never"],
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        env=env,
    )
    os.close(slave_fd)
    try:
        time.sleep(0.8)
        os.write(master_fd, b"/status\r")
        buffer = bytearray()
        deadline = time.time() + 8
        while time.time() < deadline:
            ready, _, _ = select.select([master_fd], [], [], 0.2)
            if master_fd not in ready:
                continue
            try:
                chunk = os.read(master_fd, 8192)
            except OSError:
                break
            if not chunk:
                break
            buffer.extend(chunk)
            if b"Credits:" in buffer or b"5h limit" in buffer or b"Weekly limit" in buffer:
                time.sleep(0.5)
                break
        text = ANSI_RE.sub("", buffer.decode("utf-8", "ignore"))
        snapshot = parse_status_text(text)
        snapshot["source"] = "status"
        return snapshot
    except Exception as exc:
        raise QuotaError(f"status probe failed: {exc}") from exc
    finally:
        try:
            os.write(master_fd, b"/exit\r")
        except OSError:
            pass
        os.close(master_fd)
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except Exception:
                proc.kill()


def parse_status_text(text):
    credits_match = re.search(r"Credits:\s*([0-9][0-9.,]*)", text)
    five_line = first_line(r"5h limit[^\n]*", text) or first_line(r"5-hour limit[^\n]*", text)
    weekly_line = first_line(r"Weekly limit[^\n]*", text)

    primary = window_from_status_line(five_line, 5 * 60 * 60)
    secondary = window_from_status_line(weekly_line, 7 * 24 * 60 * 60)

    if credits_match is None and primary is None and secondary is None:
        raise QuotaError("could not parse /status output")

    return {
        "email": "",
        "plan_type": "",
        "credits": {
            "balance": coerce_float(credits_match.group(1)) if credits_match else None,
            "has_credits": credits_match is not None,
            "unlimited": False,
        },
        "primary_window": primary,
        "secondary_window": secondary,
    }


def first_line(pattern, text):
    match = re.search(pattern, text, flags=re.IGNORECASE)
    return match.group(0) if match else None


def window_from_status_line(line, limit_window_seconds):
    if not line:
        return None
    used_match = re.search(r"([0-9]{1,3})%\s*used", line, flags=re.IGNORECASE)
    left_match = re.search(r"([0-9]{1,3})%\s*left", line, flags=re.IGNORECASE)
    if used_match:
        used = coerce_int(used_match.group(1))
    elif left_match:
        left = coerce_int(left_match.group(1))
        used = None if left is None else max(0, 100 - left)
    else:
        used = None
    reset_at = None
    reset_match = re.search(r"resets?\s+(?:in\s+)?(.+)$", line, flags=re.IGNORECASE)
    if reset_match:
        reset_at = None
    if used is None and reset_at is None:
        return None
    return {
        "used_percent": used,
        "remaining_percent": None if used is None else max(0, 100 - used),
        "reset_at": reset_at,
        "limit_window_seconds": limit_window_seconds,
    }


def coerce_int(value):
    if value is None or value == "":
        return None
    try:
        return int(float(str(value).replace(",", "")))
    except (TypeError, ValueError):
        return None


def coerce_float(value):
    if value is None or value == "":
        return None
    try:
        return float(str(value).replace(",", ""))
    except (TypeError, ValueError):
        return None


def snapshot_to_tsv(snapshot):
    fields = [
        snapshot.get("source") or "",
        snapshot.get("email") or "",
        snapshot.get("plan_type") or "",
        field(snapshot.get("credits", {}).get("balance")),
        field(snapshot.get("credits", {}).get("has_credits")),
        field(snapshot.get("credits", {}).get("unlimited")),
        field(window_field(snapshot, "primary_window", "used_percent")),
        field(window_field(snapshot, "primary_window", "remaining_percent")),
        field(window_field(snapshot, "primary_window", "reset_at")),
        field(window_field(snapshot, "primary_window", "limit_window_seconds")),
        field(window_field(snapshot, "secondary_window", "used_percent")),
        field(window_field(snapshot, "secondary_window", "remaining_percent")),
        field(window_field(snapshot, "secondary_window", "reset_at")),
        field(window_field(snapshot, "secondary_window", "limit_window_seconds")),
    ]
    return SHELL_FIELD_SEP.join(fields)


def window_field(snapshot, window_name, field_name):
    window = snapshot.get(window_name) or {}
    return window.get(field_name)


def field(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, float):
        text = f"{value:.2f}"
        return text.rstrip("0").rstrip(".")
    return str(value)


def fetch_snapshot(paths, source):
    attempts = {
        "auto": (fetch_oauth, fetch_rpc, fetch_status),
        "oauth": (fetch_oauth,),
        "rpc": (fetch_rpc,),
        "status": (fetch_status,),
    }[source]
    errors = []
    for handler in attempts:
        try:
            return handler(paths)
        except Exception as exc:
            errors.append(str(exc))
    raise QuotaError(" | ".join(error for error in errors if error))


def main():
    args = parse_args()
    if args.command != "snapshot":
        raise SystemExit(2)

    paths = account_paths(args.account_dir)
    try:
        snapshot = fetch_snapshot(paths, args.source)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)

    if args.format == "json":
        print(json.dumps(snapshot, sort_keys=True))
    else:
        print(snapshot_to_tsv(snapshot))


if __name__ == "__main__":
    main()

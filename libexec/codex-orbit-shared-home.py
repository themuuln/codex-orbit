#!/usr/bin/env python3

import argparse
import filecmp
import os
import pathlib
import shutil
import sqlite3
import sys


DIR_ENTRIES = ("sessions", "shell_snapshots", "memories")
FILE_ENTRIES = ("history.jsonl",)
DB_ENTRIES = ("state_5.sqlite", "logs_1.sqlite")
DB_SIDECARS = ("-shm", "-wal")
STATE_TABLES = ("_sqlx_migrations", "threads", "thread_dynamic_tools", "stage1_outputs")
LOG_COLUMNS = (
    "ts",
    "ts_nanos",
    "level",
    "target",
    "message",
    "module_path",
    "file",
    "line",
    "thread_id",
    "process_uuid",
    "estimated_bytes",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--accounts-dir", required=True)
    return parser.parse_args()


def debug(message: str) -> None:
    if os.environ.get("CODEX_ORBIT_DEBUG") in {"1", "true"}:
        print(f"[codex-orbit] {message}", file=sys.stderr)


def is_account_dir(path: pathlib.Path) -> bool:
    return path.is_dir() and path.name.startswith("acct_")


def ensure_dir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def remove_path(path: pathlib.Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def ensure_symlink(link_path: pathlib.Path, target_path: pathlib.Path) -> None:
    ensure_dir(link_path.parent)
    if link_path.is_symlink():
        current = pathlib.Path(os.readlink(link_path))
        resolved = (link_path.parent / current).resolve()
        if resolved == target_path.resolve():
            return
        link_path.unlink()
    elif link_path.exists():
        remove_path(link_path)
    relative_target = os.path.relpath(target_path, link_path.parent)
    link_path.symlink_to(relative_target)


def move_with_sidecars(source: pathlib.Path, target: pathlib.Path) -> None:
    ensure_dir(target.parent)
    shutil.move(str(source), str(target))
    for suffix in DB_SIDECARS:
        source_sidecar = source.with_name(source.name + suffix)
        target_sidecar = target.with_name(target.name + suffix)
        if source_sidecar.exists() or source_sidecar.is_symlink():
            if target_sidecar.exists() or target_sidecar.is_symlink():
                remove_path(source_sidecar)
            else:
                shutil.move(str(source_sidecar), str(target_sidecar))


def merge_history(source: pathlib.Path, target: pathlib.Path) -> None:
    ensure_dir(target.parent)
    if not target.exists():
        shutil.move(str(source), str(target))
        return

    seen = set()
    with target.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            seen.add(line.rstrip("\n"))

    with target.open("a", encoding="utf-8") as out_handle, source.open(
        "r", encoding="utf-8", errors="ignore"
    ) as in_handle:
        for line in in_handle:
            normalized = line.rstrip("\n")
            if normalized in seen:
                continue
            out_handle.write(line if line.endswith("\n") else f"{line}\n")
            seen.add(normalized)

    source.unlink()


def unique_conflict_path(path: pathlib.Path, account_name: str) -> pathlib.Path:
    candidate = path.with_name(f"{path.name}.from-{account_name}")
    if not candidate.exists():
        return candidate
    index = 2
    while True:
        candidate = path.with_name(f"{path.name}.from-{account_name}.{index}")
        if not candidate.exists():
            return candidate
        index += 1


def merge_tree(source: pathlib.Path, target: pathlib.Path, account_name: str) -> None:
    ensure_dir(target)
    for root, dirnames, filenames in os.walk(source):
        root_path = pathlib.Path(root)
        rel_root = root_path.relative_to(source)
        target_root = target / rel_root
        ensure_dir(target_root)
        dirnames.sort()
        filenames.sort()
        for dirname in dirnames:
            ensure_dir(target_root / dirname)
        for filename in filenames:
            source_file = root_path / filename
            target_file = target_root / filename
            if not target_file.exists():
                ensure_dir(target_file.parent)
                shutil.copy2(source_file, target_file)
                continue
            if filecmp.cmp(source_file, target_file, shallow=False):
                continue
            conflict_path = unique_conflict_path(target_file, account_name)
            shutil.copy2(source_file, conflict_path)

    shutil.rmtree(source)


def table_exists(conn: sqlite3.Connection, db_name: str, table_name: str) -> bool:
    row = conn.execute(
        f"SELECT 1 FROM {db_name}.sqlite_master WHERE type='table' AND name = ?",
        (table_name,),
    ).fetchone()
    return row is not None


def merge_state_db(source: pathlib.Path, target: pathlib.Path) -> None:
    ensure_dir(target.parent)
    if not target.exists():
        move_with_sidecars(source, target)
        return

    conn = sqlite3.connect(target, timeout=5)
    try:
        conn.execute("PRAGMA busy_timeout = 5000")
        conn.execute("ATTACH DATABASE ? AS src", (str(source),))
        for table_name in STATE_TABLES:
            if not table_exists(conn, "src", table_name):
                continue
            conn.execute(f"INSERT OR IGNORE INTO main.{table_name} SELECT * FROM src.{table_name}")
        if table_exists(conn, "src", "backfill_state"):
            row = conn.execute(
                "SELECT id, status, last_watermark, last_success_at, updated_at FROM src.backfill_state WHERE id = 1"
            ).fetchone()
            if row is not None:
                existing = conn.execute(
                    "SELECT updated_at FROM main.backfill_state WHERE id = 1"
                ).fetchone()
                if existing is None or row[4] >= existing[0]:
                    conn.execute(
                        """
                        INSERT INTO main.backfill_state (id, status, last_watermark, last_success_at, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                          status = excluded.status,
                          last_watermark = excluded.last_watermark,
                          last_success_at = excluded.last_success_at,
                          updated_at = excluded.updated_at
                        """,
                        row,
                    )
        conn.commit()
        conn.execute("DETACH DATABASE src")
    finally:
        conn.close()

    remove_path(source)
    for suffix in DB_SIDECARS:
        source_sidecar = source.with_name(source.name + suffix)
        if source_sidecar.exists() or source_sidecar.is_symlink():
            remove_path(source_sidecar)


def merge_logs_db(source: pathlib.Path, target: pathlib.Path) -> None:
    ensure_dir(target.parent)
    if not target.exists():
        move_with_sidecars(source, target)
        return

    conn = sqlite3.connect(target, timeout=5)
    try:
        conn.execute("PRAGMA busy_timeout = 5000")
        conn.execute("ATTACH DATABASE ? AS src", (str(source),))
        if table_exists(conn, "src", "logs"):
            columns_sql = ", ".join(LOG_COLUMNS)
            select_sql = ", ".join(f"s.{column}" for column in LOG_COLUMNS)
            match_sql = " AND ".join(f"t.{column} IS s.{column}" for column in LOG_COLUMNS)
            conn.execute(
                f"""
                INSERT INTO main.logs ({columns_sql})
                SELECT {select_sql}
                FROM src.logs AS s
                WHERE NOT EXISTS (
                  SELECT 1
                  FROM main.logs AS t
                  WHERE {match_sql}
                )
                """
            )
        conn.commit()
        conn.execute("DETACH DATABASE src")
    finally:
        conn.close()

    remove_path(source)
    for suffix in DB_SIDECARS:
        source_sidecar = source.with_name(source.name + suffix)
        if source_sidecar.exists() or source_sidecar.is_symlink():
            remove_path(source_sidecar)


def migrate_account(account_dir: pathlib.Path, shared_dir: pathlib.Path) -> None:
    account_name = account_dir.name

    for dir_name in DIR_ENTRIES:
        source = account_dir / dir_name
        target = shared_dir / dir_name
        ensure_dir(target)
        if source.is_symlink():
            ensure_symlink(source, target)
            continue
        if source.exists():
            debug(f"merge_dir account={account_name} path={dir_name}")
            merge_tree(source, target, account_name)
        ensure_symlink(source, target)

    for file_name in FILE_ENTRIES:
        source = account_dir / file_name
        target = shared_dir / file_name
        if source.is_symlink():
            ensure_symlink(source, target)
            continue
        if source.exists():
            debug(f"merge_file account={account_name} path={file_name}")
            merge_history(source, target)
        ensure_symlink(source, target)

    for db_name in DB_ENTRIES:
        source = account_dir / db_name
        target = shared_dir / db_name
        if source.is_symlink():
            ensure_symlink(source, target)
        elif source.exists():
            debug(f"merge_db account={account_name} path={db_name}")
            if db_name == "state_5.sqlite":
                merge_state_db(source, target)
            else:
                merge_logs_db(source, target)
            ensure_symlink(source, target)
        else:
            ensure_symlink(source, target)

        for suffix in DB_SIDECARS:
            sidecar = account_dir / f"{db_name}{suffix}"
            target_sidecar = shared_dir / f"{db_name}{suffix}"
            ensure_symlink(sidecar, target_sidecar)


def main() -> int:
    args = parse_args()
    accounts_dir = pathlib.Path(args.accounts_dir).expanduser()
    shared_dir = accounts_dir / ".shared"
    ensure_dir(shared_dir)

    accounts = sorted(path for path in accounts_dir.iterdir() if is_account_dir(path))
    for account_dir in accounts:
        migrate_account(account_dir, shared_dir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

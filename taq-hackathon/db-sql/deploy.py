#!/usr/bin/env python3
"""
TAQ Hackathon — DB deploy script.

Creates / refreshes / tears down the `hackathon` schema and all its artefacts.
Every DDL file is applied in its own transaction so a failure halts with
context. The full footprint is removable via a single DROP SCHEMA CASCADE.

Modes:
    python deploy.py                    # dry-run: prints the file order
    python deploy.py --apply            # executes the DDL in order
    python deploy.py --teardown         # DROP SCHEMA hackathon CASCADE
    python deploy.py --teardown --yes   # skip the y/N prompt
    python deploy.py --apply --reset    # teardown then apply (demo reset)

Creds: loaded from ../../.env.pfx.core (DB_HOST, DB_PORT, DB_NAME, DB_USER,
       DB_PASSWORD, optional PGSSLMODE).
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import psycopg
from dotenv import load_dotenv


HERE = Path(__file__).resolve().parent
ENV_PATH = HERE.parent.parent / ".env.pfx.core"


def load_env() -> dict[str, str]:
    if not ENV_PATH.exists():
        print(f"ERROR: env file not found at {ENV_PATH}", file=sys.stderr)
        sys.exit(2)
    load_dotenv(ENV_PATH, override=False)
    missing = [k for k in ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD") if not os.getenv(k)]
    if missing:
        print(f"ERROR: missing env vars: {', '.join(missing)}", file=sys.stderr)
        sys.exit(2)
    return {
        "host": os.environ["DB_HOST"],
        "port": os.environ["DB_PORT"],
        "dbname": os.environ["DB_NAME"],
        "user": os.environ["DB_USER"],
        "password": os.environ["DB_PASSWORD"],
        "sslmode": os.getenv("PGSSLMODE", "require"),
    }


def connect(cfg: dict[str, str]) -> psycopg.Connection:
    return psycopg.connect(
        host=cfg["host"],
        port=cfg["port"],
        dbname=cfg["dbname"],
        user=cfg["user"],
        password=cfg["password"],
        sslmode=cfg["sslmode"],
        application_name="hackathon-deploy",
    )


def discover_files() -> list[Path]:
    """Return DDL files in deploy order.

    Order: 00_schema.sql -> tables/ -> functions/_cfg_helpers.sql
           -> views/{item-subdirs, sorted} -> views/sections/
           -> functions/get_brief.sql
    """
    files: list[Path] = []

    # 1. Schema bootstrap
    schema_file = HERE / "00_schema.sql"
    if schema_file.exists():
        files.append(schema_file)

    # 2. Tables (numbered prefix gives stable order)
    tables_dir = HERE / "tables"
    if tables_dir.exists():
        files.extend(sorted(tables_dir.glob("*.sql")))

    # 3. Config helpers (must come before views that call them)
    cfg_helpers = HERE / "functions" / "_cfg_helpers.sql"
    if cfg_helpers.exists():
        files.append(cfg_helpers)

    # 4. Per-item views, section views last
    views_dir = HERE / "views"
    if views_dir.exists():
        item_dirs = sorted(
            [p for p in views_dir.iterdir() if p.is_dir() and p.name != "sections"]
        )
        for item_dir in item_dirs:
            files.extend(sorted(item_dir.glob("*.sql")))
        sections_dir = views_dir / "sections"
        if sections_dir.exists():
            files.extend(sorted(sections_dir.glob("*.sql")))

    # 5. Aggregator function last
    functions_dir = HERE / "functions"
    if functions_dir.exists():
        for f in sorted(functions_dir.glob("*.sql")):
            if f == cfg_helpers:
                continue
            files.append(f)

    return files


def apply(cfg: dict[str, str], files: list[Path]) -> None:
    n_applied = 0
    n_errors = 0
    with connect(cfg) as conn:
        conn.autocommit = False
        for f in files:
            rel = f.relative_to(HERE)
            sql = f.read_text(encoding="utf-8")
            try:
                with conn.cursor() as cur:
                    cur.execute(sql)
                conn.commit()
                n_applied += 1
                print(f"  OK   {rel}")
            except Exception as exc:
                conn.rollback()
                n_errors += 1
                print(f"  FAIL {rel}: {exc}", file=sys.stderr)
                # stop on first error; later files may depend on this one
                break
    print(f"\napplied {n_applied} files, {n_errors} errors")
    if n_errors:
        sys.exit(1)


def summarise(cfg: dict[str, str]) -> None:
    with connect(cfg) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT kind, count(*) FROM (
              SELECT 'tables'    AS kind FROM pg_tables    WHERE schemaname='hackathon'
              UNION ALL
              SELECT 'views'              FROM pg_views     WHERE schemaname='hackathon'
              UNION ALL
              SELECT 'functions'          FROM pg_proc p
                JOIN pg_namespace n ON p.pronamespace = n.oid
                WHERE n.nspname='hackathon'
            ) q GROUP BY kind ORDER BY kind;
            """
        )
        counts = cur.fetchall()
    if not counts:
        print("hackathon schema is empty or missing")
    else:
        print("hackathon schema contents:")
        for kind, n in counts:
            print(f"  {kind:10s} {n}")


def teardown(cfg: dict[str, str], yes: bool) -> None:
    if not yes:
        resp = input("DROP SCHEMA hackathon CASCADE — proceed? [y/N] ").strip().lower()
        if resp != "y":
            print("aborted")
            sys.exit(0)
    with connect(cfg) as conn, conn.cursor() as cur:
        cur.execute("DROP SCHEMA IF EXISTS hackathon CASCADE")
        conn.commit()
    print("hackathon schema dropped")


def dry_run(files: list[Path]) -> None:
    print("DDL apply order:")
    for i, f in enumerate(files, 1):
        print(f"  {i:2d}. {f.relative_to(HERE)}")
    print(f"\n{len(files)} file(s). Run with --apply to execute.")


def main() -> None:
    parser = argparse.ArgumentParser(description="TAQ hackathon DB deploy")
    parser.add_argument("--apply", action="store_true", help="execute DDL")
    parser.add_argument("--teardown", action="store_true", help="drop hackathon schema")
    parser.add_argument("--reset", action="store_true", help="with --apply: teardown first")
    parser.add_argument("--yes", action="store_true", help="skip teardown confirmation")
    args = parser.parse_args()

    cfg = load_env()
    files = discover_files()

    if args.teardown and not args.apply:
        teardown(cfg, yes=args.yes)
        return

    if args.apply:
        if args.reset:
            teardown(cfg, yes=args.yes)
        if not files:
            print("no DDL files discovered", file=sys.stderr)
            sys.exit(2)
        apply(cfg, files)
        summarise(cfg)
        return

    dry_run(files)


if __name__ == "__main__":
    main()

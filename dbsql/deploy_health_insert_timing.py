#!/usr/bin/env python3
"""Deploy insert timing health objects to the ONyc database.

Deploys in dependency order:
  1. mat_health_insert_timing   — hypertable + refresh procedure (CREATE IF NOT EXISTS)
  2. refresh_mat_health_all     — updated umbrella procedure (adds insert timing call)
  3. v_health_insert_timing     — current-state view
  4. v_health_insert_timing_chart — chart function
  5. v_health_base_table        — updated function+view (adds insert indicator columns)
"""

import os, sys
import psycopg2
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
from pathlib import Path
from dotenv import load_dotenv

ROOT     = Path(__file__).parent.parent          # pfx/
MID      = ROOT / "dbsql" / "mid-level-tables" / "health"
FRONTEND = ROOT / "dbsql" / "frontend-views"    / "health"

load_dotenv(ROOT / ".env.pfx.core", override=True)

DB_CONFIG = {
    "host":            os.getenv("DB_HOST"),
    "port":            int(os.getenv("DB_PORT", "5432")),
    "dbname":          os.getenv("DB_NAME"),
    "user":            os.getenv("DB_USER"),
    "password":        os.getenv("DB_PASSWORD"),
    "connect_timeout": 30,
}

DEPLOYMENTS = [
    # (label, path)
    ("mat_health_insert_timing  [hypertable + refresh proc]",
     MID      / "mat_health_insert_timing.sql"),
    ("refresh_mat_health_all    [umbrella procedure]",
     MID      / "refresh_mat_health_all.sql"),
    ("v_health_insert_timing    [current-state view]",
     FRONTEND / "v_health_insert_timing.sql"),
    ("v_health_insert_timing_chart [chart function]",
     FRONTEND / "v_health_insert_timing_chart.sql"),
    ("v_health_base_table       [activity + insert indicator]",
     FRONTEND / "v_health_base_table.sql"),
    ("v_health_master_table     [rebuild after cascade drop]",
     FRONTEND / "v_health_master_table.sql"),
]


def main():
    print("=" * 70)
    print("ONyc — INSERT TIMING HEALTH DEPLOYMENT")
    print(f"  host:   {DB_CONFIG['host']}:{DB_CONFIG['port']}")
    print(f"  db:     {DB_CONFIG['dbname']}")
    print("=" * 70)
    for label, path in DEPLOYMENTS:
        print(f"  {label}")
    print()

    response = input("Deploy? (yes/no): ")
    if response.strip().lower() not in ("yes", "y"):
        print("Cancelled.")
        return

    conn = psycopg2.connect(**DB_CONFIG)
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()

    failed = []
    for label, path in DEPLOYMENTS:
        print(f"\n{'-'*70}")
        print(f"  {label}")
        print(f"  {path.relative_to(ROOT)}")
        try:
            sql = path.read_text(encoding="utf-8")
            cur.execute(sql)
            print("  OK")
        except Exception as exc:
            print(f"  FAILED: {exc}")
            failed.append(label)

    cur.close()
    conn.close()

    print(f"\n{'='*70}")
    if failed:
        print(f"FAILED ({len(failed)}):")
        for f in failed:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print("ALL DEPLOYED SUCCESSFULLY")


if __name__ == "__main__":
    main()

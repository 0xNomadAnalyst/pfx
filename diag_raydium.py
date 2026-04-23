from __future__ import annotations

import os
import sys
from pathlib import Path

import psycopg

env_path = Path(__file__).parent / ".env.pfx.core"
env: dict[str, str] = {}
for line in env_path.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, _, v = line.partition("=")
    env[k.strip()] = v.strip()

conninfo = (
    f"host={env['DB_HOST']} port={env['DB_PORT']} dbname={env['DB_NAME']} "
    f"user={env['DB_USER']} password={env['DB_PASSWORD']} sslmode=require"
)

with psycopg.connect(conninfo) as con:
    with con.cursor() as cur:
        print("== distinct (protocol, pair) in src_acct_tickarray_queries ==")
        cur.execute(
            "SELECT LOWER(protocol), token_pair, COUNT(*) "
            "FROM dexes.src_acct_tickarray_queries "
            "GROUP BY 1, 2 ORDER BY 1, 2"
        )
        for r in cur.fetchall():
            print(r)

        print("\n== schema tables with 'pool' in name ==")
        cur.execute(
            "SELECT table_schema, table_name FROM information_schema.tables "
            "WHERE table_schema NOT IN ('pg_catalog','information_schema') "
            "AND table_name ILIKE '%pool%' ORDER BY 1,2"
        )
        for r in cur.fetchall():
            print(r)

        print("\n== get_view_dex_last('raydium', 'USDG-ONyc', '1 day') ==")
        try:
            cur.execute(
                "SELECT tvl_in_t1_units, impact_from_t0_sell3_bps, reserve_t0_t1_millions "
                "FROM dexes.get_view_dex_last('raydium','USDG-ONyc','1 day'::interval) LIMIT 1"
            )
            rows = cur.fetchall()
            print(f"rows: {len(rows)}")
            for r in rows:
                print(r)
        except Exception as e:
            print(f"ERROR: {e}")

        print("\n== get_view_dex_last('raydium', 'ONyc-USDC', '1 day') ==")
        try:
            cur.execute(
                "SELECT tvl_in_t1_units, impact_from_t0_sell3_bps, reserve_t0_t1_millions "
                "FROM dexes.get_view_dex_last('raydium','ONyc-USDC','1 day'::interval) LIMIT 1"
            )
            rows = cur.fetchall()
            print(f"rows: {len(rows)}")
            for r in rows:
                print(r)
        except Exception as e:
            print(f"ERROR: {e}")

        print("\n== src_acct_tickarray_queries raw sample ==")
        try:
            cur.execute(
                "SELECT protocol, token_pair, pool_address FROM dexes.src_acct_tickarray_queries LIMIT 30"
            )
            for r in cur.fetchall():
                print(r)
        except Exception as e:
            print(f"ERROR: {e}")

        print("\n== columns of src_acct_tickarray_queries ==")
        cur.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_schema='dexes' AND table_name='src_acct_tickarray_queries' ORDER BY ordinal_position"
        )
        for r in cur.fetchall():
            print(r)

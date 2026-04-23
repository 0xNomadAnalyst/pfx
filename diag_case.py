from __future__ import annotations

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
        print("== raw distinct (protocol, token_pair) - case sensitive ==")
        cur.execute(
            "SELECT protocol, token_pair, COUNT(*) "
            "FROM dexes.src_acct_tickarray_queries "
            "GROUP BY 1, 2 ORDER BY 1, 2"
        )
        for r in cur.fetchall():
            print(r)

        for proto in ("raydium", "Raydium", "orca", "Orca"):
            for pair in ("USDG-ONyc", "ONyc-USDC", "usdg-onyc"):
                try:
                    cur.execute(
                        "SELECT COUNT(*) FROM dexes.src_acct_tickarray_queries "
                        "WHERE protocol = %s AND token_pair = %s",
                        (proto, pair),
                    )
                    n = cur.fetchone()[0]
                    print(f"  case-sensitive ({proto!r}, {pair!r}) = {n}")
                except Exception as e:
                    print(f"  ERR ({proto}, {pair}): {e}")

        print("\n== call dex_last with RAYDIUM (uppercase) ==")
        try:
            cur.execute(
                "SELECT tvl_in_t1_units FROM dexes.get_view_dex_last(%s, %s, %s::interval) LIMIT 1",
                ("Raydium", "USDG-ONyc", "1 day"),
            )
            print("rows:", cur.fetchall())
        except Exception as e:
            print(f"ERROR: {e}")

        print("\n== call dex_last with 'raydium' lowercase ==")
        try:
            cur.execute(
                "SELECT tvl_in_t1_units FROM dexes.get_view_dex_last(%s, %s, %s::interval) LIMIT 1",
                ("raydium", "USDG-ONyc", "1 day"),
            )
            print("rows:", cur.fetchall())
        except Exception as e:
            print(f"ERROR: {e}")

        print("\n== look at src_acct_pool for raydium ==")
        try:
            cur.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema='dexes' AND table_name='src_acct_pool' ORDER BY ordinal_position"
            )
            cols = [r[0] for r in cur.fetchall()]
            print("cols:", cols[:20])
        except Exception as e:
            print(f"ERROR: {e}")

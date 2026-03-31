"""Phase 0: Discovery - identify USX/eUSX markets on Exponent."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from db import run_query, md_table
from datetime import datetime, timezone

SQL = """
SELECT vault_address, market_address, market_name, maturity_date, maturity_ts,
       TO_TIMESTAMP(maturity_ts) AS maturity_datetime,
       is_active, is_expired, env_sy_symbol, meta_pt_symbol, meta_yt_symbol,
       meta_base_symbol, mint_sy, mint_pt, mint_yt, mint_lp,
       sy_interface_type, sy_yield_bearing_mint
FROM exponent.aux_key_relations
WHERE env_sy_symbol ILIKE '%usx%' OR env_sy_symbol ILIKE '%eusx%'
   OR meta_base_symbol ILIKE '%usx%' OR meta_base_symbol ILIKE '%eusx%'
ORDER BY env_sy_symbol, maturity_ts;
"""

cols, rows = run_query(SQL)
print(f"Found {len(rows)} markets\n")
for i, c in enumerate(cols):
    print(f"  [{i}] {c}")
print()
for row in rows:
    print("---")
    for i, c in enumerate(cols):
        print(f"  {c}: {row[i]}")

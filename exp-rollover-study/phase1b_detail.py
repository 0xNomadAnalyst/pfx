"""Phase 1b detail: daily event breakdown + trade/wrap events."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from db import run_query

MARKETS = {
    "USX": {
        "expired_vault": "HJZigEFmMwArysvFpieGsEEZqWczitHFUmzUHTMkXpsW",
        "new_vault": "4hZugBhgd3xxShK5iHbBAwCnJUjthiStT6LnruRwarjr",
        "maturity_ts": 1770634699,
    },
    "eUSX": {
        "expired_vault": "5G1jVLtmqYctNTU7ok1rr8t2SeSKe8LcFUSh63EX8WWg",
        "new_vault": "7NviQEEiA5RSY4aL1wpqGE8CYAx2Lx7THHinsW1CWDXu",
        "maturity_ts": 1773226699,
    },
}

# All event types including trade_pt, mint_sy, redeem_sy
for asset, m in MARKETS.items():
    print(f"\n{'='*70}")
    print(f"  {asset} — All event types daily")
    print(f"{'='*70}")
    
    sql = """
    SELECT
        CASE WHEN vault_address = %s THEN 'expired' ELSE 'new' END AS gen,
        event_type,
        time_bucket('1 day', bucket_time) AS day,
        SUM(event_count) AS events,
        SUM(amount_vault_sy_in) AS vault_sy_in,
        SUM(amount_vault_sy_out) AS vault_sy_out,
        SUM(amount_vault_pt_in) AS vault_pt_in,
        SUM(amount_vault_pt_out) AS vault_pt_out,
        SUM(amount_amm_pt_in) AS amm_pt_in,
        SUM(amount_amm_pt_out) AS amm_pt_out,
        SUM(amount_amm_sy_in) AS amm_sy_in,
        SUM(amount_amm_sy_out) AS amm_sy_out,
        SUM(amount_base_in) AS base_in,
        SUM(amount_base_out) AS base_out,
        SUM(amount_wrapper_sy_in) AS wrapper_sy_in,
        SUM(amount_wrapper_sy_out) AS wrapper_sy_out
    FROM exponent.cagg_tx_events_5s
    WHERE vault_address IN (%s, %s)
      AND bucket_time >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
      AND bucket_time <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
    GROUP BY 1, 2, 3
    ORDER BY 3, 1, 2;
    """
    cols, rows = run_query(sql, (m["expired_vault"], m["expired_vault"], m["new_vault"], m["maturity_ts"], m["maturity_ts"]))
    
    # Print daily summary
    print(f"{'gen':8s} | {'event_type':14s} | {'day':12s} | {'events':>7s} | {'vault_sy_in':>14s} | {'vault_sy_out':>14s} | {'vault_pt_in':>14s} | {'vault_pt_out':>14s} | {'base_in':>14s} | {'base_out':>14s} | {'wrap_sy_in':>14s} | {'wrap_sy_out':>14s}")
    print("-" * 180)
    for r in rows:
        day_str = r[2].strftime("%Y-%m-%d") if r[2] else ""
        print(f"{r[0]:8s} | {r[1]:14s} | {day_str:12s} | {r[3] or 0:>7} | {float(r[4] or 0):>14.2f} | {float(r[5] or 0):>14.2f} | {float(r[6] or 0):>14.2f} | {float(r[7] or 0):>14.2f} | {float(r[12] or 0):>14.2f} | {float(r[13] or 0):>14.2f} | {float(r[14] or 0):>14.2f} | {float(r[15] or 0):>14.2f}")

# Also: check pre-maturity PT supply (at vault peak) for % calculations
print(f"\n{'='*70}")
print("  Peak PT supply (from vault state)")
print(f"{'='*70}")
for asset, m in MARKETS.items():
    sql = """
    SELECT MAX(pt_supply_ui) AS peak_pt
    FROM exponent.cagg_vaults_5s
    WHERE vault_address = %s;
    """
    cols, rows = run_query(sql, (m["expired_vault"],))
    print(f"  {asset} expired vault peak PT supply: {rows[0][0]}")
    
    sql2 = """
    SELECT LAST(pt_supply_ui, bucket) AS pt_at_maturity
    FROM exponent.cagg_vaults_5s
    WHERE vault_address = %s
      AND bucket <= TO_TIMESTAMP(%s)
      AND bucket >= TO_TIMESTAMP(%s) - INTERVAL '1 hour'
    GROUP BY time_bucket('1 hour', bucket)
    ORDER BY 1 DESC LIMIT 1;
    """
    cols2, rows2 = run_query(sql2, (m["expired_vault"], m["maturity_ts"], m["maturity_ts"]))
    if rows2:
        print(f"  {asset} PT supply at maturity: {rows2[0][0]}")

"""Phase 2: DEX sell pressure analysis around maturity dates."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from db import run_query, run_query_dict

# =========================================================================
# 2a. Identify relevant DEX pools
# =========================================================================
print("=" * 70)
print("  2a. Identify DEX pools for USX/eUSX")
print("=" * 70)

pool_sql = """
SELECT pool_address, token_pair, protocol, token0_symbol, token1_symbol,
       token0_address, token1_address, token0_decimals, token1_decimals
FROM dexes.pool_tokens_reference
WHERE token0_symbol ILIKE '%%usx%%' OR token1_symbol ILIKE '%%usx%%'
   OR token0_symbol ILIKE '%%eusx%%' OR token1_symbol ILIKE '%%eusx%%';
"""
cols, rows = run_query(pool_sql)
print(f"Found {len(rows)} pools")
for r in rows:
    print(f"  {r[2]:10s} | {r[1]:20s} | {r[3]:8s}/{r[4]:8s} | {r[0][:16]}...")

# Store for later
pools = {}
for r in rows:
    key = f"{r[3]}/{r[4]}"
    pools[r[0]] = {
        "pair": r[1], "protocol": r[2],
        "t0": r[3], "t1": r[4],
        "t0_addr": r[5], "t1_addr": r[6],
        "t0_dec": r[7], "t1_dec": r[8],
    }

# =========================================================================
# 2b. Swap volume and net sell pressure around maturity
# =========================================================================
MATURITY = {
    "USX": {"ts": 1770634699, "date": "2026-02-09"},
    "eUSX": {"ts": 1773226699, "date": "2026-03-11"},
}

for asset, mat in MATURITY.items():
    print(f"\n{'='*70}")
    print(f"  2b. {asset} DEX Activity Around Maturity ({mat['date']})")
    print(f"{'='*70}")

    # Find pools that contain USX or eUSX
    token_filter = asset.lower()
    relevant_pools = {k: v for k, v in pools.items()
                      if token_filter in v["t0"].lower() or token_filter in v["t1"].lower()}

    if not relevant_pools:
        print(f"  No pools found for {asset}")
        continue

    pool_addrs = list(relevant_pools.keys())
    print(f"  Pools: {len(pool_addrs)}")
    for pa, pv in relevant_pools.items():
        print(f"    {pv['protocol']:10s} {pv['t0']}/{pv['t1']} ({pa[:16]}...)")

    # Maturity window vs baseline
    maturity_sql = """
    WITH maturity_window AS (
        SELECT
            pool_address,
            time_bucket('1 day', bucket_time) AS day,
            SUM(event_count) FILTER (WHERE activity_category = 'swap') AS swap_count,
            SUM(amount0_in) FILTER (WHERE activity_category = 'swap') AS t0_sell_vol,
            SUM(amount0_out) FILTER (WHERE activity_category = 'swap') AS t0_buy_vol,
            SUM(amount1_in) FILTER (WHERE activity_category = 'swap') AS t1_sell_vol,
            SUM(amount1_out) FILTER (WHERE activity_category = 'swap') AS t1_buy_vol,
            SUM(amount0_in - amount0_out) FILTER (WHERE activity_category = 'swap') AS t0_net_sell,
            SUM(amount1_in - amount1_out) FILTER (WHERE activity_category = 'swap') AS t1_net_sell,
            MAX(amount0_in_max) FILTER (WHERE activity_category = 'swap') AS max_single_t0_sell,
            MAX(amount1_in_max) FILTER (WHERE activity_category = 'swap') AS max_single_t1_sell,
            AVG(c_swap_est_impact_bps_avg) FILTER (WHERE activity_category = 'swap') AS avg_impact_bps,
            MAX(c_swap_est_impact_bps_max) FILTER (WHERE activity_category = 'swap') AS max_impact_bps
        FROM dexes.cagg_events_5s
        WHERE pool_address = ANY(%s)
          AND bucket_time >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND bucket_time <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
        GROUP BY 1, 2
        ORDER BY 1, 2
    )
    SELECT * FROM maturity_window;
    """
    cols, rows_mat = run_query(maturity_sql, (pool_addrs, mat["ts"], mat["ts"]))
    print(f"\n  Maturity window daily swap activity:")
    print(f"  {'pool':16s} | {'day':12s} | {'swaps':>6s} | {'t0_sell':>14s} | {'t0_buy':>14s} | {'t0_net_sell':>14s} | {'t1_sell':>14s} | {'t1_buy':>14s} | {'max_t0_sell':>14s} | {'avg_imp_bps':>12s} | {'max_imp_bps':>12s}")
    print("  " + "-" * 160)
    for r in rows_mat:
        pa_short = r[0][:16]
        day_str = r[1].strftime("%Y-%m-%d")
        print(f"  {pa_short:16s} | {day_str:12s} | {r[2] or 0:>6} | {float(r[3] or 0):>14.2f} | {float(r[4] or 0):>14.2f} | {float(r[7] or 0):>14.2f} | {float(r[5] or 0):>14.2f} | {float(r[6] or 0):>14.2f} | {float(r[9] or 0):>14.2f} | {float(r[11] or 0):>12.4f} | {float(r[12] or 0):>12.4f}")

    # Baseline: 30 days before the T-7d window
    baseline_sql = """
    SELECT
        pool_address,
        COUNT(*) AS bucket_count,
        SUM(event_count) FILTER (WHERE activity_category = 'swap') AS swap_count,
        SUM(amount0_in) FILTER (WHERE activity_category = 'swap') / 30.0 AS avg_daily_t0_sell,
        SUM(amount0_out) FILTER (WHERE activity_category = 'swap') / 30.0 AS avg_daily_t0_buy,
        SUM(amount0_in - amount0_out) FILTER (WHERE activity_category = 'swap') / 30.0 AS avg_daily_t0_net_sell,
        SUM(amount1_in) FILTER (WHERE activity_category = 'swap') / 30.0 AS avg_daily_t1_sell,
        SUM(amount1_out) FILTER (WHERE activity_category = 'swap') / 30.0 AS avg_daily_t1_buy,
        AVG(c_swap_est_impact_bps_avg) FILTER (WHERE activity_category = 'swap') AS avg_impact_bps
    FROM dexes.cagg_events_5s
    WHERE pool_address = ANY(%s)
      AND bucket_time >= TO_TIMESTAMP(%s) - INTERVAL '37 days'
      AND bucket_time < TO_TIMESTAMP(%s) - INTERVAL '7 days'
    GROUP BY 1;
    """
    cols_b, rows_base = run_query(baseline_sql, (pool_addrs, mat["ts"], mat["ts"]))
    print(f"\n  Baseline (T-37d to T-7d) daily averages:")
    for r in rows_base:
        pa_short = r[0][:16]
        print(f"  {pa_short}: avg_daily_t0_sell={float(r[3] or 0):,.2f}, avg_daily_t0_buy={float(r[4] or 0):,.2f}, avg_daily_t0_net_sell={float(r[5] or 0):,.2f}, avg_daily_t1_sell={float(r[6] or 0):,.2f}, avg_impact={float(r[8] or 0):.4f} bps")

    # Aggregate maturity window totals for comparison
    if rows_mat:
        total_swaps = sum(r[2] or 0 for r in rows_mat)
        total_t0_sell = sum(float(r[3] or 0) for r in rows_mat)
        total_t0_buy = sum(float(r[4] or 0) for r in rows_mat)
        total_t0_net = sum(float(r[7] or 0) for r in rows_mat)
        total_days = len(set(r[1] for r in rows_mat))
        print(f"\n  Maturity window totals ({total_days} days):")
        print(f"    Total swaps: {total_swaps}")
        print(f"    Total t0 sell vol: {total_t0_sell:,.2f}")
        print(f"    Total t0 buy vol: {total_t0_buy:,.2f}")
        print(f"    Total t0 net sell: {total_t0_net:,.2f}")
        print(f"    Avg daily t0 sell: {total_t0_sell / total_days:,.2f}")
        print(f"    Avg daily t0 net sell: {total_t0_net / total_days:,.2f}")

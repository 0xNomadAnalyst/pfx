"""Phase 3: Primary market activity (Solstice USX/eUSX) around maturity dates."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from db import run_query

MATURITY = {
    "USX": {"ts": 1770634699, "date": "2026-02-09"},
    "eUSX": {"ts": 1773226699, "date": "2026-03-11"},
}

# =========================================================================
# 3a. USX mint/redeem flows around each maturity
# =========================================================================
for mat_name, mat in MATURITY.items():
    print(f"\n{'='*70}")
    print(f"  3a. USX Mint/Redeem Around {mat_name} Maturity ({mat['date']})")
    print(f"{'='*70}")

    sql = """
    SELECT
        time_bucket('1 day', bucket) AS day,
        SUM(event_count) AS total_events,
        SUM(cnt_request_mint) AS req_mints,
        SUM(cnt_confirm_mint) AS conf_mints,
        SUM(cnt_request_redeem) AS req_redeems,
        SUM(cnt_confirm_redeem) AS conf_redeems,
        SUM(collateral_requested_mint) AS coll_req_mint,
        SUM(usx_confirmed_mint) AS usx_conf_mint,
        SUM(collateral_requested_redeem) AS coll_req_redeem,
        SUM(usx_confirmed_redeem) AS usx_conf_redeem,
        SUM(unique_users_minting) AS users_mint,
        SUM(unique_users_redeeming) AS users_redeem
    FROM solstice_proprietary.cagg_usx_events_5s
    WHERE bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
      AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
    GROUP BY 1
    ORDER BY 1;
    """
    cols, rows = run_query(sql, (mat["ts"], mat["ts"]))
    print(f"Rows: {len(rows)}")
    print(f"{'day':12s} | {'events':>7s} | {'req_mint':>9s} | {'conf_mint':>10s} | {'req_redeem':>10s} | {'conf_redeem':>11s} | {'usx_minted':>14s} | {'usx_redeemed':>14s} | {'u_mint':>6s} | {'u_redeem':>8s}")
    print("-" * 130)
    for r in rows:
        day = r[0].strftime("%Y-%m-%d")
        print(f"{day:12s} | {r[1] or 0:>7} | {r[2] or 0:>9} | {r[3] or 0:>10} | {r[4] or 0:>10} | {r[5] or 0:>11} | {float(r[7] or 0):>14.2f} | {float(r[9] or 0):>14.2f} | {r[10] or 0:>6} | {r[11] or 0:>8}")

    # Baseline
    baseline_sql = """
    SELECT
        SUM(event_count) / 30.0 AS avg_daily_events,
        SUM(cnt_request_mint) / 30.0 AS avg_daily_req_mint,
        SUM(cnt_confirm_mint) / 30.0 AS avg_daily_conf_mint,
        SUM(cnt_request_redeem) / 30.0 AS avg_daily_req_redeem,
        SUM(cnt_confirm_redeem) / 30.0 AS avg_daily_conf_redeem,
        SUM(usx_confirmed_mint) / 30.0 AS avg_daily_usx_mint,
        SUM(usx_confirmed_redeem) / 30.0 AS avg_daily_usx_redeem
    FROM solstice_proprietary.cagg_usx_events_5s
    WHERE bucket >= TO_TIMESTAMP(%s) - INTERVAL '37 days'
      AND bucket < TO_TIMESTAMP(%s) - INTERVAL '7 days';
    """
    cols_b, rows_b = run_query(baseline_sql, (mat["ts"], mat["ts"]))
    if rows_b and rows_b[0][0]:
        b = rows_b[0]
        print(f"\nBaseline daily avg: events={float(b[0]):.0f}, req_mint={float(b[1]):.0f}, conf_mint={float(b[2]):.0f}, req_redeem={float(b[3]):.0f}, conf_redeem={float(b[4]):.0f}, usx_mint={float(b[5]):,.0f}, usx_redeem={float(b[6]):,.0f}")


# =========================================================================
# 3b. eUSX lock/unlock/withdraw around each maturity
# =========================================================================
for mat_name, mat in MATURITY.items():
    print(f"\n{'='*70}")
    print(f"  3b. eUSX Lock/Unlock/Withdraw Around {mat_name} Maturity ({mat['date']})")
    print(f"{'='*70}")

    sql = """
    SELECT
        time_bucket('1 day', bucket) AS day,
        SUM(event_count) AS total_events,
        SUM(usx_locked) AS usx_locked,
        SUM(usx_unlocked) AS usx_unlocked,
        SUM(usx_withdrawn) AS usx_withdrawn,
        SUM(usx_yield_harvested) AS usx_yield,
        SUM(eusx_minted) AS eusx_minted,
        SUM(eusx_burned) AS eusx_burned,
        SUM(net_usx_flow) AS net_usx_flow,
        SUM(net_eusx_supply_change) AS net_eusx_supply
    FROM solstice_proprietary.cagg_eusx_events_5s
    WHERE bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
      AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
    GROUP BY 1
    ORDER BY 1;
    """
    cols, rows = run_query(sql, (mat["ts"], mat["ts"]))
    print(f"Rows: {len(rows)}")
    print(f"{'day':12s} | {'events':>7s} | {'locked':>14s} | {'unlocked':>14s} | {'withdrawn':>14s} | {'yield':>14s} | {'minted':>14s} | {'burned':>14s} | {'net_usx':>14s} | {'net_eusx':>14s}")
    print("-" * 150)
    for r in rows:
        day = r[0].strftime("%Y-%m-%d")
        print(f"{day:12s} | {r[1] or 0:>7} | {float(r[2] or 0):>14.2f} | {float(r[3] or 0):>14.2f} | {float(r[4] or 0):>14.2f} | {float(r[5] or 0):>14.2f} | {float(r[6] or 0):>14.2f} | {float(r[7] or 0):>14.2f} | {float(r[8] or 0):>14.2f} | {float(r[9] or 0):>14.2f}")

    baseline_sql = """
    SELECT
        SUM(event_count) / 30.0 AS avg_daily_events,
        SUM(usx_locked) / 30.0 AS avg_daily_locked,
        SUM(usx_unlocked) / 30.0 AS avg_daily_unlocked,
        SUM(usx_withdrawn) / 30.0 AS avg_daily_withdrawn,
        SUM(net_usx_flow) / 30.0 AS avg_daily_net_usx,
        SUM(net_eusx_supply_change) / 30.0 AS avg_daily_net_eusx
    FROM solstice_proprietary.cagg_eusx_events_5s
    WHERE bucket >= TO_TIMESTAMP(%s) - INTERVAL '37 days'
      AND bucket < TO_TIMESTAMP(%s) - INTERVAL '7 days';
    """
    cols_b, rows_b = run_query(baseline_sql, (mat["ts"], mat["ts"]))
    if rows_b and rows_b[0][0]:
        b = rows_b[0]
        print(f"\nBaseline daily avg: events={float(b[0]):.0f}, locked={float(b[1]):,.0f}, unlocked={float(b[2]):,.0f}, withdrawn={float(b[3]):,.0f}, net_usx={float(b[4]):,.0f}, net_eusx={float(b[5]):,.0f}")


# =========================================================================
# 3c. eUSX cascade: user-level eUSX withdraw → USX redeem
# =========================================================================
for mat_name, mat in MATURITY.items():
    print(f"\n{'='*70}")
    print(f"  3c. Cascade: eUSX Withdraw -> USX Redeem ({mat_name} maturity)")
    print(f"{'='*70}")

    sql = """
    WITH eusx_exits AS (
        SELECT user_address, meta_block_time, share_amount, event_type
        FROM solstice_proprietary.src_eusx_tx_events
        WHERE event_type IN ('withdraw', 'unlock')
          AND meta_block_time >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND meta_block_time <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
          AND meta_success = TRUE
    ),
    usx_redeems AS (
        SELECT user_address, meta_block_time, redeemable_amount, event_name
        FROM solstice_proprietary.src_usx_tx_events
        WHERE event_category = 'redeem'
          AND event_name IN ('request_redeem', 'confirm_redeem')
          AND meta_block_time >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND meta_block_time <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
          AND meta_success = TRUE
    )
    SELECT
        DATE_TRUNC('day', e.meta_block_time) AS day,
        COUNT(DISTINCT e.user_address) AS cascade_users,
        COUNT(*) AS cascade_events
    FROM eusx_exits e
    INNER JOIN usx_redeems r
        ON e.user_address = r.user_address
        AND r.meta_block_time BETWEEN e.meta_block_time AND e.meta_block_time + INTERVAL '48 hours'
    GROUP BY 1
    ORDER BY 1;
    """
    cols, rows = run_query(sql, (mat["ts"], mat["ts"], mat["ts"], mat["ts"]))
    print(f"Cascade events (eUSX exit → USX redeem within 48h by same user):")
    print(f"Rows: {len(rows)}")
    for r in rows:
        day = r[0].strftime("%Y-%m-%d")
        print(f"  {day}: {r[1]} users, {r[2]} events")

    # Also count unique users who did both eUSX exit and USX redeem in window
    sql2 = """
    WITH eusx_users AS (
        SELECT DISTINCT user_address
        FROM solstice_proprietary.src_eusx_tx_events
        WHERE event_type IN ('withdraw', 'unlock')
          AND meta_block_time >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND meta_block_time <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
          AND meta_success = TRUE
    ),
    usx_users AS (
        SELECT DISTINCT user_address
        FROM solstice_proprietary.src_usx_tx_events
        WHERE event_category = 'redeem'
          AND meta_block_time >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND meta_block_time <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
          AND meta_success = TRUE
    )
    SELECT
        (SELECT COUNT(*) FROM eusx_users) AS eusx_exit_users,
        (SELECT COUNT(*) FROM usx_users) AS usx_redeem_users,
        COUNT(*) AS overlap_users
    FROM eusx_users e
    INNER JOIN usx_users u ON e.user_address = u.user_address;
    """
    cols2, rows2 = run_query(sql2, (mat["ts"], mat["ts"], mat["ts"], mat["ts"]))
    if rows2:
        print(f"\n  Total eUSX exit users: {rows2[0][0]}")
        print(f"  Total USX redeem users: {rows2[0][1]}")
        print(f"  Overlap (both actions): {rows2[0][2]}")


# =========================================================================
# 3d. eUSX yield pool state around maturity
# =========================================================================
for mat_name, mat in MATURITY.items():
    print(f"\n{'='*70}")
    print(f"  3d. eUSX Yield Pool State Around {mat_name} Maturity ({mat['date']})")
    print(f"{'='*70}")

    sql = """
    SELECT
        time_bucket('1 day', bucket) AS day,
        LAST(total_assets, bucket) AS total_assets,
        LAST(shares_supply, bucket) AS shares_supply,
        LAST(total_assets, bucket)::NUMERIC / NULLIF(LAST(shares_supply, bucket)::NUMERIC, 0) AS exchange_rate
    FROM solstice_proprietary.cagg_eusx_yieldpool_5s
    WHERE bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
      AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
    GROUP BY 1
    ORDER BY 1;
    """
    cols, rows = run_query(sql, (mat["ts"], mat["ts"]))
    print(f"Rows: {len(rows)}")
    for r in rows:
        day = r[0].strftime("%Y-%m-%d")
        ta = float(r[1] or 0)
        ss = float(r[2] or 0)
        er = float(r[3] or 0) if r[3] else 0
        print(f"  {day}: total_assets={ta:>14,.2f}, shares_supply={ss:>14,.2f}, exchange_rate={er:.8f}")

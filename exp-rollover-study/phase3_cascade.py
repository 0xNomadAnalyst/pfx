"""Phase 3c+3d: Cascade detection and yield pool state."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from db import run_query

MATURITY = {
    "USX": {"ts": 1770634699, "date": "2026-02-09"},
    "eUSX": {"ts": 1773226699, "date": "2026-03-11"},
}

# 3c. Cascade detection
for mat_name, mat in MATURITY.items():
    print(f"\n{'='*70}")
    print(f"  3c. Cascade: eUSX exit -> USX redeem ({mat_name} maturity)")
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
    print(f"Cascade events (eUSX exit -> USX redeem within 48h by same user):")
    print(f"Rows: {len(rows)}")
    for r in rows:
        day = r[0].strftime("%Y-%m-%d")
        print(f"  {day}: {r[1]} users, {r[2]} cascade events")

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
        print(f"  Overlap (both actions in window): {rows2[0][2]}")


# 3d. eUSX yield pool state
for mat_name, mat in MATURITY.items():
    print(f"\n{'='*70}")
    print(f"  3d. eUSX Yield Pool Around {mat_name} Maturity ({mat['date']})")
    print(f"{'='*70}")

    sql = """
    SELECT
        time_bucket('1 day', bucket) AS day,
        LAST(total_assets, bucket) AS total_assets,
        LAST(shares_supply, bucket) AS shares_supply
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
        er = ta / ss if ss > 0 else 0
        print(f"  {day}: total_assets={ta:>20,.0f}, shares_supply={ss:>20,.0f}, xrate={er:.10f}")


# 3e. USX controller supply around maturity
for mat_name, mat in MATURITY.items():
    print(f"\n{'='*70}")
    print(f"  3e. USX Controller Supply Around {mat_name} Maturity ({mat['date']})")
    print(f"{'='*70}")

    sql = """
    SELECT
        time_bucket('1 day', bucket) AS day,
        LAST(redeemable_circulating_supply, bucket) AS circ_supply
    FROM solstice_proprietary.cagg_usx_controller_5s
    WHERE bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
      AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
    GROUP BY 1
    ORDER BY 1;
    """
    cols, rows = run_query(sql, (mat["ts"], mat["ts"]))
    print(f"Rows: {len(rows)}")
    for r in rows:
        day = r[0].strftime("%Y-%m-%d")
        cs = float(r[1] or 0)
        print(f"  {day}: circ_supply={cs:>20,.0f} (={cs/1e6:>14,.0f} USX)")

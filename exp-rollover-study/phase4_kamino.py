"""Phase 4: Kamino collateral activity around maturity dates."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from db import run_query

MATURITY = {
    "USX": {"ts": 1770634699, "date": "2026-02-09"},
    "eUSX": {"ts": 1773226699, "date": "2026-03-11"},
}

# PT mints from Phase 0
PT_MINTS = {
    "USX_expired": "7vWj1UriSscGmz5wadAC8EkA8ndoU3M7WUifqxTC3Ysf",
    "USX_new": "3kctCXgt6pP3uZcek8SqNK2KZdQ6cqtj9hc3U46jhgBk",
    "eUSX_expired": "6oiDcfve7ybKUC8ysZmncC9iSuxQG2vrRkh3dgV7EKR4",
    "eUSX_new": "BNR2FsHo8JrYGWx2V8yxG5GBWiG3uU8voi2eMGBHFwEj",
}

# =========================================================================
# 4a. Identify PT reserves on Kamino
# =========================================================================
print("=" * 70)
print("  4a. Identify PT/USX/eUSX reserves on Kamino")
print("=" * 70)

sql = """
SELECT reserve_address, token_mint, token_symbol, reserve_type, reserve_status,
       loan_to_value_pct, liquidation_threshold_pct, market_address
FROM kamino_lend.aux_market_reserve_tokens
WHERE token_symbol ILIKE '%%pt%%'
   OR token_symbol ILIKE '%%usx%%'
   OR token_symbol ILIKE '%%eusx%%'
   OR token_mint IN (%s, %s, %s, %s)
ORDER BY token_symbol;
"""
cols, rows = run_query(sql, (
    PT_MINTS["USX_expired"], PT_MINTS["USX_new"],
    PT_MINTS["eUSX_expired"], PT_MINTS["eUSX_new"],
))
print(f"Found {len(rows)} reserves")
for r in rows:
    print(f"  {str(r[2] or ''):16s} | type={str(r[3] or ''):12s} | status={str(r[4] or ''):12s} | ltv={r[5]}% | liq={r[6]}% | reserve={r[0][:20]}... | mint={r[1][:20]}...")

# Collect reserve addresses for downstream queries
reserve_map = {}
for r in rows:
    reserve_map[r[2]] = {"address": r[0], "mint": r[1], "type": r[3], "status": r[4]}

# Also try broader search by mint address
print("\n  Searching by PT mint addresses directly...")
sql2 = """
SELECT reserve_address, token_mint, token_symbol, reserve_type, reserve_status
FROM kamino_lend.aux_market_reserve_tokens
WHERE token_mint = ANY(%s);
"""
all_pt_mints = list(PT_MINTS.values())
cols2, rows2 = run_query(sql2, (all_pt_mints,))
print(f"  Found {len(rows2)} by mint address match")
for r in rows2:
    print(f"    {str(r[2] or ''):16s} | {str(r[3] or ''):12s} | {str(r[4] or ''):12s} | reserve={r[0][:20]}... | mint={r[1][:20]}...")


# =========================================================================
# 4b. Reserve-level deposit/withdrawal flows
# =========================================================================
# Get all relevant reserve addresses
relevant_reserves = []
for r in rows:
    relevant_reserves.append(r[0])
for r in rows2:
    if r[0] not in relevant_reserves:
        relevant_reserves.append(r[0])

if not relevant_reserves:
    print("\nNo relevant Kamino reserves found - skipping 4b-4d")
else:
    for mat_name, mat in MATURITY.items():
        print(f"\n{'='*70}")
        print(f"  4b. Kamino Activity Around {mat_name} Maturity ({mat['date']})")
        print(f"{'='*70}")

        sql = """
        SELECT
            time_bucket('1 day', bucket) AS day,
            symbol,
            reserve_address,
            SUM(deposit_vault_sum) AS deposits,
            SUM(deposit_vault_count) AS dep_count,
            SUM(withdraw_vault_sum) AS withdrawals,
            SUM(withdraw_vault_count) AS wdl_count,
            SUM(deposit_vault_sum) - SUM(withdraw_vault_sum) AS net_flow,
            SUM(total_activity_count) AS total_acts
        FROM kamino_lend.cagg_activities_5s
        WHERE reserve_address = ANY(%s)
          AND bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
        GROUP BY 1, 2, 3
        ORDER BY 1, 2;
        """
        cols, rows_act = run_query(sql, (relevant_reserves, mat["ts"], mat["ts"]))
        print(f"Rows: {len(rows_act)}")
        if rows_act:
            print(f"{'day':12s} | {'symbol':16s} | {'deposits':>14s} | {'dep_cnt':>7s} | {'withdrawals':>14s} | {'wdl_cnt':>7s} | {'net_flow':>14s} | {'total':>6s}")
            print("-" * 110)
            for r in rows_act:
                day = r[0].strftime("%Y-%m-%d")
                print(f"{day:12s} | {r[1] or '':16s} | {float(r[3] or 0):>14.2f} | {r[4] or 0:>7} | {float(r[5] or 0):>14.2f} | {r[6] or 0:>7} | {float(r[7] or 0):>14.2f} | {r[8] or 0:>6}")

    # =========================================================================
    # 4c. Reserve state (collateral supply) around maturity
    # =========================================================================
    for mat_name, mat in MATURITY.items():
        print(f"\n{'='*70}")
        print(f"  4c. Kamino Reserve State Around {mat_name} Maturity ({mat['date']})")
        print(f"{'='*70}")

        sql = """
        SELECT
            time_bucket('1 day', bucket) AS day,
            symbol,
            reserve_address,
            LAST(collateral_total_supply, bucket) AS coll_supply,
            LAST(vault_collateral_balance, bucket) AS coll_balance,
            LAST(supply_total, bucket) AS supply_total,
            LAST(supply_available, bucket) AS supply_avail,
            LAST(supply_borrowed, bucket) AS supply_borrowed,
            LAST(utilization_ratio, bucket) AS util_ratio,
            LAST(deposit_tvl, bucket) AS dep_tvl
        FROM kamino_lend.cagg_reserves_5s
        WHERE reserve_address = ANY(%s)
          AND bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
        GROUP BY 1, 2, 3
        ORDER BY 1, 2;
        """
        cols, rows_res = run_query(sql, (relevant_reserves, mat["ts"], mat["ts"]))
        print(f"Rows: {len(rows_res)}")
        if rows_res:
            print(f"{'day':12s} | {'symbol':16s} | {'coll_supply':>14s} | {'supply_total':>14s} | {'supply_avail':>14s} | {'borrowed':>14s} | {'util':>8s} | {'dep_tvl':>14s}")
            print("-" * 120)
            for r in rows_res:
                day = r[0].strftime("%Y-%m-%d")
                print(f"{day:12s} | {r[1] or '':16s} | {float(r[3] or 0):>14.2f} | {float(r[5] or 0):>14.2f} | {float(r[6] or 0):>14.2f} | {float(r[7] or 0):>14.2f} | {float(r[8] or 0):>8.4f} | {float(r[9] or 0):>14.2f}")

    # =========================================================================
    # 4d. Liquidation events around maturity
    # =========================================================================
    for mat_name, mat in MATURITY.items():
        print(f"\n{'='*70}")
        print(f"  4d. Kamino Liquidations Around {mat_name} Maturity ({mat['date']})")
        print(f"{'='*70}")

        sql = """
        SELECT
            DATE_TRUNC('day', meta_block_time) AS day,
            reserve_address,
            activity_category,
            COUNT(*) AS event_count,
            SUM(liquidity_amount) AS liq_amount
        FROM kamino_lend.src_txn_events
        WHERE reserve_address = ANY(%s)
          AND activity_category = 'liquidate'
          AND meta_block_time >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND meta_block_time <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
          AND meta_success = TRUE
        GROUP BY 1, 2, 3
        ORDER BY 1;
        """
        cols, rows_liq = run_query(sql, (relevant_reserves, mat["ts"], mat["ts"]))
        print(f"Liquidation events: {len(rows_liq)}")
        for r in rows_liq:
            day = r[0].strftime("%Y-%m-%d")
            print(f"  {day}: reserve={r[1][:20]}..., count={r[3]}, amount={r[4]}")

        if len(rows_liq) == 0:
            print("  No liquidation events found.")

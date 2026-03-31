"""Phase 1: Exponent market state and flows at maturity."""
import sys, os, json
sys.path.insert(0, os.path.dirname(__file__))
from db import run_query, run_query_dict, md_table
from datetime import datetime, timezone

# Market definitions from Phase 0
MARKETS = {
    "USX": {
        "expired": {
            "vault": "HJZigEFmMwArysvFpieGsEEZqWczitHFUmzUHTMkXpsW",
            "market": "31XQjgfV5PiF2yXEbyctpq7gZ1TALkC9JvygjiR8xJrB",
            "maturity_ts": 1770634699,
        },
        "new": {
            "vault": "4hZugBhgd3xxShK5iHbBAwCnJUjthiStT6LnruRwarjr",
            "market": "BxbiZpzj32nrVGecFy8VQ1HohaW7ryhas1k9aiETDWdm",
            "maturity_ts": 1780318699,
        },
    },
    "eUSX": {
        "expired": {
            "vault": "5G1jVLtmqYctNTU7ok1rr8t2SeSKe8LcFUSh63EX8WWg",
            "market": "GhjqLUcaCrfH9s6bM5H9GvbWoDTYGsdXxVubP8J57cUr",
            "maturity_ts": 1773226699,
        },
        "new": {
            "vault": "7NviQEEiA5RSY4aL1wpqGE8CYAx2Lx7THHinsW1CWDXu",
            "market": "rBbzpGk3PTX8mvQg95VWJ24EDgvxyDJYrEo9jtauvjP",
            "maturity_ts": 1780318699,
        },
    },
}

def ts_to_dt(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


# =========================================================================
# 1a. Pre-maturity market state (final 7 days) - PT price convergence
# =========================================================================
def query_1a(asset):
    m = MARKETS[asset]["expired"]
    mat_ts = m["maturity_ts"]
    mat_dt = datetime.fromtimestamp(mat_ts, tz=timezone.utc)
    sql = """
    SELECT
        time_bucket('1 hour', bucket) AS hour,
        LAST(c_implied_pt_price, bucket) AS pt_price,
        LAST(c_implied_apy, bucket) AS implied_apy,
        LAST(pt_balance_ui, bucket) AS pt_reserve,
        LAST(sy_balance_ui, bucket) AS sy_reserve,
        LAST(c_total_market_depth_in_sy, bucket) AS pool_depth_sy,
        LAST(c_reserve_ratio, bucket) AS reserve_ratio,
        LAST(lp_escrow_amount_ui, bucket) AS lp_supply
    FROM exponent.cagg_market_twos_5s
    WHERE market_address = %s
      AND bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
      AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '1 day'
    GROUP BY 1
    ORDER BY 1;
    """
    cols, rows = run_query(sql, (m["market"], mat_ts, mat_ts))
    print(f"\n=== 1a. {asset} Market State (T-7d to T+1d) ===")
    print(f"Maturity: {ts_to_dt(mat_ts)}")
    print(f"Rows: {len(rows)}")
    if rows:
        print(f"First: {rows[0][0]}, Last: {rows[-1][0]}")
        print(f"PT price range: {min(r[1] for r in rows if r[1])} -> {max(r[1] for r in rows if r[1])}")
        last_pre = [r for r in rows if r[0] < mat_dt]
        if last_pre:
            lp = last_pre[-1]
            print(f"Last pre-maturity hour: pt_price={lp[1]}, apy={lp[2]}, pt_reserve={lp[3]}, sy_reserve={lp[4]}, lp={lp[7]}")
        post = [r for r in rows if r[0] >= mat_dt]
        if post:
            fp = post[0]
            print(f"First post-maturity hour: pt_price={fp[1]}, apy={fp[2]}, pt_reserve={fp[3]}, sy_reserve={fp[4]}, lp={fp[7]}")
    return cols, rows


# =========================================================================
# 1a-vault. Vault state final 7 days
# =========================================================================
def query_1a_vault(asset):
    m = MARKETS[asset]["expired"]
    mat_ts = m["maturity_ts"]
    sql = """
    SELECT
        time_bucket('1 hour', bucket) AS hour,
        LAST(total_sy_in_escrow_ui, bucket) AS total_sy,
        LAST(pt_supply_ui, bucket) AS pt_supply,
        LAST(c_collateralization_ratio, bucket) AS coll_ratio,
        LAST(last_seen_sy_exchange_rate, bucket) AS sy_rate,
        LAST(final_sy_exchange_rate, bucket) AS final_sy_rate,
        LAST(status, bucket) AS vault_status
    FROM exponent.cagg_vaults_5s
    WHERE vault_address = %s
      AND bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
      AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
    GROUP BY 1
    ORDER BY 1;
    """
    cols, rows = run_query(sql, (m["vault"], mat_ts, mat_ts))
    print(f"\n=== 1a-vault. {asset} Vault State (T-7d to T+14d) ===")
    print(f"Rows: {len(rows)}")
    if rows:
        pre = [r for r in rows if r[0] < datetime.fromtimestamp(mat_ts, tz=timezone.utc)]
        post = [r for r in rows if r[0] >= datetime.fromtimestamp(mat_ts, tz=timezone.utc)]
        if pre:
            lp = pre[-1]
            print(f"Last pre-maturity: sy={lp[1]}, pt_supply={lp[2]}, coll_ratio={lp[3]}, sy_rate={lp[4]}, final_rate={lp[5]}, status={lp[6]}")
        if post:
            fp = post[0]
            ep = post[-1]
            print(f"First post-maturity: sy={fp[1]}, pt_supply={fp[2]}, coll_ratio={fp[3]}, final_rate={fp[5]}, status={fp[6]}")
            print(f"Last post (T+14d): sy={ep[1]}, pt_supply={ep[2]}, coll_ratio={ep[3]}, final_rate={ep[5]}, status={ep[6]}")
    return cols, rows


# =========================================================================
# 1b. Strip/merge/trade activity around maturity
# =========================================================================
def query_1b(asset):
    exp_m = MARKETS[asset]["expired"]
    new_m = MARKETS[asset]["new"]
    mat_ts = exp_m["maturity_ts"]

    sql = """
    SELECT
        CASE WHEN vault_address = %s THEN 'expired' ELSE 'new' END AS market_gen,
        event_type,
        time_bucket('1 day', bucket_time) AS day,
        SUM(event_count) AS events,
        SUM(amount_vault_sy_in) AS sy_into_vault,
        SUM(amount_vault_sy_out) AS sy_out_of_vault,
        SUM(amount_vault_pt_in) AS pt_into_vault,
        SUM(amount_vault_pt_out) AS pt_out_of_vault,
        SUM(amount_amm_pt_in) AS amm_pt_in,
        SUM(amount_amm_pt_out) AS amm_pt_out,
        SUM(amount_amm_sy_in) AS amm_sy_in,
        SUM(amount_amm_sy_out) AS amm_sy_out,
        SUM(amount_lp_tokens_in) AS lp_in,
        SUM(amount_lp_tokens_out) AS lp_out,
        SUM(amount_base_in) AS base_in,
        SUM(amount_base_out) AS base_out
    FROM exponent.cagg_tx_events_5s
    WHERE vault_address IN (%s, %s)
      AND bucket_time >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
      AND bucket_time <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
    GROUP BY 1, 2, 3
    ORDER BY 3, 1, 2;
    """
    cols, rows = run_query(sql, (exp_m["vault"], exp_m["vault"], new_m["vault"], mat_ts, mat_ts))
    print(f"\n=== 1b. {asset} Event Flows (T-7d to T+14d) ===")
    print(f"Rows: {len(rows)}")

    # Summary by market_gen and event_type
    summary = {}
    for r in rows:
        key = (r[0], r[1])
        if key not in summary:
            summary[key] = {"events": 0, "sy_in": 0, "sy_out": 0, "pt_in": 0, "pt_out": 0, "base_in": 0, "base_out": 0}
        summary[key]["events"] += (r[3] or 0)
        summary[key]["sy_in"] += float(r[4] or 0)
        summary[key]["sy_out"] += float(r[5] or 0)
        summary[key]["pt_in"] += float(r[6] or 0)
        summary[key]["pt_out"] += float(r[7] or 0)
        summary[key]["base_in"] += float(r[14] or 0)
        summary[key]["base_out"] += float(r[15] or 0)

    for (gen, evt), v in sorted(summary.items()):
        print(f"  {gen:8s} | {evt:12s} | events={v['events']:>6} | sy_in={v['sy_in']:>14.2f} | sy_out={v['sy_out']:>14.2f} | pt_in={v['pt_in']:>14.2f} | pt_out={v['pt_out']:>14.2f} | base_in={v['base_in']:>14.2f} | base_out={v['base_out']:>14.2f}")

    return cols, rows, summary


# =========================================================================
# 1c. Vault drawdown post-maturity (extended T+14d)
# =========================================================================
def query_1c(asset):
    m = MARKETS[asset]["expired"]
    mat_ts = m["maturity_ts"]
    sql = """
    SELECT
        time_bucket('6 hours', bucket) AS period,
        LAST(total_sy_in_escrow_ui, bucket) AS total_sy,
        LAST(pt_supply_ui, bucket) AS pt_supply,
        LAST(c_collateralization_ratio, bucket) AS coll_ratio
    FROM exponent.cagg_vaults_5s
    WHERE vault_address = %s
      AND bucket >= TO_TIMESTAMP(%s)
      AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
    GROUP BY 1
    ORDER BY 1;
    """
    cols, rows = run_query(sql, (m["vault"], mat_ts, mat_ts))
    print(f"\n=== 1c. {asset} Vault Drawdown Post-Maturity ===")
    print(f"Rows: {len(rows)}")
    if rows:
        print(f"At maturity: sy={rows[0][1]}, pt_supply={rows[0][2]}, coll={rows[0][3]}")
        print(f"At T+14d:    sy={rows[-1][1]}, pt_supply={rows[-1][2]}, coll={rows[-1][3]}")
        if rows[0][2] and float(rows[0][2]) > 0:
            remaining_pct = float(rows[-1][2] or 0) / float(rows[0][2]) * 100
            print(f"PT supply remaining: {remaining_pct:.1f}%")
    return cols, rows


# Run all
print("=" * 80)
print("PHASE 1: EXPONENT MATURITY ANALYSIS")
print("=" * 80)

results = {}
for asset in ["USX", "eUSX"]:
    print(f"\n{'='*60}")
    print(f"  {asset}")
    print(f"{'='*60}")
    r1a = query_1a(asset)
    r1a_v = query_1a_vault(asset)
    r1b = query_1b(asset)
    r1c = query_1c(asset)
    results[asset] = {
        "market_state": r1a,
        "vault_state": r1a_v,
        "event_flows": r1b,
        "drawdown": r1c,
    }

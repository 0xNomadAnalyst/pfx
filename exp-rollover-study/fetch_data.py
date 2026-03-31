"""
Data fetching script for Exponent rollover study.
Pulls data from TimescaleDB and saves to local parquet files.

Usage:
    python pfx/exp-rollover-study/fetch_data.py
"""

import polars as pl
from pathlib import Path
from db import get_conn

PARQUET_DIR = Path(__file__).parent / "parquet"
PARQUET_DIR.mkdir(exist_ok=True)

MARKETS = {
    "USX": {
        "expired_vault": "HJZigEFmMwArysvFpieGsEEZqWczitHFUmzUHTMkXpsW",
        "new_vault": "4hZugBhgd3xxShK5iHbBAwCnJUjthiStT6LnruRwarjr",
        "expired_market": "31XQjgfV5PiF2yXEbyctpq7gZ1TALkC9JvygjiR8xJrB",
        "maturity_ts": 1770634699,
        "label": "PT-USX",
    },
    "eUSX": {
        "expired_vault": "5G1jVLtmqYctNTU7ok1rr8t2SeSKe8LcFUSh63EX8WWg",
        "new_vault": "7NviQEEiA5RSY4aL1wpqGE8CYAx2Lx7THHinsW1CWDXu",
        "expired_market": "GhjqLUcaCrfH9s6bM5H9GvbWoDTYGsdXxVubP8J57cUr",
        "maturity_ts": 1773226699,
        "label": "PT-eUSX",
    },
}

PT_MINTS = {
    "USX_expired": "7vWj1UriSscGmz5wadAC8EkA8ndoU3M7WUifqxTC3Ysf",
    "USX_new": "3kctCXgt6pP3uZcek8SqNK2KZdQ6cqtj9hc3U46jhgBk",
    "eUSX_expired": "6oiDcfve7ybKUC8ysZmncC9iSuxQG2vrRkh3dgV7EKR4",
    "eUSX_new": "BNR2FsHo8JrYGWx2V8yxG5GBWiG3uU8voi2eMGBHFwEj",
}


def _query_to_polars(sql: str, params=None) -> pl.DataFrame:
    """Execute SQL and return as a polars DataFrame."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
    if not rows:
        return pl.DataFrame()
    import pandas as pd
    pdf = pd.DataFrame(rows, columns=cols)
    return pl.from_pandas(pdf)


def fetch_vault_drawdown():
    """Vault PT supply and SY escrow at 6h intervals around each maturity."""
    print("Fetching vault drawdown data...")
    frames = []
    for asset, m in MARKETS.items():
        sql = """
        SELECT
            time_bucket('6 hours', bucket) AS period,
            LAST(total_sy_in_escrow_ui, bucket) AS total_sy,
            LAST(pt_supply_ui, bucket) AS pt_supply,
            LAST(c_collateralization_ratio, bucket) AS coll_ratio,
            LAST(last_seen_sy_exchange_rate, bucket) AS sy_rate
        FROM exponent.cagg_vaults_5s
        WHERE vault_address = %s
          AND bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '21 days'
        GROUP BY 1
        ORDER BY 1;
        """
        df = _query_to_polars(sql, (m["expired_vault"], m["maturity_ts"], m["maturity_ts"]))
        if len(df) > 0:
            df = df.with_columns(
                pl.lit(asset).alias("asset"),
                pl.lit(m["label"]).alias("label"),
            )
            frames.append(df)
    if frames:
        result = pl.concat(frames)
        result.write_parquet(PARQUET_DIR / "vault_drawdown.parquet")
        print(f"  -> {len(result)} rows")
    return result if frames else pl.DataFrame()


def fetch_market_state():
    """PT price convergence at hourly intervals around maturity."""
    print("Fetching market state (PT price)...")
    frames = []
    for asset, m in MARKETS.items():
        sql = """
        SELECT
            time_bucket('1 hour', bucket) AS hour,
            LAST(c_implied_pt_price, bucket) AS pt_price,
            LAST(c_implied_apy, bucket) AS implied_apy,
            LAST(pt_balance_ui, bucket) AS pt_reserve,
            LAST(sy_balance_ui, bucket) AS sy_reserve,
            LAST(lp_escrow_amount_ui, bucket) AS lp_supply
        FROM exponent.cagg_market_twos_5s
        WHERE market_address = %s
          AND bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '2 days'
        GROUP BY 1
        ORDER BY 1;
        """
        df = _query_to_polars(sql, (m["expired_market"], m["maturity_ts"], m["maturity_ts"]))
        if len(df) > 0:
            df = df.with_columns(
                pl.lit(asset).alias("asset"),
                pl.lit(m["label"]).alias("label"),
            )
            frames.append(df)
    if frames:
        result = pl.concat(frames)
        result.write_parquet(PARQUET_DIR / "market_state.parquet")
        print(f"  -> {len(result)} rows")
    return result if frames else pl.DataFrame()


def fetch_event_flows():
    """Strip/merge/trade events aggregated daily for both vaults around each maturity."""
    print("Fetching event flows...")
    frames = []
    for asset, m in MARKETS.items():
        sql = """
        SELECT
            CASE WHEN vault_address = %s THEN 'expired' ELSE 'new' END AS market_gen,
            event_type,
            time_bucket('1 day', bucket_time) AS day,
            SUM(event_count) AS events,
            SUM(amount_vault_sy_in) AS sy_in,
            SUM(amount_vault_sy_out) AS sy_out,
            SUM(amount_vault_pt_in) AS pt_in,
            SUM(amount_vault_pt_out) AS pt_out
        FROM exponent.cagg_tx_events_5s
        WHERE vault_address IN (%s, %s)
          AND bucket_time >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND bucket_time <= TO_TIMESTAMP(%s) + INTERVAL '14 days'
        GROUP BY 1, 2, 3
        ORDER BY 3, 1, 2;
        """
        df = _query_to_polars(sql, (
            m["expired_vault"], m["expired_vault"], m["new_vault"],
            m["maturity_ts"], m["maturity_ts"],
        ))
        if len(df) > 0:
            df = df.with_columns(
                pl.lit(asset).alias("asset"),
                pl.lit(m["label"]).alias("label"),
            )
            frames.append(df)
    if frames:
        result = pl.concat(frames)
        result.write_parquet(PARQUET_DIR / "event_flows.parquet")
        print(f"  -> {len(result)} rows")
    return result if frames else pl.DataFrame()


def fetch_dex_daily():
    """DEX daily swap volume and net sell pressure around each maturity + baseline."""
    print("Fetching DEX daily swap data...")
    frames = []
    for asset, m in MARKETS.items():
        # Wider window: baseline (T-37d) through post-maturity (T+21d)
        sql = """
        SELECT
            pool_address,
            time_bucket('1 day', bucket_time) AS day,
            SUM(event_count) FILTER (WHERE activity_category = 'swap') AS swap_count,
            SUM(amount0_in) FILTER (WHERE activity_category = 'swap') AS t0_sold,
            SUM(amount0_out) FILTER (WHERE activity_category = 'swap') AS t0_bought,
            SUM(amount1_in) FILTER (WHERE activity_category = 'swap') AS t1_sold,
            SUM(amount1_out) FILTER (WHERE activity_category = 'swap') AS t1_bought,
            SUM(amount0_in - amount0_out) FILTER (WHERE activity_category = 'swap') AS t0_net_sell,
            SUM(amount1_in - amount1_out) FILTER (WHERE activity_category = 'swap') AS t1_net_sell
        FROM dexes.cagg_events_5s
        WHERE bucket_time >= TO_TIMESTAMP(%s) - INTERVAL '37 days'
          AND bucket_time <= TO_TIMESTAMP(%s) + INTERVAL '21 days'
        GROUP BY 1, 2
        ORDER BY 1, 2;
        """
        df = _query_to_polars(sql, (m["maturity_ts"], m["maturity_ts"]))
        if len(df) > 0:
            df = df.with_columns(
                pl.lit(asset).alias("maturity_asset"),
                pl.lit(m["maturity_ts"]).alias("maturity_ts"),
            )
            frames.append(df)
    if frames:
        result = pl.concat(frames)
        result.write_parquet(PARQUET_DIR / "dex_daily.parquet")
        print(f"  -> {len(result)} rows")
    return result if frames else pl.DataFrame()


def fetch_dex_pools():
    """Pool reference data for USX and eUSX."""
    print("Fetching DEX pool reference...")
    sql = """
    SELECT pool_address, token_pair, protocol, token0_symbol, token1_symbol,
           token0_address, token1_address, token0_decimals, token1_decimals
    FROM dexes.pool_tokens_reference
    WHERE token0_symbol ILIKE '%%usx%%' OR token1_symbol ILIKE '%%usx%%'
       OR token0_symbol ILIKE '%%eusx%%' OR token1_symbol ILIKE '%%eusx%%';
    """
    df = _query_to_polars(sql)
    if len(df) > 0:
        df.write_parquet(PARQUET_DIR / "dex_pools.parquet")
        print(f"  -> {len(df)} pools")
    return df


def fetch_usx_mint_redeem():
    """USX mint/redeem daily flows around each maturity + baseline."""
    print("Fetching USX mint/redeem data...")
    frames = []
    for asset, m in MARKETS.items():
        sql = """
        SELECT
            time_bucket('1 day', bucket) AS day,
            SUM(cnt_confirm_redeem) AS redeems,
            SUM(cnt_confirm_mint) AS mints,
            SUM(usx_confirmed_mint) AS usx_minted,
            SUM(usx_confirmed_redeem) AS usx_redeemed
        FROM solstice_proprietary.cagg_usx_events_5s
        WHERE bucket >= TO_TIMESTAMP(%s) - INTERVAL '37 days'
          AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '21 days'
        GROUP BY 1
        ORDER BY 1;
        """
        df = _query_to_polars(sql, (m["maturity_ts"], m["maturity_ts"]))
        if len(df) > 0:
            df = df.with_columns(
                pl.lit(asset).alias("maturity_asset"),
                pl.lit(m["maturity_ts"]).alias("maturity_ts"),
            )
            frames.append(df)
    if frames:
        result = pl.concat(frames)
        result.write_parquet(PARQUET_DIR / "usx_mint_redeem.parquet")
        print(f"  -> {len(result)} rows")
    return result if frames else pl.DataFrame()


def fetch_eusx_flows():
    """eUSX lock/unlock/withdraw daily around each maturity."""
    print("Fetching eUSX flow data...")
    frames = []
    for asset, m in MARKETS.items():
        sql = """
        SELECT
            time_bucket('1 day', bucket) AS day,
            SUM(usx_locked) AS usx_locked,
            SUM(usx_unlocked) AS usx_unlocked,
            SUM(usx_withdrawn) AS usx_withdrawn,
            SUM(eusx_minted) AS eusx_minted,
            SUM(eusx_burned) AS eusx_burned,
            SUM(net_usx_flow) AS net_usx_flow,
            SUM(net_eusx_supply_change) AS net_eusx_supply
        FROM solstice_proprietary.cagg_eusx_events_5s
        WHERE bucket >= TO_TIMESTAMP(%s) - INTERVAL '37 days'
          AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '21 days'
        GROUP BY 1
        ORDER BY 1;
        """
        df = _query_to_polars(sql, (m["maturity_ts"], m["maturity_ts"]))
        if len(df) > 0:
            df = df.with_columns(
                pl.lit(asset).alias("maturity_asset"),
                pl.lit(m["maturity_ts"]).alias("maturity_ts"),
            )
            frames.append(df)
    if frames:
        result = pl.concat(frames)
        result.write_parquet(PARQUET_DIR / "eusx_flows.parquet")
        print(f"  -> {len(result)} rows")
    return result if frames else pl.DataFrame()


def fetch_eusx_yield_pool():
    """eUSX yield pool state around each maturity."""
    print("Fetching eUSX yield pool state...")
    frames = []
    for asset, m in MARKETS.items():
        sql = """
        SELECT
            time_bucket('1 day', bucket) AS day,
            LAST(total_assets, bucket) AS total_assets,
            LAST(shares_supply, bucket) AS shares_supply,
            LAST(total_assets, bucket)::NUMERIC
                / NULLIF(LAST(shares_supply, bucket)::NUMERIC, 0) AS exchange_rate
        FROM solstice_proprietary.cagg_eusx_yieldpool_5s
        WHERE bucket >= TO_TIMESTAMP(%s) - INTERVAL '37 days'
          AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '21 days'
        GROUP BY 1
        ORDER BY 1;
        """
        df = _query_to_polars(sql, (m["maturity_ts"], m["maturity_ts"]))
        if len(df) > 0:
            df = df.with_columns(
                pl.lit(asset).alias("maturity_asset"),
                pl.lit(m["maturity_ts"]).alias("maturity_ts"),
            )
            frames.append(df)
    if frames:
        result = pl.concat(frames)
        result.write_parquet(PARQUET_DIR / "eusx_yield_pool.parquet")
        print(f"  -> {len(result)} rows")
    return result if frames else pl.DataFrame()


def fetch_kamino_reserves_state():
    """Kamino reserve state (collateral supply, utilization) daily around each maturity."""
    print("Fetching Kamino reserve state...")
    all_pt_mints = list(PT_MINTS.values())

    ref_sql = """
    SELECT reserve_address, token_mint, token_symbol, reserve_type,
           loan_to_value_pct, liquidation_threshold_pct
    FROM kamino_lend.aux_market_reserve_tokens
    WHERE token_symbol ILIKE '%%pt%%'
       OR token_symbol ILIKE '%%usx%%'
       OR token_symbol ILIKE '%%eusx%%'
       OR token_mint = ANY(%s);
    """
    ref_df = _query_to_polars(ref_sql, (all_pt_mints,))
    if len(ref_df) > 0:
        ref_df.write_parquet(PARQUET_DIR / "kamino_reserve_ref.parquet")
        print(f"  -> {len(ref_df)} reserve references")
    else:
        print("  -> No Kamino reserves found")
        return

    reserve_addrs = ref_df["reserve_address"].to_list()

    frames = []
    for asset, m in MARKETS.items():
        sql = """
        SELECT
            time_bucket('1 day', bucket) AS day,
            symbol,
            reserve_address,
            LAST(collateral_total_supply, bucket) AS coll_supply,
            LAST(supply_total, bucket) AS supply_total,
            LAST(supply_available, bucket) AS supply_avail,
            LAST(supply_borrowed, bucket) AS supply_borrowed,
            LAST(utilization_ratio, bucket) AS util_ratio,
            LAST(deposit_tvl, bucket) AS dep_tvl
        FROM kamino_lend.cagg_reserves_5s
        WHERE reserve_address = ANY(%s)
          AND bucket >= TO_TIMESTAMP(%s) - INTERVAL '7 days'
          AND bucket <= TO_TIMESTAMP(%s) + INTERVAL '21 days'
        GROUP BY 1, 2, 3
        ORDER BY 1, 2;
        """
        df = _query_to_polars(sql, (reserve_addrs, m["maturity_ts"], m["maturity_ts"]))
        if len(df) > 0:
            df = df.with_columns(
                pl.lit(asset).alias("maturity_asset"),
                pl.lit(m["maturity_ts"]).alias("maturity_ts"),
            )
            frames.append(df)

    if frames:
        result = pl.concat(frames)
        result.write_parquet(PARQUET_DIR / "kamino_reserves.parquet")
        print(f"  -> {len(result)} rows")


if __name__ == "__main__":
    print("=" * 60)
    print("Exponent Rollover Study - Data Fetch")
    print("=" * 60)
    fetch_vault_drawdown()
    fetch_market_state()
    fetch_event_flows()
    fetch_dex_pools()
    fetch_dex_daily()
    fetch_usx_mint_redeem()
    fetch_eusx_flows()
    fetch_eusx_yield_pool()
    fetch_kamino_reserves_state()
    print("\nDone. Parquet files written to:", PARQUET_DIR)

import marimo

__generated_with = "0.18.4"
app = marimo.App(width="medium")


@app.cell
def _():
    import marimo as mo
    return (mo,)


@app.cell
def _(mo):
    mo.md(r"""
    # Exponent Maturity Rollover Study

    **PT-USX and PT-eUSX: First Market Maturities**

    Investigation of capital flows when the first PT-USX and PT-eUSX markets matured on Exponent,
    tracking behaviour across four protocol layers: **Exponent** (yield trading), **DEX** (secondary market),
    **Solstice** (primary market), and **Kamino** (lending).

    ---

    ## Document Overview

    | | PT-USX | PT-eUSX |
    |:---|:-------|:--------|
    | **Maturity date** | 2026-02-09 10:58 UTC | 2026-03-11 10:58 UTC |
    | **PT supply at maturity** | ~39.5M | ~22.0M |
    | **Drawdown at T+14d** | 95.1% redeemed | 93.5% redeemed |
    | **Rollover rate to market 2** | ~33% | ~10% |
    | **Kamino PT collateral recovery** | Exceeded pre-maturity (+20%) | Collapsed (-87%) |

    **Key Findings:**

    - **Orderly maturities:** Both events completed without liquidations or protocol stress.
    - **USX showed high conviction:** 33% rolled over, PT-USX Kamino collateral recovered within 2 days, but persistent DEX sell pressure (~14M net over 2 weeks).
    - **eUSX showed low rollover:** Only 10% rolled over, PT-eUSX collateral collapsed 87%, but DEX sell pressure was absorbed within a day. Users migrated to raw eUSX collateral on Kamino.
    - **The eUSX cascade was DEX-routed:** Only 3 users performed both eUSX exit and USX redeem; most sold USX on DEX instead.
    - **eUSX cooldown acted as a circuit breaker:** Spreading withdrawal pressure over 7-12 days.

    ---
    """)
    return


@app.cell
def _():
    from pathlib import Path
    import polars as pl
    import altair as alt
    import pandas as pd
    import numpy as np
    from datetime import datetime, timezone

    alt.data_transformers.enable("vegafusion")

    PARQUET_DIR = Path(__file__).parent / "parquet"

    USX_MATURITY = datetime(2026, 2, 9, 10, 58, 19, tzinfo=timezone.utc)
    EUSX_MATURITY = datetime(2026, 3, 11, 10, 58, 19, tzinfo=timezone.utc)

    def clean_for_chart(df: pl.DataFrame) -> pd.DataFrame:
        pdf = df.to_pandas()
        pdf = pdf.replace([np.inf, -np.inf], np.nan)
        return pdf

    return EUSX_MATURITY, PARQUET_DIR, USX_MATURITY, alt, clean_for_chart, datetime, np, pd, pl, timezone


# ===========================================================================
# PART 1: EXPONENT VAULT & MARKET
# ===========================================================================


@app.cell
def _(mo):
    mo.md(r"""
    ---
    # Part 1: Exponent — Vault Drawdown & Market State

    This section tracks the expired vault's PT supply decline and PT price convergence to par around each maturity.
    """)
    return


@app.cell
def _(PARQUET_DIR, pl):
    vault_df = pl.read_parquet(PARQUET_DIR / "vault_drawdown.parquet")
    market_df = pl.read_parquet(PARQUET_DIR / "market_state.parquet")
    events_df = pl.read_parquet(PARQUET_DIR / "event_flows.parquet")
    return vault_df, market_df, events_df


@app.cell
def _(EUSX_MATURITY, USX_MATURITY, alt, clean_for_chart, pl, vault_df):
    _usx = vault_df.filter(pl.col("asset") == "USX").with_columns(
        ((pl.col("period") - USX_MATURITY).dt.total_hours() / 24).alias("days_from_maturity")
    )
    _eusx = vault_df.filter(pl.col("asset") == "eUSX").with_columns(
        ((pl.col("period") - EUSX_MATURITY).dt.total_hours() / 24).alias("days_from_maturity")
    )
    _combined = pl.concat([_usx, _eusx])
    _pdf = clean_for_chart(
        _combined.select(["days_from_maturity", "pt_supply", "label"])
        .with_columns((pl.col("pt_supply") / 1e6).alias("pt_supply_m"))
    )

    _maturity_rule = (
        alt.Chart(pd.DataFrame({"x": [0]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:Q")
    )

    chart_drawdown = (
        alt.Chart(_pdf)
        .mark_line(strokeWidth=2)
        .encode(
            x=alt.X("days_from_maturity:Q", title="Days from Maturity"),
            y=alt.Y("pt_supply_m:Q", title="PT Supply (millions)"),
            color=alt.Color("label:N", title="Market",
                            scale=alt.Scale(domain=["PT-USX", "PT-eUSX"], range=["#4C78A8", "#E45756"])),
            tooltip=["label:N", "days_from_maturity:Q",
                      alt.Tooltip("pt_supply_m:Q", format=",.1f", title="PT Supply (M)")]
        )
        .properties(title="Vault PT Supply Drawdown", width=600, height=350)
    )

    chart_drawdown_final = (chart_drawdown + _maturity_rule).interactive()
    chart_drawdown_final
    return (chart_drawdown_final,)


@app.cell
def _(mo):
    mo.md(r"""
    ### Vault Drawdown — Observations

    Both vaults followed a similar drawdown shape — steep declines in the first 48 hours post-maturity,
    then a long tail over 14 days.

    - **PT-USX:** 95.1% of PT supply redeemed within 14 days. 73% of all merge activity on T+0 and T+1.
    - **PT-eUSX:** 93.5% redeemed within 14 days. 76% of merge activity on T+0 and T+1.
    - LP supply was already zero for both markets before the analysis window — no LP withdrawal shock at maturity.
    """)
    return


@app.cell
def _(EUSX_MATURITY, USX_MATURITY, alt, clean_for_chart, market_df, pd, pl):
    _usx_m = market_df.filter(pl.col("asset") == "USX").with_columns(
        ((pl.col("hour") - USX_MATURITY).dt.total_hours() / 24).alias("days_from_maturity")
    )
    _eusx_m = market_df.filter(pl.col("asset") == "eUSX").with_columns(
        ((pl.col("hour") - EUSX_MATURITY).dt.total_hours() / 24).alias("days_from_maturity")
    )
    _combined_m = pl.concat([_usx_m, _eusx_m])
    _pdf_m = clean_for_chart(
        _combined_m.select(["days_from_maturity", "pt_price", "label"])
    )

    _maturity_rule2 = (
        alt.Chart(pd.DataFrame({"x": [0]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:Q")
    )
    _peg_rule = (
        alt.Chart(pd.DataFrame({"y": [1.0]}))
        .mark_rule(color="gray", strokeDash=[2, 2], strokeWidth=1)
        .encode(y="y:Q")
    )

    chart_pt_price = (
        alt.Chart(_pdf_m)
        .mark_line(strokeWidth=2)
        .encode(
            x=alt.X("days_from_maturity:Q", title="Days from Maturity"),
            y=alt.Y("pt_price:Q", title="PT Price (SY units)", scale=alt.Scale(domain=[0.995, 1.002])),
            color=alt.Color("label:N", title="Market",
                            scale=alt.Scale(domain=["PT-USX", "PT-eUSX"], range=["#4C78A8", "#E45756"])),
            tooltip=["label:N", "days_from_maturity:Q",
                      alt.Tooltip("pt_price:Q", format=".4f")]
        )
        .properties(title="PT Price Convergence to Par", width=600, height=300)
    )

    chart_pt_price_final = (chart_pt_price + _maturity_rule2 + _peg_rule).interactive()
    chart_pt_price_final
    return (chart_pt_price_final,)


@app.cell
def _(mo):
    mo.md(r"""
    ### PT Price Convergence — Observations

    Both PT tokens converged smoothly from ~0.998 to 1.0 over the final 7 days before maturity.
    No discontinuities or stress events observed in the price path.
    """)
    return


@app.cell
def _(alt, clean_for_chart, events_df, pd, pl):
    _merge_strip = (
        events_df
        .filter(pl.col("event_type").is_in(["merge", "strip"]))
        .group_by(["day", "asset", "label", "market_gen", "event_type"])
        .agg(
            pl.col("events").sum().alias("events"),
            pl.col("sy_out").sum().alias("sy_out"),
            pl.col("sy_in").sum().alias("sy_in"),
        )
        .with_columns(
            pl.when(pl.col("event_type") == "merge")
            .then(pl.col("sy_out") / 1e6)
            .otherwise(pl.col("sy_in") / 1e6)
            .alias("sy_flow_m"),
        )
        .with_columns(
            (pl.col("market_gen") + " " + pl.col("event_type")).alias("flow_label")
        )
    )

    _pdf_flows = clean_for_chart(_merge_strip.select(
        ["day", "label", "flow_label", "sy_flow_m", "events"]
    ))

    chart_flows_usx = (
        alt.Chart(_pdf_flows[_pdf_flows["label"] == "PT-USX"])
        .mark_bar()
        .encode(
            x=alt.X("day:T", title="Date"),
            y=alt.Y("sy_flow_m:Q", title="SY Flow (millions)"),
            color=alt.Color("flow_label:N", title="Flow Type"),
            tooltip=["day:T", "flow_label:N",
                      alt.Tooltip("sy_flow_m:Q", format=",.1f"),
                      alt.Tooltip("events:Q", format=",")]
        )
        .properties(title="PT-USX: Strip / Merge Flows", width=600, height=280)
    )

    _mat_rule_usx = (
        alt.Chart(pd.DataFrame({"x": ["2026-02-09"]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:T")
    )

    chart_flows_usx_final = (chart_flows_usx + _mat_rule_usx).interactive()
    chart_flows_usx_final
    return (chart_flows_usx_final,)


@app.cell
def _(alt, clean_for_chart, events_df, pd, pl):
    _merge_strip_e = (
        events_df
        .filter(pl.col("event_type").is_in(["merge", "strip"]))
        .group_by(["day", "asset", "label", "market_gen", "event_type"])
        .agg(
            pl.col("events").sum().alias("events"),
            pl.col("sy_out").sum().alias("sy_out"),
            pl.col("sy_in").sum().alias("sy_in"),
        )
        .with_columns(
            pl.when(pl.col("event_type") == "merge")
            .then(pl.col("sy_out") / 1e6)
            .otherwise(pl.col("sy_in") / 1e6)
            .alias("sy_flow_m"),
        )
        .with_columns(
            (pl.col("market_gen") + " " + pl.col("event_type")).alias("flow_label")
        )
    )

    _pdf_flows_e = clean_for_chart(_merge_strip_e.select(
        ["day", "label", "flow_label", "sy_flow_m", "events"]
    ))

    chart_flows_eusx = (
        alt.Chart(_pdf_flows_e[_pdf_flows_e["label"] == "PT-eUSX"])
        .mark_bar()
        .encode(
            x=alt.X("day:T", title="Date"),
            y=alt.Y("sy_flow_m:Q", title="SY Flow (millions)"),
            color=alt.Color("flow_label:N", title="Flow Type"),
            tooltip=["day:T", "flow_label:N",
                      alt.Tooltip("sy_flow_m:Q", format=",.1f"),
                      alt.Tooltip("events:Q", format=",")]
        )
        .properties(title="PT-eUSX: Strip / Merge Flows", width=600, height=280)
    )

    _mat_rule_eusx = (
        alt.Chart(pd.DataFrame({"x": ["2026-03-11"]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:T")
    )

    chart_flows_eusx_final = (chart_flows_eusx + _mat_rule_eusx).interactive()
    chart_flows_eusx_final
    return (chart_flows_eusx_final,)


@app.cell
def _(mo):
    mo.md(r"""
    ### Strip / Merge Flows — Observations

    On maturity day, the expired vault saw massive merge activity as users redeemed their PT+YT for SY.
    New vault strips represent rollover: users who re-entered the next market.

    | | Expired Merges (SY out) | New Market Strips (SY in) | Approx. Rollover |
    |:--|:----|:----|:----|
    | **PT-USX** | 53.1M | 17.7M | ~33% |
    | **PT-eUSX** | 26.0M | 2.5M | ~10% |

    The dramatically lower eUSX rollover rate suggests eUSX holders had stronger exit intent —
    consistent with the cascade hypothesis explored in later sections.
    """)
    return


# ===========================================================================
# PART 2: DEX SELL PRESSURE
# ===========================================================================


@app.cell
def _(mo):
    mo.md(r"""
    ---
    # Part 2: DEX Sell Pressure

    After redeeming from Exponent vaults, exiting users need to sell their underlying token.
    This section measures net sell pressure on DEX pools around each maturity vs. a 30-day baseline.
    """)
    return


@app.cell
def _(PARQUET_DIR, pl):
    dex_df = pl.read_parquet(PARQUET_DIR / "dex_daily.parquet")
    dex_pools_df = pl.read_parquet(PARQUET_DIR / "dex_pools.parquet")
    return dex_df, dex_pools_df


@app.cell
def _(USX_MATURITY, alt, clean_for_chart, datetime, dex_df, dex_pools_df, pd, pl, timezone):
    _usx_usdc_pools = dex_pools_df.filter(
        (pl.col("token0_symbol").str.to_lowercase().str.contains("usx"))
        & (~pl.col("token0_symbol").str.to_lowercase().str.contains("eusx"))
        & (pl.col("token1_symbol").str.to_lowercase().str.contains("usdc"))
    )["pool_address"].to_list()

    _usx_dex = (
        dex_df
        .filter(
            (pl.col("maturity_asset") == "USX")
            & (pl.col("pool_address").is_in(_usx_usdc_pools))
        )
        .group_by("day")
        .agg(
            pl.col("t0_sold").sum().alias("usx_sold"),
            pl.col("t0_bought").sum().alias("usx_bought"),
            pl.col("t0_net_sell").sum().alias("usx_net_sell"),
            pl.col("swap_count").sum().alias("swaps"),
        )
        .sort("day")
        .with_columns((pl.col("usx_net_sell") / 1e6).alias("net_sell_m"))
    )

    _baseline_end = datetime(2026, 2, 2, tzinfo=timezone.utc)
    _baseline_rows = _usx_dex.filter(pl.col("day") < _baseline_end)
    _baseline_daily_avg = float(_baseline_rows["usx_net_sell"].mean()) / 1e6 if len(_baseline_rows) > 0 else 0

    _pdf_usx_dex = clean_for_chart(_usx_dex.select(["day", "net_sell_m"]))

    _bars = (
        alt.Chart(_pdf_usx_dex)
        .mark_bar()
        .encode(
            x=alt.X("day:T", title="Date"),
            y=alt.Y("net_sell_m:Q", title="Net USX Sell (millions)"),
            color=alt.condition(
                alt.datum.net_sell_m > 0,
                alt.value("#E45756"),
                alt.value("#4C78A8"),
            ),
            tooltip=["day:T", alt.Tooltip("net_sell_m:Q", format=",.2f", title="Net Sell (M)")]
        )
        .properties(title="USX-USDC Pools: Daily Net Sell Pressure (USX Maturity Window)", width=650, height=300)
    )
    _mat_line = (
        alt.Chart(pd.DataFrame({"x": ["2026-02-09"]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:T")
    )
    _baseline_line = (
        alt.Chart(pd.DataFrame({"y": [_baseline_daily_avg]}))
        .mark_rule(color="gray", strokeDash=[2, 2])
        .encode(y="y:Q")
    )

    chart_usx_dex = (_bars + _mat_line + _baseline_line).interactive()
    chart_usx_dex
    return (chart_usx_dex,)


@app.cell
def _(mo):
    mo.md(r"""
    ### USX DEX Pressure — Observations

    The grey dashed line shows the 30-day baseline daily average (mild net **buy**).
    Red bars indicate net selling; blue bars indicate net buying.

    - **Maturity day (Feb 9):** +5.9M net USX sell (7x baseline sell volume).
    - **Sustained for ~2 weeks:** The regime flipped from mild net-buy to persistent net-sell.
    - **Total window:** ~14M net USX sell over 22 days.
    - **Price impact was modest** (<3 bps per swap), absorbed by deep USX-USDC liquidity.
    """)
    return


@app.cell
def _(EUSX_MATURITY, alt, clean_for_chart, datetime, dex_df, dex_pools_df, pd, pl, timezone):
    _eusx_pools = dex_pools_df.filter(
        (pl.col("token0_symbol").str.to_lowercase().str.contains("eusx"))
    )["pool_address"].to_list()

    _eusx_dex = (
        dex_df
        .filter(
            (pl.col("maturity_asset") == "eUSX")
            & (pl.col("pool_address").is_in(_eusx_pools))
        )
        .group_by("day")
        .agg(
            pl.col("t0_sold").sum().alias("eusx_sold"),
            pl.col("t0_bought").sum().alias("eusx_bought"),
            pl.col("t0_net_sell").sum().alias("eusx_net_sell"),
            pl.col("swap_count").sum().alias("swaps"),
        )
        .sort("day")
        .with_columns((pl.col("eusx_net_sell") / 1e6).alias("net_sell_m"))
    )

    _baseline_end_e = datetime(2026, 3, 4, tzinfo=timezone.utc)
    _baseline_rows_e = _eusx_dex.filter(pl.col("day") < _baseline_end_e)
    _baseline_avg_e = float(_baseline_rows_e["eusx_net_sell"].mean()) / 1e6 if len(_baseline_rows_e) > 0 else 0

    _pdf_eusx_dex = clean_for_chart(_eusx_dex.select(["day", "net_sell_m"]))

    _bars_e = (
        alt.Chart(_pdf_eusx_dex)
        .mark_bar()
        .encode(
            x=alt.X("day:T", title="Date"),
            y=alt.Y("net_sell_m:Q", title="Net eUSX Sell (millions)"),
            color=alt.condition(
                alt.datum.net_sell_m > 0,
                alt.value("#E45756"),
                alt.value("#4C78A8"),
            ),
            tooltip=["day:T", alt.Tooltip("net_sell_m:Q", format=",.2f", title="Net Sell (M)")]
        )
        .properties(title="eUSX-USX Pools: Daily Net Sell Pressure (eUSX Maturity Window)", width=650, height=300)
    )
    _mat_line_e = (
        alt.Chart(pd.DataFrame({"x": ["2026-03-11"]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:T")
    )
    _baseline_line_e = (
        alt.Chart(pd.DataFrame({"y": [_baseline_avg_e]}))
        .mark_rule(color="gray", strokeDash=[2, 2])
        .encode(y="y:Q")
    )

    chart_eusx_dex = (_bars_e + _mat_line_e + _baseline_line_e).interactive()
    chart_eusx_dex
    return (chart_eusx_dex,)


@app.cell
def _(mo):
    mo.md(r"""
    ### eUSX DEX Pressure — Observations

    Despite a massive maturity-day volume spike (~6M eUSX traded vs ~80K/day baseline),
    the net sell pressure was surprisingly contained.

    - **Maturity day (Mar 11):** +807K net eUSX sell, but 6M total volume — strong buying absorbed most selling.
    - **Full 22-day window:** Slight net **buy** (-262K), meaning the sell pressure was fully absorbed.
    - **Price impact was higher than USX** (up to 5 bps on maturity day), reflecting thinner eUSX-USX liquidity.

    The contrast with USX is stark: USX had persistent, multi-week sell pressure; eUSX had a concentrated spike that was absorbed within days. This suggests strong arbitrageur or counterparty activity in eUSX pools.
    """)
    return


# ===========================================================================
# PART 3: PRIMARY MARKET FLOWS (SOLSTICE)
# ===========================================================================


@app.cell
def _(mo):
    mo.md(r"""
    ---
    # Part 3: Primary Market — USX Mint/Redeem & eUSX Yield Pool

    Beyond DEX activity, exiting users may interact with the primary market:
    redeeming USX through Solstice, or withdrawing from the eUSX yield vault.
    """)
    return


@app.cell
def _(PARQUET_DIR, pl):
    usx_mr_df = pl.read_parquet(PARQUET_DIR / "usx_mint_redeem.parquet")
    eusx_fl_df = pl.read_parquet(PARQUET_DIR / "eusx_flows.parquet")
    eusx_yp_df = pl.read_parquet(PARQUET_DIR / "eusx_yield_pool.parquet")
    return usx_mr_df, eusx_fl_df, eusx_yp_df


@app.cell
def _(alt, clean_for_chart, pd, pl, usx_mr_df):
    _usx_window = (
        usx_mr_df
        .filter(pl.col("maturity_asset") == "USX")
        .with_columns(
            (pl.col("usx_minted") / 1e6).alias("minted_m"),
            (pl.col("usx_redeemed") / -1e6).alias("redeemed_m"),
        )
    )

    _pdf_mr = clean_for_chart(_usx_window.select(["day", "minted_m", "redeemed_m"]))
    _pdf_long = pd.melt(_pdf_mr, id_vars=["day"], value_vars=["minted_m", "redeemed_m"],
                         var_name="type", value_name="amount_m")
    _pdf_long["type"] = _pdf_long["type"].map({"minted_m": "Minted", "redeemed_m": "Redeemed"})

    _bars_mr = (
        alt.Chart(_pdf_long)
        .mark_bar()
        .encode(
            x=alt.X("day:T", title="Date"),
            y=alt.Y("amount_m:Q", title="USX (millions)"),
            color=alt.Color("type:N", scale=alt.Scale(
                domain=["Minted", "Redeemed"], range=["#4C78A8", "#E45756"]
            )),
            tooltip=["day:T", "type:N", alt.Tooltip("amount_m:Q", format=",.1f")]
        )
        .properties(title="USX Primary Market: Daily Mint / Redeem (USX Maturity Window)", width=650, height=300)
    )
    _mat_mr = (
        alt.Chart(pd.DataFrame({"x": ["2026-02-09"]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:T")
    )

    chart_usx_mr = (_bars_mr + _mat_mr).interactive()
    chart_usx_mr
    return (chart_usx_mr,)


@app.cell
def _(mo):
    mo.md(r"""
    ### USX Primary Market — Observations

    Redemptions spiked 5-20x on maturity day and following days, but were **rapidly offset by large institutional mints**:

    - **Feb 11 (T+2):** ~30M USX minted in a single transaction.
    - **Feb 17-18:** Another ~29.5M minted.
    - **Net effect:** USX circulating supply actually **grew** from ~302M to ~341M (+13%) through the maturity window.

    The primary market mechanism absorbed the flow without stress.
    """)
    return


@app.cell
def _(alt, clean_for_chart, eusx_yp_df, pd, pl):
    _yp = (
        eusx_yp_df
        .filter(pl.col("maturity_asset") == "eUSX")
        .with_columns((pl.col("total_assets") / 1e6).alias("assets_m"))
        .sort("day")
    )

    _pdf_yp = clean_for_chart(_yp.select(["day", "assets_m", "exchange_rate"]))

    _line_assets = (
        alt.Chart(_pdf_yp)
        .mark_area(opacity=0.3, line={"strokeWidth": 2, "color": "#4C78A8"}, color="#4C78A8")
        .encode(
            x=alt.X("day:T", title="Date"),
            y=alt.Y("assets_m:Q", title="Total Assets (M USX)", scale=alt.Scale(zero=False)),
            tooltip=["day:T", alt.Tooltip("assets_m:Q", format=",.1f", title="Assets (M USX)")]
        )
        .properties(title="eUSX Yield Pool: Total Assets (eUSX Maturity Window)", width=650, height=300)
    )
    _mat_yp = (
        alt.Chart(pd.DataFrame({"x": ["2026-03-11"]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:T")
    )

    chart_yp = (_line_assets + _mat_yp).interactive()
    chart_yp
    return (chart_yp,)


@app.cell
def _(mo):
    mo.md(r"""
    ### eUSX Yield Pool — Observations

    The eUSX yield pool experienced a significant drawdown around the PT-eUSX maturity:

    - **Pre-maturity:** ~121M USX in pool.
    - **Post-maturity (T+14d):** ~102M USX — a **16.2% drawdown**.
    - **Sharpest drop on maturity day itself:** -10.3M (8.9%) in a single day.
    - **Two-phase pattern:** Immediate unlocks at T+0, then delayed withdrawals at T+7 to T+12 (driven by eUSX cooldown period).

    The exchange rate continued to grow monotonically throughout (yield accrual), confirming pool mechanics were healthy.

    ---

    ### The eUSX Cascade — Was It Real?

    The hypothesized cascade (PT-eUSX unwind -> eUSX exit -> USX redemption) **was real in aggregate but did NOT flow through the primary redemption mechanism.**

    | Metric | USX Maturity | eUSX Maturity |
    |:-------|:-------------|:--------------|
    | eUSX exit users | 550 | 577 |
    | USX redeem users | 3 | 5 |
    | **Overlap (both actions)** | **0** | **3** |

    Only **3 users** performed both eUSX withdraw and USX redeem in the eUSX maturity window.
    Most eUSX exiters sold their USX on DEX instead of redeeming through Solstice.
    The eUSX cooldown period (7-12 day delay) acted as a natural circuit breaker.
    """)
    return


# ===========================================================================
# PART 4: KAMINO COLLATERAL
# ===========================================================================


@app.cell
def _(mo):
    mo.md(r"""
    ---
    # Part 4: Kamino Lending — Collateral & Utilization

    PT tokens were used as collateral on Kamino. This section tracks how collateral supply
    and USX lending utilization responded to the maturity events.
    """)
    return


@app.cell
def _(PARQUET_DIR, pl):
    kamino_df = pl.read_parquet(PARQUET_DIR / "kamino_reserves.parquet")
    return (kamino_df,)


@app.cell
def _(alt, clean_for_chart, kamino_df, pd, pl):
    _pt_usx_coll = (
        kamino_df
        .filter(
            (pl.col("maturity_asset") == "USX")
            & (pl.col("symbol").str.to_lowercase().str.contains("pt"))
            & (pl.col("symbol").str.to_lowercase().str.contains("usx"))
            & (~pl.col("symbol").str.to_lowercase().str.contains("eusx"))
        )
        .group_by("day")
        .agg(pl.col("coll_supply").sum().alias("coll_supply"))
        .sort("day")
        .with_columns((pl.col("coll_supply") / 1e6).alias("coll_m"))
    )

    _pdf_pt_usx = clean_for_chart(_pt_usx_coll.select(["day", "coll_m"]))

    _area_usx = (
        alt.Chart(_pdf_pt_usx)
        .mark_area(opacity=0.3, line={"strokeWidth": 2, "color": "#4C78A8"}, color="#4C78A8")
        .encode(
            x=alt.X("day:T", title="Date"),
            y=alt.Y("coll_m:Q", title="PT-USX Collateral (millions)", scale=alt.Scale(zero=False)),
            tooltip=["day:T", alt.Tooltip("coll_m:Q", format=",.2f")]
        )
        .properties(title="Kamino: PT-USX Collateral Supply (USX Maturity Window)", width=650, height=280)
    )
    _mat_k = (
        alt.Chart(pd.DataFrame({"x": ["2026-02-09"]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:T")
    )

    chart_kamino_usx = (_area_usx + _mat_k).interactive()
    chart_kamino_usx
    return (chart_kamino_usx,)


@app.cell
def _(alt, clean_for_chart, kamino_df, pd, pl):
    _pt_eusx_coll = (
        kamino_df
        .filter(
            (pl.col("maturity_asset") == "eUSX")
            & (pl.col("symbol").str.to_lowercase().str.contains("pt"))
            & (pl.col("symbol").str.to_lowercase().str.contains("eusx"))
        )
        .group_by("day")
        .agg(pl.col("coll_supply").sum().alias("coll_supply"))
        .sort("day")
        .with_columns((pl.col("coll_supply") / 1e6).alias("coll_m"))
    )

    _eusx_raw_coll = (
        kamino_df
        .filter(
            (pl.col("maturity_asset") == "eUSX")
            & (pl.col("symbol").str.to_lowercase() == "eusx")
        )
        .group_by("day")
        .agg(pl.col("coll_supply").sum().alias("coll_supply"))
        .sort("day")
        .with_columns((pl.col("coll_supply") / 1e6).alias("coll_m"))
    )

    _pt_pdf = clean_for_chart(_pt_eusx_coll.select(["day", "coll_m"]))
    _pt_pdf["type"] = "PT-eUSX"
    _raw_pdf = clean_for_chart(_eusx_raw_coll.select(["day", "coll_m"]))
    _raw_pdf["type"] = "eUSX (raw)"

    _combined_coll = pd.concat([_pt_pdf, _raw_pdf], ignore_index=True)

    _lines_coll = (
        alt.Chart(_combined_coll)
        .mark_line(strokeWidth=2)
        .encode(
            x=alt.X("day:T", title="Date"),
            y=alt.Y("coll_m:Q", title="Collateral Supply (millions)", scale=alt.Scale(zero=False)),
            color=alt.Color("type:N", title="Collateral Type",
                            scale=alt.Scale(domain=["PT-eUSX", "eUSX (raw)"], range=["#E45756", "#72B7B2"])),
            tooltip=["day:T", "type:N", alt.Tooltip("coll_m:Q", format=",.2f")]
        )
        .properties(title="Kamino: PT-eUSX vs Raw eUSX Collateral (eUSX Maturity Window)", width=650, height=280)
    )
    _mat_k2 = (
        alt.Chart(pd.DataFrame({"x": ["2026-03-11"]}))
        .mark_rule(color="red", strokeDash=[4, 4], strokeWidth=1.5)
        .encode(x="x:T")
    )

    chart_kamino_eusx = (_lines_coll + _mat_k2).interactive()
    chart_kamino_eusx
    return (chart_kamino_eusx,)


@app.cell
def _(mo):
    mo.md(r"""
    ### Kamino Collateral — Observations

    **PT-USX: Clean rollover cycle**

    - Collateral dropped 31% on maturity day as users withdrew expired PT tokens.
    - Fully recovered (and exceeded baseline by 20%) within 2 days as users deposited new PT-USX.
    - Pattern: withdraw expired PT -> merge on Exponent -> strip new PT -> re-deposit.

    **PT-eUSX: Collapse and strategy migration**

    - Collateral collapsed **85%** on maturity day (10.4M -> 1.5M) and **never recovered**.
    - Only ~1.3M in new PT-eUSX collateral was deposited (consistent with 10% rollover).
    - Meanwhile, **raw eUSX collateral more than doubled** (2.0M -> 4.4M), showing users migrated from PT-eUSX yield trading to simpler eUSX collateral strategies.

    **Zero liquidations** occurred despite these massive movements. The 80% LTV / 95% liquidation threshold parameters provided adequate buffer.
    """)
    return


@app.cell
def _(alt, clean_for_chart, kamino_df, pd, pl):
    _usx_util = (
        kamino_df
        .filter(
            (pl.col("symbol").str.to_lowercase() == "usx")
        )
        .sort("day")
        .with_columns((pl.col("util_ratio") * 100).alias("util_pct"))
    )

    _pdf_util = clean_for_chart(_usx_util.select(["day", "util_pct", "maturity_asset"]))

    _line_util = (
        alt.Chart(_pdf_util)
        .mark_line(strokeWidth=2)
        .encode(
            x=alt.X("day:T", title="Date"),
            y=alt.Y("util_pct:Q", title="Utilization (%)", scale=alt.Scale(zero=False)),
            color=alt.Color("maturity_asset:N", title="Maturity Window",
                            scale=alt.Scale(domain=["USX", "eUSX"], range=["#4C78A8", "#E45756"])),
            tooltip=["day:T", alt.Tooltip("util_pct:Q", format=".1f", title="Utilization %")]
        )
        .properties(title="Kamino: USX Lending Utilization", width=650, height=280)
    )
    _mat_u1 = (
        alt.Chart(pd.DataFrame({"x": ["2026-02-09"]}))
        .mark_rule(color="#4C78A8", strokeDash=[4, 4], strokeWidth=1)
        .encode(x="x:T")
    )
    _mat_u2 = (
        alt.Chart(pd.DataFrame({"x": ["2026-03-11"]}))
        .mark_rule(color="#E45756", strokeDash=[4, 4], strokeWidth=1)
        .encode(x="x:T")
    )

    chart_util = (_line_util + _mat_u1 + _mat_u2).interactive()
    chart_util
    return (chart_util,)


@app.cell
def _(mo):
    mo.md(r"""
    ### USX Utilization — Observations

    USX lending utilization dropped sharply at both maturity events as fresh USX entered the lending pool:

    | Maturity | Pre | Post (T+0) | Recovery |
    |:---------|:----|:-----------|:---------|
    | USX (Feb 9) | 94% | 56% | ~80% by T+14d |
    | eUSX (Mar 11) | 68% | 46% | ~56% by T+14d |

    The supply influx came from users who unwound their PT positions and deposited USX into Kamino lending,
    temporarily depressing the borrow rate.
    """)
    return


# ===========================================================================
# PART 5: SYNTHESIS
# ===========================================================================


@app.cell
def _(mo):
    mo.md(r"""
    ---
    # Part 5: Synthesis — Capital Flow Diagrams

    ## PT-USX Maturity Flow (39.5M PT supply)

    ```
    PT-USX Matures (39.5M)
      |
      |--[33%]--> Roll to new PT-USX market (17.7M stripped into new vault)
      |              |
      |              +--> ~7.3M re-deposited as Kamino collateral
      |
      |--[67%]--> Redeem SY (merge: 53.1M total, net exit ~35.4M)
                    |
                    |--[major]--> Sell USX on DEX
                    |               Net ~14M USX sell pressure over 22 days
                    |               (vs baseline net buy of -134K/day)
                    |
                    |--[minor]--> USX primary redemption
                    |               Spiked but offset by 30M+ institutional mints
                    |               Supply grew 302M -> 341M (+13%)
                    |
                    |--[minor]--> Deposit USX into Kamino lending
                                  Utilization dropped 94% -> 56%
    ```

    ## PT-eUSX Maturity Flow (22.0M PT supply)

    ```
    PT-eUSX Matures (22.0M)
      |
      |--[10%]--> Roll to new PT-eUSX market (2.5M stripped into new vault)
      |              |
      |              +--> Only 1.3M as Kamino collateral (vs 10.4M pre-maturity)
      |
      |--[90%]--> Redeem SY to eUSX (merge: 26.0M total, net exit ~23.5M)
                    |
                    |--[significant]--> eUSX yield pool drawdown
                    |                    -16.2% (121M -> 102M USX in pool)
                    |                    Two-phase: unlocks at T+0, withdrawals at T+7-12
                    |
                    |--[episodic]--> Sell eUSX on DEX
                    |                 6M eUSX traded on maturity day (vs 80K/day baseline)
                    |                 But only +807K net sell (quickly absorbed)
                    |                 Full window was actually net-buy
                    |
                    |--[minimal]--> eUSX -> USX cascade via primary market
                    |                Only 3 users did both eUSX exit and USX redeem
                    |                Most eUSX exiters sold USX on DEX instead
                    |
                    |--[notable]--> Migration to raw eUSX on Kamino
                                    eUSX collateral 2.0M -> 4.4M (+120%)
                                    Users chose eUSX collateral over PT-eUSX
    ```
    """)
    return


@app.cell
def _(mo):
    mo.md(r"""
    ---
    ## Timing Patterns

    | Phase | USX | eUSX |
    |:------|:----|:-----|
    | PT price convergence | Smooth over 7 days (0.998 -> 1.0) | Smooth (0.998 -> 1.0) |
    | Peak merge activity | T+0 and T+1 (73% of all merges) | T+0 and T+1 (76% of all merges) |
    | DEX sell pressure peak | T+0 (7x baseline), sustained 2 weeks | T+0 (75x baseline), absorbed same day |
    | Kamino collateral trough | T+1, recovered by T+2 | T+0, permanent |
    | eUSX yield pool trough | n/a | T+7 to T+12 (cooldown-delayed) |
    | Full vault drawdown | 95% by T+14d | 93.5% by T+14d |

    ---
    ## Risk Implications

    1. **Maturity events create predictable, time-bounded sell pressure.** For USX, this lasted ~2 weeks. For eUSX, it was episodic and absorbed quickly. Future maturities can be anticipated.

    2. **The eUSX cooldown period is a natural circuit breaker.** It spreads withdrawal pressure over 7-12 days, preventing a single-day cascade event.

    3. **Institutional mint activity can offset maturity redemptions.** The 30M+ USX mint on Feb 11 (T+2) effectively neutralised the redemption pressure.

    4. **Kamino risk parameters are adequate.** No liquidations despite 85% PT collateral drops. However, the concentration of PT-eUSX collateral (~10M pre-maturity) could be a risk if liquidation parameters were tighter.

    5. **Low eUSX rollover rate (10%) is a retention signal.** If future maturities show similarly low rollover, it may indicate structural issues with eUSX yield demand on Exponent — or simply that users prefer direct eUSX collateral strategies on Kamino.
    """)
    return


if __name__ == "__main__":
    app.run()

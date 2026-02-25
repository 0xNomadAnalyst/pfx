import marimo

__generated_with = "0.19.5"
app = marimo.App(width="full", app_title="ONyc DEX Dashboard", css_file="")


@app.cell
def _():
    import marimo as mo
    return (mo,)


@app.cell
def _(mo):
    mo.md("""
    # ONyc DEX Markets Dashboard
    Live data from **Raydium CLMM** (USDG-ONyc) and **Orca Whirlpool** (ONyc-USDC) pools.
    """)
    return


@app.cell
def _():
    import warnings
    warnings.filterwarnings("ignore", message=".*pandas only supports SQLAlchemy.*")
    import psycopg2
    import pandas as pd
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots
    from datetime import datetime, timedelta, timezone
    import numpy as np
    return datetime, go, make_subplots, np, pd, psycopg2, timedelta, timezone


@app.cell
def _(psycopg2):
    # Database connection & pool metadata
    DB_CONFIG = {
        "host": "fd3cdmjulb.p56ar8nomm.tsdb.cloud.timescale.com",
        "port": 33971,
        "dbname": "tsdb",
        "user": "tsdbadmin",
        "password": "ner5q1iamtwzkmmd",
        "sslmode": "require",
    }
    SCHEMA = "dexes"

    def get_conn():
        return psycopg2.connect(**DB_CONFIG)

    POOLS = {
        "A9RdNEf4T9x1eNPnEHFX1ABHS7J4e9kxBm43S3o5r9Kw": {
            "pair": "USDG-ONyc",
            "protocol": "raydium",
            "token0": "USDG",
            "token1": "ONyc",
            "dec0": 6,
            "dec1": 9,
            # price_display: "ONyc per USDG" (token1 per token0 human-adjusted)
            "price_label": "ONyc per USDG",
            # To get ONyc price in USD: invert this → 1/price_human
            "invert_for_usd": True,
        },
        "7jhhyxPUKpu42hPGSYwgMXbR2dtVJHKhs8DW3sAAgAvX": {
            "pair": "ONyc-USDC",
            "protocol": "orca",
            "token0": "ONyc",
            "token1": "USDC",
            "dec0": 9,
            "dec1": 6,
            # price_display: "USDC per ONyc" (token1 per token0 human-adjusted)
            "price_label": "USDC per ONyc",
            "invert_for_usd": False,
        },
    }

    POOL_ADDRS = list(POOLS.keys())
    RAY_ADDR = "A9RdNEf4T9x1eNPnEHFX1ABHS7J4e9kxBm43S3o5r9Kw"
    ORCA_ADDR = "7jhhyxPUKpu42hPGSYwgMXbR2dtVJHKhs8DW3sAAgAvX"
    return ORCA_ADDR, POOLS, POOL_ADDRS, RAY_ADDR, SCHEMA, get_conn


@app.cell
def _(mo):
    lookback = mo.ui.dropdown(
        options={"1 Hour": "1h", "6 Hours": "6h", "24 Hours": "24h", "3 Days": "3d", "7 Days": "7d"},
        value="24 Hours",
        label="Lookback",
    )
    pool_select = mo.ui.dropdown(
        options={
            "Both Pools": "both",
            "Raydium USDG-ONyc": "A9RdNEf4T9x1eNPnEHFX1ABHS7J4e9kxBm43S3o5r9Kw",
            "Orca ONyc-USDC": "7jhhyxPUKpu42hPGSYwgMXbR2dtVJHKhs8DW3sAAgAvX",
        },
        value="Both Pools",
        label="Pool",
    )
    refresh_btn = mo.ui.run_button(label="Refresh Data")
    mo.hstack([lookback, pool_select, refresh_btn], justify="start", gap=1)
    return lookback, pool_select, refresh_btn


@app.cell
def _(lookback, timedelta):
    LOOKBACK_MAP = {
        "1h": timedelta(hours=1),
        "6h": timedelta(hours=6),
        "24h": timedelta(hours=24),
        "3d": timedelta(days=3),
        "7d": timedelta(days=7),
    }
    selected_lookback = LOOKBACK_MAP.get(lookback.value, timedelta(hours=24))
    return (selected_lookback,)


@app.cell
def _(
    POOL_ADDRS,
    SCHEMA,
    datetime,
    get_conn,
    pd,
    pool_select,
    refresh_btn,
    selected_lookback,
    timezone,
):
    """Fetch all data from TimescaleDB."""
    refresh_btn

    _now = datetime.now(timezone.utc)
    _since = _now - selected_lookback

    if pool_select.value == "both":
        pool_filter = POOL_ADDRS
    else:
        pool_filter = [pool_select.value]

    _ph = ",".join(["%s"] * len(pool_filter))
    _conn = get_conn()

    # Pool State
    df_pool = pd.read_sql(
        f"""
        SELECT time, pool_address, protocol, token_pair,
               price, tick_current, liquidity,
               sqrt_price_x64, mint_decimals_0, mint_decimals_1
        FROM {SCHEMA}.src_acct_pool
        WHERE pool_address IN ({_ph}) AND time >= %s
        ORDER BY time ASC
        """,
        _conn, params=(*pool_filter, _since),
    )

    # Token Vaults
    df_vaults = pd.read_sql(
        f"""
        SELECT time, pool_address, protocol, token_pair,
               token_0_value, token_1_value,
               token_0_mint, token_1_mint
        FROM {SCHEMA}.src_acct_vaults
        WHERE pool_address IN ({_ph}) AND time >= %s
        ORDER BY time ASC
        """,
        _conn, params=(*pool_filter, _since),
    )

    # Swap Events
    df_swaps = pd.read_sql(
        f"""
        SELECT meta_block_time, pool_address, protocol, token_pair,
               instruction_name, event_type,
               swap_token_in_symbol, swap_amount_in,
               swap_token_out_symbol, swap_amount_out,
               effective_price_buyt0_t1_per_t0,
               effective_price_sellt0_t1_per_t0,
               evt_swap_impact_bps, c_swap_est_impact_bps,
               env_token0_decimals, env_token1_decimals
        FROM {SCHEMA}.src_tx_events
        WHERE pool_address IN ({_ph}) AND meta_block_time >= %s
          AND event_type ILIKE '%%swap%%' AND meta_success = true
        ORDER BY meta_block_time ASC
        """,
        _conn, params=(*pool_filter, _since),
    )

    # Latest Depth Distribution
    _depth_frames = {}
    for _pa in pool_filter:
        _depth_frames[_pa] = pd.read_sql(
            f"""
            SELECT pool_address, tick_lower, tick_upper,
                   liquidity_balance, token0_value, token1_value,
                   token0_cumul, token1_cumul
            FROM {SCHEMA}.src_acct_tickarray_tokendist_latest
            WHERE pool_address = %s ORDER BY tick_lower ASC
            """,
            _conn, params=(_pa,),
        )

    df_depth_raydium = _depth_frames.get("A9RdNEf4T9x1eNPnEHFX1ABHS7J4e9kxBm43S3o5r9Kw", pd.DataFrame())
    df_depth_orca = _depth_frames.get("7jhhyxPUKpu42hPGSYwgMXbR2dtVJHKhs8DW3sAAgAvX", pd.DataFrame())

    # Latest Depth Query Metadata
    df_depth_meta = pd.read_sql(
        f"""
        SELECT DISTINCT ON (pool_address)
               pool_address, token_pair, protocol, block_time,
               current_tick, pool_liquidity, sqrt_price_x64,
               c_impact_from_sell_t0_1, c_impact_from_sell_t0_2, c_impact_from_sell_t0_3,
               c_sell_t0_for_impact_bps_1, c_sell_t0_for_impact_bps_2, c_sell_t0_for_impact_bps_3,
               c_liq_pct_within_xticks_of_active_1, c_liq_pct_within_xticks_of_active_2, c_liq_pct_within_xticks_of_active_3,
               c_total_liquidity_tokens,
               c_impact_from_sell_t0_quantities, c_sell_t0_for_impact_bps_levels
        FROM {SCHEMA}.src_acct_tickarray_queries
        WHERE pool_address IN ({_ph})
        ORDER BY pool_address, block_time DESC
        """,
        _conn, params=(*pool_filter,),
    )

    _conn.close()
    return (
        df_depth_meta,
        df_depth_orca,
        df_depth_raydium,
        df_pool,
        df_swaps,
        df_vaults,
    )


@app.cell
def _(POOLS, df_pool):
    """Apply decimal adjustment to prices and compute ONyc USD price."""
    _dfs = []
    for _pa, _meta in POOLS.items():
        _sub = df_pool[df_pool["pool_address"] == _pa].copy()
        if _sub.empty:
            continue
        # Human-readable price: raw_price * 10^(dec0 - dec1)
        _adj = 10 ** (_meta["dec0"] - _meta["dec1"])
        _sub["price_human"] = _sub["price"] * _adj
        # ONyc price in USD: for Raydium USDG-ONyc, price_human = ONyc/USDG → invert
        #                     for Orca ONyc-USDC, price_human = USDC/ONyc → direct
        if _meta.get("invert_for_usd"):
            _sub["onyc_usd"] = 1.0 / _sub["price_human"]
        else:
            _sub["onyc_usd"] = _sub["price_human"]
        _dfs.append(_sub)

    import pandas as _pd
    df_pool_adj = _pd.concat(_dfs) if _dfs else _pd.DataFrame()
    return (df_pool_adj,)


@app.cell
def _(POOLS, df_depth_meta, df_pool_adj, df_vaults, mo):
    """Summary stat cards."""
    _cards = []
    for _pa, _meta in POOLS.items():
        _pdf = df_pool_adj[df_pool_adj["pool_address"] == _pa]
        if _pdf.empty:
            continue

        _latest = _pdf.iloc[-1]
        _price_h = _latest["price_human"]
        _onyc_usd = _latest["onyc_usd"]
        _tick = int(_latest["tick_current"])

        # Vault TVL
        _vdf = df_vaults[df_vaults["pool_address"] == _pa]
        if not _vdf.empty:
            _vl = _vdf.iloc[-1]
            _t0 = _vl["token_0_value"] or 0
            _t1 = _vl["token_1_value"] or 0
            # Rough TVL in USD: for stablecoins, sum ≈ USD value
            _tvl_str = f"${_t0 + _t1:,.0f}"
        else:
            _tvl_str = "N/A"

        # Period change
        if len(_pdf) > 1:
            _first_p = _pdf.iloc[0]["price_human"]
            _pct = ((_price_h - _first_p) / _first_p) * 100 if _first_p else 0
            _chg_str = f"{_pct:+.4f}%"
        else:
            _chg_str = "—"

        # Impact
        _dr = df_depth_meta[df_depth_meta["pool_address"] == _pa]
        _impact_str = ""
        if not _dr.empty and _dr.iloc[0].get("c_impact_from_sell_t0_1") is not None:
            _impact_str = f" | 50K→{_dr.iloc[0]['c_impact_from_sell_t0_1']:.1f}bps"

        _cards.append(
            mo.stat(
                value=f"{_price_h:.6f}",
                label=f"{_meta['pair']} · {_meta['protocol'].title()}",
                caption=f"{_meta['price_label']} | ONyc≈${_onyc_usd:.4f} | Tick {_tick} | {_chg_str} | TVL {_tvl_str}{_impact_str}",
                bordered=True,
            )
        )

    mo.hstack(_cards, justify="start", gap=1) if _cards else mo.md("*No pool data available yet.*")
    return


@app.cell
def _(mo):
    mo.md("""
    ## ONyc Price (USD-equivalent)
    """)
    return


@app.cell
def _(POOLS, df_pool_adj, go):
    """Combined ONyc USD price chart from both pools."""
    fig_price = go.Figure()
    _colors = {"raydium": "#00D1FF", "orca": "#FFD700"}

    for _pa in df_pool_adj["pool_address"].unique():
        if _pa not in POOLS:
            continue
        _m = POOLS[_pa]
        _sub = df_pool_adj[df_pool_adj["pool_address"] == _pa]
        fig_price.add_trace(
            go.Scatter(
                x=_sub["time"], y=_sub["onyc_usd"],
                mode="lines",
                name=f"{_m['pair']} ({_m['protocol'].title()})",
                line=dict(color=_colors.get(_m["protocol"], "#00D1FF"), width=1.5),
                hovertemplate="%{x}<br>ONyc: $%{y:.6f}<extra></extra>",
            )
        )

    fig_price.update_layout(
        template="plotly_dark",
        paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
        yaxis_title="ONyc Price (USD)",
        height=400,
        margin=dict(l=60, r=30, t=20, b=40),
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
        hovermode="x unified",
    )
    fig_price
    return


@app.cell
def _(mo):
    mo.md("""
    ## Native Pool Prices
    """)
    return


@app.cell
def _(POOLS, df_pool_adj, go, make_subplots):
    """Per-pool native price charts (matching DEX UI display)."""
    _pools_in = [_p for _p in df_pool_adj["pool_address"].unique() if _p in POOLS]
    _n = max(len(_pools_in), 1)

    fig_native = make_subplots(
        rows=_n, cols=1, shared_xaxes=True, vertical_spacing=0.08,
        subplot_titles=[f"{POOLS[_p]['pair']} — {POOLS[_p]['price_label']}" for _p in _pools_in],
    )
    _colors = {"raydium": "#00D1FF", "orca": "#FFD700"}

    for _i, _pa in enumerate(_pools_in, 1):
        _m = POOLS[_pa]
        _sub = df_pool_adj[df_pool_adj["pool_address"] == _pa]
        if _sub.empty:
            continue

        fig_native.add_trace(
            go.Scatter(
                x=_sub["time"], y=_sub["price_human"],
                mode="lines",
                name=f"{_m['pair']}",
                line=dict(color=_colors.get(_m["protocol"], "#00D1FF"), width=1.5),
                hovertemplate="%{x}<br>%{y:.6f}<extra></extra>",
            ),
            row=_i, col=1,
        )

        _hi = _sub["price_human"].max()
        _lo = _sub["price_human"].min()
        fig_native.add_annotation(
            x=_sub.loc[_sub["price_human"].idxmax(), "time"], y=_hi,
            text=f"High {_hi:.6f}", showarrow=True, arrowhead=2,
            arrowcolor="#22c55e", font=dict(color="#22c55e", size=10),
            row=_i, col=1,
        )
        fig_native.add_annotation(
            x=_sub.loc[_sub["price_human"].idxmin(), "time"], y=_lo,
            text=f"Low {_lo:.6f}", showarrow=True, arrowhead=2,
            arrowcolor="#ef4444", font=dict(color="#ef4444", size=10),
            row=_i, col=1,
        )
        fig_native.update_yaxes(title_text=_m["price_label"], row=_i, col=1)

    fig_native.update_layout(
        template="plotly_dark",
        paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
        height=300 * _n,
        margin=dict(l=60, r=30, t=40, b=40),
        showlegend=True,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
        hovermode="x unified",
    )
    fig_native
    return


@app.cell
def _(mo):
    mo.md("""
    ## Liquidity Depth Distribution
    """)
    return


@app.cell
def _(
    ORCA_ADDR,
    POOLS,
    RAY_ADDR,
    df_depth_meta,
    df_depth_orca,
    df_depth_raydium,
    go,
    make_subplots,
    np,
):
    """Depth chart: CLMM-converted token amounts per tick bucket (tick space).

    Uses concentrated-liquidity math (ref: dexes/data/liquidity_depth.py):
      Above current tick → token0:  Δx = L · (1/√P_lower − 1/√P_upper) / 10^dec0
      Below current tick → token1:  Δy = L · (√P_upper  − √P_lower)    / 10^dec1
    Both pools have tick_spacing = 1 (see ONyc.md).
    """
    _TICK_SPACING = 1  # Both ONyc pools

    _items = []
    if not df_depth_raydium.empty:
        _items.append(("raydium", RAY_ADDR, df_depth_raydium))
    if not df_depth_orca.empty:
        _items.append(("orca", ORCA_ADDR, df_depth_orca))

    _n = max(len(_items), 1)
    _labels = [f"{POOLS[_a]['pair']} ({_prot.title()})" for _prot, _a, _ in _items] or ["No depth data"]

    fig_depth = make_subplots(rows=1, cols=_n, subplot_titles=_labels, horizontal_spacing=0.08)

    for _idx, (_prot, _pa, _dfd) in enumerate(_items, 1):
        _m = POOLS[_pa]
        _dr = df_depth_meta[df_depth_meta["pool_address"] == _pa]
        _ctick = int(_dr.iloc[0]["current_tick"]) if not _dr.empty else 0

        # --- CLMM conversion: virtual L → token amounts -----------------
        _ticks = _dfd["tick_lower"].values.astype(float)
        _L     = _dfd["liquidity_balance"].values.astype(float)

        # sqrt(price) at lower and upper boundaries of each tick interval
        _sqrt_P_lo = np.sqrt(np.power(1.0001, _ticks))
        _sqrt_P_hi = np.sqrt(np.power(1.0001, _ticks + _TICK_SPACING))

        # Token0 (above current tick): Δx = L · (1/√P_lo − 1/√P_hi)
        _token0_raw = _L * (1.0 / _sqrt_P_lo - 1.0 / _sqrt_P_hi)
        _token0_human = _token0_raw / (10 ** _m["dec0"])

        # Token1 (below current tick): Δy = L · (√P_hi − √P_lo)
        _token1_raw = _L * (_sqrt_P_hi - _sqrt_P_lo)
        _token1_human = _token1_raw / (10 ** _m["dec1"])

        # Select the appropriate token per tick (above→token0, below→token1)
        _is_above = _ticks >= _ctick
        _values = np.where(_is_above, _token0_human, _token1_human)

        # Labels for hover
        _tok_names = np.where(_is_above, _m["token0"], _m["token1"])
        _hover = [
            f"Tick {int(t)}<br>{nm}: {v:,.4f}"
            for t, nm, v in zip(_ticks, _tok_names, _values)
        ]

        _bar_colors = ["#3b82f6" if a else "#f97316" for a in _is_above]

        fig_depth.add_trace(
            go.Bar(
                x=_dfd["tick_lower"], y=_values,
                marker_color=_bar_colors,
                name="Token Depth",
                hovertext=_hover, hoverinfo="text",
                width=1,
            ),
            row=1, col=_idx,
        )
        fig_depth.add_vline(
            x=_ctick, line_dash="dash", line_color="#22c55e", line_width=2,
            annotation_text=f"Tick {_ctick}", annotation_font_color="#22c55e",
            row=1, col=_idx,
        )
        fig_depth.update_xaxes(title_text="Tick", row=1, col=_idx)
        fig_depth.update_yaxes(title_text="Token Amount", row=1, col=_idx)

    fig_depth.update_layout(
        template="plotly_dark",
        paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
        height=400, margin=dict(l=60, r=30, t=40, b=40),
        showlegend=False, bargap=0,
    )
    fig_depth
    return


@app.cell
def _(mo):
    mo.md("""
    ## Liquidity Depth — USD per Price Level
    """)
    return


@app.cell
def _(
    ORCA_ADDR,
    POOLS,
    RAY_ADDR,
    df_depth_meta,
    df_depth_orca,
    df_depth_raydium,
    go,
    make_subplots,
    np,
):
    """Depth chart: x=ONyc USD price, y=USD value per tick bucket.

    Same CLMM conversion as above, then:
      - x-axis: ONyc price in USD (derived from tick + decimal adjustment)
      - y-axis: USD value  = stablecoin_amount + onyc_amount × current_onyc_usd
    """
    _TICK_SPACING = 1

    _items = []
    if not df_depth_raydium.empty:
        _items.append(("raydium", RAY_ADDR, df_depth_raydium))
    if not df_depth_orca.empty:
        _items.append(("orca", ORCA_ADDR, df_depth_orca))

    _n = max(len(_items), 1)
    _labels = [f"{POOLS[_a]['pair']} ({_prot.title()})" for _prot, _a, _ in _items] or ["No depth data"]

    fig_depth_usd = make_subplots(rows=1, cols=_n, subplot_titles=_labels, horizontal_spacing=0.08)

    for _idx, (_prot, _pa, _dfd) in enumerate(_items, 1):
        _m = POOLS[_pa]
        _dr = df_depth_meta[df_depth_meta["pool_address"] == _pa]
        _ctick = int(_dr.iloc[0]["current_tick"]) if not _dr.empty else 0

        # --- CLMM conversion (identical to tick chart) -------------------
        _ticks = _dfd["tick_lower"].values.astype(float)
        _L     = _dfd["liquidity_balance"].values.astype(float)

        _sqrt_P_lo = np.sqrt(np.power(1.0001, _ticks))
        _sqrt_P_hi = np.sqrt(np.power(1.0001, _ticks + _TICK_SPACING))

        _token0_human = _L * (1.0 / _sqrt_P_lo - 1.0 / _sqrt_P_hi) / (10 ** _m["dec0"])
        _token1_human = _L * (_sqrt_P_hi - _sqrt_P_lo) / (10 ** _m["dec1"])

        # --- ONyc USD price per tick (x-axis) ----------------------------
        _dec_adj = 10 ** (_m["dec0"] - _m["dec1"])
        _raw_prices = np.power(1.0001, _ticks) * _dec_adj
        if _m.get("invert_for_usd"):
            _onyc_prices = 1.0 / _raw_prices
        else:
            _onyc_prices = _raw_prices

        _raw_cprice = (1.0001 ** _ctick) * _dec_adj
        _current_usd = 1.0 / _raw_cprice if _m.get("invert_for_usd") else _raw_cprice

        # --- USD value per tick bucket -----------------------------------
        # Raydium USDG-ONyc: token0=USDG(≈$1), token1=ONyc(×onyc_usd)
        # Orca   ONyc-USDC:  token0=ONyc(×onyc_usd), token1=USDC(≈$1)
        if _m.get("invert_for_usd"):
            _usd_vals = _token0_human + _token1_human * _current_usd
        else:
            _usd_vals = _token0_human * _current_usd + _token1_human

        _bar_colors = ["#3b82f6" if _p <= _current_usd else "#f97316" for _p in _onyc_prices]

        fig_depth_usd.add_trace(
            go.Bar(
                x=np.round(_onyc_prices, 6), y=np.round(_usd_vals, 2),
                marker_color=_bar_colors,
                name="USD Value",
                hovertemplate="ONyc $%{x:.4f}<br>$%{y:,.2f}<extra></extra>",
                width=0.0001,
            ),
            row=1, col=_idx,
        )
        fig_depth_usd.add_vline(
            x=_current_usd, line_dash="dash", line_color="#22c55e", line_width=2,
            annotation_text=f"${_current_usd:.4f}",
            annotation_font_color="#22c55e",
            row=1, col=_idx,
        )
        fig_depth_usd.update_xaxes(title_text="ONyc Price (USD)", row=1, col=_idx)
        fig_depth_usd.update_yaxes(title_text="USD Value", row=1, col=_idx)

    fig_depth_usd.update_layout(
        template="plotly_dark",
        paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
        height=400, margin=dict(l=60, r=30, t=40, b=40),
        showlegend=False, bargap=0,
    )
    fig_depth_usd
    return


@app.cell
def _(mo):
    mo.md("""
    ## Token Vault Reserves Over Time
    """)
    return


@app.cell
def _(POOLS, df_vaults, go, make_subplots):
    """Vault token balances over time per pool."""
    _vps = [_p for _p in df_vaults["pool_address"].unique() if _p in POOLS]
    _nv = max(len(_vps), 1)

    fig_vaults = make_subplots(
        rows=_nv, cols=1, shared_xaxes=True, vertical_spacing=0.1,
        subplot_titles=[f"{POOLS[_p]['pair']} Reserves" for _p in _vps],
    )

    for _i, _pa in enumerate(_vps, 1):
        _m = POOLS[_pa]
        _vdf = df_vaults[df_vaults["pool_address"] == _pa]
        if _vdf.empty:
            continue

        fig_vaults.add_trace(
            go.Scatter(
                x=_vdf["time"], y=_vdf["token_0_value"],
                mode="lines", name=f"{_m['token0']}",
                line=dict(color="#3b82f6", width=1.5),
                hovertemplate="%{x}<br>" + _m["token0"] + ": %{y:,.2f}<extra></extra>",
            ), row=_i, col=1,
        )
        fig_vaults.add_trace(
            go.Scatter(
                x=_vdf["time"], y=_vdf["token_1_value"],
                mode="lines", name=f"{_m['token1']}",
                line=dict(color="#f97316", width=1.5),
                hovertemplate="%{x}<br>" + _m["token1"] + ": %{y:,.2f}<extra></extra>",
            ), row=_i, col=1,
        )
        fig_vaults.update_yaxes(title_text="Token Amount", row=_i, col=1)

    fig_vaults.update_layout(
        template="plotly_dark",
        paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
        height=300 * _nv,
        margin=dict(l=60, r=30, t=40, b=40),
        showlegend=True,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
        hovermode="x unified",
    )
    fig_vaults
    return


@app.cell
def _(mo):
    mo.md("""
    ## Swap Events — Execution Prices
    """)
    return


@app.cell
def _(POOLS, df_pool_adj, df_swaps, go):
    """Swap execution prices scatter + pool price line overlay."""
    fig_swaps = go.Figure()
    _colors = {"raydium": "#00D1FF", "orca": "#FFD700"}

    if not df_swaps.empty:
        for _pa in df_swaps["pool_address"].unique():
            if _pa not in POOLS:
                continue
            _m = POOLS[_pa]
            _sdf = df_swaps[df_swaps["pool_address"] == _pa].copy()

            # effective_price columns are ALREADY decimal-adjusted — no further scaling needed
            _sdf["eff_price_human"] = _sdf["effective_price_buyt0_t1_per_t0"].combine_first(
                _sdf["effective_price_sellt0_t1_per_t0"]
            )

            # Convert to ONyc USD for comparison
            # Raydium USDG-ONyc: price = ONyc per USDG ≈ 0.93 → invert to get USDG per ONyc ≈ 1.075
            # Orca ONyc-USDC: price = USDC per ONyc ≈ 1.075 → already in USD terms
            if _m.get("invert_for_usd"):
                _sdf["onyc_usd"] = 1.0 / _sdf["eff_price_human"]
            else:
                _sdf["onyc_usd"] = _sdf["eff_price_human"]

            fig_swaps.add_trace(
                go.Scatter(
                    x=_sdf["meta_block_time"], y=_sdf["onyc_usd"],
                    mode="markers",
                    name=f"{_m['pair']} Swaps",
                    marker=dict(color=_colors.get(_m["protocol"], "#00D1FF"), size=4, opacity=0.6),
                    hovertemplate="%{x}<br>ONyc $%{y:.6f}<extra></extra>",
                )
            )

    # Overlay pool price line
    if not df_pool_adj.empty:
        for _pa in df_pool_adj["pool_address"].unique():
            if _pa not in POOLS:
                continue
            _m = POOLS[_pa]
            _sub = df_pool_adj[df_pool_adj["pool_address"] == _pa]
            fig_swaps.add_trace(
                go.Scatter(
                    x=_sub["time"], y=_sub["onyc_usd"],
                    mode="lines",
                    name=f"{_m['pair']} Pool Price",
                    line=dict(color=_colors.get(_m["protocol"], "#00D1FF"), width=1, dash="dot"),
                    opacity=0.5,
                    hovertemplate="%{x}<br>Pool: $%{y:.6f}<extra></extra>",
                )
            )

    fig_swaps.update_layout(
        template="plotly_dark",
        paper_bgcolor="#0d1117", plot_bgcolor="#0d1117",
        yaxis_title="ONyc Price (USD)",
        height=400, margin=dict(l=60, r=30, t=20, b=40),
        showlegend=True,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1),
        hovermode="x unified",
    )
    fig_swaps
    return


@app.cell
def _(mo):
    mo.md("""
    ## Depth & Impact Metrics
    """)
    return


@app.cell
def _(POOLS, df_depth_meta, mo, pd):
    """Table of latest depth impact metrics per pool."""
    _rows = []
    for _, _r in df_depth_meta.iterrows():
        _pa = _r["pool_address"]
        _m = POOLS.get(_pa, {})

        def _safe(_key, _fmt="{:.2f}", _default="—"):
            _v = _r.get(_key)
            if _v is None or (isinstance(_v, float) and pd.isna(_v)):
                return _default
            return _fmt.format(float(_v))

        _rows.append({
            "Pool": _m.get("pair", _pa[:12]),
            "Protocol": _m.get("protocol", "").title(),
            "Current Tick": int(_r["current_tick"]),
            "Pool Liquidity": _safe("pool_liquidity", "{:,.0f}"),
            "Total Liq": _safe("c_total_liquidity_tokens", "{:,.0f}"),
            "50K Sell bps": _safe("c_impact_from_sell_t0_1"),
            "100K Sell bps": _safe("c_impact_from_sell_t0_2"),
            "500K Sell bps": _safe("c_impact_from_sell_t0_3"),
            "Qty for 1bps": _safe("c_sell_t0_for_impact_bps_1", "{:,.0f}"),
            "Qty for 2bps": _safe("c_sell_t0_for_impact_bps_2", "{:,.0f}"),
            "Qty for 5bps": _safe("c_sell_t0_for_impact_bps_3", "{:,.0f}"),
            "Updated": str(_r.get("block_time", ""))[:19],
        })

    _output = mo.ui.table(pd.DataFrame(_rows), selection=None) if _rows else mo.md("*No depth metrics available.*")
    _output
    return


@app.cell
def _(mo):
    mo.md("""
    ## Recent Swaps
    """)
    return


@app.cell
def _(POOLS, df_swaps, mo, pd):
    """Table of most recent 50 swaps."""
    if not df_swaps.empty:
        _d = df_swaps.tail(100).copy()
        _d["Pool"] = _d["pool_address"].map(lambda _x: POOLS.get(_x, {}).get("pair", _x[:12]))
        _d["Impact (bps)"] = _d["evt_swap_impact_bps"].combine_first(_d["c_swap_est_impact_bps"])

        # Decimal-adjust swap amounts per token symbol
        _TOKEN_DECIMALS = {"ONyc": 9, "USDG": 6, "USDC": 6}
        _d["_raw_in"] = pd.to_numeric(_d["swap_amount_in"], errors="coerce")
        _d["_raw_out"] = pd.to_numeric(_d["swap_amount_out"], errors="coerce")
        _d["In Amt"] = _d.apply(
            lambda _r: _r["_raw_in"] / 10 ** _TOKEN_DECIMALS.get(_r["swap_token_in_symbol"], 0)
            if pd.notna(_r["_raw_in"]) else None, axis=1
        )
        _d["Out Amt"] = _d.apply(
            lambda _r: _r["_raw_out"] / 10 ** _TOKEN_DECIMALS.get(_r["swap_token_out_symbol"], 0)
            if pd.notna(_r["_raw_out"]) else None, axis=1
        )

        _tbl = _d[["meta_block_time", "Pool", "protocol", "swap_token_in_symbol", "In Amt",
                    "swap_token_out_symbol", "Out Amt", "Impact (bps)"]].copy()
        _tbl.columns = ["Time", "Pool", "Protocol", "In Token", "In Amt", "Out Token", "Out Amt", "Impact (bps)"]
        _tbl = _tbl.sort_values("Time", ascending=False).head(50)
        _swaps_output = mo.ui.table(_tbl, selection=None)
    else:
        _swaps_output = mo.md("*No swap events in selected period.*")
    _swaps_output
    return


if __name__ == "__main__":
    app.run()

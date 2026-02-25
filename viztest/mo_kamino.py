import marimo

__generated_with = "0.19.5"
app = marimo.App(width="full", app_title="ONyc Kamino Lend Dashboard", css_file="")


@app.cell
def _():
    import marimo as mo
    return (mo,)


@app.cell
def _(mo):
    mo.md("""
    # ONyc Kamino Lend — Activity & Monitoring
    Market **47tfyEG9SsdEnUm9cw5kY9BXngQGqu3LBoop9j5uTAv8**.
    Validate against Kamino:
    [ONyc](https://kamino.com/borrow/reserve/47tfyEG9SsdEnUm9cw5kY9BXngQGqu3LBoop9j5uTAv8/6ZxkBSJEqsXA3Kdm2PDAzHLUdPTPUK93Lf4bAezec1UQ) ·
    [USDC](https://kamino.com/borrow/reserve/47tfyEG9SsdEnUm9cw5kY9BXngQGqu3LBoop9j5uTAv8/AYL4LMc4ZCVyq3Z7XPJGWDM4H9PiWjqXAAuuHBEGVR2Z) ·
    [USDG](https://kamino.com/borrow/reserve/47tfyEG9SsdEnUm9cw5kY9BXngQGqu3LBoop9j5uTAv8/JBmLCoKqjdKSStK45onRqe6U6sxVgSpdXoeXe4h7NwJw) ·
    [USDS](https://kamino.com/borrow/reserve/47tfyEG9SsdEnUm9cw5kY9BXngQGqu3LBoop9j5uTAv8/3yDc9ARvtPLhYxZLgucZGuBtZ9bHshBvXTwHxGe3nhmC)
    """)
    return


@app.cell
def _():
    import warnings
    warnings.filterwarnings("ignore", message=".*pandas only supports SQLAlchemy.*")
    import psycopg2, pandas as pd, numpy as np
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots
    from datetime import datetime, timedelta, timezone
    return datetime, go, make_subplots, np, pd, psycopg2, timedelta, timezone


@app.cell
def _(psycopg2):
    DB_CONFIG = {
        "host": "fd3cdmjulb.p56ar8nomm.tsdb.cloud.timescale.com",
        "port": 33971,
        "dbname": "tsdb",
        "user": "tsdbadmin",
        "password": "ner5q1iamtwzkmmd",
        "sslmode": "require",
    }
    SCHEMA = "kamino_lend"
    MARKET_ADDR = "47tfyEG9SsdEnUm9cw5kY9BXngQGqu3LBoop9j5uTAv8"

    def get_conn():
        return psycopg2.connect(**DB_CONFIG)

    return DB_CONFIG, MARKET_ADDR, SCHEMA, get_conn


@app.cell
def _():
    DARK_LAYOUT = dict(
        template="plotly_dark",
        paper_bgcolor="#0d1117",
        plot_bgcolor="#0d1117",
    )
    COLORS = ["#3b82f6", "#22c55e", "#f97316", "#a855f7", "#ef4444", "#eab308", "#06b6d4", "#ec4899"]
    return COLORS, DARK_LAYOUT


@app.cell
def _(mo):
    lookback = mo.ui.dropdown(
        options={"1 Hour": "1h", "6 Hours": "6h", "24 Hours": "24h", "3 Days": "3d", "7 Days": "7d"},
        value="24 Hours",
        label="Lookback",
    )
    refresh_btn = mo.ui.run_button(label="Refresh Data")
    mo.hstack([lookback, refresh_btn], justify="start", gap=1)
    return lookback, refresh_btn


@app.cell
def _(lookback, timedelta):
    _LB_MAP = {"1h": timedelta(hours=1), "6h": timedelta(hours=6), "24h": timedelta(hours=24), "3d": timedelta(days=3), "7d": timedelta(days=7)}
    LB_DELTA = _LB_MAP.get(lookback.value, timedelta(hours=24))
    return (LB_DELTA,)


# ── DATA FETCHES ───────────────────────────────────────────────────

@app.cell
def _(MARKET_ADDR, SCHEMA, get_conn, pd, refresh_btn):
    refresh_btn
    _conn = get_conn()
    # aux_market_reserve_tokens may not be populated; fall back to latest src_reserves
    df_tokens = pd.read_sql(f"""
        SELECT DISTINCT ON (reserve_address)
            reserve_address, env_symbol AS token_symbol, env_decimals AS token_decimals,
            env_reserve_type AS reserve_type, reserve_status,
            loan_to_value_pct, liquidation_threshold_pct, borrow_factor_pct,
            liquidity_mint_pubkey AS token_mint
        FROM {SCHEMA}.src_reserves
        WHERE market_address = '{MARKET_ADDR}'
        ORDER BY reserve_address, time DESC
    """, _conn)
    _conn.close()
    return (df_tokens,)


@app.cell
def _(LB_DELTA, MARKET_ADDR, SCHEMA, datetime, get_conn, pd, refresh_btn, timezone):
    refresh_btn
    _since = datetime.now(timezone.utc) - LB_DELTA
    _conn = get_conn()
    df_reserves = pd.read_sql(f"""
        SELECT * FROM {SCHEMA}.src_reserves
        WHERE market_address = '{MARKET_ADDR}' AND time >= '{_since.isoformat()}'
        ORDER BY time DESC
    """, _conn)
    _conn.close()
    return (df_reserves,)


@app.cell
def _(LB_DELTA, MARKET_ADDR, SCHEMA, datetime, get_conn, pd, refresh_btn, timezone):
    refresh_btn
    _since = datetime.now(timezone.utc) - LB_DELTA
    _conn = get_conn()
    df_agg = pd.read_sql(f"""
        SELECT * FROM {SCHEMA}.src_obligations_agg
        WHERE market_address = '{MARKET_ADDR}' AND time >= '{_since.isoformat()}'
        ORDER BY time DESC
    """, _conn)
    _conn.close()
    return (df_agg,)


@app.cell
def _(MARKET_ADDR, SCHEMA, get_conn, pd, refresh_btn):
    refresh_btn
    _conn = get_conn()
    df_obligs = pd.read_sql(f"""
        SELECT obligation_address, owner, c_user_total_deposit, c_user_total_borrow,
               c_health_factor, c_loan_to_value_pct, c_is_unhealthy, c_is_bad_debt,
               c_is_healthy_below_1_1, c_leverage, c_liquidation_buffer_pct,
               c_liquidatable_value, c_net_account_value, has_debt, c_num_deposits, c_num_borrows
        FROM {SCHEMA}.src_obligations_last
        WHERE market_address = '{MARKET_ADDR}'
    """, _conn)
    _conn.close()
    return (df_obligs,)


@app.cell
def _(LB_DELTA, MARKET_ADDR, SCHEMA, datetime, get_conn, pd, refresh_btn, timezone):
    refresh_btn
    _since = datetime.now(timezone.utc) - LB_DELTA
    _conn = get_conn()
    df_events = pd.read_sql(f"""
        SELECT * FROM {SCHEMA}.src_txn_events
        WHERE lending_market_address = '{MARKET_ADDR}' AND meta_block_time >= '{_since.isoformat()}'
        ORDER BY meta_block_time DESC LIMIT 500
    """, _conn)
    _conn.close()
    return (df_events,)


@app.cell
def _(SCHEMA, get_conn, pd, refresh_btn):
    refresh_btn
    _conn = get_conn()
    try:
        df_sensitivity = pd.read_sql(f"SELECT * FROM {SCHEMA}.get_view_klend_sensitivities()", _conn)
    except Exception:
        df_sensitivity = pd.DataFrame()
    _conn.close()
    return (df_sensitivity,)


# ── RESERVE REFERENCE TABLE ────────────────────────────────────────

@app.cell
def _(df_tokens, mo):
    _items = [mo.md("---\n## Reserve Reference")]
    if not df_tokens.empty:
        _cols = ["reserve_address", "token_symbol", "token_decimals", "reserve_type", "reserve_status",
                 "loan_to_value_pct", "liquidation_threshold_pct", "borrow_factor_pct"]
        _dc = [c for c in _cols if c in df_tokens.columns]
        _items.append(mo.ui.table(df_tokens[_dc], selection=None))
    else:
        _items.append(mo.md("*No reserve token data.*"))
    mo.vstack(_items)
    return


# ── KPI CARDS ──────────────────────────────────────────────────────

@app.cell
def _(df_agg, df_obligs, df_reserves, mo):
    _kpis = {}

    # From latest aggregate snapshot
    if not df_agg.empty:
        _a = df_agg.iloc[0]
        _kpis["Total Deposits"] = f"${float(_a.get('total_collateral_value') or 0):,.0f}"
        _kpis["Total Borrows"] = f"${float(_a.get('total_borrow_value') or 0):,.0f}"
        _tv = float(_a.get('total_collateral_value') or 0)
        _tb = float(_a.get('total_borrow_value') or 0)
        _kpis["Market LTV"] = f"{(_tb / _tv * 100) if _tv > 0 else 0:.1f}%"
        _kpis["Obligations"] = f"{int(_a.get('n_obligations_all') or 0):,}"
        _kpis["Active (debt)"] = f"{int(_a.get('n_obligations_with_debt_all') or 0):,}"
        _kpis["Avg HF (sig)"] = f"{float(_a.get('avg_health_factor_sig') or 0):.2f}"
        _kpis["Wt-Avg HF"] = f"{float(_a.get('weighted_avg_health_factor_sig') or 0):.2f}"
        _kpis["Median HF"] = f"{float(_a.get('median_health_factor_sig') or 0):.2f}"
        _kpis["Avg LTV (sig)"] = f"{float(_a.get('avg_loan_to_value_sig') or 0):.1f}%"
        _kpis["Unhealthy"] = f"{int(_a.get('n_unhealthy_all') or 0)}"
        _kpis["Bad Debt"] = f"{int(_a.get('n_bad_debt_all') or 0)}"
        _kpis["Danger Zone"] = f"{int(_a.get('n_danger_zone_all') or 0)}"
        _kpis["Unhealthy Debt $"] = f"${float(_a.get('total_unhealthy_debt') or 0):,.0f}"
        _kpis["Bad Debt $"] = f"${float(_a.get('total_bad_debt') or 0):,.0f}"
        _kpis["Liquidatable $"] = f"${float(_a.get('total_liquidatable_value') or 0):,.0f}"
        _kpis["Top-1 Conc."] = f"{float(_a.get('top_1_debt_concentration_pct') or 0):.1f}%"
        _kpis["Top-10 Conc."] = f"{float(_a.get('top_10_debt_concentration_pct') or 0):.1f}%"
        _kpis["HHI"] = f"{float(_a.get('herfindahl_index_debt') or 0):.2f}%"

    # Reserve count
    if not df_reserves.empty:
        _symbols = df_reserves["env_symbol"].dropna().unique()
        _kpis["Reserves"] = f"{len(_symbols)} ({', '.join(sorted(_symbols))})"

    # Obligation count from last snapshot
    if not df_obligs.empty:
        _kpis["Obligs (last)"] = f"{len(df_obligs):,}"

    _cards = [mo.md(f"**{k}**\n\n`{v}`") for k, v in _kpis.items()]
    mo.vstack([mo.md("---\n## Key Metrics (latest snapshot)"), mo.hstack(_cards, wrap=True, gap=1)])
    return


# ── RESERVE COMPOSITION (BAR CHARTS) ──────────────────────────────

@app.cell
def _(COLORS, DARK_LAYOUT, df_reserves, go, make_subplots, mo):
    _items = [mo.md("---\n## Reserve Composition (Vault Market Value)")]
    if not df_reserves.empty:
        _latest = df_reserves.sort_values("time").groupby("env_symbol").last().reset_index()
        _latest["_liq_mv"] = _latest["c_liquidity_vault_marketvalue"].fillna(0).astype(float)
        _latest["_col_mv"] = _latest["c_collateral_vault_marketvalue"].fillna(0).astype(float)
        _latest = _latest.sort_values("_liq_mv", ascending=False)

        _fig = make_subplots(rows=1, cols=2, subplot_titles=["Liquidity Vault ($)", "Collateral Vault ($)"], horizontal_spacing=0.1)
        _syms = _latest["env_symbol"].tolist()
        _fig.add_trace(go.Bar(x=_syms, y=_latest["_liq_mv"].tolist(), marker_color=[COLORS[i % len(COLORS)] for i in range(len(_syms))], name="Liquidity", hovertemplate="%{x}: $%{y:,.0f}<extra></extra>"), row=1, col=1)
        _fig.add_trace(go.Bar(x=_syms, y=_latest["_col_mv"].tolist(), marker_color=[COLORS[i % len(COLORS)] for i in range(len(_syms))], name="Collateral", hovertemplate="%{x}: $%{y:,.0f}<extra></extra>"), row=1, col=2)
        _fig.update_layout(**DARK_LAYOUT, height=350, showlegend=False, margin=dict(l=60, r=30, t=40, b=40))
        _items.append(_fig)
    else:
        _items.append(mo.md("*No reserve data.*"))
    mo.vstack(_items)
    return


# ── RESERVE TIME-SERIES: APY ──────────────────────────────────────

@app.cell
def _(COLORS, DARK_LAYOUT, df_reserves, go, make_subplots, mo):
    _items = [mo.md("## Supply & Borrow APY Over Time")]
    if not df_reserves.empty:
        _symbols = sorted(df_reserves["env_symbol"].dropna().unique())
        _fig = make_subplots(rows=1, cols=2, subplot_titles=["Supply APY (%)", "Borrow APY (%)"], horizontal_spacing=0.1)
        for _i, _sym in enumerate(_symbols):
            _sub = df_reserves[df_reserves["env_symbol"] == _sym].sort_values("time")
            _c = COLORS[_i % len(COLORS)]
            _fig.add_trace(go.Scatter(x=_sub["time"], y=_sub["supply_apy"].astype(float) * 100, mode="lines", name=_sym, line=dict(color=_c, width=2), legendgroup=_sym, showlegend=True), row=1, col=1)
            _fig.add_trace(go.Scatter(x=_sub["time"], y=_sub["borrow_apy"].astype(float) * 100, mode="lines", name=_sym, line=dict(color=_c, width=2), legendgroup=_sym, showlegend=False), row=1, col=2)
        _fig.update_layout(**DARK_LAYOUT, height=350, legend=dict(orientation="h", y=1.12), margin=dict(l=60, r=30, t=50, b=40))
        _fig.update_yaxes(title_text="APY %", row=1, col=1)
        _fig.update_yaxes(title_text="APY %", row=1, col=2)
        _items.append(_fig)
    else:
        _items.append(mo.md("*No APY data.*"))
    mo.vstack(_items)
    return


# ── RESERVE TIME-SERIES: UTILIZATION + ORACLE PRICE ───────────────

@app.cell
def _(COLORS, DARK_LAYOUT, df_reserves, go, make_subplots, mo):
    _items = [mo.md("## Utilization & Oracle Price")]
    if not df_reserves.empty:
        _symbols = sorted(df_reserves["env_symbol"].dropna().unique())
        _fig = make_subplots(rows=1, cols=2, subplot_titles=["Utilization Ratio", "Oracle Price ($)"], horizontal_spacing=0.1)
        for _i, _sym in enumerate(_symbols):
            _sub = df_reserves[df_reserves["env_symbol"] == _sym].sort_values("time")
            _c = COLORS[_i % len(COLORS)]
            _fig.add_trace(go.Scatter(x=_sub["time"], y=_sub["utilization_ratio"].astype(float) * 100, mode="lines", name=_sym, line=dict(color=_c, width=2), legendgroup=_sym, showlegend=True), row=1, col=1)
            _fig.add_trace(go.Scatter(x=_sub["time"], y=_sub["oracle_price"].astype(float), mode="lines", name=_sym, line=dict(color=_c, width=2), legendgroup=_sym, showlegend=False), row=1, col=2)
        _fig.update_layout(**DARK_LAYOUT, height=350, legend=dict(orientation="h", y=1.12), margin=dict(l=60, r=30, t=50, b=40))
        _fig.update_yaxes(title_text="Util %", row=1, col=1)
        _fig.update_yaxes(title_text="Price $", row=1, col=2)
        _items.append(_fig)
    else:
        _items.append(mo.md("*No utilization data.*"))
    mo.vstack(_items)
    return


# ── RESERVE TIME-SERIES: DEPOSIT & BORROW TVL ────────────────────

@app.cell
def _(COLORS, DARK_LAYOUT, df_reserves, go, make_subplots, mo):
    _items = [mo.md("## Vault Market Value Over Time")]
    if not df_reserves.empty:
        _symbols = sorted(df_reserves["env_symbol"].dropna().unique())
        _fig = make_subplots(rows=1, cols=2, subplot_titles=["Liquidity Vault ($)", "Collateral Vault ($)"], horizontal_spacing=0.1)
        for _i, _sym in enumerate(_symbols):
            _sub = df_reserves[df_reserves["env_symbol"] == _sym].sort_values("time")
            _c = COLORS[_i % len(COLORS)]
            _fig.add_trace(go.Scatter(x=_sub["time"], y=_sub["c_liquidity_vault_marketvalue"].fillna(0).astype(float), mode="lines", name=_sym, line=dict(color=_c, width=2), legendgroup=_sym, showlegend=True), row=1, col=1)
            _fig.add_trace(go.Scatter(x=_sub["time"], y=_sub["c_collateral_vault_marketvalue"].fillna(0).astype(float), mode="lines", name=_sym, line=dict(color=_c, width=2), legendgroup=_sym, showlegend=False), row=1, col=2)
        _fig.update_layout(**DARK_LAYOUT, height=350, legend=dict(orientation="h", y=1.12), margin=dict(l=60, r=30, t=50, b=40))
        _fig.update_yaxes(title_text="Value $", row=1, col=1)
        _fig.update_yaxes(title_text="Value $", row=1, col=2)
        _items.append(_fig)
    else:
        _items.append(mo.md("*No vault data.*"))
    mo.vstack(_items)
    return


# ── OBLIGATION HEALTH DISTRIBUTION ────────────────────────────────

@app.cell
def _(DARK_LAYOUT, df_obligs, go, make_subplots, mo, np):
    _items = [mo.md("---\n## Obligation Health Distribution (latest snapshot)")]
    if not df_obligs.empty:
        _debt = df_obligs[df_obligs["has_debt"] == True].copy()
        _fig = make_subplots(rows=1, cols=2, subplot_titles=["Health Factor Distribution", "LTV Distribution (%)"], horizontal_spacing=0.1)

        if not _debt.empty:
            _hf = _debt["c_health_factor"].astype(float).clip(upper=5)
            _fig.add_trace(go.Histogram(x=_hf, nbinsx=50, marker_color="#3b82f6", name="HF", hovertemplate="HF: %{x:.2f}<br>Count: %{y}<extra></extra>"), row=1, col=1)
            _fig.add_vline(x=1.0, line_dash="dash", line_color="#ef4444", annotation_text="HF=1.0", annotation_font_color="#ef4444", row=1, col=1)
            _fig.add_vline(x=1.1, line_dash="dot", line_color="#eab308", annotation_text="1.1", annotation_font_color="#eab308", row=1, col=1)

            _ltv = _debt["c_loan_to_value_pct"].astype(float).clip(upper=120)
            _fig.add_trace(go.Histogram(x=_ltv, nbinsx=50, marker_color="#a855f7", name="LTV %", hovertemplate="LTV: %{x:.1f}%<br>Count: %{y}<extra></extra>"), row=1, col=2)
        _fig.update_layout(**DARK_LAYOUT, height=350, showlegend=False, margin=dict(l=60, r=30, t=40, b=40))
        _fig.update_xaxes(title_text="Health Factor", row=1, col=1)
        _fig.update_xaxes(title_text="LTV %", row=1, col=2)
        _items.append(_fig)

        # Summary stats
        if not _debt.empty:
            _n_unhealth = int((_debt["c_is_unhealthy"] == True).sum())
            _n_bad = int((_debt["c_is_bad_debt"] == True).sum())
            _n_danger = int((_debt["c_is_healthy_below_1_1"] == True).sum())
            _items.append(mo.hstack([
                mo.md(f"**Unhealthy**: `{_n_unhealth}`"),
                mo.md(f"**Bad Debt**: `{_n_bad}`"),
                mo.md(f"**Danger (1.0-1.1)**: `{_n_danger}`"),
                mo.md(f"**Total w/ debt**: `{len(_debt)}`"),
            ], gap=2))
    else:
        _items.append(mo.md("*No obligation data.*"))
    mo.vstack(_items)
    return


# ── MARKET AGGREGATE TIME-SERIES ──────────────────────────────────

@app.cell
def _(DARK_LAYOUT, df_agg, go, make_subplots, mo):
    _items = [mo.md("---\n## Market Aggregates Over Time")]
    if not df_agg.empty:
        _df = df_agg.sort_values("time")
        _fig = make_subplots(rows=2, cols=2, subplot_titles=["Total Deposits & Borrows ($)", "Avg HF / Wt-Avg HF (sig)", "Unhealthy & Bad Debt ($)", "Debt Concentration (%)"], vertical_spacing=0.12, horizontal_spacing=0.1)

        # Deposits & Borrows
        _fig.add_trace(go.Scatter(x=_df["time"], y=_df["total_collateral_value"].astype(float), mode="lines", name="Deposits", line=dict(color="#3b82f6", width=2)), row=1, col=1)
        _fig.add_trace(go.Scatter(x=_df["time"], y=_df["total_borrow_value"].astype(float), mode="lines", name="Borrows", line=dict(color="#f97316", width=2)), row=1, col=1)

        # Health factors
        _fig.add_trace(go.Scatter(x=_df["time"], y=_df["avg_health_factor_sig"].astype(float), mode="lines", name="Avg HF", line=dict(color="#22c55e", width=2)), row=1, col=2)
        _fig.add_trace(go.Scatter(x=_df["time"], y=_df["weighted_avg_health_factor_sig"].astype(float), mode="lines", name="Wt-Avg HF", line=dict(color="#06b6d4", width=2)), row=1, col=2)
        _fig.add_hline(y=1.0, line_dash="dash", line_color="#ef4444", row=1, col=2)

        # Unhealthy & bad debt
        _fig.add_trace(go.Scatter(x=_df["time"], y=_df["total_unhealthy_debt"].astype(float), mode="lines", name="Unhealthy $", line=dict(color="#eab308", width=2), fill="tozeroy", fillcolor="rgba(234,179,8,0.1)"), row=2, col=1)
        _fig.add_trace(go.Scatter(x=_df["time"], y=_df["total_bad_debt"].astype(float), mode="lines", name="Bad Debt $", line=dict(color="#ef4444", width=2), fill="tozeroy", fillcolor="rgba(239,68,68,0.1)"), row=2, col=1)

        # Concentration
        if "top_1_debt_concentration_pct" in _df.columns:
            _fig.add_trace(go.Scatter(x=_df["time"], y=_df["top_1_debt_concentration_pct"].astype(float), mode="lines", name="Top-1 %", line=dict(color="#a855f7", width=2)), row=2, col=2)
            _fig.add_trace(go.Scatter(x=_df["time"], y=_df["top_10_debt_concentration_pct"].astype(float), mode="lines", name="Top-10 %", line=dict(color="#ec4899", width=2)), row=2, col=2)

        _fig.update_layout(**DARK_LAYOUT, height=650, legend=dict(orientation="h", y=1.05), margin=dict(l=60, r=30, t=60, b=40))
        _items.append(_fig)
    else:
        _items.append(mo.md("*No aggregate data.*"))
    mo.vstack(_items)
    return


# ── SENSITIVITY ANALYSIS ──────────────────────────────────────────

@app.cell
def _(DARK_LAYOUT, df_sensitivity, go, make_subplots, mo):
    _items = [mo.md("---\n## Sensitivity Analysis (Stress Test)")]
    if not df_sensitivity.empty:
        _df = df_sensitivity.sort_values("step_number")

        _fig = make_subplots(rows=2, cols=2, subplot_titles=[
            "Unhealthy & Bad Debt vs Scenario",
            "Liquidatable Value vs Scenario",
            "Market LTV vs Scenario",
            "At-Risk Debt % vs Scenario",
        ], vertical_spacing=0.12, horizontal_spacing=0.1)

        _x = _df["pct_change"].astype(float)

        # Unhealthy + bad debt
        _fig.add_trace(go.Scatter(x=_x, y=_df["unhealthy_debt"].astype(float), mode="lines+markers", name="Unhealthy Debt $", line=dict(color="#eab308", width=2), marker=dict(size=4)), row=1, col=1)
        _fig.add_trace(go.Scatter(x=_x, y=_df["bad_debt"].astype(float), mode="lines+markers", name="Bad Debt $", line=dict(color="#ef4444", width=2), marker=dict(size=4)), row=1, col=1)

        # Liquidatable value
        _fig.add_trace(go.Scatter(x=_x, y=_df["total_liquidatable_value"].astype(float), mode="lines+markers", name="Total Liquidatable $", line=dict(color="#a855f7", width=2), marker=dict(size=4)), row=1, col=2)

        # Market LTV
        _fig.add_trace(go.Scatter(x=_x, y=_df["market_ltv_pct"].astype(float), mode="lines+markers", name="Market LTV %", line=dict(color="#3b82f6", width=2), marker=dict(size=4)), row=2, col=1)

        # At-risk debt %
        _fig.add_trace(go.Scatter(x=_x, y=_df["total_at_risk_debt_pct"].astype(float), mode="lines+markers", name="At-Risk %", line=dict(color="#f97316", width=2), marker=dict(size=4)), row=2, col=2)

        # Vertical line at current state (pct_change=0)
        for _r in [1, 2]:
            for _c in [1, 2]:
                _fig.add_vline(x=0, line_dash="dash", line_color="#22c55e", annotation_text="Current", row=_r, col=_c)

        _fig.update_layout(**DARK_LAYOUT, height=650, legend=dict(orientation="h", y=1.05), margin=dict(l=60, r=30, t=60, b=40))
        _fig.update_xaxes(title_text="Price Change %")
        _items.append(_fig)

        # Table
        _display_cols = ["step_number", "scenario_type", "pct_change", "total_deposits", "total_borrows", "market_ltv_pct",
                         "unhealthy_debt", "bad_debt", "total_at_risk_debt_pct", "total_liquidatable_value", "liquidatable_value_pct_of_deposits"]
        _dc = [c for c in _display_cols if c in _df.columns]
        _items.append(mo.md("### Sensitivity Table"))
        _items.append(mo.ui.table(_df[_dc], selection=None))
    else:
        _items.append(mo.md("*Sensitivity function not available or returned no data.*"))
    mo.vstack(_items)
    return


# ── LARGEST OBLIGATIONS TABLE ─────────────────────────────────────

@app.cell
def _(df_obligs, mo, pd):
    _items = [mo.md("---\n## Largest Obligations (by Borrow)")]
    if not df_obligs.empty:
        _top = df_obligs.sort_values("c_user_total_borrow", ascending=False).head(25).copy()
        _cols = ["obligation_address", "owner", "c_user_total_deposit", "c_user_total_borrow",
                 "c_health_factor", "c_loan_to_value_pct", "c_leverage", "c_is_unhealthy", "c_is_bad_debt"]
        _dc = [c for c in _cols if c in _top.columns]
        _tbl = _top[_dc].copy()
        if "obligation_address" in _tbl.columns:
            _tbl["obligation_address"] = _tbl["obligation_address"].str[:16] + "..."
        if "owner" in _tbl.columns:
            _tbl["owner"] = _tbl["owner"].fillna("").str[:16] + "..."
        for _nc in ["c_user_total_deposit", "c_user_total_borrow"]:
            if _nc in _tbl.columns:
                _tbl[_nc] = _tbl[_nc].apply(lambda x: f"${float(x):,.0f}" if pd.notna(x) else "")
        for _nc in ["c_health_factor", "c_leverage"]:
            if _nc in _tbl.columns:
                _tbl[_nc] = _tbl[_nc].apply(lambda x: f"{float(x):.2f}" if pd.notna(x) else "")
        if "c_loan_to_value_pct" in _tbl.columns:
            _tbl["c_loan_to_value_pct"] = _tbl["c_loan_to_value_pct"].apply(lambda x: f"{float(x):.1f}%" if pd.notna(x) else "")
        _items.append(mo.ui.table(_tbl, selection=None))
    else:
        _items.append(mo.md("*No obligation data.*"))
    mo.vstack(_items)
    return


# ── TRANSACTION EVENTS ─────────────────────────────────────────────

@app.cell
def _(COLORS, DARK_LAYOUT, df_events, df_tokens, go, make_subplots, mo):
    _items = [mo.md("---\n## Transaction Events")]
    if not df_events.empty:
        # Build reserve->symbol lookup
        _rsym = {}
        if not df_tokens.empty:
            for _, _row in df_tokens.iterrows():
                _rsym[_row["reserve_address"]] = _row["token_symbol"]

        # Category bar chart + reserve activity
        _cats = df_events["activity_category"].value_counts()
        _fig = make_subplots(rows=1, cols=2, subplot_titles=["Activity Category", "Activity by Reserve"], horizontal_spacing=0.12)
        _fig.add_trace(go.Bar(x=_cats.index.tolist(), y=_cats.values.tolist(), marker_color="#3b82f6"), row=1, col=1)

        # By reserve
        if "reserve_address" in df_events.columns:
            _rev = df_events.copy()
            _rev["_sym"] = _rev["reserve_address"].map(_rsym).fillna(_rev["reserve_address"].str[:8] + "...")
            _rsv_counts = _rev["_sym"].value_counts().head(10)
            _fig.add_trace(go.Bar(x=_rsv_counts.index.tolist(), y=_rsv_counts.values.tolist(), marker_color="#22c55e"), row=1, col=2)

        _fig.update_layout(**DARK_LAYOUT, height=300, showlegend=False, margin=dict(l=60, r=30, t=40, b=40))
        _items.append(_fig)
    else:
        _items.append(mo.md("*No events in lookback window.*"))
    mo.vstack(_items)
    return


# ── EVENT TIMELINE ─────────────────────────────────────────────────

@app.cell
def _(COLORS, DARK_LAYOUT, df_events, go, mo):
    _items = [mo.md("### Event Timeline")]
    if not df_events.empty and "meta_block_time" in df_events.columns:
        _df = df_events.sort_values("meta_block_time")
        _types = _df["activity_category"].dropna().unique()
        _fig = go.Figure()
        for _i, _cat in enumerate(_types):
            _sub = _df[_df["activity_category"] == _cat]
            _fig.add_trace(go.Scatter(x=_sub["meta_block_time"], y=[_cat] * len(_sub), mode="markers", name=_cat, marker=dict(color=COLORS[_i % len(COLORS)], size=8)))
        _fig.update_layout(**DARK_LAYOUT, height=max(200, len(_types) * 40), showlegend=False, xaxis_title="Time", margin=dict(l=150, r=30, t=30, b=40))
        _items.append(_fig)
    else:
        _items.append(mo.md("*No event data.*"))
    mo.vstack(_items)
    return


# ── RECENT EVENTS TABLE ───────────────────────────────────────────

@app.cell
def _(df_events, df_tokens, mo):
    _items = [mo.md("### Recent Events")]
    if not df_events.empty:
        _rsym = {}
        if not df_tokens.empty:
            for _, _row in df_tokens.iterrows():
                _rsym[_row["reserve_address"]] = _row["token_symbol"]

        _cols = ["meta_block_time", "activity_category", "instruction_name", "reserve_address", "user_address", "liquidity_amount", "signature"]
        _dc = [c for c in _cols if c in df_events.columns]
        _tbl = df_events[_dc].head(50).copy()
        if "reserve_address" in _tbl.columns:
            _tbl["reserve"] = _tbl["reserve_address"].map(_rsym).fillna(_tbl["reserve_address"].str[:12] + "...")
            _tbl = _tbl.drop(columns=["reserve_address"])
        if "signature" in _tbl.columns:
            _tbl["signature"] = _tbl["signature"].str[:16] + "..."
        if "user_address" in _tbl.columns:
            _tbl["user_address"] = _tbl["user_address"].fillna("").str[:16] + "..."
        _items.append(mo.ui.table(_tbl, selection=None))
    else:
        _items.append(mo.md("*No events.*"))
    mo.vstack(_items)
    return


if __name__ == "__main__":
    app.run()

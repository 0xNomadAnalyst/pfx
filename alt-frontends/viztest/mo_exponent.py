import marimo

__generated_with = "0.19.5"
app = marimo.App(width="full", app_title="ONyc Exponent Dashboard", css_file="")


@app.cell
def _():
    import marimo as mo
    return (mo,)


@app.cell
def _(mo):
    mo.md("""
    # ONyc Exponent — Activity & Monitoring
    Live data from **PT-ONyc-13MAY26** market.  Validate against [Exponent Income](https://www.exponent.finance/income/onyc-13May26).
    """)
    return


@app.cell
def _():
    import warnings
    warnings.filterwarnings("ignore", message=".*pandas only supports SQLAlchemy.*")
    import warnings
    warnings.filterwarnings("ignore", message=".*pandas only supports SQLAlchemy.*")
    import psycopg2
    import pandas as pd
    import plotly.graph_objects as go
    from plotly.subplots import make_subplots
    from datetime import datetime, timedelta, timezone
    import numpy as np
    import math
    return datetime, go, make_subplots, math, np, pd, psycopg2, timedelta, timezone


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
    SCHEMA = "exponent"
    ONYC_BASE_MINT = "5Y8NV33Vv7WbnLfq3zBcKSdYPrk7g2KoiQoe7M2tcxp5"
    ONYC_DECIMALS = 9

    def get_conn():
        return psycopg2.connect(**DB_CONFIG)

    return DB_CONFIG, ONYC_BASE_MINT, ONYC_DECIMALS, SCHEMA, get_conn


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


@app.cell
def _(ONYC_BASE_MINT, SCHEMA, get_conn, pd, refresh_btn):
    refresh_btn
    _conn = get_conn()
    df_relations = pd.read_sql(f"""
        SELECT * FROM {SCHEMA}.aux_key_relations
        WHERE sy_yield_bearing_mint = '{ONYC_BASE_MINT}' OR meta_base_symbol = 'ONyc'
        ORDER BY is_active DESC, maturity_date
    """, _conn)
    _conn.close()
    df_relations
    return (df_relations,)


@app.cell
def _(df_relations):
    if not df_relations.empty:
        _r = df_relations.iloc[0]
        VAULT_ADDR = str(_r["vault_address"])
        MARKET_ADDR = str(_r["market_address"])
        MINT_SY = str(_r["mint_sy"])
        MINT_PT = str(_r["mint_pt"])
        MINT_YT = str(_r["mint_yt"])
        SY_META_ADDR = str(_r.get("sy_meta_address", ""))
        META_PT_NAME = str(_r.get("meta_pt_name", "PT-ONyc"))
        ENV_DECIMALS = int(_r.get("env_sy_decimals") or 9)
        MATURITY_TS = int(_r.get("maturity_ts") or 0)
    else:
        VAULT_ADDR = MARKET_ADDR = MINT_SY = MINT_PT = MINT_YT = SY_META_ADDR = ""
        META_PT_NAME = "PT-ONyc"
        ENV_DECIMALS = 9
        MATURITY_TS = 0
    return ENV_DECIMALS, MARKET_ADDR, MATURITY_TS, META_PT_NAME, MINT_PT, MINT_SY, MINT_YT, SY_META_ADDR, VAULT_ADDR


# ---- DATA FETCHES ----

@app.cell
def _(LB_DELTA, SCHEMA, VAULT_ADDR, datetime, get_conn, pd, refresh_btn, timezone):
    refresh_btn
    _since = datetime.now(timezone.utc) - LB_DELTA
    _conn = get_conn()
    df_vault = pd.read_sql(f"SELECT * FROM {SCHEMA}.src_vaults WHERE vault_address = '{VAULT_ADDR}' AND block_time >= '{_since.isoformat()}' ORDER BY block_time DESC", _conn)
    _conn.close()
    return (df_vault,)


@app.cell
def _(LB_DELTA, MARKET_ADDR, SCHEMA, datetime, get_conn, pd, refresh_btn, timezone):
    refresh_btn
    _since = datetime.now(timezone.utc) - LB_DELTA
    _conn = get_conn()
    df_market = pd.read_sql(f"SELECT * FROM {SCHEMA}.src_market_twos WHERE market_address = '{MARKET_ADDR}' AND block_time >= '{_since.isoformat()}' ORDER BY block_time DESC", _conn)
    _conn.close()
    return (df_market,)


@app.cell
def _(LB_DELTA, MINT_SY, SCHEMA, datetime, get_conn, pd, refresh_btn, timezone):
    refresh_btn
    _since = datetime.now(timezone.utc) - LB_DELTA
    _conn = get_conn()
    df_sy_meta = pd.read_sql(f"SELECT * FROM {SCHEMA}.src_sy_meta_account WHERE mint_sy = '{MINT_SY}' AND time >= '{_since.isoformat()}' ORDER BY time DESC", _conn)
    _conn.close()
    return (df_sy_meta,)


@app.cell
def _(LB_DELTA, MINT_SY, SCHEMA, datetime, get_conn, pd, refresh_btn, timezone):
    refresh_btn
    _since = datetime.now(timezone.utc) - LB_DELTA
    _conn = get_conn()
    df_sy_supply = pd.read_sql(f"SELECT * FROM {SCHEMA}.src_sy_token_account WHERE mint_sy = '{MINT_SY}' AND time >= '{_since.isoformat()}' ORDER BY time DESC", _conn)
    _conn.close()
    return (df_sy_supply,)


@app.cell
def _(LB_DELTA, MARKET_ADDR, SCHEMA, VAULT_ADDR, datetime, get_conn, pd, refresh_btn, timezone):
    refresh_btn
    _since = datetime.now(timezone.utc) - LB_DELTA
    _conn = get_conn()
    df_events = pd.read_sql(f"SELECT * FROM {SCHEMA}.src_tx_events WHERE (vault_address = '{VAULT_ADDR}' OR market_address = '{MARKET_ADDR}') AND meta_block_time >= '{_since.isoformat()}' ORDER BY meta_block_time DESC LIMIT 500", _conn)
    _conn.close()
    return (df_events,)


# ---- HELPER: Dark plotly layout ----
@app.cell
def _():
    DARK_LAYOUT = dict(
        template="plotly_dark",
        paper_bgcolor="#0d1117",
        plot_bgcolor="#0d1117",
        margin=dict(l=60, r=30, t=30, b=40),
    )
    return (DARK_LAYOUT,)


# ===================================================================
# KPI SECTION
# ===================================================================

@app.cell
def _(ENV_DECIMALS, MATURITY_TS, datetime, df_market, df_sy_meta, df_vault, mo, timezone):
    _kpis = {}
    if not df_vault.empty:
        _v = df_vault.iloc[0]
        _kpis["Collateral Ratio"] = f"{float(_v.get('c_collateralization_ratio') or 0):.4f}"
        _kpis["PT Supply"] = f"{float(_v['pt_supply']) / 10**ENV_DECIMALS:,.2f}"
        _kpis["SY in Escrow"] = f"{float(_v['total_sy_in_escrow']) / 10**ENV_DECIMALS:,.2f}"
        _kpis["Utilization"] = f"{float(_v.get('c_utilization_ratio') or 0)*100:.1f}%"
        _kpis["Yield Index Health"] = f"{float(_v.get('c_yield_index_health') or 0):.6f}"
        _kpis["SY Xrate (vault)"] = f"{float(_v['last_seen_sy_exchange_rate']):.6f}"
    if not df_market.empty:
        _m = df_market.iloc[0]
        _kpis["Implied APY"] = f"{float(_m.get('c_implied_apy') or 0)*100:.2f}%"
        _kpis["PT Price"] = f"{float(_m.get('c_implied_pt_price') or 0):.6f}"
        _kpis["YT Price"] = f"{float(_m.get('c_implied_yt_price') or 0):.6f}"
        _kpis["PT in Pool"] = f"{float(_m['pt_balance']) / 10**ENV_DECIMALS:,.0f}"
        _kpis["SY in Pool"] = f"{float(_m['sy_balance']) / 10**ENV_DECIMALS:,.0f}"
        _kpis["Depth (SY)"] = f"{float(_m.get('c_total_market_depth_in_sy') or 0) / 10**ENV_DECIMALS:,.0f}"
        _kpis["Days to Mat."] = f"{float(_m.get('c_time_to_expiry_days') or 0):.1f}"
    if not df_sy_meta.empty:
        _kpis["SY Xrate"] = f"{float(df_sy_meta.iloc[0]['sy_exchange_rate']):.6f}"
        _kpis["Interface"] = str(df_sy_meta.iloc[0].get("interface_type", ""))
    if MATURITY_TS > 0:
        _mat_dt = datetime.fromtimestamp(MATURITY_TS, tz=timezone.utc)
        _kpis["Maturity"] = _mat_dt.strftime("%d %b %Y")
        _kpis["Days Left"] = f"{((_mat_dt - datetime.now(timezone.utc)).total_seconds()) / 86400:.1f}"

    _cards = [mo.md(f"**{k}**\n\n`{v}`") for k, v in _kpis.items()]
    mo.vstack([mo.md("---\n## Key Metrics"), mo.hstack(_cards, wrap=True, gap=1)])
    return


# ===================================================================
# MATURITY PROGRESS
# ===================================================================

@app.cell
def _(MATURITY_TS, META_PT_NAME, datetime, df_vault, go, mo, timezone, DARK_LAYOUT):
    _fig = go.Figure()
    if not df_vault.empty and MATURITY_TS > 0:
        _start = int(df_vault.iloc[0]["start_ts"])
        _now = datetime.now(timezone.utc).timestamp()
        _total = MATURITY_TS - _start
        _pct = (min(_now - _start, _total) / _total) * 100 if _total > 0 else 0
        _fig.add_trace(go.Bar(x=[_pct], y=[META_PT_NAME], orientation="h", marker_color="#3b82f6", text=[f"{_pct:.1f}%"], textposition="inside"))
        _fig.add_trace(go.Bar(x=[100 - _pct], y=[META_PT_NAME], orientation="h", marker_color="#1e293b", hoverinfo="skip"))
    _fig.update_layout(**DARK_LAYOUT, barmode="stack", height=100, showlegend=False, xaxis=dict(range=[0, 100], showticklabels=False), yaxis=dict(autorange="reversed"), margin=dict(l=120, r=30, t=10, b=10))
    mo.vstack([mo.md("## Maturity Progress"), _fig])
    return


# ===================================================================
# SY Exchange Rate
# ===================================================================

@app.cell
def _(DARK_LAYOUT, df_sy_meta, go, mo):
    _fig = go.Figure()
    if not df_sy_meta.empty:
        _df = df_sy_meta.sort_values("time")
        _fig.add_trace(go.Scatter(x=_df["time"], y=_df["sy_exchange_rate"].astype(float), mode="lines", name="SY Exchange Rate", line=dict(color="#3b82f6", width=2)))
    _fig.update_layout(**DARK_LAYOUT, height=350, yaxis_title="Exchange Rate", xaxis_title="Time")
    mo.vstack([mo.md("---\n## SY Exchange Rate Over Time"), _fig])
    return


# ===================================================================
# Implied APY
# ===================================================================

@app.cell
def _(DARK_LAYOUT, df_market, go, mo):
    _fig = go.Figure()
    if not df_market.empty:
        _df = df_market.sort_values("block_time")
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["c_implied_apy"].astype(float) * 100, mode="lines", name="Implied APY %", line=dict(color="#22c55e", width=2), fill="tozeroy", fillcolor="rgba(34,197,94,0.15)"))
    _fig.update_layout(**DARK_LAYOUT, height=350, yaxis_title="APY %", xaxis_title="Time")
    mo.vstack([mo.md("## Implied APY (Fixed Yield)"), _fig])
    return


# ===================================================================
# PT / SY Pool Balances
# ===================================================================

@app.cell
def _(DARK_LAYOUT, ENV_DECIMALS, df_market, go, make_subplots, mo):
    _fig = make_subplots(rows=1, cols=1, specs=[[{"secondary_y": True}]])
    if not df_market.empty:
        _df = df_market.sort_values("block_time")
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["pt_balance"].astype(float) / 10**ENV_DECIMALS, mode="lines", name="PT Balance", line=dict(color="#f97316", width=2)), secondary_y=False)
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["sy_balance"].astype(float) / 10**ENV_DECIMALS, mode="lines", name="SY Balance", line=dict(color="#3b82f6", width=2)), secondary_y=True)
    _fig.update_layout(**DARK_LAYOUT, height=350, legend=dict(orientation="h", y=1.1), margin=dict(l=60, r=60, t=30, b=40))
    _fig.update_yaxes(title_text="PT Balance", secondary_y=False)
    _fig.update_yaxes(title_text="SY Balance", secondary_y=True)
    mo.vstack([mo.md("## Market Vault — PT & SY Balances"), _fig])
    return


# ===================================================================
# PT Price & Reserve Ratio
# ===================================================================

@app.cell
def _(DARK_LAYOUT, df_market, go, make_subplots, mo):
    _fig = make_subplots(rows=1, cols=1, specs=[[{"secondary_y": True}]])
    if not df_market.empty:
        _df = df_market.sort_values("block_time")
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["c_implied_pt_price"].astype(float), mode="lines", name="PT Price (SY)", line=dict(color="#a855f7", width=2)), secondary_y=False)
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["c_reserve_ratio"].astype(float), mode="lines", name="Reserve Ratio", line=dict(color="#eab308", width=1, dash="dot")), secondary_y=True)
    _fig.update_layout(**DARK_LAYOUT, height=350, legend=dict(orientation="h", y=1.1), margin=dict(l=60, r=60, t=30, b=40))
    _fig.update_yaxes(title_text="PT Price (SY)", secondary_y=False)
    _fig.update_yaxes(title_text="Reserve Ratio", secondary_y=True)
    mo.vstack([mo.md("## PT Price & Reserve Ratio"), _fig])
    return


# ===================================================================
# Vault Collateral & PT Supply
# ===================================================================

@app.cell
def _(DARK_LAYOUT, ENV_DECIMALS, df_vault, go, make_subplots, mo):
    _fig = make_subplots(rows=1, cols=1, specs=[[{"secondary_y": True}]])
    if not df_vault.empty:
        _df = df_vault.sort_values("block_time")
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["total_sy_in_escrow"].astype(float) / 10**ENV_DECIMALS, mode="lines", name="SY in Escrow", line=dict(color="#3b82f6", width=2), fill="tozeroy", fillcolor="rgba(59,130,246,0.1)"), secondary_y=False)
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["sy_for_pt"].astype(float) / 10**ENV_DECIMALS, mode="lines", name="SY for PT", line=dict(color="#22c55e", width=1, dash="dash")), secondary_y=False)
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["pt_supply"].astype(float) / 10**ENV_DECIMALS, mode="lines", name="PT Supply", line=dict(color="#f97316", width=2)), secondary_y=True)
    _fig.update_layout(**DARK_LAYOUT, height=350, legend=dict(orientation="h", y=1.1), margin=dict(l=60, r=60, t=30, b=40))
    _fig.update_yaxes(title_text="SY Amount", secondary_y=False)
    _fig.update_yaxes(title_text="PT Supply", secondary_y=True)
    mo.vstack([mo.md("## Vault Collateral & PT Supply"), _fig])
    return


# ===================================================================
# Collateralization Ratio
# ===================================================================

@app.cell
def _(DARK_LAYOUT, df_vault, go, mo):
    _fig = go.Figure()
    if not df_vault.empty:
        _df = df_vault.sort_values("block_time")
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["c_collateralization_ratio"].astype(float), mode="lines", name="Collateral Ratio", line=dict(color="#22c55e", width=2)))
        _fig.add_hline(y=1.0, line_dash="dash", line_color="#ef4444", annotation_text="1.0 (parity)", annotation_font_color="#ef4444")
    _fig.update_layout(**DARK_LAYOUT, height=300, yaxis_title="Ratio", xaxis_title="Time")
    mo.vstack([mo.md("## Collateralization Ratio"), _fig])
    return


# ===================================================================
# Transaction Events
# ===================================================================

@app.cell
def _(df_events, go, mo, DARK_LAYOUT):
    _items = [mo.md("---\n## Transaction Events")]
    if not df_events.empty:
        _cats = df_events["event_category"].value_counts()
        _fig = go.Figure()
        _fig.add_trace(go.Bar(x=_cats.index.tolist(), y=_cats.values.tolist(), marker_color="#3b82f6"))
        _fig.update_layout(**DARK_LAYOUT, height=300, yaxis_title="Count", xaxis_title="Event Category")
        _items.append(_fig)
    else:
        _items.append(mo.md("*No events in lookback window.*"))
    mo.vstack(_items)
    return


# ===================================================================
# Event Timeline
# ===================================================================

@app.cell
def _(DARK_LAYOUT, df_events, go, mo):
    _items = [mo.md("### Event Timeline")]
    if not df_events.empty and "meta_block_time" in df_events.columns:
        _df = df_events.sort_values("meta_block_time")
        _types = _df["event_type"].dropna().unique()
        _colors = ["#3b82f6", "#22c55e", "#f97316", "#a855f7", "#ef4444", "#eab308", "#06b6d4", "#ec4899", "#84cc16", "#f43f5e"]
        _fig = go.Figure()
        for _i, _et in enumerate(_types):
            _sub = _df[_df["event_type"] == _et]
            _fig.add_trace(go.Scatter(x=_sub["meta_block_time"], y=[_et] * len(_sub), mode="markers", name=_et, marker=dict(color=_colors[_i % len(_colors)], size=8), hovertemplate="%{x}<br>%{text}<extra></extra>", text=_sub["signature"].str[:12] + "..."))
        _fig.update_layout(**DARK_LAYOUT, height=max(250, len(_types) * 35), showlegend=False, xaxis_title="Time", margin=dict(l=200, r=30, t=30, b=40))
        _items.append(_fig)
    else:
        _items.append(mo.md("*No event data.*"))
    mo.vstack(_items)
    return


# ===================================================================
# PT Trades
# ===================================================================

@app.cell
def _(DARK_LAYOUT, ENV_DECIMALS, df_events, go, mo, np):
    _items = [mo.md("### PT Trades — Price & Volume")]
    _pt_trades = df_events[df_events["event_type"].isin(["trade_pt", "market_two_trade_pt"])].copy() if not df_events.empty else None
    if _pt_trades is not None and not _pt_trades.empty:
        _df = _pt_trades.sort_values("meta_block_time")
        _pt_d = _df["amm_pt_vault_delta_from_transfers"].fillna(_df["amm_pt_vault_delta"]).fillna(0).astype(float).abs() / 10**ENV_DECIMALS
        _sy_d = _df["trader_sy_delta_from_transfers"].fillna(_df["trader_sy_delta"]).fillna(0).astype(float).abs() / 10**ENV_DECIMALS
        _prices = np.where(_pt_d > 0, _sy_d / _pt_d, np.nan)
        _fig = go.Figure()
        _fig.add_trace(go.Scatter(x=_df["meta_block_time"], y=_prices, mode="markers", marker=dict(size=np.clip(_pt_d * 2, 4, 30), color="#a855f7", opacity=0.7), name="Trade Price", hovertemplate="Price: %{y:.4f}<br>Size: %{text:,.2f}<extra></extra>", text=_pt_d))
        _fig.update_layout(**DARK_LAYOUT, height=350, yaxis_title="PT Price (SY)", xaxis_title="Time")
        _items.append(_fig)
    else:
        _items.append(mo.md("*No PT trades.*"))
    mo.vstack(_items)
    return


# ===================================================================
# Strip / Merge Flows
# ===================================================================

@app.cell
def _(DARK_LAYOUT, ENV_DECIMALS, df_events, go, mo):
    _items = [mo.md("### Strip & Merge Flows")]
    _flows = df_events[df_events["event_type"].isin(["strip", "merge"])].copy() if not df_events.empty else None
    if _flows is not None and not _flows.empty:
        _df = _flows.sort_values("meta_block_time")
        _fig = go.Figure()
        _strips = _df[_df["event_type"] == "strip"]
        _merges = _df[_df["event_type"] == "merge"]
        if not _strips.empty:
            _fig.add_trace(go.Bar(x=_strips["meta_block_time"], y=_strips["amount_vault_sy_in"].fillna(0).astype(float) / 10**ENV_DECIMALS, name="Strip (SY in)", marker_color="#22c55e"))
        if not _merges.empty:
            _fig.add_trace(go.Bar(x=_merges["meta_block_time"], y=-_merges["amount_vault_sy_out"].fillna(0).astype(float) / 10**ENV_DECIMALS, name="Merge (SY out)", marker_color="#ef4444"))
        _fig.update_layout(**DARK_LAYOUT, height=350, yaxis_title="SY Amount", xaxis_title="Time", barmode="relative", legend=dict(orientation="h", y=1.1))
        _items.append(_fig)
    else:
        _items.append(mo.md("*No strip/merge events.*"))
    mo.vstack(_items)
    return


# ===================================================================
# Recent Events Table
# ===================================================================

@app.cell
def _(df_events, mo):
    _items = [mo.md("### Recent Events")]
    if not df_events.empty:
        _cols = ["meta_block_time", "event_type", "event_category", "instruction_name", "user_address", "signature"]
        _dc = [c for c in _cols if c in df_events.columns]
        _tbl = df_events[_dc].head(50).copy()
        if "signature" in _tbl.columns:
            _tbl["signature"] = _tbl["signature"].str[:16] + "..."
        if "user_address" in _tbl.columns:
            _tbl["user_address"] = _tbl["user_address"].fillna("").str[:16] + "..."
        _items.append(mo.ui.table(_tbl, selection=None))
    else:
        _items.append(mo.md("*No events.*"))
    mo.vstack(_items)
    return


# ===================================================================
# SY Token Supply
# ===================================================================

@app.cell
def _(DARK_LAYOUT, ENV_DECIMALS, df_sy_supply, go, mo):
    _fig = go.Figure()
    if not df_sy_supply.empty:
        _df = df_sy_supply.sort_values("time")
        _fig.add_trace(go.Scatter(x=_df["time"], y=_df["supply"].astype(float) / 10**ENV_DECIMALS, mode="lines", name="SY Supply", line=dict(color="#06b6d4", width=2), fill="tozeroy", fillcolor="rgba(6,182,212,0.1)"))
    _fig.update_layout(**DARK_LAYOUT, height=300, yaxis_title="SY Supply", xaxis_title="Time")
    mo.vstack([mo.md("---\n## SY Token Supply"), _fig])
    return


# ===================================================================
# Market Depth
# ===================================================================

@app.cell
def _(DARK_LAYOUT, ENV_DECIMALS, df_market, go, mo):
    _fig = go.Figure()
    if not df_market.empty and "c_total_market_depth_in_sy" in df_market.columns:
        _df = df_market.sort_values("block_time")
        _fig.add_trace(go.Scatter(x=_df["block_time"], y=_df["c_total_market_depth_in_sy"].astype(float) / 10**ENV_DECIMALS, mode="lines", name="Depth", line=dict(color="#eab308", width=2), fill="tozeroy", fillcolor="rgba(234,179,8,0.1)"))
    _fig.update_layout(**DARK_LAYOUT, height=300, yaxis_title="Depth (SY)", xaxis_title="Time")
    mo.vstack([mo.md("## Market Depth (Total in SY)"), _fig])
    return


if __name__ == "__main__":
    app.run()

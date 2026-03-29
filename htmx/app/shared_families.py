from __future__ import annotations

from typing import Dict, Set, Tuple


# Shared backend loader family hints keyed by (api_page_id, source_widget_id).
# These are used by UI scheduling/runtime to keep shared-data widget families
# in sync and by tooling to build reusable mapping groups.
SHARED_DATA_FAMILY_HINTS: Dict[Tuple[str, str], str] = {
    # Dex liquidity
    ("playbook-liquidity", "liquidity-distribution"): "dex_liquidity_tick_dist",
    ("playbook-liquidity", "liquidity-depth"): "dex_liquidity_tick_dist",
    ("playbook-liquidity", "liquidity-change-heatmap"): "dex_liquidity_tick_dist",
    ("playbook-liquidity", "kpi-tvl"): "dex_liquidity_last_row",
    ("playbook-liquidity", "kpi-impact-500k"): "dex_liquidity_last_row",
    ("playbook-liquidity", "kpi-reserves"): "dex_liquidity_last_row",
    ("playbook-liquidity", "kpi-largest-impact"): "dex_liquidity_last_row",
    ("playbook-liquidity", "kpi-pool-balance"): "dex_liquidity_last_row",
    ("playbook-liquidity", "kpi-average-impact"): "dex_liquidity_last_row",
    ("playbook-liquidity", "usdc-pool-share-concentration"): "dex_liquidity_timeseries",
    ("playbook-liquidity", "trade-impact-toggle"): "dex_liquidity_timeseries",
    ("playbook-liquidity", "usdc-lp-flows"): "dex_liquidity_timeseries",
    ("playbook-liquidity", "impact-from-trade-size"): "dex_liquidity_timeseries",
    # Dex swaps
    ("dex-swaps", "kpi-swap-volume-24h"): "dex_swaps_last_row",
    ("dex-swaps", "kpi-swap-count-24h"): "dex_swaps_last_row",
    ("dex-swaps", "kpi-price-min-max"): "dex_swaps_last_row",
    ("dex-swaps", "kpi-vwap-buy-sell"): "dex_swaps_last_row",
    ("dex-swaps", "kpi-price-std-dev"): "dex_swaps_last_row",
    ("dex-swaps", "kpi-vwap-spread"): "dex_swaps_last_row",
    ("dex-swaps", "kpi-largest-usx-sell"): "dex_swaps_last_row",
    ("dex-swaps", "kpi-largest-usx-buy"): "dex_swaps_last_row",
    ("dex-swaps", "kpi-max-1h-sell-pressure"): "dex_swaps_last_row",
    ("dex-swaps", "kpi-max-1h-buy-pressure"): "dex_swaps_last_row",
    ("dex-swaps", "swaps-flows-toggle"): "dex_swaps_timeseries",
    ("dex-swaps", "swaps-price-impacts"): "dex_swaps_timeseries",
    ("dex-swaps", "swaps-spread-volatility"): "dex_swaps_timeseries",
    ("dex-swaps", "swaps-directional-vwap-spread"): "dex_swaps_timeseries",
    # Global ecosystem
    ("global-ecosystem", "ge-availability-time"): "global_timeseries",
    ("global-ecosystem", "ge-tvl-time"): "global_timeseries",
    ("global-ecosystem", "ge-yields-vs-time"): "global_timeseries",
    ("global-ecosystem", "ge-tvl-share"): "global_timeseries",
    ("global-ecosystem", "ge-activity-vol"): "global_timeseries",
    ("global-ecosystem", "ge-activity-share"): "global_timeseries",
    ("global-ecosystem", "ge-activity-vol-usx"): "global_timeseries",
    ("global-ecosystem", "ge-activity-vol-eusx"): "global_timeseries",
    ("global-ecosystem", "ge-tvl-share-usx"): "global_timeseries",
    ("global-ecosystem", "ge-tvl-share-eusx"): "global_timeseries",
    ("global-ecosystem", "ge-activity-bar"): "global_interval_row",
    ("global-ecosystem", "ge-activity-pct"): "global_interval_row",
    ("global-ecosystem", "ge-issuance-bar"): "global_issuance_snapshot",
    ("global-ecosystem", "ge-issuance-pie"): "global_issuance_snapshot",
    ("global-ecosystem", "ge-tvl-bar"): "global_v_last",
    ("global-ecosystem", "ge-tvl-pie"): "global_v_last",
    ("global-ecosystem", "ge-current-yields"): "global_v_last",
    ("global-ecosystem", "ge-availability-bar"): "global_v_last",
    # Exponent
    ("exponent", "exponent-pie-tvl"): "exponent_v_last",
    ("exponent", "exponent-timeline"): "exponent_v_last",
    ("exponent", "kpi-base-token-yield"): "exponent_v_last",
    ("exponent", "kpi-locked-base-tokens"): "exponent_v_last",
    ("exponent", "kpi-current-fixed-yield"): "exponent_v_last",
    ("exponent", "kpi-sy-base-collateral"): "exponent_v_last",
    ("exponent", "kpi-fixed-variable-spread"): "exponent_v_last",
    ("exponent", "kpi-sy-coll-ratio"): "exponent_v_last",
    ("exponent", "kpi-yt-staked-share"): "exponent_v_last",
    ("exponent", "kpi-amm-depth"): "exponent_v_last",
    ("exponent", "kpi-pt-base-price"): "exponent_v_last",
    ("exponent", "kpi-apy-impact-pt-trade"): "exponent_v_last",
    ("exponent", "kpi-pt-vol-24h"): "exponent_v_last",
    ("exponent", "kpi-amm-deployment-ratio"): "exponent_v_last",
    ("exponent", "exponent-market-info-mkt1"): "exponent_v_last",
    ("exponent", "exponent-market-info-mkt2"): "exponent_v_last",
    ("exponent", "exponent-pt-swap-flows-mkt1"): "exponent_timeseries_mkt1",
    ("exponent", "exponent-token-strip-flows-mkt1"): "exponent_timeseries_mkt1",
    ("exponent", "exponent-vault-sy-balance-mkt1"): "exponent_timeseries_mkt1",
    ("exponent", "exponent-yt-staked-mkt1"): "exponent_timeseries_mkt1",
    ("exponent", "exponent-yield-trading-liq-mkt1"): "exponent_timeseries_mkt1",
    ("exponent", "exponent-realized-rates-mkt1"): "exponent_timeseries_mkt1",
    ("exponent", "exponent-divergence-mkt1"): "exponent_timeseries_mkt1",
    ("exponent", "exponent-pt-swap-flows-mkt2"): "exponent_timeseries_mkt2",
    ("exponent", "exponent-token-strip-flows-mkt2"): "exponent_timeseries_mkt2",
    ("exponent", "exponent-vault-sy-balance-mkt2"): "exponent_timeseries_mkt2",
    ("exponent", "exponent-yt-staked-mkt2"): "exponent_timeseries_mkt2",
    ("exponent", "exponent-yield-trading-liq-mkt2"): "exponent_timeseries_mkt2",
    ("exponent", "exponent-realized-rates-mkt2"): "exponent_timeseries_mkt2",
    ("exponent", "exponent-divergence-mkt2"): "exponent_timeseries_mkt2",
    # Kamino
    ("kamino", "kamino-utilization-timeseries"): "kamino_timeseries",
    ("kamino", "kamino-ltv-hf-timeseries"): "kamino_timeseries",
    ("kamino", "kamino-liability-flows"): "kamino_timeseries",
    ("kamino", "kamino-liquidations"): "kamino_timeseries",
    ("kamino", "kamino-stress-debt"): "kamino_sensitivity",
    ("kamino", "kamino-sensitivity-table"): "kamino_sensitivity",
    # Health
    ("health", "health-queue-chart"): "health_queue_chart",
    ("health", "health-queue-chart-2"): "health_queue_chart",
    ("health", "health-base-chart-events"): "health_base_chart",
    ("health", "health-base-chart-accounts"): "health_base_chart",
    # Risk analysis
    ("risk-analysis", "ra-liq-dist-ray"): "risk_liq_curves_ray",
    ("risk-analysis", "ra-liq-depth-ray"): "risk_liq_curves_ray",
    ("risk-analysis", "ra-prob-ray"): "risk_liq_curves_ray",
    ("risk-analysis", "ra-liq-dist-orca"): "risk_liq_curves_orca",
    ("risk-analysis", "ra-liq-depth-orca"): "risk_liq_curves_orca",
    ("risk-analysis", "ra-prob-orca"): "risk_liq_curves_orca",
    ("risk-analysis", "ra-xp-dist-ray"): "risk_xp_curves_ray",
    ("risk-analysis", "ra-xp-depth-ray"): "risk_xp_curves_ray",
    ("risk-analysis", "ra-xp-dist-orca"): "risk_xp_curves_orca",
    ("risk-analysis", "ra-xp-depth-orca"): "risk_xp_curves_orca",
    ("risk-analysis", "ra-stress-test"): "risk_stress_sensitivity",
    ("risk-analysis", "ra-sensitivity-table"): "risk_stress_sensitivity",
}

# Endpoints intentionally left without a shared-family hint.
# Use this to make "no family" an explicit decision rather than an omission.
# Intentionally empty until an audited allowlist is reviewed and approved.
# Keep this explicit to avoid silently bypassing intent verification.
EXPLICIT_NO_SHARED_FAMILY_HINTS: Set[Tuple[str, str]] = set()


def resolve_shared_data_family(api_page_id: str, source_widget_id: str) -> str:
    return SHARED_DATA_FAMILY_HINTS.get((str(api_page_id), str(source_widget_id)), "")


def has_intentional_shared_family_mapping(api_page_id: str, source_widget_id: str) -> bool:
    key = (str(api_page_id), str(source_widget_id))
    return key in SHARED_DATA_FAMILY_HINTS or key in EXPLICIT_NO_SHARED_FAMILY_HINTS


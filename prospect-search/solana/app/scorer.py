"""
Lightweight interestingness heuristic.

Adds a 0-100 ``interest_score`` column and a ``shortlist_tier`` column
to the aggregated DataFrame.

interest_score is a screening signal ("worth further research"), not a
commercial quality judgment.

shortlist_tier provides coarse bucketing because the score compresses
heavily in the tail — the top cohort separates cleanly, but the bottom
thousands cluster together.  The tier is more actionable than the raw
score for downstream routing.
"""

import math

import pandas as pd

import config


def score(df: pd.DataFrame) -> pd.DataFrame:
    if df.empty:
        return df

    out = df.copy()

    # --- Economic significance (log-scaled TVL) ---
    max_log = math.log10(max(out["total_tvl_usd"].max(), 1))
    out["_econ"] = out["total_tvl_usd"].apply(
        lambda v: math.log10(max(v, 1)) / max_log if max_log > 0 else 0
    )

    # --- Cross-venue breadth ---
    out["_breadth"] = (
        out["protocol_count"] / 5  # 5 protocols total
        + out["venue_type_count"] / 3  # 3 venue types total
    ) / 2  # average of the two ratios, each in [0, 1]

    # --- Structural complexity ---
    cap = config.POOL_COUNT_CAP
    out["_complex"] = out["total_pool_count"].clip(upper=cap) / cap

    # --- Risk relevance ---
    out["_risk"] = (
        out.get("has_kamino", pd.Series(False, index=out.index)).astype(float) * 0.5
        + out.get("has_exponent", pd.Series(False, index=out.index)).astype(float) * 0.5
    )

    # --- Composite ---
    out["interest_score"] = (
        config.SCORE_WEIGHT_ECONOMIC * out["_econ"]
        + config.SCORE_WEIGHT_BREADTH * out["_breadth"]
        + config.SCORE_WEIGHT_COMPLEXITY * out["_complex"]
        + config.SCORE_WEIGHT_RISK * out["_risk"]
    ) * 100

    out.drop(columns=["_econ", "_breadth", "_complex", "_risk"], inplace=True)
    out["interest_score"] = out["interest_score"].round(2)

    # --- Shortlist tier ---
    out["shortlist_tier"] = out.apply(_assign_tier, axis=1)

    return out


def _assign_tier(row: pd.Series) -> str:
    """
    Assign a coarse shortlist tier based on structural signals.

    tier_1 — Multi-ecosystem tokens with genuine cross-domain DeFi
             footprints and meaningful TVL.  The "definitely research
             further" list.  (~20-30 tokens typically.)

    tier_2 — Credible candidates: multi-protocol presence, or
             significant single-protocol TVL with a resolved symbol.
             Worth investigating with more data.  (~100-200 tokens.)

    tail   — Long-tail single-protocol small tokens.  Kept for
             completeness but unlikely to be immediate prospects.
    """
    proto = row.get("protocol_count", 0)
    venues = row.get("venue_type_count", 0)
    tvl = row.get("total_tvl_usd", 0)
    has_symbol = bool(row.get("token_symbol"))

    if proto >= 3 and venues >= 2 and tvl >= 1_000_000:
        return "tier_1"

    if proto >= 2:
        return "tier_2"
    if tvl >= 500_000 and has_symbol:
        return "tier_2"

    return "tail"

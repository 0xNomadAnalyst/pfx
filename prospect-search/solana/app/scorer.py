"""
Lightweight interestingness heuristic.

Adds a 0-100 ``interest_score`` column to the aggregated DataFrame.
This is a screening signal ("worth further research"), not a commercial
quality judgment.
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

    return out

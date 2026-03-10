-- mat_xp_last: Cross-protocol snapshot of the latest ONyc ecosystem state
-- Singleton row providing TVL distribution, yield comparison, and DEX price.
-- Eliminates the per-request multi-schema DISTINCT ON scans from the original
-- v_prop_last pattern.

CREATE SCHEMA IF NOT EXISTS cross_protocol;

CREATE TABLE IF NOT EXISTS cross_protocol.mat_xp_last (
    id                          INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),

    -- ONyc TVL by protocol (decimal-adjusted ONyc)
    onyc_in_dexes               NUMERIC     DEFAULT 0,
    onyc_in_kamino              NUMERIC     DEFAULT 0,
    onyc_in_exponent            NUMERIC     DEFAULT 0,
    onyc_tracked_total          NUMERIC     DEFAULT 0,

    -- TVL percentages
    onyc_in_dexes_pct           NUMERIC     DEFAULT 0,
    onyc_in_kamino_pct          NUMERIC     DEFAULT 0,
    onyc_in_exponent_pct        NUMERIC     DEFAULT 0,

    -- Current yields
    kam_onyc_supply_apy         NUMERIC,
    kam_onyc_borrow_apy         NUMERIC,
    kam_onyc_utilization        NUMERIC,
    exp_weighted_implied_apy    NUMERIC,

    -- DEX aggregate price (last observed, ONyc per stablecoin)
    dex_avg_price_t1_per_t0     NUMERIC,

    -- Kamino market-level risk summary
    kam_total_collateral_value  NUMERIC,
    kam_total_borrow_value      NUMERIC,
    kam_weighted_avg_ltv        NUMERIC,

    refreshed_at                TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Refresh procedure: full recompute from domain mat-last tables + live CAGGs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE cross_protocol.refresh_mat_xp_last()
LANGUAGE plpgsql AS $$
DECLARE
    v_onyc_mint TEXT := '5Y8NV33Vv7WbnLfq3zBcKSdYPrk7g2KoiQoe7M2tcxp5';

    v_dex_tvl     NUMERIC := 0;
    v_kam_tvl     NUMERIC := 0;
    v_exp_tvl     NUMERIC := 0;
    v_total       NUMERIC := 0;

    v_kam_supply_apy  NUMERIC;
    v_kam_borrow_apy  NUMERIC;
    v_kam_util        NUMERIC;
    v_exp_apy         NUMERIC;
    v_dex_price       NUMERIC;

    v_kam_coll_val    NUMERIC;
    v_kam_borr_val    NUMERIC;
    v_kam_avg_ltv     NUMERIC;
BEGIN
    -- ── DEX: ONyc reserves from mat_dex_last ──
    SELECT COALESCE(SUM(
        CASE
            WHEN ptr.token0_address = v_onyc_mint THEN COALESCE(dl.t0_reserve, 0)
            WHEN ptr.token1_address = v_onyc_mint THEN COALESCE(dl.t1_reserve, 0)
            ELSE 0
        END
    ), 0)
    INTO v_dex_tvl
    FROM dexes.mat_dex_last dl
    JOIN dexes.pool_tokens_reference ptr ON dl.pool_address = ptr.pool_address
    WHERE ptr.token0_address = v_onyc_mint OR ptr.token1_address = v_onyc_mint;

    -- DEX price (average across pools)
    SELECT AVG(dl.price_t1_per_t0)
    INTO v_dex_price
    FROM dexes.mat_dex_last dl
    WHERE dl.price_t1_per_t0 IS NOT NULL
      AND dl.price_t1_per_t0 > 0;

    -- ── KAMINO: ONyc reserve TVL + yield from mat_klend_last_reserves ──
    SELECT
        COALESCE(SUM(lr.collateral_total_supply), 0),
        MAX(lr.supply_apy),
        MAX(lr.borrow_apy),
        MAX(lr.utilization_ratio)
    INTO v_kam_tvl, v_kam_supply_apy, v_kam_borrow_apy, v_kam_util
    FROM kamino_lend.mat_klend_last_reserves lr
    JOIN kamino_lend.aux_market_reserve_tokens art
        ON lr.reserve_address = art.reserve_address
    WHERE art.token_mint = v_onyc_mint;

    -- Kamino market risk summary from mat_klend_last_obligations
    SELECT
        lo.total_collateral_value,
        lo.total_borrow_value,
        lo.weighted_avg_loan_to_value_sig
    INTO v_kam_coll_val, v_kam_borr_val, v_kam_avg_ltv
    FROM kamino_lend.mat_klend_last_obligations lo
    LIMIT 1;

    -- ── EXPONENT: ONyc in base token escrow ──
    SELECT COALESCE(SUM(c_balance_readable_last), 0)
    INTO v_exp_tvl
    FROM (
        SELECT DISTINCT ON (escrow_address)
            c_balance_readable_last
        FROM exponent.cagg_base_token_escrow_5s
        WHERE mint = v_onyc_mint
        ORDER BY escrow_address, bucket DESC
    ) sub;

    -- Exponent depth-weighted implied APY from mat_exp_last (active markets only)
    SELECT
        CASE
            WHEN SUM(COALESCE(pool_depth_in_sy, 0))
                    FILTER (WHERE NOT COALESCE(is_expired, FALSE)
                              AND c_market_implied_apy IS NOT NULL) > 0
            THEN SUM(c_market_implied_apy * COALESCE(pool_depth_in_sy, 0))
                    FILTER (WHERE NOT COALESCE(is_expired, FALSE)
                              AND c_market_implied_apy IS NOT NULL)
                 / SUM(COALESCE(pool_depth_in_sy, 0))
                    FILTER (WHERE NOT COALESCE(is_expired, FALSE)
                              AND c_market_implied_apy IS NOT NULL)
            ELSE NULL
        END
    INTO v_exp_apy
    FROM exponent.mat_exp_last;

    -- ── Compute totals ──
    v_total := v_dex_tvl + v_kam_tvl + v_exp_tvl;

    -- ── Upsert singleton row ──
    INSERT INTO cross_protocol.mat_xp_last (
        id,
        onyc_in_dexes, onyc_in_kamino, onyc_in_exponent, onyc_tracked_total,
        onyc_in_dexes_pct, onyc_in_kamino_pct, onyc_in_exponent_pct,
        kam_onyc_supply_apy, kam_onyc_borrow_apy, kam_onyc_utilization,
        exp_weighted_implied_apy,
        dex_avg_price_t1_per_t0,
        kam_total_collateral_value, kam_total_borrow_value, kam_weighted_avg_ltv,
        refreshed_at
    ) VALUES (
        1,
        v_dex_tvl, v_kam_tvl, v_exp_tvl, v_total,
        ROUND(COALESCE(v_dex_tvl / NULLIF(v_total, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(v_kam_tvl / NULLIF(v_total, 0) * 100, 0)::NUMERIC, 1),
        ROUND(COALESCE(v_exp_tvl / NULLIF(v_total, 0) * 100, 0)::NUMERIC, 1),
        v_kam_supply_apy, v_kam_borrow_apy, v_kam_util,
        v_exp_apy,
        v_dex_price,
        v_kam_coll_val, v_kam_borr_val, v_kam_avg_ltv,
        NOW()
    )
    ON CONFLICT (id) DO UPDATE SET
        onyc_in_dexes      = EXCLUDED.onyc_in_dexes,
        onyc_in_kamino     = EXCLUDED.onyc_in_kamino,
        onyc_in_exponent   = EXCLUDED.onyc_in_exponent,
        onyc_tracked_total = EXCLUDED.onyc_tracked_total,
        onyc_in_dexes_pct  = EXCLUDED.onyc_in_dexes_pct,
        onyc_in_kamino_pct = EXCLUDED.onyc_in_kamino_pct,
        onyc_in_exponent_pct = EXCLUDED.onyc_in_exponent_pct,
        kam_onyc_supply_apy = EXCLUDED.kam_onyc_supply_apy,
        kam_onyc_borrow_apy = EXCLUDED.kam_onyc_borrow_apy,
        kam_onyc_utilization = EXCLUDED.kam_onyc_utilization,
        exp_weighted_implied_apy = EXCLUDED.exp_weighted_implied_apy,
        dex_avg_price_t1_per_t0 = EXCLUDED.dex_avg_price_t1_per_t0,
        kam_total_collateral_value = EXCLUDED.kam_total_collateral_value,
        kam_total_borrow_value = EXCLUDED.kam_total_borrow_value,
        kam_weighted_avg_ltv = EXCLUDED.kam_weighted_avg_ltv,
        refreshed_at       = EXCLUDED.refreshed_at;
END;
$$;

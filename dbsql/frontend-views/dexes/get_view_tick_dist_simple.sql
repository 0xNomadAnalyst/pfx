-- =====================================================
-- Tick Distribution View Function (Simple)
-- =====================================================
-- Function: get_view_tick_dist_simple
-- Purpose: Return tick distribution data with minimal/deprecated-free inputs.
--
-- Notes:
-- - This simplified version removes deprecated frontend-oriented features.
-- - It no longer requires persisting React frontend dependency parameters.
-- - It is intended to be easier to consume in other dashboarding platforms.
-- - Current state is sourced from src_acct_tickarray_tokendist_latest.
-- - Historical src_acct_tickarray_tokendist is only used when p_delta_time is provided.
-- =====================================================

DROP FUNCTION IF EXISTS dexes.get_view_tick_dist_simple(TEXT, TEXT, INTERVAL);
CREATE OR REPLACE FUNCTION dexes.get_view_tick_dist_simple(
    p_protocol TEXT DEFAULT NULL,      -- Optional protocol filter; NULL = no protocol filter
    p_pair TEXT DEFAULT NULL,          -- Optional token-pair filter; NULL = no pair filter
    p_delta_time INTERVAL DEFAULT NULL, -- Optional lookback interval for delta calculations
    p_invert BOOLEAN DEFAULT FALSE     -- When TRUE, swap t0↔t1 perspective in output
)
RETURNS TABLE (
    pool_address TEXT,
    protocol TEXT,
    token_pair TEXT,
    block_time TIMESTAMPTZ,
    current_tick INTEGER,
    current_tick_float DOUBLE PRECISION,
    current_price_t1_per_t0 NUMERIC(20,6),
    current_price_t0_per_t1 NUMERIC(20,6),
    tick_lower INTEGER,
    tick_price_t1_per_t0 NUMERIC(20,6),
    tick_price_t0_per_t1 NUMERIC(20,6),
    tick_delta_to_peg INTEGER,
    tick_delta_to_peg_price_t1_per_t0_bps NUMERIC(20,6),
    tick_delta_to_peg_price_t0_per_t1_bps NUMERIC(20,6),
    tick_delta_to_current INTEGER,
    tick_delta_to_current_price_t1_per_t0_bps NUMERIC(20,6),
    tick_delta_to_current_price_t0_per_t1_bps NUMERIC(20,6),
    token0_value DOUBLE PRECISION,
    token1_value DOUBLE PRECISION,
    token0_cumul DOUBLE PRECISION,
    token1_cumul DOUBLE PRECISION,
    token0_value_delta DOUBLE PRECISION,
    token1_value_delta DOUBLE PRECISION,
    token0_cumul_pct_reserve NUMERIC(10,2),
    token1_cumul_pct_reserve NUMERIC(10,2),
    liquidity_period_delta_in_t1_units DOUBLE PRECISION,
    liquidity_period_delta_in_t1_units_pct NUMERIC(10,2),
    liquidity_period_delta_net_reallocation_in_t1_units DOUBLE PRECISION,
    liquidity_period_delta_in_t0_units DOUBLE PRECISION,
    liquidity_period_delta_in_t0_units_pct NUMERIC(10,2),
    liquidity_period_delta_net_reallocation_in_t0_units DOUBLE PRECISION
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_delta_time IS NULL THEN
        -- Fast path: latest-only mode (no historical table access).
        RETURN QUERY
        WITH params AS (
            SELECT NULLIF(TRIM(p_protocol), '') AS protocol_filter, NULLIF(TRIM(p_pair), '') AS pair_filter
        ),
        latest_query_per_pool AS (
            SELECT
                l.pool_address,
                MAX(l.query_id) AS query_id
            FROM src_acct_tickarray_tokendist_latest l
            GROUP BY l.pool_address
        ),
        current_meta AS (
            SELECT
                q.pool_address,
                q.query_id,
                q.protocol,
                q.token_pair,
                q.block_time,
                q.current_tick,
                q.sqrt_price_x64,
                q.price_fixed_point_base,
                q.mint_decimals_0,
                q.mint_decimals_1,
                ROUND(
                    (
                        LN(POWER(10::DOUBLE PRECISION, q.mint_decimals_1 - q.mint_decimals_0))
                        / LN(1.0001::DOUBLE PRECISION)
                    )::NUMERIC,
                    0
                )::INTEGER AS peg_tick,
                ROUND(
                    (POWER(q.sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2) *
                        POWER(10, q.mint_decimals_0 - q.mint_decimals_1))::NUMERIC,
                    6
                ) AS current_price_t1_per_t0
            FROM latest_query_per_pool lqp
            INNER JOIN src_acct_tickarray_queries q
                ON q.query_id = lqp.query_id
            CROSS JOIN params p
            WHERE (p.protocol_filter IS NULL OR q.protocol = p.protocol_filter)
              AND (p.pair_filter IS NULL OR q.token_pair = p.pair_filter)
        ),
        vault_reserves AS (
            SELECT
                cm.pool_address,
                vl.token_0_value,
                vl.token_1_value
            FROM current_meta cm
            LEFT JOIN LATERAL (
                SELECT v.token_0_value, v.token_1_value
                FROM dexes.cagg_vaults_5s v
                WHERE v.pool_address = cm.pool_address
                ORDER BY v.bucket_time DESC
                LIMIT 1
            ) vl ON TRUE
        ),
        current_rows AS (
            SELECT
                cm.pool_address,
                cm.protocol,
                cm.token_pair,
                cm.block_time,
                cm.current_tick,
                dexes.get_tick_float_from_sqrtPriceXQQ(
                    cm.sqrt_price_x64::DOUBLE PRECISION,
                    POWER(2::DOUBLE PRECISION, cm.price_fixed_point_base),
                    1.0001::DOUBLE PRECISION
                ) AS current_tick_float,
                cm.current_price_t1_per_t0,
                ROUND((1 / NULLIF(cm.current_price_t1_per_t0, 0))::NUMERIC, 6) AS current_price_t0_per_t1,
                cm.peg_tick,
                ROUND(
                    (dexes.get_price_from_tick(cm.peg_tick, 1.0001::DOUBLE PRECISION) *
                        POWER(10, cm.mint_decimals_0 - cm.mint_decimals_1))::NUMERIC,
                    6
                ) AS peg_price_t1_per_t0,
                td.tick_lower,
                ROUND(
                    (dexes.get_price_from_tick(td.tick_lower, 1.0001::DOUBLE PRECISION) *
                        POWER(10, cm.mint_decimals_0 - cm.mint_decimals_1))::NUMERIC,
                    6
                ) AS tick_price_t1_per_t0,
                ROUND(td.token0_value::NUMERIC, 0)::DOUBLE PRECISION AS token0_value,
                ROUND(td.token1_value::NUMERIC, 0)::DOUBLE PRECISION AS token1_value,
                ROUND(td.token0_cumul::NUMERIC, 0)::DOUBLE PRECISION AS token0_cumul,
                ROUND(td.token1_cumul::NUMERIC, 0)::DOUBLE PRECISION AS token1_cumul
            FROM src_acct_tickarray_tokendist_latest td
            INNER JOIN current_meta cm
                ON cm.pool_address = td.pool_address
               AND cm.query_id = td.query_id
        )
        SELECT
            cr.pool_address,
            cr.protocol,
            cr.token_pair,
            cr.block_time,
            cr.current_tick,
            cr.current_tick_float,
            -- Prices: swap t1_per_t0 ↔ t0_per_t1 when inverted
            CASE WHEN p_invert THEN cr.current_price_t0_per_t1 ELSE cr.current_price_t1_per_t0 END,
            CASE WHEN p_invert THEN cr.current_price_t1_per_t0 ELSE cr.current_price_t0_per_t1 END,
            cr.tick_lower,
            CASE WHEN p_invert
                 THEN ROUND((1 / NULLIF(cr.tick_price_t1_per_t0, 0))::NUMERIC, 6)
                 ELSE cr.tick_price_t1_per_t0 END,
            CASE WHEN p_invert
                 THEN cr.tick_price_t1_per_t0
                 ELSE ROUND((1 / NULLIF(cr.tick_price_t1_per_t0, 0))::NUMERIC, 6) END,
            (cr.peg_tick - cr.tick_lower) AS tick_delta_to_peg,
            -- BPS deltas: swap t1_per_t0 ↔ t0_per_t1 when inverted
            CASE WHEN p_invert
                 THEN ROUND((((cr.peg_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.peg_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            CASE WHEN p_invert
                 THEN ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.peg_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.peg_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            (cr.current_tick - cr.tick_lower) AS tick_delta_to_current,
            CASE WHEN p_invert
                 THEN ROUND((((cr.current_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.current_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            CASE WHEN p_invert
                 THEN ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.current_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.current_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            -- Token values: swap t0↔t1 when inverted
            CASE WHEN p_invert THEN cr.token1_value ELSE cr.token0_value END,
            CASE WHEN p_invert THEN cr.token0_value ELSE cr.token1_value END,
            CASE WHEN p_invert THEN cr.token1_cumul ELSE cr.token0_cumul END,
            CASE WHEN p_invert THEN cr.token0_cumul ELSE cr.token1_cumul END,
            NULL::DOUBLE PRECISION AS token0_value_delta,
            NULL::DOUBLE PRECISION AS token1_value_delta,
            -- Cumul pct reserve: swap when inverted
            CASE WHEN p_invert
                 THEN ROUND((cr.token1_cumul / NULLIF(vr.token_1_value, 0) * 100)::NUMERIC, 2)
                 ELSE ROUND((cr.token0_cumul / NULLIF(vr.token_0_value, 0) * 100)::NUMERIC, 2) END,
            CASE WHEN p_invert
                 THEN ROUND((cr.token0_cumul / NULLIF(vr.token_0_value, 0) * 100)::NUMERIC, 2)
                 ELSE ROUND((cr.token1_cumul / NULLIF(vr.token_1_value, 0) * 100)::NUMERIC, 2) END,
            NULL::DOUBLE PRECISION AS liquidity_period_delta_in_t1_units,
            NULL::NUMERIC(10,2) AS liquidity_period_delta_in_t1_units_pct,
            NULL::DOUBLE PRECISION AS liquidity_period_delta_net_reallocation_in_t1_units,
            NULL::DOUBLE PRECISION AS liquidity_period_delta_in_t0_units,
            NULL::NUMERIC(10,2) AS liquidity_period_delta_in_t0_units_pct,
            NULL::DOUBLE PRECISION AS liquidity_period_delta_net_reallocation_in_t0_units
        FROM current_rows cr
        LEFT JOIN vault_reserves vr
            ON vr.pool_address = cr.pool_address
        ORDER BY cr.pool_address, cr.tick_lower;

        RETURN;
    END IF;

    -- Delta path: uses historical src_acct_tickarray_tokendist for prior snapshot comparison.
    RETURN QUERY
    WITH params AS (
        SELECT
            NULLIF(TRIM(p_protocol), '') AS protocol_filter,
            NULLIF(TRIM(p_pair), '') AS pair_filter,
            p_delta_time AS delta_time
    ),
    latest_query_per_pool AS (
        SELECT
            l.pool_address,
            MAX(l.query_id) AS query_id
        FROM src_acct_tickarray_tokendist_latest l
        GROUP BY l.pool_address
    ),
    current_meta AS (
        SELECT
            q.pool_address,
            q.query_id,
            q.protocol,
            q.token_pair,
            q.block_time,
            q.time AS query_time,
            q.current_tick,
            q.sqrt_price_x64,
            q.price_fixed_point_base,
            q.mint_decimals_0,
            q.mint_decimals_1,
            ROUND(
                (
                    LN(POWER(10::DOUBLE PRECISION, q.mint_decimals_1 - q.mint_decimals_0))
                    / LN(1.0001::DOUBLE PRECISION)
                )::NUMERIC,
                0
            )::INTEGER AS peg_tick,
            ROUND(
                (POWER(q.sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2) *
                    POWER(10, q.mint_decimals_0 - q.mint_decimals_1))::NUMERIC,
                6
            ) AS current_price_t1_per_t0
        FROM latest_query_per_pool lqp
        INNER JOIN src_acct_tickarray_queries q
            ON q.query_id = lqp.query_id
        CROSS JOIN params p
        WHERE (p.protocol_filter IS NULL OR q.protocol = p.protocol_filter)
          AND (p.pair_filter IS NULL OR q.token_pair = p.pair_filter)
    ),
    prior_candidates AS (
        SELECT
            cm.pool_address,
            q.query_id,
            q.sqrt_price_x64,
            q.mint_decimals_0,
            q.mint_decimals_1,
            q.time
        FROM current_meta cm
        CROSS JOIN params p
        JOIN src_acct_tickarray_queries q
          ON q.pool_address = cm.pool_address
         AND q.time <= cm.query_time - p.delta_time
         AND q.query_id <> cm.query_id
    ),
    prior_meta AS (
        SELECT DISTINCT ON (pc.pool_address)
            pc.pool_address,
            pc.query_id AS prior_query_id,
            ROUND(
                (POWER(pc.sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2) *
                    POWER(10, pc.mint_decimals_0 - pc.mint_decimals_1))::NUMERIC,
                6
            ) AS prior_price_t1_per_t0
        FROM prior_candidates pc
        ORDER BY pc.pool_address, pc.time DESC
    ),
    vault_reserves AS (
        SELECT
            cm.pool_address,
            vl.token_0_value,
            vl.token_1_value
        FROM current_meta cm
        LEFT JOIN LATERAL (
            SELECT v.token_0_value, v.token_1_value
            FROM dexes.cagg_vaults_5s v
            WHERE v.pool_address = cm.pool_address
            ORDER BY v.bucket_time DESC
            LIMIT 1
        ) vl ON TRUE
    ),
    current_rows AS (
        SELECT
            cm.pool_address,
            cm.protocol,
            cm.token_pair,
            cm.block_time,
            cm.current_tick,
            dexes.get_tick_float_from_sqrtPriceXQQ(
                cm.sqrt_price_x64::DOUBLE PRECISION,
                POWER(2::DOUBLE PRECISION, cm.price_fixed_point_base),
                1.0001::DOUBLE PRECISION
            ) AS current_tick_float,
            cm.current_price_t1_per_t0,
            ROUND((1 / NULLIF(cm.current_price_t1_per_t0, 0))::NUMERIC, 6) AS current_price_t0_per_t1,
            cm.peg_tick,
            ROUND(
                (dexes.get_price_from_tick(cm.peg_tick, 1.0001::DOUBLE PRECISION) *
                    POWER(10, cm.mint_decimals_0 - cm.mint_decimals_1))::NUMERIC,
                6
            ) AS peg_price_t1_per_t0,
            td.tick_lower,
            ROUND(
                (dexes.get_price_from_tick(td.tick_lower, 1.0001::DOUBLE PRECISION) *
                    POWER(10, cm.mint_decimals_0 - cm.mint_decimals_1))::NUMERIC,
                6
            ) AS tick_price_t1_per_t0,
            ROUND(td.token0_value::NUMERIC, 0)::DOUBLE PRECISION AS token0_value,
            ROUND(td.token1_value::NUMERIC, 0)::DOUBLE PRECISION AS token1_value,
            ROUND(td.token0_cumul::NUMERIC, 0)::DOUBLE PRECISION AS token0_cumul,
            ROUND(td.token1_cumul::NUMERIC, 0)::DOUBLE PRECISION AS token1_cumul,
            pm.prior_query_id,
            pm.prior_price_t1_per_t0
        FROM src_acct_tickarray_tokendist_latest td
        INNER JOIN current_meta cm
            ON cm.pool_address = td.pool_address
           AND cm.query_id = td.query_id
        LEFT JOIN prior_meta pm
            ON pm.pool_address = cm.pool_address
    ),
    prior_rows AS (
        SELECT
            pm.pool_address,
            td.tick_lower,
            td.token0_value,
            td.token1_value
        FROM prior_meta pm
        INNER JOIN src_acct_tickarray_tokendist td
            ON td.query_id = pm.prior_query_id
    ),
    total_liquidity_change AS (
        SELECT
            cr.pool_address,
            SUM(ABS(
                ((
                    (ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.current_price_t1_per_t0, 6))
                    + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0)
                ) - (
                    (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.prior_price_t1_per_t0, 6))
                    + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0)
                ))::DOUBLE PRECISION
            )) AS total_abs_change_t1,
            SUM(ABS(
                ((
                    ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                    + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.current_price_t1_per_t0, 6), 0))
                ) - (
                    ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                    + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.prior_price_t1_per_t0, 6), 0))
                ))::DOUBLE PRECISION
            )) AS total_abs_change_t0
        FROM current_rows cr
        LEFT JOIN prior_rows pr
            ON pr.pool_address = cr.pool_address
           AND pr.tick_lower = cr.tick_lower
        WHERE cr.prior_query_id IS NOT NULL
          AND cr.prior_price_t1_per_t0 IS NOT NULL
        GROUP BY cr.pool_address
    )
    SELECT
        cr.pool_address,
        cr.protocol,
        cr.token_pair,
        cr.block_time,
        cr.current_tick,
        cr.current_tick_float,
        -- Prices: swap t1_per_t0 ↔ t0_per_t1 when inverted
        CASE WHEN p_invert THEN cr.current_price_t0_per_t1 ELSE cr.current_price_t1_per_t0 END,
        CASE WHEN p_invert THEN cr.current_price_t1_per_t0 ELSE cr.current_price_t0_per_t1 END,
        cr.tick_lower,
        CASE WHEN p_invert
             THEN ROUND((1 / NULLIF(cr.tick_price_t1_per_t0, 0))::NUMERIC, 6)
             ELSE cr.tick_price_t1_per_t0 END,
        CASE WHEN p_invert
             THEN cr.tick_price_t1_per_t0
             ELSE ROUND((1 / NULLIF(cr.tick_price_t1_per_t0, 0))::NUMERIC, 6) END,
        (cr.peg_tick - cr.tick_lower) AS tick_delta_to_peg,
        -- BPS deltas: swap t1_per_t0 ↔ t0_per_t1 when inverted
        CASE WHEN p_invert
             THEN ROUND((((cr.peg_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
             ELSE ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.peg_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
        CASE WHEN p_invert
             THEN ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.peg_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
             ELSE ROUND((((cr.peg_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
        (cr.current_tick - cr.tick_lower) AS tick_delta_to_current,
        CASE WHEN p_invert
             THEN ROUND((((cr.current_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
             ELSE ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.current_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
        CASE WHEN p_invert
             THEN ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.current_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
             ELSE ROUND((((cr.current_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
        -- Token values: swap t0↔t1 when inverted
        CASE WHEN p_invert THEN cr.token1_value ELSE cr.token0_value END,
        CASE WHEN p_invert THEN cr.token0_value ELSE cr.token1_value END,
        CASE WHEN p_invert THEN cr.token1_cumul ELSE cr.token0_cumul END,
        CASE WHEN p_invert THEN cr.token0_cumul ELSE cr.token1_cumul END,
        -- Token value deltas: swap when inverted
        CASE
            WHEN cr.prior_query_id IS NOT NULL THEN
                CASE WHEN p_invert THEN cr.token1_value - COALESCE(pr.token1_value, 0)
                     ELSE cr.token0_value - COALESCE(pr.token0_value, 0) END
            ELSE NULL
        END AS token0_value_delta,
        CASE
            WHEN cr.prior_query_id IS NOT NULL THEN
                CASE WHEN p_invert THEN cr.token0_value - COALESCE(pr.token0_value, 0)
                     ELSE cr.token1_value - COALESCE(pr.token1_value, 0) END
            ELSE NULL
        END AS token1_value_delta,
        -- Cumul pct reserve: swap when inverted
        CASE WHEN p_invert
             THEN ROUND((cr.token1_cumul / NULLIF(vr.token_1_value, 0) * 100)::NUMERIC, 2)
             ELSE ROUND((cr.token0_cumul / NULLIF(vr.token_0_value, 0) * 100)::NUMERIC, 2) END,
        CASE WHEN p_invert
             THEN ROUND((cr.token0_cumul / NULLIF(vr.token_0_value, 0) * 100)::NUMERIC, 2)
             ELSE ROUND((cr.token1_cumul / NULLIF(vr.token_1_value, 0) * 100)::NUMERIC, 2) END,
        -- Liquidity period delta: swap t1↔t0 units when inverted
        CASE WHEN p_invert THEN
            CASE
                WHEN cr.prior_query_id IS NOT NULL AND cr.prior_price_t1_per_t0 IS NOT NULL THEN
                    ((
                        ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                        + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.current_price_t1_per_t0, 6), 0))
                    ) - (
                        ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                        + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.prior_price_t1_per_t0, 6), 0))
                    ))::DOUBLE PRECISION
                ELSE NULL
            END
        ELSE
            CASE
                WHEN cr.prior_query_id IS NOT NULL AND cr.prior_price_t1_per_t0 IS NOT NULL THEN
                    ((
                        (ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.current_price_t1_per_t0, 6))
                        + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0)
                    ) - (
                        (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.prior_price_t1_per_t0, 6))
                        + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0)
                    ))::DOUBLE PRECISION
                ELSE NULL
            END
        END AS liquidity_period_delta_in_t1_units,
        CASE WHEN p_invert THEN
            CASE
                WHEN cr.prior_query_id IS NOT NULL
                    AND cr.prior_price_t1_per_t0 IS NOT NULL
                    AND tlc.total_abs_change_t0 > 0 THEN
                    ROUND(
                        (
                            ((
                                ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                                + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.current_price_t1_per_t0, 6), 0))
                            ) - (
                                ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                                + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.prior_price_t1_per_t0, 6), 0))
                            ))
                            / NULLIF(tlc.total_abs_change_t0, 0)
                            * 100
                        )::NUMERIC,
                        2
                    )
                ELSE NULL
            END
        ELSE
            CASE
                WHEN cr.prior_query_id IS NOT NULL
                    AND cr.prior_price_t1_per_t0 IS NOT NULL
                    AND tlc.total_abs_change_t1 > 0 THEN
                    ROUND(
                        (
                            ((
                                (ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.current_price_t1_per_t0, 6))
                                + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0)
                            ) - (
                                (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.prior_price_t1_per_t0, 6))
                                + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0)
                            ))
                            / NULLIF(tlc.total_abs_change_t1, 0)
                            * 100
                        )::NUMERIC,
                        2
                    )
                ELSE NULL
            END
        END AS liquidity_period_delta_in_t1_units_pct,
        CASE WHEN p_invert
             THEN CASE WHEN cr.prior_query_id IS NOT NULL THEN ROUND(tlc.total_abs_change_t0::NUMERIC, 0)::DOUBLE PRECISION ELSE NULL END
             ELSE CASE WHEN cr.prior_query_id IS NOT NULL THEN ROUND(tlc.total_abs_change_t1::NUMERIC, 0)::DOUBLE PRECISION ELSE NULL END
        END AS liquidity_period_delta_net_reallocation_in_t1_units,
        CASE WHEN p_invert THEN
            CASE
                WHEN cr.prior_query_id IS NOT NULL AND cr.prior_price_t1_per_t0 IS NOT NULL THEN
                    ((
                        (ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.current_price_t1_per_t0, 6))
                        + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0)
                    ) - (
                        (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.prior_price_t1_per_t0, 6))
                        + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0)
                    ))::DOUBLE PRECISION
                ELSE NULL
            END
        ELSE
            CASE
                WHEN cr.prior_query_id IS NOT NULL AND cr.prior_price_t1_per_t0 IS NOT NULL THEN
                    ((
                        ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                        + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.current_price_t1_per_t0, 6), 0))
                    ) - (
                        ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                        + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.prior_price_t1_per_t0, 6), 0))
                    ))::DOUBLE PRECISION
                ELSE NULL
            END
        END AS liquidity_period_delta_in_t0_units,
        CASE WHEN p_invert THEN
            CASE
                WHEN cr.prior_query_id IS NOT NULL
                    AND cr.prior_price_t1_per_t0 IS NOT NULL
                    AND tlc.total_abs_change_t1 > 0 THEN
                    ROUND(
                        (
                            ((
                                (ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.current_price_t1_per_t0, 6))
                                + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0)
                            ) - (
                                (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(cr.prior_price_t1_per_t0, 6))
                                + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0)
                            ))
                            / NULLIF(tlc.total_abs_change_t1, 0)
                            * 100
                        )::NUMERIC,
                        2
                    )
                ELSE NULL
            END
        ELSE
            CASE
                WHEN cr.prior_query_id IS NOT NULL
                    AND cr.prior_price_t1_per_t0 IS NOT NULL
                    AND tlc.total_abs_change_t0 > 0 THEN
                    ROUND(
                        (
                            ((
                                ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                                + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.current_price_t1_per_t0, 6), 0))
                            ) - (
                                ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                                + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(cr.prior_price_t1_per_t0, 6), 0))
                            ))
                            / NULLIF(tlc.total_abs_change_t0, 0)
                            * 100
                        )::NUMERIC,
                        2
                    )
                ELSE NULL
            END
        END AS liquidity_period_delta_in_t0_units_pct,
        CASE WHEN p_invert
             THEN CASE WHEN cr.prior_query_id IS NOT NULL THEN ROUND(tlc.total_abs_change_t1::NUMERIC, 0)::DOUBLE PRECISION ELSE NULL END
             ELSE CASE WHEN cr.prior_query_id IS NOT NULL THEN ROUND(tlc.total_abs_change_t0::NUMERIC, 0)::DOUBLE PRECISION ELSE NULL END
        END AS liquidity_period_delta_net_reallocation_in_t0_units
    FROM current_rows cr
    LEFT JOIN prior_rows pr
        ON pr.pool_address = cr.pool_address
       AND pr.tick_lower = cr.tick_lower
    LEFT JOIN vault_reserves vr
        ON vr.pool_address = cr.pool_address
    LEFT JOIN total_liquidity_change tlc
        ON tlc.pool_address = cr.pool_address
    ORDER BY cr.pool_address, cr.tick_lower;
END;
$$
SECURITY DEFINER
SET search_path = dexes, pg_catalog, public;

COMMENT ON FUNCTION dexes.get_view_tick_dist_simple IS
'Simplified tick distribution function with deprecated features removed.
This version was developed to remove deprecated frontend-oriented parameters,
avoid persisting React frontend dependencies, and improve compatibility with
other dashboarding platforms.

When p_invert = TRUE, the output swaps t0↔t1 perspectives:
  - Prices: current_price_t1_per_t0 ↔ current_price_t0_per_t1
  - Tick prices: tick_price_t1_per_t0 ↔ tick_price_t0_per_t1
  - BPS deltas: t1_per_t0_bps ↔ t0_per_t1_bps
  - Token values: token0_value ↔ token1_value, token0_cumul ↔ token1_cumul
  - Liquidity deltas: t1_units ↔ t0_units

Current-state and filtering behavior:
  - Uses src_acct_tickarray_tokendist_latest for current liquidity distribution.
  - p_protocol and p_pair are optional; when NULL they apply no filters.
  - When protocol/pair are NULL, returns all matching pools (set-based, not single-pool).
  - Uses src_acct_tickarray_tokendist (historical) only when p_delta_time is provided.
  - When p_delta_time IS NULL, the function does not touch historical token distribution tables.

Additional output fields for dashboard filtering:
  - tick_delta_to_peg uses a dynamic peg_tick derived from token decimals.
  - tick_delta_to_peg_price_t1_per_t0_bps = ((tick_price_t1_per_t0 / peg_price_t1_per_t0) - 1) * 10000
  - tick_delta_to_peg_price_t0_per_t1_bps = ((tick_price_t0_per_t1 / peg_price_t0_per_t1) - 1) * 10000
  - tick_delta_to_current = current_tick - tick_lower
  - tick_delta_to_current_price_t1_per_t0_bps = ((tick_price_t1_per_t0 / current_price_t1_per_t0) - 1) * 10000
  - tick_delta_to_current_price_t0_per_t1_bps = ((tick_price_t0_per_t1 / current_price_t0_per_t1) - 1) * 10000
  - liquidity_period_delta_in_t0_units converts liquidity delta to T0 terms
    using token1/current_price_t1_per_t0.';

-- Example usage:
-- SELECT * FROM dexes.get_view_tick_dist_simple(NULL, NULL, NULL);
-- SELECT * FROM dexes.get_view_tick_dist_simple('raydium_clmm', NULL, NULL);
-- SELECT * FROM dexes.get_view_tick_dist_simple('raydium_clmm', 'USX-USDC', '5 minutes');
-- SELECT * FROM dexes.get_view_tick_dist_simple('raydium_clmm', 'USX-USDC', '5 minutes', TRUE);

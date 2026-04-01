-- =====================================================
-- Tick Distribution View Function (Simple)
-- =====================================================
-- Function: get_view_tick_dist_simple
-- Purpose: Return tick distribution data with minimal/deprecated-free inputs.
--
-- Performance notes:
-- - The delta path uses the "solstice pattern": PL/pgSQL scalar variables
--   for query_id lookups ensure OSM foreign scans prune S3-tiered chunks.
--   CTE-derived values in JOIN conditions cannot be pushed into OSM.
-- - Each matching pool is processed in its own loop iteration with its
--   own RETURN QUERY, which naturally handles multi-pool mode.
-- =====================================================

DROP FUNCTION IF EXISTS dexes.get_view_tick_dist_simple(TEXT, TEXT, INTERVAL);
CREATE OR REPLACE FUNCTION dexes.get_view_tick_dist_simple(
    p_protocol TEXT DEFAULT NULL,
    p_pair TEXT DEFAULT NULL,
    p_delta_time INTERVAL DEFAULT NULL,
    p_invert BOOLEAN DEFAULT FALSE
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
AS $function$
DECLARE
    _r RECORD;
    v_prior_query_id BIGINT;
    v_prior_price_t1_per_t0 NUMERIC;
    v_protocol_filter TEXT := NULLIF(TRIM(p_protocol), '');
    v_pair_filter TEXT := NULLIF(TRIM(p_pair), '');
    v_current_price_t0_per_t1 NUMERIC;
    v_peg_price_t1_per_t0 NUMERIC;
    v_current_tick_float DOUBLE PRECISION;
BEGIN
    IF p_delta_time IS NULL THEN
        -- Fast path: latest-only mode (no historical table access).
        RETURN QUERY
        WITH latest_query_per_pool AS (
            SELECT l.pool_address, MAX(l.query_id) AS query_id
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
                    (LN(POWER(10::DOUBLE PRECISION, q.mint_decimals_1 - q.mint_decimals_0))
                     / LN(1.0001::DOUBLE PRECISION))::NUMERIC, 0
                )::INTEGER AS peg_tick,
                ROUND(
                    (POWER(q.sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2)
                     * POWER(10, q.mint_decimals_0 - q.mint_decimals_1))::NUMERIC, 6
                ) AS current_price_t1_per_t0
            FROM latest_query_per_pool lqp
            INNER JOIN src_acct_tickarray_queries q ON q.query_id = lqp.query_id
            WHERE (v_protocol_filter IS NULL OR q.protocol = v_protocol_filter)
              AND (v_pair_filter IS NULL OR q.token_pair = v_pair_filter)
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
                    (dexes.get_price_from_tick(cm.peg_tick, 1.0001::DOUBLE PRECISION)
                     * POWER(10, cm.mint_decimals_0 - cm.mint_decimals_1))::NUMERIC, 6
                ) AS peg_price_t1_per_t0,
                td.tick_lower,
                ROUND(
                    (dexes.get_price_from_tick(td.tick_lower, 1.0001::DOUBLE PRECISION)
                     * POWER(10, cm.mint_decimals_0 - cm.mint_decimals_1))::NUMERIC, 6
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
            CASE WHEN p_invert THEN cr.current_price_t0_per_t1 ELSE cr.current_price_t1_per_t0 END,
            CASE WHEN p_invert THEN cr.current_price_t1_per_t0 ELSE cr.current_price_t0_per_t1 END,
            cr.tick_lower,
            CASE WHEN p_invert
                 THEN ROUND((1 / NULLIF(cr.tick_price_t1_per_t0, 0))::NUMERIC, 6)
                 ELSE cr.tick_price_t1_per_t0 END,
            CASE WHEN p_invert
                 THEN cr.tick_price_t1_per_t0
                 ELSE ROUND((1 / NULLIF(cr.tick_price_t1_per_t0, 0))::NUMERIC, 6) END,
            (cr.peg_tick - cr.tick_lower),
            CASE WHEN p_invert
                 THEN ROUND((((cr.peg_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.peg_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            CASE WHEN p_invert
                 THEN ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.peg_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.peg_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            (cr.current_tick - cr.tick_lower),
            CASE WHEN p_invert
                 THEN ROUND((((cr.current_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.current_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            CASE WHEN p_invert
                 THEN ROUND((((cr.tick_price_t1_per_t0 / NULLIF(cr.current_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.current_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            CASE WHEN p_invert THEN cr.token1_value ELSE cr.token0_value END,
            CASE WHEN p_invert THEN cr.token0_value ELSE cr.token1_value END,
            CASE WHEN p_invert THEN cr.token1_cumul ELSE cr.token0_cumul END,
            CASE WHEN p_invert THEN cr.token0_cumul ELSE cr.token1_cumul END,
            NULL::DOUBLE PRECISION,
            NULL::DOUBLE PRECISION,
            CASE WHEN p_invert
                 THEN ROUND((cr.token1_cumul / NULLIF(vr.token_1_value, 0) * 100)::NUMERIC, 2)
                 ELSE ROUND((cr.token0_cumul / NULLIF(vr.token_0_value, 0) * 100)::NUMERIC, 2) END,
            CASE WHEN p_invert
                 THEN ROUND((cr.token0_cumul / NULLIF(vr.token_0_value, 0) * 100)::NUMERIC, 2)
                 ELSE ROUND((cr.token1_cumul / NULLIF(vr.token_1_value, 0) * 100)::NUMERIC, 2) END,
            NULL::DOUBLE PRECISION,
            NULL::NUMERIC(10,2),
            NULL::DOUBLE PRECISION,
            NULL::DOUBLE PRECISION,
            NULL::NUMERIC(10,2),
            NULL::DOUBLE PRECISION
        FROM current_rows cr
        LEFT JOIN vault_reserves vr ON vr.pool_address = cr.pool_address
        ORDER BY cr.pool_address, cr.tick_lower;

        RETURN;
    END IF;

    -- =========================================================================
    -- Delta path: solstice-style per-pool loop with scalar query_id resolution.
    --
    -- PL/pgSQL scalar variables in JOIN/WHERE conditions are treated as
    -- constants by the planner, enabling OSM chunk pruning on S3-tiered
    -- hypertables. CTE-derived values cannot be pushed into foreign scans.
    --
    -- Step 1: Loop over matching pools from the _latest table.
    -- Step 2: Resolve prior_query_id as a scalar (fast, index-only on queries).
    -- Step 3: RETURN QUERY per pool using the scalar in JOINs (~2ms per pool).
    -- =========================================================================

    FOR _r IN
        WITH latest_query_per_pool AS (
            SELECT l.pool_address, MAX(l.query_id) AS query_id
            FROM src_acct_tickarray_tokendist_latest l
            GROUP BY l.pool_address
        )
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
                (LN(POWER(10::DOUBLE PRECISION, q.mint_decimals_1 - q.mint_decimals_0))
                 / LN(1.0001::DOUBLE PRECISION))::NUMERIC, 0
            )::INTEGER AS peg_tick,
            ROUND(
                (POWER(q.sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2)
                 * POWER(10, q.mint_decimals_0 - q.mint_decimals_1))::NUMERIC, 6
            ) AS current_price_t1_per_t0
        FROM latest_query_per_pool lqp
        INNER JOIN src_acct_tickarray_queries q ON q.query_id = lqp.query_id
        WHERE (v_protocol_filter IS NULL OR q.protocol = v_protocol_filter)
          AND (v_pair_filter IS NULL OR q.token_pair = v_pair_filter)
    LOOP
        -- Pre-compute per-pool derived values (once per pool, not per tick row)
        v_current_price_t0_per_t1 := ROUND((1 / NULLIF(_r.current_price_t1_per_t0, 0))::NUMERIC, 6);
        v_peg_price_t1_per_t0 := ROUND(
            (dexes.get_price_from_tick(_r.peg_tick, 1.0001::DOUBLE PRECISION)
             * POWER(10, _r.mint_decimals_0 - _r.mint_decimals_1))::NUMERIC, 6
        );
        v_current_tick_float := dexes.get_tick_float_from_sqrtPriceXQQ(
            _r.sqrt_price_x64::DOUBLE PRECISION,
            POWER(2::DOUBLE PRECISION, _r.price_fixed_point_base),
            1.0001::DOUBLE PRECISION
        );

        -- Resolve prior query_id as scalar (LOCF: last observation before target time)
        SELECT
            q.query_id,
            ROUND(
                (POWER(q.sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2)
                 * POWER(10, q.mint_decimals_0 - q.mint_decimals_1))::NUMERIC, 6
            )
        INTO v_prior_query_id, v_prior_price_t1_per_t0
        FROM src_acct_tickarray_queries q
        WHERE q.pool_address = _r.pool_address
          AND q.block_time <= _r.query_time - p_delta_time
          AND q.query_id <> _r.query_id
        ORDER BY q.block_time DESC
        LIMIT 1;

        RETURN QUERY
        WITH current_rows AS (
            SELECT
                td.tick_lower,
                ROUND(
                    (dexes.get_price_from_tick(td.tick_lower, 1.0001::DOUBLE PRECISION)
                     * POWER(10, _r.mint_decimals_0 - _r.mint_decimals_1))::NUMERIC, 6
                ) AS tick_price_t1_per_t0,
                ROUND(td.token0_value::NUMERIC, 0)::DOUBLE PRECISION AS token0_value,
                ROUND(td.token1_value::NUMERIC, 0)::DOUBLE PRECISION AS token1_value,
                ROUND(td.token0_cumul::NUMERIC, 0)::DOUBLE PRECISION AS token0_cumul,
                ROUND(td.token1_cumul::NUMERIC, 0)::DOUBLE PRECISION AS token1_cumul
            FROM src_acct_tickarray_tokendist_latest td
            WHERE td.pool_address = _r.pool_address
              AND td.query_id = _r.query_id
        ),
        prior_rows AS (
            SELECT td.tick_lower, td.token0_value, td.token1_value
            FROM src_acct_tickarray_tokendist td
            WHERE td.query_id = v_prior_query_id
        ),
        total_liquidity_change AS (
            SELECT
                SUM(ABS(
                    ((ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(_r.current_price_t1_per_t0, 6))
                     + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0))
                    -
                    ((ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(v_prior_price_t1_per_t0, 6))
                     + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0))
                )::DOUBLE PRECISION) AS total_abs_change_t1,
                SUM(ABS(
                    (ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                     + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(_r.current_price_t1_per_t0, 6), 0)))
                    -
                    (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                     + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(v_prior_price_t1_per_t0, 6), 0)))
                )::DOUBLE PRECISION) AS total_abs_change_t0
            FROM current_rows cr
            LEFT JOIN prior_rows pr ON pr.tick_lower = cr.tick_lower
            WHERE v_prior_query_id IS NOT NULL
              AND v_prior_price_t1_per_t0 IS NOT NULL
        )
        SELECT
            _r.pool_address::TEXT,
            _r.protocol::TEXT,
            _r.token_pair::TEXT,
            _r.block_time,
            _r.current_tick,
            v_current_tick_float,
            -- Prices: swap t1_per_t0 <-> t0_per_t1 when inverted
            CASE WHEN p_invert THEN v_current_price_t0_per_t1 ELSE _r.current_price_t1_per_t0 END,
            CASE WHEN p_invert THEN _r.current_price_t1_per_t0 ELSE v_current_price_t0_per_t1 END,
            cr.tick_lower,
            CASE WHEN p_invert
                 THEN ROUND((1 / NULLIF(cr.tick_price_t1_per_t0, 0))::NUMERIC, 6)
                 ELSE cr.tick_price_t1_per_t0 END,
            CASE WHEN p_invert
                 THEN cr.tick_price_t1_per_t0
                 ELSE ROUND((1 / NULLIF(cr.tick_price_t1_per_t0, 0))::NUMERIC, 6) END,
            (_r.peg_tick - cr.tick_lower),
            -- BPS deltas to peg
            CASE WHEN p_invert
                 THEN ROUND((((v_peg_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.tick_price_t1_per_t0 / NULLIF(v_peg_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            CASE WHEN p_invert
                 THEN ROUND((((cr.tick_price_t1_per_t0 / NULLIF(v_peg_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((v_peg_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            (_r.current_tick - cr.tick_lower),
            -- BPS deltas to current
            CASE WHEN p_invert
                 THEN ROUND((((_r.current_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((cr.tick_price_t1_per_t0 / NULLIF(_r.current_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            CASE WHEN p_invert
                 THEN ROUND((((cr.tick_price_t1_per_t0 / NULLIF(_r.current_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6)
                 ELSE ROUND((((_r.current_price_t1_per_t0 / NULLIF(cr.tick_price_t1_per_t0, 0)) - 1) * 10000)::NUMERIC, 6) END,
            -- Token values: swap t0<->t1 when inverted
            CASE WHEN p_invert THEN cr.token1_value ELSE cr.token0_value END,
            CASE WHEN p_invert THEN cr.token0_value ELSE cr.token1_value END,
            CASE WHEN p_invert THEN cr.token1_cumul ELSE cr.token0_cumul END,
            CASE WHEN p_invert THEN cr.token0_cumul ELSE cr.token1_cumul END,
            -- Token value deltas
            CASE
                WHEN v_prior_query_id IS NOT NULL THEN
                    CASE WHEN p_invert THEN cr.token1_value - COALESCE(pr.token1_value, 0)
                         ELSE cr.token0_value - COALESCE(pr.token0_value, 0) END
                ELSE NULL
            END,
            CASE
                WHEN v_prior_query_id IS NOT NULL THEN
                    CASE WHEN p_invert THEN cr.token0_value - COALESCE(pr.token0_value, 0)
                         ELSE cr.token1_value - COALESCE(pr.token1_value, 0) END
                ELSE NULL
            END,
            -- Cumul pct reserve
            CASE WHEN p_invert
                 THEN ROUND((cr.token1_cumul / NULLIF(vr.token_1_value, 0) * 100)::NUMERIC, 2)
                 ELSE ROUND((cr.token0_cumul / NULLIF(vr.token_0_value, 0) * 100)::NUMERIC, 2) END,
            CASE WHEN p_invert
                 THEN ROUND((cr.token0_cumul / NULLIF(vr.token_0_value, 0) * 100)::NUMERIC, 2)
                 ELSE ROUND((cr.token1_cumul / NULLIF(vr.token_1_value, 0) * 100)::NUMERIC, 2) END,
            -- Liquidity period delta in T1 units
            CASE WHEN p_invert THEN
                CASE
                    WHEN v_prior_query_id IS NOT NULL AND v_prior_price_t1_per_t0 IS NOT NULL THEN
                        ((ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                          + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(_r.current_price_t1_per_t0, 6), 0)))
                         -
                         (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                          + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(v_prior_price_t1_per_t0, 6), 0)))
                        )::DOUBLE PRECISION
                    ELSE NULL
                END
            ELSE
                CASE
                    WHEN v_prior_query_id IS NOT NULL AND v_prior_price_t1_per_t0 IS NOT NULL THEN
                        (((ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(_r.current_price_t1_per_t0, 6))
                          + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0))
                         -
                         ((ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(v_prior_price_t1_per_t0, 6))
                          + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0))
                        )::DOUBLE PRECISION
                    ELSE NULL
                END
            END,
            -- Liquidity period delta in T1 units pct
            CASE WHEN p_invert THEN
                CASE
                    WHEN v_prior_query_id IS NOT NULL
                        AND v_prior_price_t1_per_t0 IS NOT NULL
                        AND tlc.total_abs_change_t0 > 0 THEN
                        ROUND((
                            ((ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                              + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(_r.current_price_t1_per_t0, 6), 0)))
                             -
                             (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                              + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(v_prior_price_t1_per_t0, 6), 0))))
                            / NULLIF(tlc.total_abs_change_t0, 0) * 100
                        )::NUMERIC, 2)
                    ELSE NULL
                END
            ELSE
                CASE
                    WHEN v_prior_query_id IS NOT NULL
                        AND v_prior_price_t1_per_t0 IS NOT NULL
                        AND tlc.total_abs_change_t1 > 0 THEN
                        ROUND((
                            (((ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(_r.current_price_t1_per_t0, 6))
                              + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0))
                             -
                             ((ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(v_prior_price_t1_per_t0, 6))
                              + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0)))
                            / NULLIF(tlc.total_abs_change_t1, 0) * 100
                        )::NUMERIC, 2)
                    ELSE NULL
                END
            END,
            -- Net reallocation in T1 units
            CASE WHEN p_invert
                 THEN CASE WHEN v_prior_query_id IS NOT NULL THEN ROUND(tlc.total_abs_change_t0::NUMERIC, 0)::DOUBLE PRECISION ELSE NULL END
                 ELSE CASE WHEN v_prior_query_id IS NOT NULL THEN ROUND(tlc.total_abs_change_t1::NUMERIC, 0)::DOUBLE PRECISION ELSE NULL END
            END,
            -- Liquidity period delta in T0 units
            CASE WHEN p_invert THEN
                CASE
                    WHEN v_prior_query_id IS NOT NULL AND v_prior_price_t1_per_t0 IS NOT NULL THEN
                        (((ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(_r.current_price_t1_per_t0, 6))
                          + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0))
                         -
                         ((ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(v_prior_price_t1_per_t0, 6))
                          + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0))
                        )::DOUBLE PRECISION
                    ELSE NULL
                END
            ELSE
                CASE
                    WHEN v_prior_query_id IS NOT NULL AND v_prior_price_t1_per_t0 IS NOT NULL THEN
                        ((ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                          + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(_r.current_price_t1_per_t0, 6), 0)))
                         -
                         (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                          + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(v_prior_price_t1_per_t0, 6), 0)))
                        )::DOUBLE PRECISION
                    ELSE NULL
                END
            END,
            -- Liquidity period delta in T0 units pct
            CASE WHEN p_invert THEN
                CASE
                    WHEN v_prior_query_id IS NOT NULL
                        AND v_prior_price_t1_per_t0 IS NOT NULL
                        AND tlc.total_abs_change_t1 > 0 THEN
                        ROUND((
                            (((ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0) * ROUND(_r.current_price_t1_per_t0, 6))
                              + ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0))
                             -
                             ((ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0) * ROUND(v_prior_price_t1_per_t0, 6))
                              + ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0)))
                            / NULLIF(tlc.total_abs_change_t1, 0) * 100
                        )::NUMERIC, 2)
                    ELSE NULL
                END
            ELSE
                CASE
                    WHEN v_prior_query_id IS NOT NULL
                        AND v_prior_price_t1_per_t0 IS NOT NULL
                        AND tlc.total_abs_change_t0 > 0 THEN
                        ROUND((
                            ((ROUND(COALESCE(cr.token0_value, 0)::NUMERIC, 0)
                              + (ROUND(COALESCE(cr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(_r.current_price_t1_per_t0, 6), 0)))
                             -
                             (ROUND(COALESCE(pr.token0_value, 0)::NUMERIC, 0)
                              + (ROUND(COALESCE(pr.token1_value, 0)::NUMERIC, 0) / NULLIF(ROUND(v_prior_price_t1_per_t0, 6), 0))))
                            / NULLIF(tlc.total_abs_change_t0, 0) * 100
                        )::NUMERIC, 2)
                    ELSE NULL
                END
            END,
            -- Net reallocation in T0 units
            CASE WHEN p_invert
                 THEN CASE WHEN v_prior_query_id IS NOT NULL THEN ROUND(tlc.total_abs_change_t1::NUMERIC, 0)::DOUBLE PRECISION ELSE NULL END
                 ELSE CASE WHEN v_prior_query_id IS NOT NULL THEN ROUND(tlc.total_abs_change_t0::NUMERIC, 0)::DOUBLE PRECISION ELSE NULL END
            END
        FROM current_rows cr
        LEFT JOIN prior_rows pr ON pr.tick_lower = cr.tick_lower
        LEFT JOIN LATERAL (
            SELECT v.token_0_value, v.token_1_value
            FROM dexes.cagg_vaults_5s v
            WHERE v.pool_address = _r.pool_address
            ORDER BY v.bucket_time DESC
            LIMIT 1
        ) vr ON TRUE
        LEFT JOIN total_liquidity_change tlc ON TRUE
        ORDER BY cr.tick_lower;
    END LOOP;
END;
$function$
SECURITY DEFINER
SET search_path = dexes, pg_catalog, public;

COMMENT ON FUNCTION dexes.get_view_tick_dist_simple IS
'Simplified tick distribution function with deprecated features removed.

Performance characteristics:
  - Fast path (p_delta_time IS NULL): pure CTE query against _latest tables only.
  - Delta path: uses solstice-style PL/pgSQL scalar variables for query_id
    lookups. This enables OSM chunk pruning on S3-tiered hypertables (~2ms
    per pool instead of ~27s with CTE-derived values in JOINs).

When p_invert = TRUE, the output swaps t0/t1 perspectives:
  - Prices: current_price_t1_per_t0 <-> current_price_t0_per_t1
  - Tick prices: tick_price_t1_per_t0 <-> tick_price_t0_per_t1
  - BPS deltas: t1_per_t0_bps <-> t0_per_t1_bps
  - Token values: token0_value <-> token1_value, token0_cumul <-> token1_cumul
  - Liquidity deltas: t1_units <-> t0_units

Current-state and filtering behavior:
  - Uses src_acct_tickarray_tokendist_latest for current liquidity distribution.
  - p_protocol and p_pair are optional; when NULL they apply no filters.
  - When protocol/pair are NULL, returns all matching pools (set-based).
  - Uses src_acct_tickarray_tokendist (historical) only when p_delta_time is provided.
  - When p_delta_time IS NULL, the function does not touch historical tables.';

-- Example usage:
-- SELECT * FROM dexes.get_view_tick_dist_simple(NULL, NULL, NULL);
-- SELECT * FROM dexes.get_view_tick_dist_simple('raydium_clmm', NULL, NULL);
-- SELECT * FROM dexes.get_view_tick_dist_simple('raydium_clmm', 'USX-USDC', '5 minutes');
-- SELECT * FROM dexes.get_view_tick_dist_simple('raydium_clmm', 'USX-USDC', '5 minutes', TRUE);

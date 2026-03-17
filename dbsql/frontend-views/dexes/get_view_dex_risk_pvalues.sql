-- ============================================================================
-- GET VIEW: DEX RISK P-VALUES
-- ============================================================================
-- Returns percentile statistics for risk analysis, filtered by protocol, pair,
-- event type, and optionally interval length.
--
-- Parameters:
--   p_protocol: DEX protocol filter ('orca', 'raydium', or NULL for all)
--   p_pair: Token pair filter ('onyc-usdc', 'usdg-onyc', or NULL for all)
--   p_event_type: One of:
--       - 'Single Swaps': Individual swap amounts (t0_sell_amount)
--       - 'Max Net Pressure Over Interval': Final net sell pressure (t0_sell_pressure_amount)
--       - 'Max Net Pressure Within Interval': Peak cumulative sell (t0_max_cumulative_sell_amount)
--   p_interval: Interval length as text (e.g., '15 minutes', '1 hour', '6 hours', '24 hours')
--       - Only applies to pressure event types
--       - Ignored for 'Single Swaps'
--       - NULL returns all intervals for pressure types
--
-- Returns key percentiles: max, p99.999, p99.99, p99.9, p99, p90, p80, p50, mean
--
-- Optimised: single query branch with dynamic column selection via CASE,
-- rather than three near-identical branches.
-- ============================================================================

CREATE OR REPLACE FUNCTION dexes.get_view_dex_risk_pvalues(
    p_protocol TEXT DEFAULT NULL,
    p_pair TEXT DEFAULT NULL,
    p_event_type TEXT DEFAULT 'Single Swaps',
    p_interval TEXT DEFAULT '15 minutes'
)
RETURNS TABLE (
    date                        TIMESTAMPTZ,
    protocol                    TEXT,
    pair                        TEXT,
    event_type                  TEXT,
    interval_mins               INTEGER,
    stat_name                   TEXT,
    stat_order                  INTEGER,
    value                       BIGINT,
    event_count_at_or_above     BIGINT,
    last_observed_at            TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_interval_mins INTEGER;
    v_metric TEXT;
    v_latest_date TIMESTAMPTZ;
BEGIN
    -- Resolve metric column name
    IF p_event_type = 'Single Swaps' THEN
        v_metric := 'sell_amount';
        v_interval_mins := 0;
    ELSIF p_event_type = 'Max Net Pressure Over Interval' THEN
        v_metric := 'sell_pressure';
    ELSIF p_event_type = 'Max Net Pressure Within Interval' THEN
        v_metric := 'max_cumulative';
    ELSE
        RAISE EXCEPTION 'Invalid event_type: %. Must be one of: ''Single Swaps'', ''Max Net Pressure Over Interval'', ''Max Net Pressure Within Interval''', p_event_type;
    END IF;

    -- Convert interval text to minutes for pressure types
    IF v_metric != 'sell_amount' THEN
        IF p_interval IS NOT NULL THEN
            v_interval_mins := EXTRACT(EPOCH FROM p_interval::INTERVAL)::INTEGER / 60;
        ELSE
            v_interval_mins := NULL;
        END IF;
    END IF;

    -- Latest refresh date
    SELECT MAX(r.date) INTO v_latest_date FROM dexes.risk_pvalues r;

    RETURN QUERY
    SELECT
        r.date,
        r.protocol,
        r.pair,
        p_event_type AS event_type,
        r.sell_pressure_interval_mins AS interval_mins,
        CASE r.stat
            WHEN 'max'    THEN 'Max'
            WHEN '99.999' THEN 'p 99.999'
            WHEN '99.99'  THEN 'p 99.99'
            WHEN '99.9'   THEN 'p 99.9'
            WHEN '99'     THEN 'p 99'
            WHEN '90'     THEN 'p 90'
            WHEN '80'     THEN 'p 80'
            WHEN '50'     THEN 'p 50'
            WHEN 'mean'   THEN 'Mean'
        END AS stat_name,
        CASE r.stat
            WHEN 'max'    THEN 1
            WHEN '99.999' THEN 2
            WHEN '99.99'  THEN 3
            WHEN '99.9'   THEN 4
            WHEN '99'     THEN 5
            WHEN '90'     THEN 6
            WHEN '80'     THEN 7
            WHEN '50'     THEN 8
            WHEN 'mean'   THEN 9
        END AS stat_order,
        CASE v_metric
            WHEN 'sell_amount'    THEN r.t0_sell_amount
            WHEN 'sell_pressure'  THEN r.t0_sell_pressure_amount
            WHEN 'max_cumulative' THEN r.t0_max_cumulative_sell_amount
        END AS value,
        r.event_count_at_or_above,
        r.last_observed_at
    FROM dexes.risk_pvalues r
    WHERE r.date = v_latest_date
      AND r.stat IN ('max', '99.999', '99.99', '99.9', '99', '90', '80', '50', 'mean')
      AND (p_protocol IS NULL OR LOWER(r.protocol) = LOWER(p_protocol))
      AND (p_pair IS NULL OR LOWER(r.pair) = LOWER(p_pair))
      -- Interval filtering: single swaps = 0, pressure types match requested or all
      AND (
          (v_metric = 'sell_amount' AND r.sell_pressure_interval_mins = 0)
          OR
          (v_metric != 'sell_amount' AND r.sell_pressure_interval_mins > 0
           AND (v_interval_mins IS NULL OR r.sell_pressure_interval_mins = v_interval_mins))
      )
      -- Only return rows where the selected metric has data
      AND CASE v_metric
            WHEN 'sell_amount'    THEN r.t0_sell_amount IS NOT NULL
            WHEN 'sell_pressure'  THEN r.t0_sell_pressure_amount IS NOT NULL
            WHEN 'max_cumulative' THEN r.t0_max_cumulative_sell_amount IS NOT NULL
          END
    ORDER BY r.protocol, r.pair, r.sell_pressure_interval_mins, stat_order;
END;
$$;

COMMENT ON FUNCTION dexes.get_view_dex_risk_pvalues(TEXT, TEXT, TEXT, TEXT) IS
'Returns percentile statistics for DEX risk analysis.

Parameters:
  p_protocol: Filter by protocol (''orca'', ''raydium'', or NULL for all)
  p_pair: Filter by pair (''onyc-usdc'', ''usdg-onyc'', or NULL for all)
  p_event_type: Type of event to analyze:
    - ''Single Swaps'': Individual swap sell amounts
    - ''Max Net Pressure Over Interval'': Final net sell pressure at end of interval
    - ''Max Net Pressure Within Interval'': Peak cumulative sell within interval (drawdown-style)
  p_interval: Interval length as text (''5 minutes'', ''15 minutes'', ''30 minutes'',
              ''1 hour'', ''6 hours'', ''24 hours'', or NULL for all intervals)

Returns: date, protocol, pair, event_type, interval_mins, stat_name, stat_order, value,
         event_count_at_or_above, last_observed_at

Stats returned: Max, p 99.999, p 99.99, p 99.9, p 99, p 90, p 80, p 50, Mean';

-- Kamino Lend - Sensitize Value (Partial Stress)
-- Generalized version of sensitize_deposit_value / sensitize_borrow_value
-- that applies the price shock only to a fraction (stressed_share) of the total value.
--
-- Formula per step i:
--   value[i] = current_value * (1 + stressed_share * delta_bps * i / 10000)
--
-- When stressed_share = 1.0, this is identical to the original full-shock functions.
-- When stressed_share = 0.0, the value array is constant (no shock).
--
-- Parameters:
--   current_value  - Current total deposit or borrow value
--   stressed_share - Fraction of value being stressed (0.0 to 1.0)
--   delta_bps      - Basis points change per step (e.g., -100 for -1%)
--   steps          - Number of steps to generate
--
-- Returns:
--   NUMERIC[] - Array of values at each step (length = steps + 1)

CREATE OR REPLACE FUNCTION kamino_lend.sensitize_value_partial(
    current_value   NUMERIC,
    stressed_share  NUMERIC,
    delta_bps       INTEGER,
    steps           INTEGER
) RETURNS NUMERIC[] AS $$
    SELECT ARRAY(
        SELECT current_value * (1 + stressed_share * (delta_bps * i)::NUMERIC / 10000.0)
        FROM generate_series(0, steps) AS i
    );
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION kamino_lend.sensitize_value_partial(NUMERIC, NUMERIC, INTEGER, INTEGER) IS
'Generates an array of values under partial price stress.
Only the stressed_share fraction of current_value is shocked; the rest stays constant.
Formula: value[i] = current_value * (1 + stressed_share * delta_bps * i / 10000).
When stressed_share = 1.0, equivalent to sensitize_deposit_value / sensitize_borrow_value.
LANGUAGE sql IMMUTABLE — eligible for inlining by the planner.';

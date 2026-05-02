-- Kamino Lend - Compute Stressed Share
-- Calculates what fraction of an obligation's deposit or borrow value
-- falls within a set of target asset symbols.
--
-- Used by get_view_klend_sensitivities to support asset-level stress testing.
-- The share (0.0-1.0) determines how much of the total value is shocked at each step.
--
-- Parameters:
--   position_reserves  - deposit_reserve_by_asset or borrow_reserve_by_asset
--   position_values_sf - deposit_market_value_sf_by_asset or borrow_market_value_sf_by_asset
--   resrv_addresses    - resrv_address (all reserves in the lending market)
--   resrv_symbols      - resrv_symbol (parallel array with resrv_addresses)
--   target_symbols     - symbols to stress, e.g. ARRAY['ONyc']
--
-- Returns:
--   NUMERIC in [0.0, 1.0] representing the fraction of total value in target symbols.
--   Returns 1.0 when position arrays are NULL/empty (full stress as fallback).

CREATE OR REPLACE FUNCTION kamino_lend.compute_stressed_share(
    position_reserves  TEXT[],
    position_values_sf NUMERIC[],
    resrv_addresses    TEXT[],
    resrv_symbols      TEXT[],
    target_symbols     TEXT[]
) RETURNS NUMERIC AS $$
    SELECT CASE
        WHEN COALESCE(SUM(pos_val), 0) = 0 THEN 1.0
        ELSE COALESCE(SUM(pos_val) FILTER (WHERE r_sym = ANY(target_symbols)), 0)
             / SUM(pos_val)
    END
    FROM (
        SELECT
            COALESCE(p.pos_val, 0) AS pos_val,
            (
                SELECT r_sym
                FROM unnest(resrv_addresses, resrv_symbols) AS l(r_addr, r_sym)
                WHERE l.r_addr = p.pos_addr
                LIMIT 1
            ) AS r_sym
        FROM unnest(position_reserves, position_values_sf) AS p(pos_addr, pos_val)
    ) joined;
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION kamino_lend.compute_stressed_share(TEXT[], NUMERIC[], TEXT[], TEXT[], TEXT[]) IS
'Computes the fraction (0.0-1.0) of an obligation''s deposit or borrow value that belongs
to the specified target asset symbols. Used for asset-level stress testing.
Maps position reserve addresses to symbols via the market-level resrv_address/resrv_symbol arrays.
Returns 1.0 when position arrays are NULL/empty (full-stress fallback).';

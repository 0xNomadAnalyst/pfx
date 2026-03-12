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
DECLARE
    n_positions  INTEGER;
    n_reserves   INTEGER;
    total_sf     NUMERIC := 0;
    stressed_sf  NUMERIC := 0;
    i            INTEGER;
    j            INTEGER;
    pos_addr     TEXT;
    pos_val      NUMERIC;
    sym          TEXT;
BEGIN
    n_positions := COALESCE(array_length(position_reserves, 1), 0);
    IF n_positions = 0 THEN
        RETURN 1.0;
    END IF;

    n_reserves := COALESCE(array_length(resrv_addresses, 1), 0);

    FOR i IN 1..n_positions LOOP
        pos_addr := position_reserves[i];
        pos_val  := COALESCE(position_values_sf[i], 0);
        total_sf := total_sf + pos_val;

        sym := NULL;
        FOR j IN 1..n_reserves LOOP
            IF resrv_addresses[j] = pos_addr THEN
                sym := resrv_symbols[j];
                EXIT;
            END IF;
        END LOOP;

        IF sym IS NOT NULL AND sym = ANY(target_symbols) THEN
            stressed_sf := stressed_sf + pos_val;
        END IF;
    END LOOP;

    IF total_sf = 0 THEN
        RETURN 1.0;
    END IF;

    RETURN stressed_sf / total_sf;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION kamino_lend.compute_stressed_share(TEXT[], NUMERIC[], TEXT[], TEXT[], TEXT[]) IS
'Computes the fraction (0.0-1.0) of an obligation''s deposit or borrow value that belongs
to the specified target asset symbols. Used for asset-level stress testing.
Maps position reserve addresses to symbols via the market-level resrv_address/resrv_symbol arrays.
Returns 1.0 when position arrays are NULL/empty (full-stress fallback).';

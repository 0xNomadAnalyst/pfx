-- Kamino Lend - Compute LTV Array from Deposit/Borrow Arrays
-- Derives per-step LTV directly from the actual deposit and borrow value arrays,
-- rather than approximating from a uniform-shock formula.
--
-- This replaces sensitize_ltv() in the main sensitivity function when
-- asset-level (partial) stress is active, because the LTV change depends
-- on how much of the obligation is being stressed.
--
-- Formula: ltv[i] = borrow[i] / deposit[i] * 100
--
-- Parameters:
--   deposit_array - Array of deposit values at each stress step
--   borrow_array  - Array of borrow values at each stress step
--
-- Returns:
--   NUMERIC[] - Array of LTV percentages (same length as inputs)

CREATE OR REPLACE FUNCTION kamino_lend.compute_ltv_array(
    deposit_array NUMERIC[],
    borrow_array  NUMERIC[]
) RETURNS NUMERIC[] AS $$
DECLARE
    result NUMERIC[] := ARRAY[]::NUMERIC[];
    n      INTEGER;
    i      INTEGER;
BEGIN
    n := COALESCE(array_length(deposit_array, 1), 0);

    IF n != COALESCE(array_length(borrow_array, 1), 0) THEN
        RAISE EXCEPTION 'deposit_array and borrow_array must have same length';
    END IF;

    FOR i IN 1..n LOOP
        IF deposit_array[i] IS NOT NULL AND deposit_array[i] > 0 THEN
            result := array_append(result, (borrow_array[i] / deposit_array[i]) * 100);
        ELSE
            result := array_append(result, NULL);
        END IF;
    END LOOP;

    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION kamino_lend.compute_ltv_array(NUMERIC[], NUMERIC[]) IS
'Computes LTV percentage array from deposit and borrow value arrays.
Formula: ltv[i] = borrow[i] / deposit[i] * 100.
Used instead of sensitize_ltv() when partial (asset-level) stress is active,
because the LTV change depends on the obligation-specific stressed share.';

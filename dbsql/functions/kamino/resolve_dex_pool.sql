-- Kamino Lend - Resolve DEX Pool for Reserve Symbol
-- Given a Kamino lending reserve symbol (e.g. 'ONyc', 'AUSD'), finds the
-- corresponding DEX pool and determines which token position the symbol
-- occupies (t0 or t1).
--
-- ASSUMPTION: Each token symbol is uniquely associated with a single DEX pool
-- in dexes.pool_tokens_reference. If a symbol appears in multiple pools, only
-- the first match is returned (non-deterministic). Callers should ensure the
-- reference table is curated to enforce this uniqueness for monitored assets.
--
-- Lookup path:
--   dexes.pool_tokens_reference.token0_symbol / token1_symbol -> pool_address
--
-- Parameters:
--   p_symbol: Token symbol as it appears in pool_tokens_reference (e.g. 'ONyc')
--
-- Returns: Single row with pool_address, token_side ('t0'/'t1'), and both symbols

CREATE OR REPLACE FUNCTION kamino_lend.resolve_dex_pool(p_symbol TEXT)
RETURNS TABLE (
    pool_address TEXT,
    token_side   TEXT,
    token0_symbol TEXT,
    token1_symbol TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ptr.pool_address,
        CASE
            WHEN ptr.token0_symbol = p_symbol THEN 't0'
            ELSE 't1'
        END AS token_side,
        ptr.token0_symbol,
        ptr.token1_symbol
    FROM dexes.pool_tokens_reference ptr
    WHERE ptr.token0_symbol = p_symbol
       OR ptr.token1_symbol = p_symbol
    LIMIT 1;
END;
$$ LANGUAGE plpgsql STABLE
SET search_path TO kamino_lend, dexes, public;

COMMENT ON FUNCTION kamino_lend.resolve_dex_pool(TEXT) IS
'Resolves a Kamino reserve token symbol to its DEX pool address and token position (t0/t1).
Assumes each symbol maps to exactly one pool in dexes.pool_tokens_reference.
Used by simulate_cascade_amplification to determine which pool receives liquidation sell pressure.';

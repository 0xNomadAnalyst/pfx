-- Kamino Lend - Resolve DEX Pool(s) for Reserve Symbol
-- Given a Kamino lending reserve symbol (e.g. 'ONyc', 'AUSD'), finds ALL
-- corresponding DEX pools and determines which token position the symbol
-- occupies (t0 or t1) in each.
--
-- A symbol may appear in multiple pools (e.g. ONyc in ONyc-USDC and USDG-ONyc).
-- Returns one row per matching pool.
--
-- Lookup path:
--   dexes.pool_tokens_reference.token0_symbol / token1_symbol -> pool_address
--
-- Parameters:
--   p_symbol: Token symbol as it appears in pool_tokens_reference (e.g. 'ONyc')
--
-- Returns: One row per matching pool with pool_address, token_side, and both symbols

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
       OR ptr.token1_symbol = p_symbol;
END;
$$ LANGUAGE plpgsql STABLE
SET search_path TO kamino_lend, dexes, public;

COMMENT ON FUNCTION kamino_lend.resolve_dex_pool(TEXT) IS
'Resolves a Kamino reserve token symbol to ALL its DEX pools and token positions (t0/t1).
Returns one row per matching pool in dexes.pool_tokens_reference.
Used by simulate_cascade_amplification to determine which pools receive liquidation sell pressure.';

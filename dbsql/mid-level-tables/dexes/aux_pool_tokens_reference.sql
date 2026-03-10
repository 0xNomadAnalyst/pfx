-- Pool Token Reference Table
-- Maps each pool to its canonical token0 and token1 addresses with metadata
-- This is needed for continuous aggregates which don't support CTEs or subqueries

CREATE TABLE IF NOT EXISTS dexes.pool_tokens_reference (
    pool_address TEXT PRIMARY KEY,
    token0_address TEXT NOT NULL,
    token1_address TEXT NOT NULL,
    token0_symbol TEXT,
    token1_symbol TEXT,
    token0_decimals INTEGER,
    token1_decimals INTEGER,
    token_pair TEXT,
    protocol TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Populate from source events (run this after initial data load)
-- Note: First populate basic token addresses, then enrich with symbols from swaps
-- Step 1: Populate token addresses from liquidity events OR swap events
INSERT INTO dexes.pool_tokens_reference (
    pool_address, 
    token0_address, 
    token1_address,
    token0_decimals,
    token1_decimals,
    token_pair,
    protocol
)
SELECT DISTINCT ON (pool_address)
    pool_address,
    -- Try liquidity events first, fall back to determining from swap events
    COALESCE(
        COALESCE(liq_token0_in, liq_token0_out),
        CASE WHEN swap_token_in < swap_token_out THEN swap_token_in ELSE swap_token_out END
    ) AS token0_address,
    COALESCE(
        COALESCE(liq_token1_in, liq_token1_out),
        CASE WHEN swap_token_in < swap_token_out THEN swap_token_out ELSE swap_token_in END
    ) AS token1_address,
    env_token0_decimals,
    env_token1_decimals,
    token_pair,
    protocol
FROM dexes.src_events_solscan
WHERE (
    activity_type IN ('ACTIVITY_TOKEN_ADD_LIQ', 'ACTIVITY_TOKEN_REMOVE_LIQ')
    OR activity_type IN ('ACTIVITY_TOKEN_SWAP', 'ACTIVITY_AGG_TOKEN_SWAP')
)
ORDER BY pool_address, block_time DESC
ON CONFLICT (pool_address) DO UPDATE
    SET token0_address = EXCLUDED.token0_address,
        token1_address = EXCLUDED.token1_address,
        token0_decimals = EXCLUDED.token0_decimals,
        token1_decimals = EXCLUDED.token1_decimals,
        token_pair = EXCLUDED.token_pair,
        protocol = EXCLUDED.protocol,
        updated_at = NOW();

-- Step 2: Update token symbols from swap events (they have swap_token_in_symbol and swap_token_out_symbol)
UPDATE dexes.pool_tokens_reference ptr
SET 
    token0_symbol = s.token0_symbol,
    token1_symbol = s.token1_symbol
FROM (
    SELECT DISTINCT ON (se.pool_address)
        se.pool_address,
        CASE 
            WHEN se.swap_token_in = pr.token0_address THEN se.swap_token_in_symbol
            WHEN se.swap_token_out = pr.token0_address THEN se.swap_token_out_symbol
        END AS token0_symbol,
        CASE 
            WHEN se.swap_token_in = pr.token1_address THEN se.swap_token_in_symbol
            WHEN se.swap_token_out = pr.token1_address THEN se.swap_token_out_symbol
        END AS token1_symbol
    FROM dexes.src_events_solscan se
    JOIN dexes.pool_tokens_reference pr ON se.pool_address = pr.pool_address
    WHERE se.activity_type IN ('ACTIVITY_TOKEN_SWAP', 'ACTIVITY_AGG_TOKEN_SWAP')
        AND se.swap_token_in_symbol IS NOT NULL
    ORDER BY se.pool_address, se.block_time DESC
) s
WHERE ptr.pool_address = s.pool_address;

-- Create index for joins
CREATE INDEX IF NOT EXISTS idx_pool_tokens_reference_pool_address 
    ON dexes.pool_tokens_reference (pool_address);

COMMENT ON TABLE dexes.pool_tokens_reference IS 
    'Reference table mapping pool addresses to their canonical token0 and token1 addresses with metadata (symbols, decimals, token_pair, protocol). Updated from swap and liquidity events.';


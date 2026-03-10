-- Market and Reserve Token Reference Table
-- Maps markets and reserves to their canonical token addresses with metadata
-- This is needed for continuous aggregates which don't support CTEs or subqueries
-- Dynamically populated from src_lending_market and src_reserves tables

CREATE TABLE IF NOT EXISTS kamino_lend.aux_market_reserve_tokens (
    -- Market identification
    market_address TEXT NOT NULL,
    market_quote_currency TEXT,
    
    -- Reserve identification
    reserve_address TEXT PRIMARY KEY,
    
    -- Token addresses
    token_mint TEXT NOT NULL,  -- Liquidity mint (from blockchain)
    collateral_mint TEXT,  -- Collateral mint (from blockchain)
    
    -- Token metadata
    token_symbol TEXT,
    token_decimals INTEGER,
    
    -- Reserve classification
    reserve_type TEXT,  -- 'borrow' or 'collateral' (from config)
    reserve_status TEXT,  -- 'Active', 'Obsolete', 'Hidden' (from blockchain)
    
    -- Risk parameters (latest values)
    loan_to_value_pct INTEGER,
    liquidation_threshold_pct INTEGER,
    borrow_factor_pct INTEGER,
    
    -- Scaling conventions for this reserve
    sf_scaling_factor NUMERIC DEFAULT 1152921504606846976,  -- 2^60 for scaled fraction fields
    sf_requires_decimal_adjustment BOOLEAN DEFAULT TRUE,    -- TRUE: reserves need ÷10^decimals after ÷2^60
    
    -- Config validation flags
    env_token_mint_matches BOOLEAN,  -- TRUE if env_token_mint = liquidity_mint_pubkey
    env_market_address_matches BOOLEAN,  -- TRUE if env_market_address = market_address
    
    -- Metadata
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Populate from source tables (run this after initial data load)
-- Step 1: Insert/update from latest reserves data
INSERT INTO kamino_lend.aux_market_reserve_tokens (
    market_address,
    reserve_address,
    token_mint,
    collateral_mint,
    token_symbol,
    token_decimals,
    reserve_type,
    reserve_status,
    loan_to_value_pct,
    liquidation_threshold_pct,
    borrow_factor_pct,
    env_token_mint_matches,
    env_market_address_matches
)
SELECT DISTINCT ON (r.reserve_address)
    r.market_address,
    r.reserve_address,
    r.liquidity_mint_pubkey AS token_mint,
    r.collateral_mint_pubkey AS collateral_mint,
    r.env_symbol AS token_symbol,
    r.env_decimals AS token_decimals,
    r.env_reserve_type AS reserve_type,
    r.reserve_status,
    r.loan_to_value_pct,
    r.liquidation_threshold_pct,
    r.borrow_factor_pct,
    -- Validation: check if config matches blockchain
    (r.env_token_mint = r.liquidity_mint_pubkey) AS env_token_mint_matches,
    (r.env_market_address = r.market_address) AS env_market_address_matches
FROM kamino_lend.src_reserves r
ORDER BY r.reserve_address, r.block_time DESC
ON CONFLICT (reserve_address) DO UPDATE
    SET market_address = EXCLUDED.market_address,
        token_mint = EXCLUDED.token_mint,
        collateral_mint = EXCLUDED.collateral_mint,
        token_symbol = EXCLUDED.token_symbol,
        token_decimals = EXCLUDED.token_decimals,
        reserve_type = EXCLUDED.reserve_type,
        reserve_status = EXCLUDED.reserve_status,
        loan_to_value_pct = EXCLUDED.loan_to_value_pct,
        liquidation_threshold_pct = EXCLUDED.liquidation_threshold_pct,
        borrow_factor_pct = EXCLUDED.borrow_factor_pct,
        env_token_mint_matches = EXCLUDED.env_token_mint_matches,
        env_market_address_matches = EXCLUDED.env_market_address_matches,
        updated_at = NOW();

-- Step 2: Enrich with market quote currency
UPDATE kamino_lend.aux_market_reserve_tokens mrt
SET market_quote_currency = m.quote_currency
FROM (
    SELECT DISTINCT ON (market_address)
        market_address,
        quote_currency
    FROM kamino_lend.src_lending_market
    ORDER BY market_address, block_time DESC
) m
WHERE mrt.market_address = m.market_address;

-- Create indexes for common lookups
CREATE INDEX IF NOT EXISTS idx_aux_market_reserve_tokens_market 
    ON kamino_lend.aux_market_reserve_tokens (market_address);

CREATE INDEX IF NOT EXISTS idx_aux_market_reserve_tokens_token_mint 
    ON kamino_lend.aux_market_reserve_tokens (token_mint);

CREATE INDEX IF NOT EXISTS idx_aux_market_reserve_tokens_symbol 
    ON kamino_lend.aux_market_reserve_tokens (token_symbol);

CREATE INDEX IF NOT EXISTS idx_aux_market_reserve_tokens_type 
    ON kamino_lend.aux_market_reserve_tokens (reserve_type);

-- Create composite index for common queries
CREATE INDEX IF NOT EXISTS idx_aux_market_reserve_tokens_market_type 
    ON kamino_lend.aux_market_reserve_tokens (market_address, reserve_type, token_symbol);

-- Table comment
COMMENT ON TABLE kamino_lend.aux_market_reserve_tokens IS 
    'Auxiliary reference table mapping reserve addresses to their token addresses, symbols, and metadata. Dynamically populated from src_lending_market and src_reserves. Used for efficient lookups in continuous aggregates and queries.';

-- Column comments
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.market_address IS 'Lending market address (parent)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.market_quote_currency IS 'Market quote currency (e.g., USD or token mint)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.reserve_address IS 'Reserve address (primary key)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.token_mint IS 'Liquidity token mint address (from blockchain)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.collateral_mint IS 'Collateral token mint address (from blockchain)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.token_symbol IS 'Token symbol (e.g., WSOL, bSOL) from config';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.token_decimals IS 'Token decimals from config';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.reserve_type IS 'Reserve type: "borrow" or "collateral" (from config)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.reserve_status IS 'Reserve status: Active, Obsolete, or Hidden (from blockchain)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.loan_to_value_pct IS 'Latest LTV percentage (from blockchain)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.liquidation_threshold_pct IS 'Latest liquidation threshold percentage (from blockchain)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.borrow_factor_pct IS 'Latest borrow factor percentage (from blockchain)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.sf_scaling_factor IS 'Scaling factor for *_sf fields (2^60 = 1152921504606846976)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.sf_requires_decimal_adjustment IS 'TRUE if *_sf fields require additional ÷10^decimals adjustment (reserves=TRUE, obligations=FALSE)';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.env_token_mint_matches IS 'Validation flag: TRUE if config token_mint matches blockchain liquidity_mint_pubkey';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.env_market_address_matches IS 'Validation flag: TRUE if config market_address matches actual market_address';
COMMENT ON COLUMN kamino_lend.aux_market_reserve_tokens.updated_at IS 'Timestamp when this row was last updated';

-- Example usage queries:

-- Get all reserves for a market with full token info:
-- SELECT * FROM kamino_lend.aux_market_reserve_tokens WHERE market_address = 'C7h9YnjP...';

-- Get borrow vs collateral reserves:
-- SELECT reserve_type, COUNT(*), array_agg(token_symbol) 
-- FROM kamino_lend.aux_market_reserve_tokens 
-- GROUP BY reserve_type;

-- Verify config matches blockchain:
-- SELECT reserve_address, token_symbol, 
--        env_token_mint_matches, env_market_address_matches
-- FROM kamino_lend.aux_market_reserve_tokens
-- WHERE NOT env_token_mint_matches OR NOT env_market_address_matches;

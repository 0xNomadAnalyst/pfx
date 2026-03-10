-- Kamino Lend - Reserves 5 Second Continuous Aggregate (Flat/Dynamic Format)
-- Flat table structure that dynamically handles any number of reserves
-- Uses block_time (blockchain timestamp) for bucketing - the hypertable partition dimension

CREATE MATERIALIZED VIEW kamino_lend.cagg_reserves_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket with 5-second intervals using block_time (hypertable dimension)
    time_bucket('5 seconds', r.block_time) AS bucket,
    
    -- Reserve identification and classification
    r.reserve_address,
    last(r.market_address, r.block_time) AS market_address,
    last(r.env_symbol, r.block_time) AS symbol,
    last(r.env_reserve_type, r.block_time) AS reserve_type_config,  -- From config: 'borrow' or 'collateral'
    last(r.c_reserve_type_evaluated, r.block_time) AS reserve_type_evaluated,  -- Calculated from vault balances
    last(r.reserve_status, r.block_time) AS reserve_status,  -- 'Active', 'Obsolete', 'Hidden'
    
    -- Token metadata (needed for calculations and display)
    last(r.env_decimals, r.block_time) AS decimals,
    last(r.liquidity_mint_pubkey, r.block_time) AS token_mint,
    last(r.collateral_mint_pubkey, r.block_time) AS collateral_mint,
    
    -- Supply metrics (human-readable, decimal-adjusted)
    last(r.liquidity_total_supply / POWER(10, r.env_decimals), r.block_time) AS supply_total,
    last(r.liquidity_available_amount / POWER(10, r.env_decimals), r.block_time) AS supply_available,
    last(r.liquidity_borrowed_amount_sf / POWER(2, 60) / POWER(10, r.env_decimals), r.block_time) AS supply_borrowed,
    
    -- Collateral metrics (human-readable, decimal-adjusted)
    last(r.collateral_mint_total_supply / POWER(10, r.env_decimals), r.block_time) AS collateral_total_supply,
    
    -- Vault balances (human-readable, decimal-adjusted)
    last(r.liquidity_vault_amount / POWER(10, r.env_decimals), r.block_time) AS vault_liquidity_balance,
    last(r.collateral_vault_amount / POWER(10, r.env_decimals), r.block_time) AS vault_collateral_balance,
    last(r.c_liquidity_vault_marketvalue, r.block_time) AS vault_liquidity_marketvalue,
    last(r.c_collateral_vault_marketvalue, r.block_time) AS vault_collateral_marketvalue,
    
    -- Utilization and rates (already in decimal format, no scaling needed)
    last(r.utilization_ratio, r.block_time) AS utilization_ratio,
    last(r.supply_apy, r.block_time) AS supply_apy,
    last(r.borrow_apy, r.block_time) AS borrow_apy,
    
    -- Pricing (human-readable, scaled fraction converted to USD)
    last(r.liquidity_market_price_sf / POWER(2, 60), r.block_time) AS market_price,  -- Vault's cached price
    last(r.oracle_price, r.block_time) AS oracle_price,  -- Oracle price (already in USD)
    
    -- TVL metrics (already in USD, no scaling needed)
    last(r.deposit_tvl, r.block_time) AS deposit_tvl,
    last(r.borrow_tvl, r.block_time) AS borrow_tvl,
    
    -- Risk parameters (percentages as integers)
    last(r.loan_to_value_pct, r.block_time) AS loan_to_value_pct,
    last(r.liquidation_threshold_pct, r.block_time) AS liquidation_threshold_pct,
    last(r.borrow_factor_pct, r.block_time) AS borrow_factor_pct,
    
    -- Limits (raw values for reference)
    last(r.deposit_limit / POWER(10, r.env_decimals), r.block_time) AS deposit_limit,
    last(r.borrow_limit / POWER(10, r.env_decimals), r.block_time) AS borrow_limit,
    
    -- Metadata - track both blockchain time (block_time) and ingestion time (time)
    last(r.block_time, r.block_time) AS last_block_time,
    last(r.time, r.block_time) AS last_updated,
    last(r.slot, r.block_time) AS last_slot

FROM kamino_lend.src_reserves r
WHERE r.block_time IS NOT NULL  -- Filter out rows without block_time
GROUP BY 
    time_bucket('5 seconds', r.block_time),
    r.reserve_address
WITH NO DATA;


-- Create indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_cagg_reserves_5s_bucket 
    ON kamino_lend.cagg_reserves_5s (bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_reserves_5s_reserve 
    ON kamino_lend.cagg_reserves_5s (reserve_address, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_reserves_5s_symbol 
    ON kamino_lend.cagg_reserves_5s (symbol, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_reserves_5s_type 
    ON kamino_lend.cagg_reserves_5s (reserve_type_config, bucket DESC);

-- Add view comment (TimescaleDB CAGGs appear as views, not materialized views)
COMMENT ON VIEW kamino_lend.cagg_reserves_5s IS 
'5-second continuous aggregate of reserve metrics in FLAT format (one row per reserve per bucket).
Uses block_time (blockchain timestamp) as canonical time for bucketing.
Dynamically handles any number of reserves without schema changes.

STRUCTURE:
- Flat table: Each row represents one reserve at one time bucket
- Dynamic: Automatically includes new reserves as they are added to src_reserves
- No hardcoded reserve addresses in the query

SCALING APPLIED:
- All token quantities are human-readable (decimal-adjusted)
- supply_borrowed: ÷ 2^60 (sf) ÷ 10^decimals → token units
- market_price: ÷ 2^60 (sf) → USD per token
- supply_total, supply_available: ÷ 10^decimals → token units
- collateral_total_supply: ÷ 10^decimals → token units
- vault balances: ÷ 10^decimals → token units
- Ratios and APYs: Used directly (no scaling)

COLUMNS:
- bucket: 5-second time bucket (TIMESTAMPTZ)
- reserve_address: Reserve public key
- market_address: Parent lending market
- symbol: Token symbol (e.g., USX, eUSX, USDC, PT-eUSX)
- reserve_type_config: Type from config ("borrow" or "collateral")
- reserve_type_evaluated: Type calculated from vault balances
- reserve_status: Reserve status (Active, Obsolete, Hidden)
- decimals: Token decimals (for reference)
- supply_total: Total supply in token units
- supply_available: Available liquidity in token units
- supply_borrowed: Borrowed amount in token units
- collateral_total_supply: Total collateral supply in token units
- vault_liquidity_balance: Liquidity vault balance in token units
- vault_collateral_balance: Collateral vault balance in token units
- vault_*_marketvalue: Vault balances in USD
- utilization_ratio: Utilization (0-1 decimal)
- supply_apy: Supply APY (0-1 decimal, multiply by 100 for %)
- borrow_apy: Borrow APY (0-1 decimal, multiply by 100 for %)
- market_price: Vault cached price (USD per token)
- oracle_price: Oracle price (USD per token)
- deposit_tvl: Total value locked in deposits (USD)
- borrow_tvl: Total value locked in borrows (USD)
- loan_to_value_pct: LTV percentage (0-100)
- liquidation_threshold_pct: Liquidation threshold (0-100)
- borrow_factor_pct: Borrow factor (0-100)
- deposit_limit: Deposit limit in token units
- borrow_limit: Borrow limit in token units

USAGE:
-- Get latest metrics for all reserves
SELECT * FROM kamino_lend.cagg_reserves_5s 
WHERE bucket >= NOW() - INTERVAL ''1 hour''
ORDER BY bucket DESC, symbol;

-- Get time series for specific reserve
SELECT * FROM kamino_lend.cagg_reserves_5s 
WHERE symbol = ''USX'' 
  AND bucket >= NOW() - INTERVAL ''24 hours''
ORDER BY bucket DESC;

-- Compare borrow vs collateral reserves
SELECT 
    bucket,
    reserve_type_config,
    COUNT(*) as reserve_count,
    SUM(supply_total) as total_supply,
    AVG(utilization_ratio) as avg_utilization
FROM kamino_lend.cagg_reserves_5s
WHERE bucket >= NOW() - INTERVAL ''1 hour''
GROUP BY bucket, reserve_type_config
ORDER BY bucket DESC;';



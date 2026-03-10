-- Kamino Lend Market Activities - 5 Second Continuous Aggregate (Flat/Dynamic Format)
-- Sources from src_txn_events (unified GRPC + migrated Solscan data)
-- Flat table structure that dynamically handles any number of reserves
-- Activity types remain as columns (deposit, withdraw, borrow, repay, liquidate)
-- Reserves are flattened into rows with token metadata
-- Uses 'meta_block_time' (TIMESTAMPTZ) for bucketing - the hypertable partition dimension
--
-- IMPORTANT: Liquidation events use repay_reserve_address for token lookup (debt being repaid)
-- while other activities use token1_address (the liquidity token). This is handled via
-- two LEFT JOINs with COALESCE to select the correct token metadata.

CREATE MATERIALIZED VIEW kamino_lend.cagg_activities_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket with 5-second intervals (using 'meta_block_time' which is TIMESTAMPTZ)
    time_bucket('5 seconds', a.meta_block_time) AS bucket,

    -- Token identification: For liquidations use repay reserve, otherwise use token1
    CASE
        WHEN a.activity_type = 'ACTIVITY_LIQUIDATE_BORROWING' THEN t_liq.token_mint
        ELSE a.token1_address
    END AS token_mint,

    -- Token metadata (enriched from aux_market_reserve_tokens)
    -- For liquidations: use t_liq (joined on repay_reserve_address)
    -- For others: use t_normal (joined on token1_address)
    COALESCE(
        CASE WHEN a.activity_type = 'ACTIVITY_LIQUIDATE_BORROWING' THEN t_liq.token_symbol ELSE t_normal.token_symbol END,
        'UNKNOWN'
    ) AS symbol,
    COALESCE(
        CASE WHEN a.activity_type = 'ACTIVITY_LIQUIDATE_BORROWING' THEN t_liq.token_decimals ELSE t_normal.token_decimals END,
        a.token1_decimals,
        6
    ) AS decimals,
    COALESCE(
        CASE WHEN a.activity_type = 'ACTIVITY_LIQUIDATE_BORROWING' THEN t_liq.reserve_address ELSE t_normal.reserve_address END,
        a.reserve_address
    ) AS reserve_address,
    COALESCE(
        CASE WHEN a.activity_type = 'ACTIVITY_LIQUIDATE_BORROWING' THEN t_liq.market_address ELSE t_normal.market_address END,
        a.lending_market_address
    ) AS market_address,

    -- Activity type columns (sum and count for each type)
    -- All amounts are decimal-adjusted to human-readable token units
    -- liquidity_amount is BIGINT, no CAST needed

    -- DEPOSIT VAULT activities
    COALESCE(SUM(
        CASE WHEN a.activity_type = 'ACTIVITY_TOKEN_DEPOSIT_VAULT'
        THEN a.liquidity_amount::NUMERIC / POWER(10, COALESCE(t_normal.token_decimals, a.token1_decimals, 6))
        END
    ), 0) AS deposit_vault_sum,

    COUNT(
        CASE WHEN a.activity_type = 'ACTIVITY_TOKEN_DEPOSIT_VAULT' THEN 1 END
    ) AS deposit_vault_count,

    -- WITHDRAW VAULT activities
    COALESCE(SUM(
        CASE WHEN a.activity_type = 'ACTIVITY_TOKEN_WITHDRAW_VAULT'
        THEN a.liquidity_amount::NUMERIC / POWER(10, COALESCE(t_normal.token_decimals, a.token1_decimals, 6))
        END
    ), 0) AS withdraw_vault_sum,

    COUNT(
        CASE WHEN a.activity_type = 'ACTIVITY_TOKEN_WITHDRAW_VAULT' THEN 1 END
    ) AS withdraw_vault_count,

    -- BORROWING activities
    COALESCE(SUM(
        CASE WHEN a.activity_type = 'ACTIVITY_BORROWING'
        THEN a.liquidity_amount::NUMERIC / POWER(10, COALESCE(t_normal.token_decimals, a.token1_decimals, 6))
        END
    ), 0) AS borrowing_sum,

    COUNT(
        CASE WHEN a.activity_type = 'ACTIVITY_BORROWING' THEN 1 END
    ) AS borrowing_count,

    -- REPAY BORROWING activities
    COALESCE(SUM(
        CASE WHEN a.activity_type = 'ACTIVITY_REPAY_BORROWING'
        THEN a.liquidity_amount::NUMERIC / POWER(10, COALESCE(t_normal.token_decimals, a.token1_decimals, 6))
        END
    ), 0) AS repay_borrowing_sum,

    COUNT(
        CASE WHEN a.activity_type = 'ACTIVITY_REPAY_BORROWING' THEN 1 END
    ) AS repay_borrowing_count,

    -- LIQUIDATE BORROWING activities (uses t_liq decimals - the debt token being repaid)
    COALESCE(SUM(
        CASE WHEN a.activity_type = 'ACTIVITY_LIQUIDATE_BORROWING'
        THEN a.liquidity_amount::NUMERIC / POWER(10, COALESCE(t_liq.token_decimals, 6))
        END
    ), 0) AS liquidate_borrowing_sum,

    COUNT(
        CASE WHEN a.activity_type = 'ACTIVITY_LIQUIDATE_BORROWING' THEN 1 END
    ) AS liquidate_borrowing_count,

    -- Total activity metrics (across all types)
    COUNT(*) AS total_activity_count,
    COALESCE(SUM(
        a.liquidity_amount::NUMERIC / POWER(10,
            CASE WHEN a.activity_type = 'ACTIVITY_LIQUIDATE_BORROWING'
                 THEN COALESCE(t_liq.token_decimals, 6)
                 ELSE COALESCE(t_normal.token_decimals, a.token1_decimals, 6)
            END
        )
    ), 0) AS total_volume

FROM kamino_lend.src_txn_events a
-- Join for non-liquidation activities (token1_address = token_mint)
LEFT JOIN kamino_lend.aux_market_reserve_tokens t_normal
    ON a.token1_address = t_normal.token_mint
-- Join for liquidation activities (repay_reserve_address = reserve_address)
-- This correctly attributes liquidations to the DEBT reserve being repaid
LEFT JOIN kamino_lend.aux_market_reserve_tokens t_liq
    ON a.repay_reserve_address = t_liq.reserve_address
WHERE a.meta_block_time IS NOT NULL  -- Filter out rows without time
  AND a.activity_type IS NOT NULL    -- Only rows with activity classification
GROUP BY
    time_bucket('5 seconds', a.meta_block_time),
    a.activity_type,
    a.token1_address,
    a.token1_decimals,
    a.reserve_address,
    a.repay_reserve_address,
    a.lending_market_address,
    t_normal.token_symbol,
    t_normal.token_decimals,
    t_normal.reserve_address,
    t_normal.market_address,
    t_normal.token_mint,
    t_liq.token_symbol,
    t_liq.token_decimals,
    t_liq.reserve_address,
    t_liq.market_address,
    t_liq.token_mint
WITH NO DATA;


-- Create indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_cagg_activities_5s_bucket
    ON kamino_lend.cagg_activities_5s (bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_activities_5s_token
    ON kamino_lend.cagg_activities_5s (token_mint, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_activities_5s_symbol
    ON kamino_lend.cagg_activities_5s (symbol, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_activities_5s_reserve
    ON kamino_lend.cagg_activities_5s (reserve_address, bucket DESC);

-- Add view comment (TimescaleDB CAGGs appear as views, not materialized views)
COMMENT ON VIEW kamino_lend.cagg_activities_5s IS
'5-second continuous aggregate of market activities in FLAT format (one row per token per bucket).
Sources from src_txn_events (unified GRPC + migrated Solscan data).
Uses meta_block_time as canonical time for bucketing.
Dynamically handles any number of reserves without schema changes.

STRUCTURE:
- Flat table: Each row represents one token/reserve at one time bucket
- Dynamic: Automatically includes new reserves as they are added
- Activity types remain as columns (deposit, withdraw, borrow, repay, liquidate)
- No hardcoded token mint addresses in the query

DATA SOURCE:
- src_txn_events table (unified GRPC + MIGRATED_FROM_SOLSCAN data)
- Uses liquidity_amount (BIGINT) for volume calculations

LIQUIDATION ATTRIBUTION (FIX 2025-12-28):
- Liquidations are attributed to the DEBT reserve being repaid, not the collateral seized
- Uses repay_reserve_address -> aux_market_reserve_tokens.reserve_address for liquidations
- Uses token1_address -> aux_market_reserve_tokens.token_mint for other activities
- This ensures liquidation metrics appear under borrow reserves (USX, USDC) not collateral (eUSX)

SCALING APPLIED:
- All token amounts are human-readable (decimal-adjusted)
- Uses token_decimals from aux_market_reserve_tokens when available
- Falls back to token1_decimals from src_txn_events if not found
- Default decimals: 6 (for stablecoins)

COLUMNS:
- bucket: 5-second time bucket (TIMESTAMPTZ)
- token_mint: SPL token mint address (debt token for liquidations, liquidity token for others)
- symbol: Token symbol (e.g., USX, eUSX, USDC, PT-eUSX)
- decimals: Token decimals (for reference)
- reserve_address: Associated reserve public key (debt reserve for liquidations)
- market_address: Parent lending market
- deposit_vault_sum: Total deposit volume in token units
- deposit_vault_count: Number of deposit transactions
- withdraw_vault_sum: Total withdraw volume in token units
- withdraw_vault_count: Number of withdraw transactions
- borrowing_sum: Total borrow volume in token units
- borrowing_count: Number of borrow transactions
- repay_borrowing_sum: Total repay volume in token units
- repay_borrowing_count: Number of repay transactions
- liquidate_borrowing_sum: Total liquidation volume in DEBT token units (not collateral)
- liquidate_borrowing_count: Number of liquidation transactions
- total_activity_count: Total number of activities across all types
- total_volume: Total volume across all activity types in token units

USAGE:
-- Get latest activity metrics for all tokens
SELECT * FROM kamino_lend.cagg_activities_5s
WHERE bucket >= NOW() - INTERVAL ''1 hour''
ORDER BY bucket DESC, symbol;

-- Get time series for specific token
SELECT * FROM kamino_lend.cagg_activities_5s
WHERE symbol = ''USX''
  AND bucket >= NOW() - INTERVAL ''24 hours''
ORDER BY bucket DESC;

-- Compare deposit vs withdraw activity
SELECT
    bucket,
    symbol,
    deposit_vault_sum,
    withdraw_vault_sum,
    (deposit_vault_sum - withdraw_vault_sum) as net_flow
FROM kamino_lend.cagg_activities_5s
WHERE bucket >= NOW() - INTERVAL ''1 hour''
ORDER BY bucket DESC, symbol;

-- Aggregate activity by token (liquidations now correctly attributed to debt token)
SELECT
    symbol,
    SUM(deposit_vault_count) as total_deposits,
    SUM(withdraw_vault_count) as total_withdraws,
    SUM(borrowing_count) as total_borrows,
    SUM(repay_borrowing_count) as total_repays,
    SUM(liquidate_borrowing_count) as total_liquidations,
    SUM(total_volume) as total_volume
FROM kamino_lend.cagg_activities_5s
WHERE bucket >= NOW() - INTERVAL ''24 hours''
GROUP BY symbol
ORDER BY total_volume DESC;';

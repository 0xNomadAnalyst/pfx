-- Continuous Aggregate: 5-second time buckets for Exponent economic events
-- Aggregates flows at three distinct layers:
--   1. Base ↔ SY Layer (wrapper operations: mint_sy/redeem_sy) - partitioned by base_escrow_address/sy_meta_address
--   2. SY ↔ Vault PT/YT Layer (core flows: strip/merge) - partitioned by vault_address
--   3. PT ↔ SY AMM Layer (trading + liquidity) - partitioned by market_address
-- Source: src_tx_events (gRPC stream data)
--
-- Layer 1: Base ↔ SY (Wrapper Operations)
--   - mint_sy: Base → SY (base_in, sy_out)
--   - redeem_sy: SY → Base (sy_in, base_out)
--   Partitioned by: base_escrow_address, sy_meta_address
--
-- Layer 2: SY ↔ Vault PT/YT (Core Flows)
--   - strip: SY → PT+YT (sy_in, pt_out)
--   - merge: PT+YT → SY (pt_in, sy_out)
--   Partitioned by: vault_address
--
-- Layer 3: PT ↔ SY AMM (Trading + Liquidity)
--   - trade_pt: PT ↔ SY swaps on AMM (pt_in/out, sy_in/out)
--   - deposit_liquidity: PT + SY → LP tokens (lp_pt_in, lp_sy_in, lp_out)
--   - withdraw_liquidity: LP tokens → PT + SY (lp_in, lp_pt_out, lp_sy_out)
--   Partitioned by: market_address
--
-- AMM Trade Data Handling:
--   PT flows use coalesce priority: amm_pt_vault_delta, amm_pt_vault_delta_from_transfers, -1*trader_pt_delta, -1*net_trader_pt
--   SY flows use coalesce priority: -1*trader_sy_delta_from_transfers, -1*sy_constraint
--   All flows are from protocol's perspective (positive = inflow to protocol, negative = outflow)
--
-- LP Liquidity Data Handling:
--   PT/SY flows use coalesce priority: dedicated column, event_data JSONB, instruction_params JSONB (intent)
--   LP token flows use coalesce priority: dedicated column, event_data JSONB, instruction_params JSONB
--   Note: Realized flows (event_data) may be empty for CPI calls; intent values used as fallback

-- Drop existing CAGG if recreating
DROP MATERIALIZED VIEW IF EXISTS exponent.cagg_tx_events_5s CASCADE;

CREATE MATERIALIZED VIEW IF NOT EXISTS exponent.cagg_tx_events_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5 second intervals)
    time_bucket('5 seconds'::interval, s.meta_block_time) AS bucket_time,

    -- Partition dimensions (layer-specific)
    s.vault_address,  -- For Layer 2: SY ↔ Vault PT/YT flows
    s.market_address,  -- For Layer 3: PT ↔ SY AMM trading
    s.sy_meta_address,  -- For Layer 1: Base ↔ SY wrapper operations
    s.base_escrow_address,  -- For Layer 1: Base ↔ SY wrapper operations

    -- Metadata
    MAX(akr.env_sy_symbol) AS sy_symbol,
    MAX(COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)) AS sy_decimals,  -- Default to 6 if not found
    MAX(COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6)) AS pt_decimals,  -- PT typically same decimals as SY

    -- Event classification
    s.event_category,
    s.event_type,

    -- Event counts
    COUNT(*) AS event_count,

    -- Trade-specific count (for PT swap counting)
    SUM(CASE WHEN s.event_type = 'trade_pt' THEN 1 ELSE 0 END) AS trade_pt_count,

    -- Exchange rates (latest in bucket)
    MAX(s.sy_exchange_rate) AS sy_exchange_rate,

    -- ============================================================================
    -- LAYER 1: BASE ↔ SY FLOWS (Wrapper Operations: mint_sy/redeem_sy)
    -- ============================================================================
    -- Partitioned by: base_escrow_address, sy_meta_address
    -- Base IN: Base asset deposited (mint_sy) - DIRECT VALUES ONLY (no conversions)
    -- Base OUT: Base asset withdrawn (redeem_sy) - DIRECT VALUES ONLY (no conversions)
    -- SY IN: SY burned/redeemed (redeem_sy) - DIRECT VALUES ONLY (no conversions)
    -- SY OUT: SY minted (mint_sy) - DIRECT VALUES ONLY (no conversions)
    --
    -- Note: Complementary flows (derived via exchange_rate conversions) are NOT calculated here.
    --       Only direct values from return data are included.

    SUM(
        CASE
            -- mint_sy: Use amount_base_in column if populated (from database.py calculation)
            -- Note: This is kept for backward compatibility, but ideally should be NULL
            --       as we're not deriving complementary flows at this layer
            WHEN s.event_type = 'mint_sy' AND s.amount_base_in IS NOT NULL
                THEN CAST(s.amount_base_in AS NUMERIC) / POWER(10, COALESCE(akr.meta_base_decimals, akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            ELSE 0
        END
    ) AS amount_base_in,  -- Base asset deposited to wrapper (direct value only, no conversion)

    SUM(
        CASE
            -- redeem_sy: base_out_amount is already in base units (from RedeemSyReturnData)
            WHEN s.event_type = 'redeem_sy' AND s.amount_base_out IS NOT NULL
                THEN CAST(s.amount_base_out AS NUMERIC) / POWER(10, COALESCE(akr.meta_base_decimals, akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            -- Fallback: Extract from event_data if column not populated
            WHEN s.event_type = 'redeem_sy' AND (s.event_data->>'base_out_amount') IS NOT NULL
                THEN CAST(s.event_data->>'base_out_amount' AS NUMERIC) / POWER(10, COALESCE(akr.meta_base_decimals, akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            ELSE 0
        END
    ) AS amount_base_out,  -- Base asset withdrawn from wrapper (direct value only)

    SUM(
        CASE
            -- redeem_sy: Use instruction_params amount (raw SY units) - DIRECT VALUE ONLY
            -- Note: We're NOT calculating sy_in from base_out/exchange_rate
            WHEN s.event_type = 'redeem_sy' AND (s.instruction_params->>'amount') IS NOT NULL
                THEN CAST(s.instruction_params->>'amount' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            ELSE 0
        END
    ) AS amount_wrapper_sy_in,  -- SY redeemed/burned (SY → Base) - direct value only, no conversion

    SUM(
        CASE
            -- mint_sy: Use amount_sy_out column (raw u64 value from MintSyReturnData.sy_out_amount)
            WHEN s.event_type = 'mint_sy' AND s.amount_sy_out IS NOT NULL
                THEN CAST(s.amount_sy_out AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            -- Fallback: Extract from event_data if column not populated
            WHEN s.event_type = 'mint_sy' AND (s.event_data->>'sy_out_amount') IS NOT NULL
                THEN CAST(s.event_data->>'sy_out_amount' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            ELSE 0
        END
    ) AS amount_wrapper_sy_out,  -- SY minted (Base → SY) - direct value only, no conversion

    -- ============================================================================
    -- LAYER 2: SY ↔ VAULT PT/YT FLOWS (Core Flows: strip/merge)
    -- ============================================================================
    -- Partitioned by: vault_address
    -- SY IN: SY deposited to vault (strip)
    -- SY OUT: SY withdrawn from vault (merge)
    -- PT IN: PT burned (merge)
    -- PT OUT: PT minted (strip)

    SUM(
        CASE
            -- Use column if populated (preferred)
            WHEN s.amount_vault_sy_in IS NOT NULL
                THEN CAST(s.amount_vault_sy_in AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            -- Fallback: Extract from instruction_params
            WHEN s.event_type = 'strip' AND (s.instruction_params->>'amount') IS NOT NULL
                THEN CAST(s.instruction_params->>'amount' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            ELSE 0
        END
    ) AS amount_vault_sy_in,  -- SY deposited to vault (strip: SY → PT+YT)

    SUM(
        CASE
            -- Use column if populated (preferred)
            WHEN s.amount_vault_sy_out IS NOT NULL
                THEN CAST(s.amount_vault_sy_out AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            -- Fallback: Extract from instruction_params
            WHEN s.event_type = 'merge' AND (s.instruction_params->>'amount') IS NOT NULL
                THEN CAST(s.instruction_params->>'amount' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6))
            ELSE 0
        END
    ) AS amount_vault_sy_out,  -- SY withdrawn from vault (merge: PT+YT → SY)

    SUM(
        CASE
            -- Use column if populated (preferred)
            WHEN s.amount_vault_pt_in IS NOT NULL
                THEN CAST(s.amount_vault_pt_in AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6))
            -- Fallback: Extract from instruction_params
            WHEN s.event_type = 'merge' AND (s.instruction_params->>'amount') IS NOT NULL
                THEN CAST(s.instruction_params->>'amount' AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6))
            ELSE 0
        END
    ) AS amount_vault_pt_in,  -- PT burned (merge: PT+YT → SY)

    SUM(
        CASE
            -- Use column if populated (preferred)
            WHEN s.amount_vault_pt_out IS NOT NULL
                THEN CAST(s.amount_vault_pt_out AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6))
            -- Fallback: Extract from instruction_params
            WHEN s.event_type = 'strip' AND (s.instruction_params->>'amount') IS NOT NULL
                THEN CAST(s.instruction_params->>'amount' AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6))
            ELSE 0
        END
    ) AS amount_vault_pt_out,  -- PT minted (strip: SY → PT+YT)

    -- ============================================================================
    -- LAYER 3: PT ↔ SY AMM FLOWS (Trading: trade_pt)
    -- ============================================================================
    -- Partitioned by: market_address
    -- PT IN: PT sold to AMM pool (trader selling PT)
    -- PT OUT: PT bought from AMM pool (trader buying PT)
    -- SY IN: SY sold to AMM pool (trader selling SY)
    -- SY OUT: SY bought from AMM pool (trader buying SY)

    -- PT flows use coalesce priority: amm_pt_vault_delta, amm_pt_vault_delta_from_transfers, -1*trader_pt_delta, -1*net_trader_pt
    -- Note: All these fields are already decimal-adjusted (NUMERIC type)
    -- PT IN: Positive delta = PT inflow to pool (trader selling PT)
    -- PT OUT: Negative delta = PT outflow from pool (trader buying PT)
    -- We use the sign of the delta to determine direction, not mirror values
    SUM(
        CASE
            WHEN s.event_type = 'trade_pt'
                THEN COALESCE(
                    CASE WHEN s.amm_pt_vault_delta > 0 THEN s.amm_pt_vault_delta ELSE NULL END,  -- Positive = PT IN
                    CASE WHEN s.amm_pt_vault_delta_from_transfers > 0 THEN s.amm_pt_vault_delta_from_transfers ELSE NULL END,  -- Positive = PT IN
                    CASE WHEN s.trader_pt_delta < 0 THEN -1 * s.trader_pt_delta ELSE NULL END,  -- Negative trader = positive protocol (PT IN)
                    CASE WHEN s.net_trader_pt < 0 THEN -1 * s.net_trader_pt ELSE NULL END,  -- Negative trader = positive protocol (PT IN)
                    0
                )
            ELSE 0
        END
    ) AS amount_amm_pt_in,  -- PT sold to AMM pool (trader selling PT for SY)

    SUM(
        CASE
            WHEN s.event_type = 'trade_pt'
                THEN COALESCE(
                    CASE WHEN s.amm_pt_vault_delta < 0 THEN ABS(s.amm_pt_vault_delta) ELSE NULL END,  -- Negative = PT OUT (take absolute)
                    CASE WHEN s.amm_pt_vault_delta_from_transfers < 0 THEN ABS(s.amm_pt_vault_delta_from_transfers) ELSE NULL END,  -- Negative = PT OUT (take absolute)
                    CASE WHEN s.trader_pt_delta > 0 THEN s.trader_pt_delta ELSE NULL END,  -- Positive trader = protocol selling (PT OUT)
                    CASE WHEN s.net_trader_pt > 0 THEN s.net_trader_pt ELSE NULL END,  -- Positive trader = protocol selling (PT OUT)
                    0
                )
            ELSE 0
        END
    ) AS amount_amm_pt_out,  -- PT bought from AMM pool (trader buying PT with SY)

    -- SY flows use coalesce priority: -1*trader_sy_delta_from_transfers, -1*sy_constraint
    -- Note: Both fields are already decimal-adjusted (NUMERIC type)
    -- SY IN: Negative trader delta = SY paid to AMM (protocol receives SY)
    -- SY OUT: Positive trader delta = SY received from AMM (protocol pays SY)
    -- We use the sign of the delta to determine direction, not mirror values
    SUM(
        CASE
            WHEN s.event_type = 'trade_pt'
                THEN COALESCE(
                    CASE WHEN s.trader_sy_delta_from_transfers < 0 THEN -1 * s.trader_sy_delta_from_transfers ELSE NULL END,  -- Negative trader = positive protocol (SY IN)
                    CASE WHEN s.sy_constraint < 0 THEN -1 * s.sy_constraint ELSE NULL END,  -- Negative constraint = positive protocol (SY IN)
                    0
                )
            ELSE 0
        END
    ) AS amount_amm_sy_in,  -- SY sold to AMM pool (trader selling SY for PT)

    SUM(
        CASE
            WHEN s.event_type = 'trade_pt'
                THEN COALESCE(
                    CASE WHEN s.trader_sy_delta_from_transfers > 0 THEN s.trader_sy_delta_from_transfers ELSE NULL END,  -- Positive trader = protocol paying (SY OUT)
                    CASE WHEN s.sy_constraint > 0 THEN s.sy_constraint ELSE NULL END,  -- Positive constraint = protocol paying (SY OUT)
                    0
                )
            ELSE 0
        END
    ) AS amount_amm_sy_out,  -- SY bought from AMM pool (trader buying SY with PT)

    -- ============================================================================
    -- LAYER 3 (continued): LP LIQUIDITY FLOWS (deposit_liquidity/withdraw_liquidity)
    -- ============================================================================
    -- Partitioned by: market_address
    -- These flows represent liquidity provision/withdrawal affecting AMM pool reserves
    -- Different from trading: LPs add/remove both PT and SY simultaneously
    --
    -- deposit_liquidity: PT + SY → LP tokens
    --   - LP provides PT and SY to the pool
    --   - Receives LP tokens representing pool share
    --
    -- withdraw_liquidity: LP tokens → PT + SY
    --   - LP burns LP tokens
    --   - Receives PT and SY from the pool
    --
    -- Data source priority (COALESCE):
    --   1. Dedicated columns (amount_lp_pt_in, etc.) - populated from event_data when available
    --   2. event_data JSONB (pt_in, sy_in, etc.) - realized flows from DepositLiquidityEvent/WithdrawLiquidityEvent
    --   3. instruction_params JSONB (pt_intent, sy_intent, lp_in) - intent values as fallback
    -- Note: For CPI calls, event_data is often empty; intent values provide best available data

    -- LP Event Counts (for distinguishing LP activity from trading)
    SUM(
        CASE
            WHEN s.event_type IN ('market_two_deposit_liquidity', 'deposit_liquidity') THEN 1
            ELSE 0
        END
    ) AS lp_deposit_count,  -- Number of liquidity deposits in bucket

    SUM(
        CASE
            WHEN s.event_type IN ('market_two_withdraw_liquidity', 'withdraw_liquidity') THEN 1
            ELSE 0
        END
    ) AS lp_withdraw_count,  -- Number of liquidity withdrawals in bucket

    -- PT deposited to AMM pool (deposit_liquidity)
    -- Priority: event_data column > AMM vault balance delta > event_data JSONB > instruction_params (intent)
    SUM(
        CASE
            WHEN s.event_type IN ('market_two_deposit_liquidity', 'deposit_liquidity')
                THEN COALESCE(
                    -- 1. Dedicated column (realized flow from event_data)
                    CAST(s.amount_lp_pt_in AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6)),
                    -- 2. AMM PT vault balance delta (definitive when available, positive = inflow)
                    CASE WHEN s.amm_pt_vault_delta > 0 THEN s.amm_pt_vault_delta ELSE NULL END,
                    -- 3. event_data JSONB (realized flow)
                    CAST(s.event_data->>'pt_in' AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6)),
                    -- 4. instruction_params (intent - may differ from realized)
                    CAST(s.lp_pt_intent AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6)),
                    CAST(s.instruction_params->>'pt_intent' AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6)),
                    0
                )
            ELSE 0
        END
    ) AS amount_lp_pt_in,  -- PT deposited to pool (deposit_liquidity)

    -- PT withdrawn from AMM pool (withdraw_liquidity)
    -- Priority: event_data column > AMM vault balance delta > event_data JSONB
    -- Note: min_pt_out is slippage protection, not actual amount - only use realized flows
    SUM(
        CASE
            WHEN s.event_type IN ('market_two_withdraw_liquidity', 'withdraw_liquidity')
                THEN COALESCE(
                    -- 1. Dedicated column (realized flow from event_data)
                    CAST(s.amount_lp_pt_out AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6)),
                    -- 2. AMM PT vault balance delta (definitive when available, negative = outflow, take absolute)
                    CASE WHEN s.amm_pt_vault_delta < 0 THEN ABS(s.amm_pt_vault_delta) ELSE NULL END,
                    -- 3. event_data JSONB (realized flow)
                    CAST(s.event_data->>'pt_out' AS NUMERIC) / POWER(10, COALESCE(akr.meta_pt_decimals, akr.env_sy_decimals, 6)),
                    -- Note: NOT using min_pt_out as fallback - it's slippage protection, not actual flow
                    0
                )
            ELSE 0
        END
    ) AS amount_lp_pt_out,  -- PT withdrawn from pool (withdraw_liquidity)

    -- SY deposited to AMM pool (deposit_liquidity)
    -- Priority: event_data column > AMM SY vault balance delta > event_data JSONB > instruction_params (intent)
    -- Note: sy_intent of max u64 means "use all available" - filter these out
    SUM(
        CASE
            WHEN s.event_type IN ('market_two_deposit_liquidity', 'deposit_liquidity')
                THEN COALESCE(
                    -- 1. Dedicated column (realized flow from event_data)
                    CAST(s.amount_lp_sy_in AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)),
                    -- 2. AMM SY vault balance delta (definitive when available, positive = inflow)
                    CASE WHEN s.amm_sy_vault_delta > 0 THEN s.amm_sy_vault_delta ELSE NULL END,
                    -- 3. event_data JSONB (realized flow)
                    CAST(s.event_data->>'sy_in' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)),
                    -- 4. instruction_params (intent) - exclude max u64 (18446744073709551615 = "use all")
                    CASE
                        WHEN s.lp_sy_intent IS NOT NULL AND s.lp_sy_intent < 18446744073709551615
                        THEN CAST(s.lp_sy_intent AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6))
                        WHEN (s.instruction_params->>'sy_intent') IS NOT NULL
                             AND CAST(s.instruction_params->>'sy_intent' AS NUMERIC) < 18446744073709551615
                        THEN CAST(s.instruction_params->>'sy_intent' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6))
                        ELSE NULL
                    END,
                    0
                )
            ELSE 0
        END
    ) AS amount_lp_sy_in,  -- SY deposited to pool (deposit_liquidity)

    -- SY withdrawn from AMM pool (withdraw_liquidity)
    -- Priority: event_data column > AMM SY vault balance delta > event_data JSONB
    -- Note: min_sy_out is slippage protection, not actual amount - only use realized flows
    SUM(
        CASE
            WHEN s.event_type IN ('market_two_withdraw_liquidity', 'withdraw_liquidity')
                THEN COALESCE(
                    -- 1. Dedicated column (realized flow from event_data)
                    CAST(s.amount_lp_sy_out AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)),
                    -- 2. AMM SY vault balance delta (definitive when available, negative = outflow, take absolute)
                    CASE WHEN s.amm_sy_vault_delta < 0 THEN ABS(s.amm_sy_vault_delta) ELSE NULL END,
                    -- 3. event_data JSONB (realized flow)
                    CAST(s.event_data->>'sy_out' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)),
                    -- Note: NOT using min_sy_out as fallback - it's slippage protection, not actual flow
                    0
                )
            ELSE 0
        END
    ) AS amount_lp_sy_out,  -- SY withdrawn from pool (withdraw_liquidity)

    -- LP tokens minted (deposit_liquidity)
    -- Priority: dedicated column > event_data
    SUM(
        CASE
            WHEN s.event_type IN ('market_two_deposit_liquidity', 'deposit_liquidity')
                THEN COALESCE(
                    -- 1. Dedicated column (realized flow from event_data)
                    CAST(s.amount_lp_out AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)),
                    -- 2. event_data JSONB (realized flow)
                    CAST(s.event_data->>'lp_out' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)),
                    -- Note: min_lp_out is slippage protection, not actual minted amount
                    0
                )
            ELSE 0
        END
    ) AS amount_lp_tokens_out,  -- LP tokens minted (deposit_liquidity)

    -- LP tokens burned (withdraw_liquidity)
    -- Priority: dedicated column > event_data > instruction_params
    SUM(
        CASE
            WHEN s.event_type IN ('market_two_withdraw_liquidity', 'withdraw_liquidity')
                THEN COALESCE(
                    -- 1. Dedicated column (from event_data or instruction_params)
                    CAST(s.amount_lp_in AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)),
                    -- 2. event_data JSONB
                    CAST(s.event_data->>'lp_in' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)),
                    -- 3. instruction_params (this IS the actual input amount, not a constraint)
                    CAST(s.instruction_params->>'lp_in' AS NUMERIC) / POWER(10, COALESCE(akr.meta_sy_decimals, akr.env_sy_decimals, 6)),
                    0
                )
            ELSE 0
        END
    ) AS amount_lp_tokens_in  -- LP tokens burned (withdraw_liquidity)

FROM exponent.src_tx_events s
LEFT JOIN exponent.aux_key_relations akr ON s.vault_address = akr.vault_address
WHERE
    -- Filter to economic events of interest
    s.event_type IN (
        'strip', 'merge',  -- Layer 2: Core flows
        'trade_pt',  -- Layer 3: AMM trading
        'market_two_deposit_liquidity', 'deposit_liquidity',  -- Layer 3: LP deposits
        'market_two_withdraw_liquidity', 'withdraw_liquidity',  -- Layer 3: LP withdrawals
        'mint_sy', 'redeem_sy'  -- Layer 1: Wrapper operations
    )
    AND s.event_category IN ('core_flow', 'pt_trading', 'liquidity', 'wrapper')
    AND s.meta_block_time IS NOT NULL
    AND s.meta_success = TRUE  -- Only successful transactions

GROUP BY
    time_bucket('5 seconds'::interval, s.meta_block_time),
    s.vault_address,
    s.market_address,
    s.sy_meta_address,
    s.base_escrow_address,
    s.event_category,
    s.event_type

ORDER BY time_bucket('5 seconds'::interval, s.meta_block_time) DESC;

-- Create indexes on the materialized view for better query performance
CREATE INDEX IF NOT EXISTS idx_cagg_tx_events_5s_bucket_time
    ON exponent.cagg_tx_events_5s (bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_tx_events_5s_vault
    ON exponent.cagg_tx_events_5s (vault_address, bucket_time DESC)
    WHERE vault_address IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cagg_tx_events_5s_market
    ON exponent.cagg_tx_events_5s (market_address, bucket_time DESC)
    WHERE market_address IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cagg_tx_events_5s_sy_meta
    ON exponent.cagg_tx_events_5s (sy_meta_address, bucket_time DESC)
    WHERE sy_meta_address IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cagg_tx_events_5s_base_escrow
    ON exponent.cagg_tx_events_5s (base_escrow_address, bucket_time DESC)
    WHERE base_escrow_address IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cagg_tx_events_5s_event_category
    ON exponent.cagg_tx_events_5s (event_category, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_tx_events_5s_event_type
    ON exponent.cagg_tx_events_5s (event_type, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_tx_events_5s_vault_category
    ON exponent.cagg_tx_events_5s (vault_address, event_category, bucket_time DESC)
    WHERE vault_address IS NOT NULL;

-- Note: No automatic refresh policy - refresh manually via cronjob
-- See: cronjobs/cagg_refresh/railway_cagg_refresh.sh

-- Example queries:

-- Layer 1: Base ↔ SY wrapper operations (partitioned by base_escrow_address/sy_meta_address)
-- SELECT
--     bucket_time,
--     base_escrow_address,
--     sy_meta_address,
--     sy_symbol,
--     event_type,
--     event_count,
--     amount_base_in,
--     amount_base_out,
--     amount_wrapper_sy_in,
--     amount_wrapper_sy_out,
--     sy_exchange_rate
-- FROM exponent.cagg_tx_events_5s
-- WHERE base_escrow_address IS NOT NULL
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- Layer 2: SY ↔ Vault PT/YT flows (partitioned by vault_address)
-- SELECT
--     bucket_time,
--     vault_address,
--     sy_symbol,
--     event_type,
--     event_count,
--     amount_vault_sy_in,
--     amount_vault_sy_out,
--     amount_vault_pt_in,
--     amount_vault_pt_out,
--     sy_exchange_rate
-- FROM exponent.cagg_tx_events_5s
-- WHERE vault_address IS NOT NULL
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- Layer 3: PT ↔ SY AMM trading (partitioned by market_address)
-- SELECT
--     bucket_time,
--     market_address,
--     sy_symbol,
--     event_count,
--     amount_amm_pt_in,
--     amount_amm_pt_out,
--     amount_amm_sy_in,
--     amount_amm_sy_out,
--     sy_exchange_rate
-- FROM exponent.cagg_tx_events_5s
-- WHERE event_type = 'trade_pt'
--     AND market_address IS NOT NULL
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- Layer 3: LP liquidity flows (partitioned by market_address)
-- SELECT
--     bucket_time,
--     market_address,
--     sy_symbol,
--     event_type,
--     lp_deposit_count,
--     lp_withdraw_count,
--     amount_lp_pt_in,
--     amount_lp_pt_out,
--     amount_lp_sy_in,
--     amount_lp_sy_out,
--     amount_lp_tokens_out,  -- LP tokens minted (deposits)
--     amount_lp_tokens_in    -- LP tokens burned (withdrawals)
-- FROM exponent.cagg_tx_events_5s
-- WHERE event_type IN ('market_two_deposit_liquidity', 'deposit_liquidity',
--                      'market_two_withdraw_liquidity', 'withdraw_liquidity')
--     AND market_address IS NOT NULL
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- Combined AMM activity (trading + liquidity) for a market
-- SELECT
--     bucket_time,
--     market_address,
--     sy_symbol,
--     event_type,
--     event_count,
--     -- Trading flows
--     amount_amm_pt_in,
--     amount_amm_pt_out,
--     amount_amm_sy_in,
--     amount_amm_sy_out,
--     -- LP flows
--     lp_deposit_count,
--     lp_withdraw_count,
--     amount_lp_pt_in,
--     amount_lp_pt_out,
--     amount_lp_sy_in,
--     amount_lp_sy_out,
--     amount_lp_tokens_out,
--     amount_lp_tokens_in
-- FROM exponent.cagg_tx_events_5s
-- WHERE market_address = '<market_address>'
--     AND event_category IN ('pt_trading', 'liquidity')
-- ORDER BY bucket_time DESC
-- LIMIT 50;

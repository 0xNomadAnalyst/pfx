-- Exponent Key Account Relationships
-- Maps vault → market → YT escrow → SY meta → SY token → mints relationships for easy lookup
-- This is needed for continuous aggregates which don't support CTEs or subqueries
-- Dynamically populated from src_vaults, src_market_twos, src_vault_yield_position, src_vault_yt_escrow, 
-- src_sy_meta_account, src_sy_token_account, and src_base_token_escrow tables
--
-- Complete relationship graph per vault:
--   vault_address (core)
--     ├── market_address (AMM for PT/SY trading)
--     ├── yield_position_address (YieldTokenPosition - vault robot YT position tracking)
--     ├── vault_yt_escrow_address (SPL Token Account - holds YT tokens for user deposits)
--     ├── sy_meta_address (SY metadata & exchange rates)
--     ├── sy_token_address (SY token mint for supply tracking)
--     ├── underlying_escrow_address (SPL Token Account - holds backing assets)
--     ├── mint_sy, mint_pt, mint_yt, mint_lp (token mints)
--     └── sy_interface_type, sy_yield_bearing_mint (protocol info)

CREATE TABLE IF NOT EXISTS exponent.aux_key_relations (
    -- Account addresses
    vault_address TEXT NOT NULL PRIMARY KEY,
    market_address TEXT NOT NULL,
    yield_position_address TEXT,  -- YieldTokenPosition account (vault.yield_position field - tracks YT position state)
    vault_yt_escrow_address TEXT,  -- Vault YT escrow SPL Token Account (vault.escrow_yt field - holds YT tokens)
    sy_meta_address TEXT,  -- SyMeta (from generic_wrap program - metadata/config)
    sy_token_address TEXT,  -- SY token mint address (same as mint_sy - for clarity)
    underlying_escrow_address TEXT,  -- Underlying token escrow (ATA holding backing assets)
    
    -- Token mints (all PDAs derived from vault)
    mint_sy TEXT NOT NULL,  -- Underlying (e.g., fragSOL)
    mint_pt TEXT NOT NULL,  -- Principal Token
    mint_yt TEXT NOT NULL,  -- Yield Token
    mint_lp TEXT,  -- LP Token (from market)
    
    -- Token metadata (from config/environment, prefixed with env_)
    env_sy_symbol TEXT,  -- Underlying token symbol (e.g., "fragSOL", "eUSX")
    env_sy_decimals SMALLINT,  -- Token decimals (9 for SOL-based, 6 for USDC-based)
    env_sy_type TEXT,  -- Token type (e.g., "yield_bearing")
    env_sy_lifetime_apy_start_date DATE,  -- Config override: lifetime APY baseline date
    env_sy_lifetime_apy_start_index DOUBLE PRECISION,  -- Config override: lifetime APY baseline index
    
    -- Token metadata (from on-chain discovery, prefixed with meta_)
    -- SY token metadata
    meta_sy_symbol TEXT,  -- SY token symbol from on-chain metadata
    meta_sy_name TEXT,  -- SY token name from on-chain metadata
    meta_sy_decimals SMALLINT,  -- SY token decimals from on-chain metadata
    -- PT token metadata
    meta_pt_symbol TEXT,  -- PT token symbol from on-chain metadata
    meta_pt_name TEXT,  -- PT token name from on-chain metadata
    meta_pt_decimals SMALLINT,  -- PT token decimals from on-chain metadata
    -- YT token metadata
    meta_yt_symbol TEXT,  -- YT token symbol from on-chain metadata
    meta_yt_name TEXT,  -- YT token name from on-chain metadata
    meta_yt_decimals SMALLINT,  -- YT token decimals from on-chain metadata
    -- LP token metadata
    meta_lp_symbol TEXT,  -- LP token symbol from on-chain metadata
    meta_lp_name TEXT,  -- LP token name from on-chain metadata
    meta_lp_decimals SMALLINT,  -- LP token decimals from on-chain metadata
    -- Base token metadata (yield_bearing_mint)
    meta_base_symbol TEXT,  -- Base token symbol from on-chain metadata
    meta_base_name TEXT,  -- Base token name from on-chain metadata
    meta_base_decimals SMALLINT,  -- Base token decimals from on-chain metadata
    
    -- SY Program and Protocol Info (from SyMeta)
    sy_program TEXT,  -- SY program address (generic_wrap)
    sy_interface_type TEXT,  -- Protocol type: KaminoVault, JupiterLend, etc.
    sy_yield_bearing_mint TEXT,  -- Underlying yield token (e.g., Kamino kToken)
    
    -- Vault authority (PDA) - derived from vault address
    authority TEXT NOT NULL,
    
    -- PDA derivation metadata
    pda_pattern TEXT DEFAULT 'market_vault',  -- Standard Exponent pattern
    pda_bump SMALLINT,  -- Bump seed for MarketTwo derivation
    
    -- Market metadata
    market_name TEXT,  -- e.g., "fragSOL-31Oct25" (from config)
    maturity_date DATE,  -- Derived from start_ts + duration
    
    -- Vault timing
    start_ts INTEGER,  -- Unix timestamp when vault started
    duration INTEGER,  -- Seconds until maturity
    maturity_ts INTEGER,  -- Calculated: start_ts + duration
    
    -- Status flags
    is_active BOOLEAN DEFAULT TRUE,
    is_expired BOOLEAN DEFAULT FALSE,
    
    -- Config validation flags
    config_vault_matches BOOLEAN,  -- TRUE if vault_address matches config
    config_market_matches BOOLEAN,  -- TRUE if market_address matches config
    
    -- Metadata
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add new columns if they don't exist (for existing tables)
DO $$ 
BEGIN
    -- Add yield_position_address column (renamed from yt_escrow_address)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'yield_position_address'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN yield_position_address TEXT;
        -- Migrate data from old column if it exists
        IF EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'exponent' 
            AND table_name = 'aux_key_relations' 
            AND column_name = 'yt_escrow_address'
        ) THEN
            UPDATE exponent.aux_key_relations 
            SET yield_position_address = yt_escrow_address 
            WHERE yield_position_address IS NULL;
        END IF;
    END IF;
    
    -- Add vault_yt_escrow_address column (renamed from yt_unstaked_token_escrow)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'vault_yt_escrow_address'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN vault_yt_escrow_address TEXT;
        -- Migrate data from old column if it exists
        IF EXISTS (
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'exponent' 
            AND table_name = 'aux_key_relations' 
            AND column_name = 'yt_unstaked_token_escrow'
        ) THEN
            UPDATE exponent.aux_key_relations 
            SET vault_yt_escrow_address = yt_unstaked_token_escrow 
            WHERE vault_yt_escrow_address IS NULL;
        END IF;
    END IF;
    
    -- Add sy_meta_address column
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'sy_meta_address'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN sy_meta_address TEXT;
    END IF;
    
    -- Add sy_token_address column
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'sy_token_address'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN sy_token_address TEXT;
    END IF;
    
    -- Add sy_program column
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'sy_program'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN sy_program TEXT;
    END IF;
    
    -- Add sy_interface_type column
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'sy_interface_type'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN sy_interface_type TEXT;
    END IF;
    
    -- Add sy_yield_bearing_mint column
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'sy_yield_bearing_mint'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN sy_yield_bearing_mint TEXT;
    END IF;

    -- Add env_sy_lifetime_apy_start_date column
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'env_sy_lifetime_apy_start_date'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN env_sy_lifetime_apy_start_date DATE;
    END IF;

    -- Add env_sy_lifetime_apy_start_index column
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'env_sy_lifetime_apy_start_index'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN env_sy_lifetime_apy_start_index DOUBLE PRECISION;
    END IF;
    
    -- Add underlying_escrow_address column
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'underlying_escrow_address'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN underlying_escrow_address TEXT;
    END IF;
    
    -- Add meta_* columns for token metadata from on-chain discovery
    -- SY token metadata
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'meta_sy_symbol'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_sy_symbol TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_sy_name TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_sy_decimals SMALLINT;
    END IF;
    
    -- PT token metadata
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'meta_pt_symbol'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_pt_symbol TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_pt_name TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_pt_decimals SMALLINT;
    END IF;
    
    -- YT token metadata
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'meta_yt_symbol'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_yt_symbol TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_yt_name TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_yt_decimals SMALLINT;
    END IF;
    
    -- LP token metadata
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'meta_lp_symbol'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_lp_symbol TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_lp_name TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_lp_decimals SMALLINT;
    END IF;
    
    -- Base token metadata
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'exponent' 
        AND table_name = 'aux_key_relations' 
        AND column_name = 'meta_base_symbol'
    ) THEN
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_base_symbol TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_base_name TEXT;
        ALTER TABLE exponent.aux_key_relations ADD COLUMN meta_base_decimals SMALLINT;
    END IF;
END $$;

-- Populate from source tables (run this after initial data load)
-- Step 1: Insert/update from latest vaults, markets, yield positions, vault YT escrows, and SY accounts data
INSERT INTO exponent.aux_key_relations (
    vault_address,
    market_address,
    yield_position_address,
    vault_yt_escrow_address,
    sy_meta_address,
    sy_token_address,
    underlying_escrow_address,
    mint_sy,
    mint_pt,
    mint_yt,
    mint_lp,
    env_sy_symbol,
    env_sy_decimals,
    env_sy_type,
    env_sy_lifetime_apy_start_date,
    env_sy_lifetime_apy_start_index,
    sy_program,
    sy_interface_type,
    sy_yield_bearing_mint,
    authority,
    pda_pattern,
    pda_bump,
    market_name,
    maturity_date,
    start_ts,
    duration,
    maturity_ts,
    is_active,
    is_expired,
    config_vault_matches,
    config_market_matches,
    -- Token metadata from on-chain discovery
    meta_sy_symbol,
    meta_sy_name,
    meta_sy_decimals,
    meta_pt_symbol,
    meta_pt_name,
    meta_pt_decimals,
    meta_yt_symbol,
    meta_yt_name,
    meta_yt_decimals,
    meta_lp_symbol,
    meta_lp_name,
    meta_lp_decimals,
    meta_base_symbol,
    meta_base_name,
    meta_base_decimals
)
SELECT DISTINCT ON (v.vault_address)
    v.vault_address,
    m.market_address,
    -- YieldTokenPosition account (vault.yield_position field - tracks YT position state and accrued yield)
    v.yield_position AS yield_position_address,
    -- Vault YT escrow SPL Token Account (vault.escrow_yt field - holds YT tokens deposited by users)
    v.escrow_yt AS vault_yt_escrow_address,
    -- SY meta from latest SY meta data
    sya.sy_meta_address,
    -- SY token mint (same as mint_sy, but explicit for clarity)
    v.mint_sy AS sy_token_address,
    -- Underlying escrow from latest escrow data
    ute.underlying_escrow_address,
    -- Mints
    v.mint_sy,
    v.mint_pt,
    v.mint_yt,
    m.mint_lp,
    -- Token metadata (from vault or market - they should match)
    COALESCE(v.env_sy_symbol, m.env_sy_symbol) AS env_sy_symbol,
    COALESCE(v.env_sy_decimals, m.env_sy_decimals) AS env_sy_decimals,
    COALESCE(v.env_sy_type, m.env_sy_type) AS env_sy_type,
    sya.env_sy_lifetime_apy_start_date,
    sya.env_sy_lifetime_apy_start_index,
    -- SY program and protocol info (from vault and SY account)
    v.sy_program,
    sya.interface_type AS sy_interface_type,
    sya.yield_bearing_mint AS sy_yield_bearing_mint,
    -- Derive authority PDA (standard pattern: ["authority", vault] -> bump 254)
    -- Note: This would need to be calculated using findProgramAddress in practice
    'AUTHORITY_PDA_PLACEHOLDER' AS authority,  -- TODO: Implement PDA derivation
    'market_vault' AS pda_pattern,
    255 AS pda_bump,  -- Standard MarketTwo bump
    -- Extract market name from config (would need config table)
    NULL AS market_name,  -- TODO: Join with config table
    -- Calculate maturity date from start_ts + duration
    (to_timestamp(v.start_ts + v.duration))::DATE AS maturity_date,
    v.start_ts,
    v.duration,
    v.maturity_ts,
    -- Determine status from vault data
    (v.status = 1) AS is_active,  -- status 1 = active
    (v.status = 2) AS is_expired,  -- status 2 = expired
    -- Validation flags (would need config comparison)
    TRUE AS config_vault_matches,  -- TODO: Compare with config
    TRUE AS config_market_matches,  -- TODO: Compare with config
    -- Token metadata from on-chain discovery (prefer vault, fallback to market/SY meta/base escrow)
    COALESCE(v.meta_sy_symbol, m.meta_sy_symbol, sya.meta_sy_symbol) AS meta_sy_symbol,
    COALESCE(v.meta_sy_name, m.meta_sy_name, sya.meta_sy_name) AS meta_sy_name,
    COALESCE(v.meta_sy_decimals, m.meta_sy_decimals, sya.meta_sy_decimals) AS meta_sy_decimals,
    COALESCE(v.meta_pt_symbol, m.meta_pt_symbol) AS meta_pt_symbol,
    COALESCE(v.meta_pt_name, m.meta_pt_name) AS meta_pt_name,
    COALESCE(v.meta_pt_decimals, m.meta_pt_decimals) AS meta_pt_decimals,
    v.meta_yt_symbol AS meta_yt_symbol,
    v.meta_yt_name AS meta_yt_name,
    v.meta_yt_decimals AS meta_yt_decimals,
    m.meta_lp_symbol AS meta_lp_symbol,
    m.meta_lp_name AS meta_lp_name,
    m.meta_lp_decimals AS meta_lp_decimals,
    COALESCE(sya.meta_base_symbol, ute.meta_base_symbol) AS meta_base_symbol,
    COALESCE(sya.meta_base_name, ute.meta_base_name) AS meta_base_name,
    COALESCE(sya.meta_base_decimals, ute.meta_base_decimals) AS meta_base_decimals
FROM (
    -- Get latest vault data with yield_position, escrow_yt, and meta_* fields
    SELECT DISTINCT ON (vault_address)
        vault_address, sy_program, mint_sy, mint_pt, mint_yt,
        env_sy_symbol, env_sy_decimals, env_sy_type,
        start_ts, duration, maturity_ts, status,
        yield_position, escrow_yt, escrow_sy,
        meta_sy_symbol, meta_sy_name, meta_sy_decimals,
        meta_pt_symbol, meta_pt_name, meta_pt_decimals,
        meta_yt_symbol, meta_yt_name, meta_yt_decimals,
        block_time
    FROM exponent.src_vaults
    ORDER BY vault_address, block_time DESC
) v
JOIN (
    -- Get latest market data with meta_* fields
    SELECT DISTINCT ON (vault_address)
        vault_address, market_address, mint_lp,
        env_sy_symbol, env_sy_decimals, env_sy_type,
        meta_pt_symbol, meta_pt_name, meta_pt_decimals,
        meta_sy_symbol, meta_sy_name, meta_sy_decimals,
        meta_lp_symbol, meta_lp_name, meta_lp_decimals
    FROM exponent.src_market_twos
    ORDER BY vault_address, block_time DESC
) m ON v.vault_address = m.vault_address
LEFT JOIN LATERAL (
    -- Get latest SY meta for this mint_sy with meta_* fields
    SELECT sy_meta_address, interface_type, yield_bearing_mint,
           env_sy_lifetime_apy_start_date, env_sy_lifetime_apy_start_index,
           meta_sy_symbol, meta_sy_name, meta_sy_decimals,
           meta_base_symbol, meta_base_name, meta_base_decimals
    FROM exponent.src_sy_meta_account
    WHERE mint_sy = v.mint_sy
    ORDER BY time DESC
    LIMIT 1
) sya ON TRUE
LEFT JOIN LATERAL (
    -- Get latest underlying escrow (derived from SyMeta) with meta_* fields
    SELECT DISTINCT ON (escrow_address) 
        escrow_address AS underlying_escrow_address,
        meta_base_symbol, meta_base_name, meta_base_decimals
    FROM exponent.src_base_token_escrow
    WHERE owner = sya.sy_meta_address
    ORDER BY escrow_address, time DESC
) ute ON TRUE
ORDER BY v.vault_address
ON CONFLICT (vault_address) DO UPDATE SET
    market_address = EXCLUDED.market_address,
    yield_position_address = EXCLUDED.yield_position_address,
    vault_yt_escrow_address = EXCLUDED.vault_yt_escrow_address,
    sy_meta_address = EXCLUDED.sy_meta_address,
    sy_token_address = EXCLUDED.sy_token_address,
    underlying_escrow_address = EXCLUDED.underlying_escrow_address,
    mint_sy = EXCLUDED.mint_sy,
    mint_pt = EXCLUDED.mint_pt,
    mint_yt = EXCLUDED.mint_yt,
    mint_lp = EXCLUDED.mint_lp,
    env_sy_symbol = EXCLUDED.env_sy_symbol,
    env_sy_decimals = EXCLUDED.env_sy_decimals,
    env_sy_type = EXCLUDED.env_sy_type,
    env_sy_lifetime_apy_start_date = EXCLUDED.env_sy_lifetime_apy_start_date,
    env_sy_lifetime_apy_start_index = EXCLUDED.env_sy_lifetime_apy_start_index,
    sy_program = EXCLUDED.sy_program,
    sy_interface_type = EXCLUDED.sy_interface_type,
    sy_yield_bearing_mint = EXCLUDED.sy_yield_bearing_mint,
    authority = EXCLUDED.authority,
    pda_pattern = EXCLUDED.pda_pattern,
    pda_bump = EXCLUDED.pda_bump,
    market_name = EXCLUDED.market_name,
    maturity_date = EXCLUDED.maturity_date,
    start_ts = EXCLUDED.start_ts,
    duration = EXCLUDED.duration,
    maturity_ts = EXCLUDED.maturity_ts,
    is_active = EXCLUDED.is_active,
    is_expired = EXCLUDED.is_expired,
    config_vault_matches = EXCLUDED.config_vault_matches,
    config_market_matches = EXCLUDED.config_market_matches,
    -- Token metadata from on-chain discovery
    meta_sy_symbol = EXCLUDED.meta_sy_symbol,
    meta_sy_name = EXCLUDED.meta_sy_name,
    meta_sy_decimals = EXCLUDED.meta_sy_decimals,
    meta_pt_symbol = EXCLUDED.meta_pt_symbol,
    meta_pt_name = EXCLUDED.meta_pt_name,
    meta_pt_decimals = EXCLUDED.meta_pt_decimals,
    meta_yt_symbol = EXCLUDED.meta_yt_symbol,
    meta_yt_name = EXCLUDED.meta_yt_name,
    meta_yt_decimals = EXCLUDED.meta_yt_decimals,
    meta_lp_symbol = EXCLUDED.meta_lp_symbol,
    meta_lp_name = EXCLUDED.meta_lp_name,
    meta_lp_decimals = EXCLUDED.meta_lp_decimals,
    meta_base_symbol = EXCLUDED.meta_base_symbol,
    meta_base_name = EXCLUDED.meta_base_name,
    meta_base_decimals = EXCLUDED.meta_base_decimals,
    updated_at = NOW();

-- Create indexes for common lookups
CREATE INDEX IF NOT EXISTS idx_aux_key_relations_market 
    ON exponent.aux_key_relations (market_address);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_yield_position 
    ON exponent.aux_key_relations (yield_position_address);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_vault_yt_escrow 
    ON exponent.aux_key_relations (vault_yt_escrow_address);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_sy_meta 
    ON exponent.aux_key_relations (sy_meta_address);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_sy_token 
    ON exponent.aux_key_relations (sy_token_address);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_underlying_escrow 
    ON exponent.aux_key_relations (underlying_escrow_address);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_mint_sy 
    ON exponent.aux_key_relations (mint_sy);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_mint_pt 
    ON exponent.aux_key_relations (mint_pt);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_mint_yt 
    ON exponent.aux_key_relations (mint_yt);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_sy_interface_type 
    ON exponent.aux_key_relations (sy_interface_type);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_active 
    ON exponent.aux_key_relations (is_active, maturity_date);

CREATE INDEX IF NOT EXISTS idx_aux_key_relations_expired 
    ON exponent.aux_key_relations (is_expired, maturity_date);

-- Create composite index for common queries
CREATE INDEX IF NOT EXISTS idx_aux_key_relations_active_maturity 
    ON exponent.aux_key_relations (is_active, is_expired, maturity_date);

-- Table comment
COMMENT ON TABLE exponent.aux_key_relations IS 
    'Auxiliary reference table mapping vault addresses to all related accounts: markets, yield positions (YieldTokenPosition), vault YT escrows (SPL Token Account), SY meta (config), SY token (supply), underlying escrows, and all token mints. Dynamically populated from src_vaults (includes yield_position and escrow_yt), src_market_twos, src_vault_yield_position, src_vault_yt_escrow, src_sy_meta_account, src_sy_token_account, and src_base_token_escrow. Used for efficient lookups in continuous aggregates and queries.';

-- Column comments
COMMENT ON COLUMN exponent.aux_key_relations.vault_address IS 'Vault address (primary key)';
COMMENT ON COLUMN exponent.aux_key_relations.market_address IS 'MarketTwo address (AMM for PT/SY trading)';
COMMENT ON COLUMN exponent.aux_key_relations.yield_position_address IS 'YieldTokenPosition account address (vault.yield_position field - tracks YT position state and accrued yield)';
COMMENT ON COLUMN exponent.aux_key_relations.vault_yt_escrow_address IS 'Vault YT escrow SPL Token Account address (vault.escrow_yt field - holds YT tokens deposited by users)';
COMMENT ON COLUMN exponent.aux_key_relations.sy_meta_address IS 'SyMeta address (SY program metadata account from generic_wrap)';
COMMENT ON COLUMN exponent.aux_key_relations.sy_token_address IS 'SY token mint address (SPL token mint for supply tracking, same as mint_sy)';
COMMENT ON COLUMN exponent.aux_key_relations.underlying_escrow_address IS 'Underlying token escrow address (ATA holding actual backing assets like wfragSOL)';
COMMENT ON COLUMN exponent.aux_key_relations.mint_sy IS 'Standardized Yield token mint (underlying, e.g., fragSOL) - same as sy_token_address';
COMMENT ON COLUMN exponent.aux_key_relations.mint_pt IS 'Principal Token mint address';
COMMENT ON COLUMN exponent.aux_key_relations.mint_yt IS 'Yield Token mint address';
COMMENT ON COLUMN exponent.aux_key_relations.mint_lp IS 'LP Token mint address (from market)';
COMMENT ON COLUMN exponent.aux_key_relations.env_sy_symbol IS 'Token symbol from config/environment (e.g., "fragSOL")';
COMMENT ON COLUMN exponent.aux_key_relations.env_sy_decimals IS 'Token decimals from config/environment';
COMMENT ON COLUMN exponent.aux_key_relations.env_sy_type IS 'Token type (e.g., "yield_bearing")';
COMMENT ON COLUMN exponent.aux_key_relations.env_sy_lifetime_apy_start_date IS 'Config override: Base token lifetime APY start date';
COMMENT ON COLUMN exponent.aux_key_relations.env_sy_lifetime_apy_start_index IS 'Config override: Base token lifetime APY baseline exchange-rate index';
COMMENT ON COLUMN exponent.aux_key_relations.sy_program IS 'SY program address (generic_wrap program)';
COMMENT ON COLUMN exponent.aux_key_relations.sy_interface_type IS 'Underlying protocol type: KaminoVault, JupiterLend, Meteora, etc.';
COMMENT ON COLUMN exponent.aux_key_relations.sy_yield_bearing_mint IS 'Underlying yield-bearing token mint (e.g., Kamino kToken)';
COMMENT ON COLUMN exponent.aux_key_relations.authority IS 'Vault authority PDA address';
COMMENT ON COLUMN exponent.aux_key_relations.pda_pattern IS 'PDA derivation pattern (e.g., "market_vault")';
COMMENT ON COLUMN exponent.aux_key_relations.pda_bump IS 'Bump seed for MarketTwo derivation';
COMMENT ON COLUMN exponent.aux_key_relations.market_name IS 'Market name from config (e.g., "fragSOL-31Oct25")';
COMMENT ON COLUMN exponent.aux_key_relations.maturity_date IS 'Maturity date calculated from start_ts + duration';
COMMENT ON COLUMN exponent.aux_key_relations.start_ts IS 'Unix timestamp when vault started';
COMMENT ON COLUMN exponent.aux_key_relations.duration IS 'Seconds until maturity';
COMMENT ON COLUMN exponent.aux_key_relations.maturity_ts IS 'Unix timestamp of maturity (start_ts + duration)';
COMMENT ON COLUMN exponent.aux_key_relations.is_active IS 'TRUE if vault is active (status = 1)';
COMMENT ON COLUMN exponent.aux_key_relations.is_expired IS 'TRUE if vault is expired (status = 2)';
COMMENT ON COLUMN exponent.aux_key_relations.config_vault_matches IS 'Validation flag: TRUE if vault_address matches config';
COMMENT ON COLUMN exponent.aux_key_relations.config_market_matches IS 'Validation flag: TRUE if market_address matches config';
COMMENT ON COLUMN exponent.aux_key_relations.updated_at IS 'Timestamp when this row was last updated';

-- Example usage queries:

-- Get complete account relationship map for a vault:
-- SELECT vault_address, market_address, yield_position_address, vault_yt_escrow_address, 
--        sy_meta_address, sy_token_address, underlying_escrow_address,
--        mint_sy, mint_pt, mint_yt, mint_lp,
--        sy_interface_type, sy_yield_bearing_mint
-- FROM exponent.aux_key_relations 
-- WHERE vault_address = 'HgpfpAZXWyg8...';

-- Get all vaults for a market with full token info:
-- SELECT * FROM exponent.aux_key_relations WHERE market_address = 'G7sZHej...';

-- Find yield position and vault YT escrow by vault:
-- SELECT vault_address, yield_position_address, vault_yt_escrow_address, sy_meta_address
-- FROM exponent.aux_key_relations 
-- WHERE vault_address = 'HgpfpAZXWyg8...';

-- Find vault by yield position address:
-- SELECT vault_address, market_address, mint_sy, env_sy_symbol
-- FROM exponent.aux_key_relations 
-- WHERE yield_position_address = 'ABC123...';

-- Find vault by vault YT escrow address:
-- SELECT vault_address, market_address, mint_sy, env_sy_symbol
-- FROM exponent.aux_key_relations 
-- WHERE vault_yt_escrow_address = 'XYZ789...';

-- Find all vaults using a specific protocol (e.g., Kamino):
-- SELECT vault_address, market_address, env_sy_symbol, sy_yield_bearing_mint
-- FROM exponent.aux_key_relations 
-- WHERE sy_interface_type = 'KaminoVault';

-- Get active vs expired vaults by protocol:
-- SELECT sy_interface_type, is_active, is_expired, COUNT(*), 
--        array_agg(env_sy_symbol) AS tokens
-- FROM exponent.aux_key_relations 
-- GROUP BY sy_interface_type, is_active, is_expired
-- ORDER BY sy_interface_type, is_active DESC;

-- Get vaults by maturity date range:
-- SELECT vault_address, market_name, env_sy_symbol, maturity_date, is_active,
--        sy_interface_type
-- FROM exponent.aux_key_relations
-- WHERE maturity_date BETWEEN '2025-01-01' AND '2025-12-31'
-- ORDER BY maturity_date;

-- Verify config matches blockchain:
-- SELECT vault_address, market_name, 
--        config_vault_matches, config_market_matches
-- FROM exponent.aux_key_relations
-- WHERE NOT config_vault_matches OR NOT config_market_matches;

-- Get vaults expiring soon:
-- SELECT vault_address, market_name, env_sy_symbol, maturity_date, 
--        maturity_date - CURRENT_DATE AS days_to_maturity,
--        sy_interface_type, sy_yield_bearing_mint
-- FROM exponent.aux_key_relations
-- WHERE is_active = TRUE 
--   AND maturity_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '30 days'
-- ORDER BY maturity_date;

-- Get complete ecosystem map (all accounts for all vaults):
-- SELECT vault_address, market_address, yield_position_address, vault_yt_escrow_address,
--        sy_meta_address, sy_token_address, underlying_escrow_address,
--        env_sy_symbol, sy_interface_type,
--        mint_sy, mint_pt, mint_yt, mint_lp,
--        is_active, maturity_date
-- FROM exponent.aux_key_relations
-- ORDER BY is_active DESC, maturity_date;

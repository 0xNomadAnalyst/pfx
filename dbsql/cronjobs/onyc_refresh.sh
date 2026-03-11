#!/bin/bash
# =====================================================
# ONyc Pipeline Refresh Script
# =====================================================
# Tiered refresh for ONyc mid-level ETL pipeline:
#   Tier 1 (every cycle): 5s CAGGs (30-min window) + all hot mat tables
#   Tier 2 (every AUX_REFRESH_MULT cycles): Aux/discovery table sync
#   Tier 3 (every HEALTH_CHECK_MULT cycles): Health check + stats
#   Daily (midnight UTC): Cleanup of old mat data beyond retention
#
# All mat tables refresh at a uniform cadence to ensure consistent
# freshness across domains during market stress.
# =====================================================

set -euo pipefail

# =====================================================
# Configuration (override via environment)
# =====================================================

# Hot-path refresh interval in seconds (uniform for all domains)
MAT_REFRESH_INTERVAL_S="${MAT_REFRESH_INTERVAL_S:-30}"

# CAGG refresh trailing window
CAGG_REFRESH_WINDOW="${CAGG_REFRESH_WINDOW:-30 minutes}"

# Aux/discovery table sync: every N hot-path cycles
AUX_REFRESH_MULT="${AUX_REFRESH_MULT:-10}"

# Health check: every N hot-path cycles
HEALTH_CHECK_MULT="${HEALTH_CHECK_MULT:-60}"

# Mat data retention (for cleanup of old materialized rows)
MAT_RETENTION_DAYS="${MAT_RETENTION_DAYS:-100}"

# Max consecutive failures before exit
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-10}"

# =====================================================
# Database connection
# =====================================================
export PGHOST="${DB_HOST:-${TIMESCALEDB_HOST:-$PGHOST}}"
export PGPORT="${DB_PORT:-${TIMESCALEDB_PORT:-$PGPORT}}"
export PGDATABASE="${DB_NAME:-${TIMESCALEDB_DATABASE:-$PGDATABASE}}"
export PGUSER="${DB_USER:-${TIMESCALEDB_USERNAME:-$PGUSER}}"
export PGPASSWORD="${DB_PASSWORD:-${TIMESCALEDB_PASSWORD:-$PGPASSWORD}}"
export PGSSLMODE="${DB_SSLMODE:-${TIMESCALEDB_SSLMODE:-${PGSSLMODE:-require}}}"

DB_CONNECTION="postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}?sslmode=${PGSSLMODE}"

# Schema names
DEX_SCHEMA="${DB_DEX_SCHEMA:-dexes}"
KAMINO_SCHEMA="${DB_KAMINO_SCHEMA:-kamino_lend}"
EXPONENT_SCHEMA="${DB_EXPONENT_SCHEMA:-exponent}"

LOG_PREFIX="[ONyc Refresh]"

# =====================================================
# Startup
# =====================================================
echo "$LOG_PREFIX Starting ONyc pipeline refresh service"
echo "$LOG_PREFIX Hot-path interval: ${MAT_REFRESH_INTERVAL_S}s"
echo "$LOG_PREFIX CAGG window: ${CAGG_REFRESH_WINDOW}"
echo "$LOG_PREFIX Aux sync: every ${AUX_REFRESH_MULT} cycles ($((MAT_REFRESH_INTERVAL_S * AUX_REFRESH_MULT))s)"
echo "$LOG_PREFIX Health check: every ${HEALTH_CHECK_MULT} cycles ($((MAT_REFRESH_INTERVAL_S * HEALTH_CHECK_MULT))s)"
echo "$LOG_PREFIX Database: ${PGHOST}:${PGPORT}/${PGDATABASE}"

echo "$LOG_PREFIX Testing database connection..."
if psql "$DB_CONNECTION" -c "SELECT 1;" > /dev/null 2>&1; then
    echo "$LOG_PREFIX Database connection successful"
else
    echo "$LOG_PREFIX Database connection failed"
    exit 1
fi

# =====================================================
# Tier 1: CAGG refresh (narrowed window)
# =====================================================
refresh_caggs() {
    psql "$DB_CONNECTION" <<EOF
-- DEX CAGGs
CALL refresh_continuous_aggregate('${DEX_SCHEMA}.cagg_events_5s',      NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${DEX_SCHEMA}.cagg_vaults_5s',      NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${DEX_SCHEMA}.cagg_poolstate_5s',   NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${DEX_SCHEMA}.cagg_tickarrays_5s',  NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');

-- Kamino CAGGs
CALL refresh_continuous_aggregate('${KAMINO_SCHEMA}.cagg_activities_5s',     NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${KAMINO_SCHEMA}.cagg_reserves_5s',      NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${KAMINO_SCHEMA}.cagg_obligations_agg_5s', NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');

-- Exponent CAGGs
CALL refresh_continuous_aggregate('${EXPONENT_SCHEMA}.cagg_vaults_5s',              NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${EXPONENT_SCHEMA}.cagg_market_twos_5s',         NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${EXPONENT_SCHEMA}.cagg_sy_meta_account_5s',     NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${EXPONENT_SCHEMA}.cagg_sy_token_account_5s',    NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${EXPONENT_SCHEMA}.cagg_vault_yield_position_5s', NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${EXPONENT_SCHEMA}.cagg_vault_yt_escrow_5s',     NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${EXPONENT_SCHEMA}.cagg_base_token_escrow_5s',   NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
CALL refresh_continuous_aggregate('${EXPONENT_SCHEMA}.cagg_tx_events_5s',           NOW() - INTERVAL '${CAGG_REFRESH_WINDOW}', NOW() - INTERVAL '1 minute');
EOF
}

# =====================================================
# Tier 1: Mat table refresh (all hot-path, uniform)
# =====================================================
refresh_mat_tables() {
    psql "$DB_CONNECTION" <<EOF
-- Dexes materialized tables
CALL ${DEX_SCHEMA}.refresh_mat_dex_timeseries_1m();
CALL ${DEX_SCHEMA}.refresh_mat_dex_ohlcv_1m();
CALL ${DEX_SCHEMA}.refresh_mat_dex_last();

-- Kamino materialized tables
CALL ${KAMINO_SCHEMA}.refresh_mat_klend_timeseries_1m();
CALL ${KAMINO_SCHEMA}.refresh_mat_klend_last();
CALL ${KAMINO_SCHEMA}.refresh_mat_klend_config();

-- Exponent materialized tables
CALL ${EXPONENT_SCHEMA}.refresh_mat_exp_timeseries_1m();
CALL ${EXPONENT_SCHEMA}.refresh_mat_exp_last();

-- Health materialized tables
CALL health.refresh_mat_health_all();

-- Cross-protocol materialized tables (must run after domain mat refreshes)
CALL cross_protocol.refresh_mat_xp_all();
EOF
}

# =====================================================
# Tier 2: Aux/discovery table sync
# =====================================================
refresh_aux_tables() {
    psql "$DB_CONNECTION" <<EOF
-- Kamino: aux_market_reserve_tokens
INSERT INTO ${KAMINO_SCHEMA}.aux_market_reserve_tokens (
    market_address, reserve_address, token_mint, collateral_mint,
    token_symbol, token_decimals, reserve_type, reserve_status,
    loan_to_value_pct, liquidation_threshold_pct, borrow_factor_pct,
    env_token_mint_matches, env_market_address_matches
)
SELECT DISTINCT ON (r.reserve_address)
    r.market_address, r.reserve_address,
    r.liquidity_mint_pubkey AS token_mint,
    r.collateral_mint_pubkey AS collateral_mint,
    r.env_symbol AS token_symbol, r.env_decimals AS token_decimals,
    r.env_reserve_type AS reserve_type, r.reserve_status,
    r.loan_to_value_pct, r.liquidation_threshold_pct, r.borrow_factor_pct,
    (r.env_token_mint = r.liquidity_mint_pubkey),
    (r.env_market_address = r.market_address)
FROM ${KAMINO_SCHEMA}.src_reserves r
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

UPDATE ${KAMINO_SCHEMA}.aux_market_reserve_tokens mrt
SET market_quote_currency = m.quote_currency
FROM (
    SELECT DISTINCT ON (market_address) market_address, quote_currency
    FROM ${KAMINO_SCHEMA}.src_lending_market
    ORDER BY market_address, block_time DESC
) m
WHERE mrt.market_address = m.market_address;

-- Exponent: aux_key_relations
INSERT INTO ${EXPONENT_SCHEMA}.aux_key_relations (
    vault_address, market_address, yield_position_address,
    vault_yt_escrow_address, sy_meta_address, sy_token_address,
    underlying_escrow_address,
    mint_sy, mint_pt, mint_yt, mint_lp,
    env_sy_symbol, env_sy_decimals, env_sy_type,
    env_sy_lifetime_apy_start_date, env_sy_lifetime_apy_start_index,
    sy_program, sy_interface_type, sy_yield_bearing_mint,
    authority, pda_pattern, pda_bump,
    market_name, maturity_date, start_ts, duration, maturity_ts,
    is_active, is_expired, config_vault_matches, config_market_matches
)
SELECT DISTINCT ON (v.vault_address)
    v.vault_address, m.market_address,
    v.yield_position, v.escrow_yt,
    sya.sy_meta_address, v.mint_sy, ute.underlying_escrow_address,
    v.mint_sy, v.mint_pt, v.mint_yt, m.mint_lp,
    COALESCE(v.env_sy_symbol, m.env_sy_symbol),
    COALESCE(v.env_sy_decimals, m.env_sy_decimals),
    COALESCE(v.env_sy_type, m.env_sy_type),
    sya.env_sy_lifetime_apy_start_date, sya.env_sy_lifetime_apy_start_index,
    v.sy_program, sya.interface_type, sya.yield_bearing_mint,
    'AUTHORITY_PDA_PLACEHOLDER', 'market_vault', 255,
    NULL, (to_timestamp(v.start_ts + v.duration))::DATE,
    v.start_ts, v.duration, v.maturity_ts,
    (v.status = 1), (v.status = 2), TRUE, TRUE
FROM (
    SELECT DISTINCT ON (vault_address)
        vault_address, sy_program, mint_sy, mint_pt, mint_yt,
        env_sy_symbol, env_sy_decimals, env_sy_type,
        start_ts, duration, maturity_ts, status,
        yield_position, escrow_yt, escrow_sy, block_time
    FROM ${EXPONENT_SCHEMA}.src_vaults
    ORDER BY vault_address, block_time DESC
) v
JOIN (
    SELECT DISTINCT ON (vault_address)
        vault_address, market_address, mint_lp,
        env_sy_symbol, env_sy_decimals, env_sy_type
    FROM ${EXPONENT_SCHEMA}.src_market_twos
    ORDER BY vault_address, block_time DESC
) m ON v.vault_address = m.vault_address
LEFT JOIN LATERAL (
    SELECT sy_meta_address, interface_type, yield_bearing_mint,
           env_sy_lifetime_apy_start_date, env_sy_lifetime_apy_start_index
    FROM ${EXPONENT_SCHEMA}.src_sy_meta_account
    WHERE mint_sy = v.mint_sy ORDER BY time DESC LIMIT 1
) sya ON TRUE
LEFT JOIN LATERAL (
    SELECT DISTINCT ON (escrow_address) escrow_address AS underlying_escrow_address
    FROM ${EXPONENT_SCHEMA}.src_base_token_escrow
    WHERE owner = sya.sy_meta_address ORDER BY escrow_address, time DESC
) ute ON TRUE
ORDER BY v.vault_address
ON CONFLICT (vault_address) DO UPDATE SET
    market_address = EXCLUDED.market_address,
    yield_position_address = EXCLUDED.yield_position_address,
    vault_yt_escrow_address = EXCLUDED.vault_yt_escrow_address,
    sy_meta_address = EXCLUDED.sy_meta_address,
    sy_token_address = EXCLUDED.sy_token_address,
    underlying_escrow_address = EXCLUDED.underlying_escrow_address,
    mint_sy = EXCLUDED.mint_sy, mint_pt = EXCLUDED.mint_pt,
    mint_yt = EXCLUDED.mint_yt, mint_lp = EXCLUDED.mint_lp,
    env_sy_symbol = EXCLUDED.env_sy_symbol,
    env_sy_decimals = EXCLUDED.env_sy_decimals,
    env_sy_type = EXCLUDED.env_sy_type,
    env_sy_lifetime_apy_start_date = EXCLUDED.env_sy_lifetime_apy_start_date,
    env_sy_lifetime_apy_start_index = EXCLUDED.env_sy_lifetime_apy_start_index,
    sy_program = EXCLUDED.sy_program,
    sy_interface_type = EXCLUDED.sy_interface_type,
    sy_yield_bearing_mint = EXCLUDED.sy_yield_bearing_mint,
    start_ts = EXCLUDED.start_ts, duration = EXCLUDED.duration,
    maturity_ts = EXCLUDED.maturity_ts,
    is_active = EXCLUDED.is_active, is_expired = EXCLUDED.is_expired,
    updated_at = NOW();

-- Dexes: pool_tokens_reference
INSERT INTO ${DEX_SCHEMA}.pool_tokens_reference (
    protocol, pool_address, token_pair,
    token0_address, token1_address, token0_symbol, token1_symbol,
    token0_decimals, token1_decimals
)
SELECT DISTINCT ON (pool_address)
    protocol, pool_address,
    token_pair,
    token_mint_0, token_mint_1,
    SPLIT_PART(token_pair, '-', 1),
    SPLIT_PART(token_pair, '-', 2),
    mint_decimals_0, mint_decimals_1
FROM ${DEX_SCHEMA}.src_acct_pool
ORDER BY pool_address, block_time DESC
ON CONFLICT (pool_address) DO UPDATE
    SET protocol = EXCLUDED.protocol,
        token_pair = EXCLUDED.token_pair,
        token0_address = EXCLUDED.token0_address,
        token1_address = EXCLUDED.token1_address,
        token0_symbol = EXCLUDED.token0_symbol,
        token1_symbol = EXCLUDED.token1_symbol,
        token0_decimals = EXCLUDED.token0_decimals,
        token1_decimals = EXCLUDED.token1_decimals,
        updated_at = NOW();
EOF
}

# =====================================================
# Tier 3: Health check
# =====================================================
check_health() {
    local ts=$(date -u '+%Y-%m-%d %H:%M:%S')
    echo "$LOG_PREFIX [$ts UTC] Health check"

    psql "$DB_CONNECTION" -c "
        SELECT view_name, materialized_only, compression_enabled
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema IN ('${DEX_SCHEMA}', '${KAMINO_SCHEMA}', '${EXPONENT_SCHEMA}')
        ORDER BY view_schema, view_name;
    " 2>/dev/null || true

    echo "$LOG_PREFIX Mat table freshness:"
    psql "$DB_CONNECTION" -c "
        SELECT 'dex_ts_1m' AS tbl,   MAX(refreshed_at) AS refreshed_at, COUNT(*) AS rows FROM ${DEX_SCHEMA}.mat_dex_timeseries_1m
        UNION ALL
        SELECT 'dex_ohlcv_1m',       MAX(refreshed_at), COUNT(*) FROM ${DEX_SCHEMA}.mat_dex_ohlcv_1m
        UNION ALL
        SELECT 'dex_last',           MAX(refreshed_at), COUNT(*) FROM ${DEX_SCHEMA}.mat_dex_last
        UNION ALL
        SELECT 'klend_reserve_1m',   MAX(refreshed_at), COUNT(*) FROM ${KAMINO_SCHEMA}.mat_klend_reserve_ts_1m
        UNION ALL
        SELECT 'klend_last_res',     MAX(refreshed_at), COUNT(*) FROM ${KAMINO_SCHEMA}.mat_klend_last_reserves
        UNION ALL
        SELECT 'klend_config',       MAX(refreshed_at), COUNT(*) FROM ${KAMINO_SCHEMA}.mat_klend_config
        UNION ALL
        SELECT 'exp_ts_1m',          MAX(refreshed_at), COUNT(*) FROM ${EXPONENT_SCHEMA}.mat_exp_timeseries_1m
        UNION ALL
        SELECT 'exp_last',           MAX(refreshed_at), COUNT(*) FROM ${EXPONENT_SCHEMA}.mat_exp_last
        UNION ALL
        SELECT 'health_queue_bench', MAX(refreshed_at), COUNT(*) FROM health.mat_health_queue_benchmarks
        UNION ALL
        SELECT 'health_trigger',     MAX(refreshed_at), COUNT(*) FROM health.mat_health_trigger_stats
        UNION ALL
        SELECT 'health_base_act',    MAX(refreshed_at), COUNT(*) FROM health.mat_health_base_activity
        UNION ALL
        SELECT 'health_cagg_stat',   MAX(refreshed_at), COUNT(*) FROM health.mat_health_cagg_status
        UNION ALL
        SELECT 'health_base_hourly', MAX(refreshed_at), COUNT(*) FROM health.mat_health_base_hourly
        UNION ALL
        SELECT 'xp_ts_1m',          MAX(refreshed_at), COUNT(*) FROM cross_protocol.mat_xp_ts_1m
        UNION ALL
        SELECT 'xp_last',           MAX(refreshed_at), COUNT(*) FROM cross_protocol.mat_xp_last
        ORDER BY tbl;
    " 2>/dev/null || true
}

# =====================================================
# Daily: Retention cleanup
# =====================================================
cleanup_old_data() {
    local ts=$(date -u '+%Y-%m-%d %H:%M:%S')
    echo "$LOG_PREFIX [$ts UTC] Running retention cleanup (>${MAT_RETENTION_DAYS} days)..."

    psql "$DB_CONNECTION" <<EOF
DELETE FROM ${DEX_SCHEMA}.mat_dex_timeseries_1m  WHERE bucket_time < NOW() - INTERVAL '${MAT_RETENTION_DAYS} days';
DELETE FROM ${DEX_SCHEMA}.mat_dex_ohlcv_1m       WHERE bucket_time < NOW() - INTERVAL '${MAT_RETENTION_DAYS} days';
DELETE FROM ${KAMINO_SCHEMA}.mat_klend_reserve_ts_1m    WHERE bucket_time < NOW() - INTERVAL '${MAT_RETENTION_DAYS} days';
DELETE FROM ${KAMINO_SCHEMA}.mat_klend_obligation_ts_1m WHERE bucket_time < NOW() - INTERVAL '${MAT_RETENTION_DAYS} days';
DELETE FROM ${KAMINO_SCHEMA}.mat_klend_activity_ts_1m   WHERE bucket_time < NOW() - INTERVAL '${MAT_RETENTION_DAYS} days';
DELETE FROM ${EXPONENT_SCHEMA}.mat_exp_timeseries_1m    WHERE bucket_time < NOW() - INTERVAL '${MAT_RETENTION_DAYS} days';
VACUUM (ANALYZE) ${DEX_SCHEMA}.mat_dex_timeseries_1m;
VACUUM (ANALYZE) ${DEX_SCHEMA}.mat_dex_ohlcv_1m;
VACUUM (ANALYZE) ${KAMINO_SCHEMA}.mat_klend_reserve_ts_1m;
VACUUM (ANALYZE) ${KAMINO_SCHEMA}.mat_klend_obligation_ts_1m;
VACUUM (ANALYZE) ${KAMINO_SCHEMA}.mat_klend_activity_ts_1m;
VACUUM (ANALYZE) ${EXPONENT_SCHEMA}.mat_exp_timeseries_1m;
DELETE FROM health.mat_health_base_hourly WHERE hour < NOW() - INTERVAL '8 days';
VACUUM (ANALYZE) health.mat_health_base_hourly;
DELETE FROM cross_protocol.mat_xp_ts_1m WHERE bucket_time < NOW() - INTERVAL '${MAT_RETENTION_DAYS} days';
VACUUM (ANALYZE) cross_protocol.mat_xp_ts_1m;
EOF
    echo "$LOG_PREFIX [$ts UTC] Retention cleanup completed"
}

# =====================================================
# Main loop
# =====================================================
cycle_count=0
failure_count=0
last_cleanup_date=""

echo "$LOG_PREFIX Entering main loop..."

while true; do
    cycle_count=$((cycle_count + 1))
    cycle_start=$(date +%s%N)
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    # --- Tier 2: Aux tables (every AUX_REFRESH_MULT cycles) ---
    if [ $((cycle_count % AUX_REFRESH_MULT)) -eq 1 ]; then
        echo "$LOG_PREFIX [$ts] Cycle #${cycle_count} — aux sync + CAGGs + mat tables"
        if refresh_aux_tables 2>&1; then
            echo "$LOG_PREFIX Aux tables synced"
        else
            echo "$LOG_PREFIX Aux table sync failed (non-fatal)"
        fi
    else
        echo "$LOG_PREFIX [$ts] Cycle #${cycle_count} — CAGGs + mat tables"
    fi

    # --- Tier 1: CAGGs + mat tables (every cycle) ---
    if refresh_caggs 2>&1 && refresh_mat_tables 2>&1; then
        failure_count=0
        elapsed_ms=$(( ($(date +%s%N) - cycle_start) / 1000000 ))
        echo "$LOG_PREFIX Cycle #${cycle_count} completed in ${elapsed_ms}ms"
    else
        failure_count=$((failure_count + 1))
        echo "$LOG_PREFIX Cycle #${cycle_count} FAILED (${failure_count}/${MAX_CONSECUTIVE_FAILURES})"
        if [ "$failure_count" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
            echo "$LOG_PREFIX Too many consecutive failures — exiting"
            exit 1
        fi
    fi

    # --- Tier 3: Health check ---
    if [ $((cycle_count % HEALTH_CHECK_MULT)) -eq 0 ]; then
        check_health
    fi

    # --- Daily: Retention cleanup (midnight UTC) ---
    current_utc_date=$(date -u '+%Y-%m-%d')
    current_utc_hour=$(date -u '+%H')
    if [ "$current_utc_date" != "$last_cleanup_date" ] && [ "$current_utc_hour" = "00" ]; then
        cleanup_old_data
        last_cleanup_date="$current_utc_date"
    fi

    # --- Sleep until next cycle ---
    elapsed_s=$(( ($(date +%s%N) - cycle_start) / 1000000000 ))
    sleep_time=$((MAT_REFRESH_INTERVAL_S - elapsed_s))
    if [ "$sleep_time" -gt 0 ]; then
        sleep "$sleep_time"
    fi
done

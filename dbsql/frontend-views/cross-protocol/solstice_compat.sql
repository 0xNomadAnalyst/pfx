-- solstice_compat.sql
-- Compatibility layer for the ONyc database: creates solstice_proprietary.*
-- objects with the same column names as the Solstice production views, so the
-- Python global_ecosystem.py page service works for both pipelines.
--
-- ONyc-specific data is mapped where meaningful; Solstice-only concepts
-- (eUSX yield vesting, PT-USX supply, base collateral AUM, etc.) return NULL.

CREATE SCHEMA IF NOT EXISTS solstice_proprietary;

-- =============================================================================
-- v_prop_last — snapshot view (global_ecosystem.py._v_last)
-- =============================================================================

DROP VIEW IF EXISTS solstice_proprietary.v_prop_last CASCADE;
CREATE OR REPLACE VIEW solstice_proprietary.v_prop_last AS
SELECT
    -- Asset issuance (ONyc ecosystem equivalents)
    0::NUMERIC                       AS ptyt_all_csupply_in_usx,
    0::NUMERIC                       AS sy_all_csupply_in_usx,
    0::NUMERIC                       AS eusx_csupply,
    xp.onyc_tracked_total            AS usx_csupply,
    xp.kam_total_collateral_value    AS base_coll_total,
    0::NUMERIC                       AS base_coll_in_prog_vault,
    0::NUMERIC                       AS base_coll_aum,

    -- Issuance percentages (single-token ecosystem → 100% primary)
    100::NUMERIC                     AS usx_csupply_pure_pct,
    0::NUMERIC                       AS eusx_csupply_pure_pct,
    0::NUMERIC                       AS sy_all_csupply_in_usx_pure_pct,
    0::NUMERIC                       AS ptyt_all_csupply_in_usx_pct,

    -- Yields (map ONyc equivalents)
    NULL::NUMERIC                    AS yield_eusx_7d,
    NULL::NUMERIC                    AS yield_eusx_30d,
    xp.exp_weighted_implied_apy_pct  AS yield_pteusx,
    NULL::NUMERIC                    AS yield_ptusx,
    xp.kam_onyc_supply_apy_pct       AS yield_kusx,

    -- TVL distribution — map ONyc token across protocols to the USX slots
    xp.onyc_in_dexes_pct             AS usx_tvl_in_dexes_pct,
    xp.onyc_in_kamino_pct            AS usx_tvl_in_kamino_pct,
    0::NUMERIC                       AS usx_tvl_in_kamino_as_ptusx_pct,
    0::NUMERIC                       AS usx_tvl_in_eusx_pct,
    xp.onyc_in_exponent_pct          AS usx_tvl_in_exponent_pct,
    GREATEST(0, 100 - COALESCE(xp.onyc_in_dexes_pct, 0)
                     - COALESCE(xp.onyc_in_kamino_pct, 0)
                     - COALESCE(xp.onyc_in_exponent_pct, 0))
                                     AS usx_tvl_remainder_pct,

    -- eUSX TVL distribution (not applicable for ONyc)
    0::NUMERIC                       AS eusx_tvl_in_dexes_pct,
    0::NUMERIC                       AS eusx_tvl_in_kamino_pct,
    0::NUMERIC                       AS eusx_tvl_in_kamino_as_pteusx_pct,
    0::NUMERIC                       AS eusx_tvl_in_exponent_only_pct,
    0::NUMERIC                       AS eusx_tvl_remainder_pct,

    -- Token availability (USX-slot = ONyc)
    0::NUMERIC                       AS usx_timelocked,
    xp.onyc_tracked_total            AS usx_defi_deployed,
    0::NUMERIC                       AS usx_freeunknown,

    -- eUSX availability (not applicable)
    0::NUMERIC                       AS eusx_defi_deployed,
    0::NUMERIC                       AS eusx_freeunknown
FROM cross_protocol.v_xp_last xp;


-- =============================================================================
-- get_view_prop_timeseries — timeseries function (global_ecosystem.py._ts_rows)
-- =============================================================================

DROP FUNCTION IF EXISTS solstice_proprietary.get_view_prop_timeseries(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
CREATE OR REPLACE FUNCTION solstice_proprietary.get_view_prop_timeseries(
    bucket_interval TEXT DEFAULT '4 hours',
    from_ts TIMESTAMPTZ DEFAULT NOW() - INTERVAL '7 days',
    to_ts   TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
    bucket_time TIMESTAMPTZ,
    usx_csupply_pure_pct NUMERIC,
    eusx_csupply_pure_pct NUMERIC,
    sy_all_csupply_in_usx_pure_pct NUMERIC,
    ptyt_all_csupply_in_usx_pct NUMERIC,
    yield_eusx_24h NUMERIC,
    yield_eusx_7d NUMERIC,
    yield_ptusx NUMERIC,
    yield_pteusx NUMERIC,
    yield_kusx NUMERIC,
    usx_timelocked NUMERIC,
    usx_defi_deployed NUMERIC,
    usx_freeunknown NUMERIC,
    eusx_defi_deployed NUMERIC,
    eusx_freeunknown NUMERIC,
    usx_tvl_in_dexes NUMERIC,
    usx_tvl_in_kamino NUMERIC,
    usx_tvl_in_eusx NUMERIC,
    usx_tvl_in_exponent NUMERIC,
    eusx_tvl_in_dexes NUMERIC,
    eusx_tvl_in_kamino NUMERIC,
    eusx_tvl_in_kamino_as_pteusx NUMERIC,
    eusx_tvl_in_exponent_only NUMERIC,
    usx_tvl_in_dexes_pct NUMERIC,
    usx_tvl_in_kamino_pct NUMERIC,
    usx_tvl_in_eusx_pct NUMERIC,
    usx_tvl_in_exponent_pct NUMERIC,
    usx_tvl_remainder_pct NUMERIC,
    eusx_tvl_in_dexes_pct NUMERIC,
    eusx_tvl_in_kamino_pct NUMERIC,
    eusx_tvl_in_kamino_as_pteusx_pct NUMERIC,
    eusx_tvl_in_exponent_only_pct NUMERIC,
    eusx_tvl_remainder_pct NUMERIC,
    usx_eusx_yield_flows NUMERIC,
    usx_dex_flows NUMERIC,
    usx_kam_all_flows NUMERIC,
    usx_exp_all_flows NUMERIC,
    eusx_dex_flows NUMERIC,
    eusx_kam_all_flows NUMERIC,
    eusx_exp_all_flows NUMERIC,
    usx_eusx_yield_flows_pct_usx_activity NUMERIC,
    usx_dex_flows_pct_usx_activity NUMERIC,
    usx_kam_all_flows_pct_usx_activity NUMERIC,
    usx_exp_all_flows_pct_usx_activity NUMERIC,
    eusx_dex_flows_pct_eusx_activity NUMERIC,
    eusx_kam_all_flows_pct_eusx_activity NUMERIC,
    eusx_exp_all_flows_pct_eusx_activity NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        xp.bucket_time,
        100::NUMERIC,   -- usx_csupply_pure_pct (single token)
        0::NUMERIC,     -- eusx_csupply_pure_pct
        0::NUMERIC,     -- sy_all_csupply_in_usx_pure_pct
        0::NUMERIC,     -- ptyt_all_csupply_in_usx_pct
        NULL::NUMERIC,  -- yield_eusx_24h
        NULL::NUMERIC,  -- yield_eusx_7d
        NULL::NUMERIC,  -- yield_ptusx
        xp.exp_weighted_implied_apy, -- yield_pteusx → exponent implied APY
        xp.kam_onyc_supply_apy,      -- yield_kusx → kamino supply APY
        0::NUMERIC,     -- usx_timelocked
        xp.onyc_tracked_total,       -- usx_defi_deployed → ONyc total
        0::NUMERIC,     -- usx_freeunknown
        0::NUMERIC,     -- eusx_defi_deployed
        0::NUMERIC,     -- eusx_freeunknown
        xp.onyc_in_dexes,           -- usx_tvl_in_dexes
        xp.onyc_in_kamino,          -- usx_tvl_in_kamino
        0::NUMERIC,                  -- usx_tvl_in_eusx
        xp.onyc_in_exponent,        -- usx_tvl_in_exponent
        0::NUMERIC,     -- eusx_tvl_in_dexes
        0::NUMERIC,     -- eusx_tvl_in_kamino
        0::NUMERIC,     -- eusx_tvl_in_kamino_as_pteusx
        0::NUMERIC,     -- eusx_tvl_in_exponent_only
        xp.onyc_in_dexes_pct,       -- usx_tvl_in_dexes_pct
        xp.onyc_in_kamino_pct,      -- usx_tvl_in_kamino_pct
        0::NUMERIC,                  -- usx_tvl_in_eusx_pct
        xp.onyc_in_exponent_pct,    -- usx_tvl_in_exponent_pct
        GREATEST(0, 100 - COALESCE(xp.onyc_in_dexes_pct, 0)
                         - COALESCE(xp.onyc_in_kamino_pct, 0)
                         - COALESCE(xp.onyc_in_exponent_pct, 0)),
        0::NUMERIC, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC, 0::NUMERIC,
        0::NUMERIC,                  -- usx_eusx_yield_flows
        xp.dex_total_volume,         -- usx_dex_flows
        xp.kam_total_volume,         -- usx_kam_all_flows
        xp.exp_total_volume,         -- usx_exp_all_flows
        0::NUMERIC,     -- eusx_dex_flows
        0::NUMERIC,     -- eusx_kam_all_flows
        0::NUMERIC,     -- eusx_exp_all_flows
        0::NUMERIC,                  -- usx_eusx_yield_flows_pct_usx_activity
        xp.dex_volume_pct,           -- usx_dex_flows_pct_usx_activity
        xp.kam_volume_pct,           -- usx_kam_all_flows_pct_usx_activity
        xp.exp_volume_pct,           -- usx_exp_all_flows_pct_usx_activity
        0::NUMERIC,     -- eusx_dex_flows_pct_eusx_activity
        0::NUMERIC,     -- eusx_kam_all_flows_pct_eusx_activity
        0::NUMERIC      -- eusx_exp_all_flows_pct_eusx_activity
    FROM cross_protocol.get_view_xp_timeseries(
        bucket_interval, from_ts, to_ts
    ) xp
    ORDER BY xp.bucket_time;
END;
$$ LANGUAGE plpgsql STABLE;


-- =============================================================================
-- get_view_prop_last_interval — interval aggregation (global_ecosystem.py._interval_row)
-- =============================================================================

DROP FUNCTION IF EXISTS solstice_proprietary.get_view_prop_last_interval(TEXT) CASCADE;
CREATE OR REPLACE FUNCTION solstice_proprietary.get_view_prop_last_interval(
    lookback TEXT DEFAULT '24 hours'
)
RETURNS TABLE (
    usx_dex_flows_pct_usx_activity NUMERIC,
    usx_kam_all_flows_pct_usx_activity NUMERIC,
    usx_exp_all_flows_pct_usx_activity NUMERIC,
    usx_eusx_yield_flows_pct_usx_activity NUMERIC,
    usx_allprotocol_flows NUMERIC,
    eusx_dex_flows_pct_eusx_activity NUMERIC,
    eusx_kam_all_flows_pct_eusx_activity NUMERIC,
    eusx_exp_all_flows_pct_eusx_activity NUMERIC,
    eusx_allprotocol_flows NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        xa.dex_volume_pct,
        xa.kam_volume_pct,
        xa.exp_volume_pct,
        0::NUMERIC,
        xa.all_protocol_volume,
        0::NUMERIC,
        0::NUMERIC,
        0::NUMERIC,
        0::NUMERIC
    FROM cross_protocol.get_view_xp_activity(lookback) xa;
END;
$$ LANGUAGE plpgsql STABLE;


-- =============================================================================
-- v_eusx_yield_vesting — yield vesting view (global_ecosystem.py._yield_rows)
-- Returns empty result set since ONyc has no eUSX yield vesting.
-- =============================================================================

DROP VIEW IF EXISTS solstice_proprietary.v_eusx_yield_vesting CASCADE;
CREATE OR REPLACE VIEW solstice_proprietary.v_eusx_yield_vesting AS
SELECT
    NOW()       AS bucket_time,
    0::NUMERIC  AS yield_eusx_pool_total_assets,
    0::NUMERIC  AS yield_eusx_pool_shares_supply,
    0::NUMERIC  AS yield_eusx_amount,
    0::NUMERIC  AS yield_eusx_apy_24h_pct,
    0::NUMERIC  AS yield_eusx_apy_7d_pct,
    0::NUMERIC  AS yield_eusx_apy_30d_pct
WHERE FALSE;

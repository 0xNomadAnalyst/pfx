-- =============================================================================
-- Seed hackathon.brief_config with shipped-default thresholds.
-- =============================================================================
-- Idempotent: ON CONFLICT DO NOTHING preserves any tuning done after seed.
-- To reset a value to defaults, delete the row first, then re-run this file.
-- =============================================================================

INSERT INTO hackathon.brief_config (item_id, key, value_num, value_text, notes) VALUES
-- Global
('_global', 'baseline_days',         7,      NULL, 'Trailing baseline window for all ''vs 7d'' comparisons'),

-- Ecosystem
('E1', 'pp_threshold',                2.0,    NULL, 'Supply composition share shift, percentage points vs 7d baseline'),
('E2', 'pct_threshold',               5.0,    NULL, 'Venue TVL share move vs 7d baseline, percentage points'),
('E3', 'pp_threshold',                3.0,    NULL, 'Availability bucket shift, percentage points'),
('E4', 'zscore_threshold',            2.0,    NULL, 'Activity rotation z-score vs 7d normal'),
('E5', 'bps_threshold',               50.0,   NULL, 'Yield spread widen/narrow vs 7d baseline, bps'),

-- DEXes
('D1', 'peg_bps_threshold',           25.0,   NULL, 'Off-peg threshold, bps from 1.00'),
('D1', 'drift_bps_threshold',         15.0,   NULL, '24h VWAP drift vs prior 24h, bps'),
('D2', 'pvalue_stat',                 NULL,   '99', 'Percentile stat in dexes.risk_pvalues for extreme sell threshold'),
('D3', 'depth_pct_threshold',         15.0,   NULL, 'Depth-in-peg-neighbourhood change vs 7d, %'),
('D4', 'pvalue_stat',                 NULL,   '95', 'Percentile stat for 24h net sell-pressure imbalance'),
('D4', 'pvalue_interval_mins',        1440,   NULL, 'sell_pressure_interval_mins to look up in risk_pvalues (1440 = 24h)'),
('D5', 'swap_onyc_threshold',         50000,  NULL, 'Large single-swap threshold, ONyc units'),
('D6', 'pool_pct_threshold',          5.0,    NULL, 'Single LP event threshold, % of pool'),

-- Kamino
('K1', 'zone_stressed_from_pct',      70.0,   NULL, 'Utilisation at or above this percent enters the stressed zone'),
('K1', 'zone_critical_from_pct',      90.0,   NULL, 'Utilisation at or above this percent enters the critical zone'),
('K3', 'apy_bps_threshold',           50.0,   NULL, 'Borrow APY move vs 24h ago, bps'),
('K4', 'tvl_pct_threshold',           10.0,   NULL, 'Reserve supply/borrow TVL move vs 7d baseline, %'),
('K4', 'min_tvl_floor',               10000,  NULL, 'Minimum absolute TVL (market value units) for K4 to consider a reserve — excludes dust-sized reserves'),
('K5', 'hf_floor',                    1.30,   NULL, 'Top-obligation HF floor below which item fires'),
('K5', 'hf_pct_threshold',            5.0,    NULL, 'Top-obligation HF move vs 7d baseline, %'),
('K5', 'top_n',                       10,     NULL, 'Watchlist size: top-N obligations by debt value'),
('K6', 'dar_pct_threshold',           10.0,   NULL, 'Aggregate debt-at-risk move vs 7d, %'),

-- Exponent
('X1', 'bps_threshold',               40.0,   NULL, 'Implied PT fixed APY move vs 24h ago, bps'),
('X2', 'bps_threshold',               40.0,   NULL, 'Fixed-variable spread change vs 24h ago, bps'),
('X3', 'pct_threshold',               15.0,   NULL, 'SY-in-pool or deployment ratio move vs 24h ago, %'),
('X4', 'pt_onyc_threshold',           25000,  NULL, 'Large PT trade threshold, ONyc-equivalent'),
('X5', 'expiry_warning_days',         7,      NULL, 'Days-to-expiry threshold for discovery-event firing')
ON CONFLICT (item_id, key) DO NOTHING;

-- =============================================================================
-- hackathon.brief_config — per-item tunable thresholds for the daily brief
-- =============================================================================
-- One row per (item_id, key). Views read this table via the cfg_num / cfg_text
-- helper functions so thresholds can be tuned via SQL UPDATE without a code
-- redeploy.
--
-- item_id convention: 'E1'..'E5' (ecosystem), 'D1'..'D6' (dexes),
--                     'K1'..'K6' (kamino), 'X1'..'X5' (exponent),
--                     '_global' (shared values such as baseline_days).
-- =============================================================================

CREATE TABLE IF NOT EXISTS hackathon.brief_config (
    item_id     text    NOT NULL,
    key         text    NOT NULL,
    value_num   numeric,
    value_text  text,
    notes       text,
    PRIMARY KEY (item_id, key)
);

COMMENT ON TABLE hackathon.brief_config IS
  'Per-item tunable thresholds for the daily brief. Views read via hackathon.cfg_num / hackathon.cfg_text.';

COMMENT ON COLUMN hackathon.brief_config.item_id IS
  'Brief item identifier (E1-E5, D1-D6, K1-K6, X1-X5) or ''_global'' for shared values.';
COMMENT ON COLUMN hackathon.brief_config.key IS
  'Threshold key (e.g. ''bps_threshold'', ''pct_threshold'', ''pvalue_stat''). Views reference this exact key.';
COMMENT ON COLUMN hackathon.brief_config.value_num IS
  'Numeric threshold value (bps, pp, %, ONyc units, HF). Populated for numeric thresholds.';
COMMENT ON COLUMN hackathon.brief_config.value_text IS
  'Text threshold value (e.g. percentile stat ''99''). Populated for text values.';

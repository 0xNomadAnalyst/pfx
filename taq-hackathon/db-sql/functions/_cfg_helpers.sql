-- =============================================================================
-- Config helpers — hackathon.cfg_num / hackathon.cfg_text
-- =============================================================================
-- Small lookup helpers that return a threshold from hackathon.brief_config,
-- falling back to a hardcoded default if the row is absent. Views reference
-- these so threshold overrides via SQL UPDATE take effect without a redeploy.
-- =============================================================================

CREATE OR REPLACE FUNCTION hackathon.cfg_num(
    p_item    text,
    p_key     text,
    p_default numeric
) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT value_num FROM hackathon.brief_config
         WHERE item_id = p_item AND key = p_key),
        p_default
    );
$$;

COMMENT ON FUNCTION hackathon.cfg_num(text, text, numeric) IS
  'Lookup helper: returns hackathon.brief_config.value_num for (item_id, key), falling back to p_default.';

CREATE OR REPLACE FUNCTION hackathon.cfg_text(
    p_item    text,
    p_key     text,
    p_default text
) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT value_text FROM hackathon.brief_config
         WHERE item_id = p_item AND key = p_key),
        p_default
    );
$$;

COMMENT ON FUNCTION hackathon.cfg_text(text, text, text) IS
  'Lookup helper: returns hackathon.brief_config.value_text for (item_id, key), falling back to p_default.';

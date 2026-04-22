-- =============================================================================
-- hackathon.get_brief — aggregate all fired items into a single jsonb payload
-- =============================================================================
-- Unions the four section collector views, groups by section, and packages the
-- result as:
--
--   {
--     "as_of":        <timestamptz>,
--     "generated_at": <timestamptz>,
--     "items_fired":  <int>,
--     "sections": {
--       "ecosystem": {"items": [...], "n_fired": <int>},
--       "dexes":     {"items": [...], "n_fired": <int>},
--       "kamino":    {"items": [...], "n_fired": <int>},
--       "exponent":  {"items": [...], "n_fired": <int>}
--     }
--   }
--
-- Every section key is always present, even on a quiet day, so the frontend
-- can render the "quiet day" form unconditionally.
--
-- p_as_of: accepted for API symmetry. The per-item views currently always
-- compare "last 24h" against now(); backfill is out of scope.
-- =============================================================================

CREATE OR REPLACE FUNCTION hackathon.get_brief(p_as_of timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH items AS (
        SELECT * FROM hackathon.v_brief_section_ecosystem
        UNION ALL SELECT * FROM hackathon.v_brief_section_dexes
        UNION ALL SELECT * FROM hackathon.v_brief_section_kamino
        UNION ALL SELECT * FROM hackathon.v_brief_section_exponent
    ),
    by_section AS (
        SELECT
            section,
            jsonb_agg(
                jsonb_build_object(
                    'item_id',       item_id,
                    'headline',      headline,
                    'direction',     direction,
                    'value_primary', value_primary,
                    'value_unit',    value_unit,
                    'value_delta',   value_delta,
                    'ref',           ref,
                    'supporting',    supporting
                )
                ORDER BY item_id
            )       AS items,
            count(*) AS n_fired
        FROM items
        GROUP BY section
    )
    SELECT jsonb_build_object(
        'as_of',        p_as_of,
        'generated_at', now(),
        'items_fired',  COALESCE((SELECT sum(n_fired)::int FROM by_section), 0),
        'sections', jsonb_build_object(
            'ecosystem', COALESCE(
                (SELECT jsonb_build_object('items', items, 'n_fired', n_fired)
                 FROM by_section WHERE section = 'ecosystem'),
                jsonb_build_object('items', '[]'::jsonb, 'n_fired', 0)
            ),
            'dexes', COALESCE(
                (SELECT jsonb_build_object('items', items, 'n_fired', n_fired)
                 FROM by_section WHERE section = 'dexes'),
                jsonb_build_object('items', '[]'::jsonb, 'n_fired', 0)
            ),
            'kamino', COALESCE(
                (SELECT jsonb_build_object('items', items, 'n_fired', n_fired)
                 FROM by_section WHERE section = 'kamino'),
                jsonb_build_object('items', '[]'::jsonb, 'n_fired', 0)
            ),
            'exponent', COALESCE(
                (SELECT jsonb_build_object('items', items, 'n_fired', n_fired)
                 FROM by_section WHERE section = 'exponent'),
                jsonb_build_object('items', '[]'::jsonb, 'n_fired', 0)
            )
        )
    );
$$;

COMMENT ON FUNCTION hackathon.get_brief(timestamptz) IS
  'Assemble a daily brief. Returns jsonb with per-section item lists. Every section key is present (even empty) so frontend renders quiet-day form unconditionally.';

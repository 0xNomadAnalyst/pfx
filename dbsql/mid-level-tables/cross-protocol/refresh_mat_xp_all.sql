-- refresh_mat_xp_all: Unified wrapper that calls both cross-protocol refresh procedures.
-- Called from onyc_refresh.sh Tier 1 hot-path (after domain mat refreshes).

CREATE SCHEMA IF NOT EXISTS cross_protocol;

CREATE OR REPLACE PROCEDURE cross_protocol.refresh_mat_xp_all()
LANGUAGE plpgsql AS $$
BEGIN
    CALL cross_protocol.refresh_mat_xp_ts_1m();
    CALL cross_protocol.refresh_mat_xp_last();
END;
$$;

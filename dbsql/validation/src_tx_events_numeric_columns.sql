-- Optional generated numeric columns for ranked-events hot path.
-- Apply only if your PostgreSQL/Timescale version supports generated columns on this table.

SET search_path = dexes, public;

ALTER TABLE dexes.src_tx_events
    ADD COLUMN IF NOT EXISTS swap_amount_in_num NUMERIC
        GENERATED ALWAYS AS (NULLIF(REGEXP_REPLACE(swap_amount_in, '[^0-9.-]', '', 'g'), '')::NUMERIC) STORED;

ALTER TABLE dexes.src_tx_events
    ADD COLUMN IF NOT EXISTS swap_amount_out_num NUMERIC
        GENERATED ALWAYS AS (NULLIF(REGEXP_REPLACE(swap_amount_out, '[^0-9.-]', '', 'g'), '')::NUMERIC) STORED;

ALTER TABLE dexes.src_tx_events
    ADD COLUMN IF NOT EXISTS liq_amount0_in_num NUMERIC
        GENERATED ALWAYS AS (NULLIF(REGEXP_REPLACE(liq_amount0_in, '[^0-9.-]', '', 'g'), '')::NUMERIC) STORED;

ALTER TABLE dexes.src_tx_events
    ADD COLUMN IF NOT EXISTS liq_amount0_out_num NUMERIC
        GENERATED ALWAYS AS (NULLIF(REGEXP_REPLACE(liq_amount0_out, '[^0-9.-]', '', 'g'), '')::NUMERIC) STORED;

ALTER TABLE dexes.src_tx_events
    ADD COLUMN IF NOT EXISTS liq_amount1_in_num NUMERIC
        GENERATED ALWAYS AS (NULLIF(REGEXP_REPLACE(liq_amount1_in, '[^0-9.-]', '', 'g'), '')::NUMERIC) STORED;

ALTER TABLE dexes.src_tx_events
    ADD COLUMN IF NOT EXISTS liq_amount1_out_num NUMERIC
        GENERATED ALWAYS AS (NULLIF(REGEXP_REPLACE(liq_amount1_out, '[^0-9.-]', '', 'g'), '')::NUMERIC) STORED;

CREATE INDEX IF NOT EXISTS idx_src_tx_events_proto_pair_event_time_num
ON dexes.src_tx_events (protocol, token_pair, event_type, time DESC);

SELECT 'src_tx_events_numeric_columns: complete' AS status;

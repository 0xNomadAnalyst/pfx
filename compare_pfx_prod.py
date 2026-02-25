"""
Cross-Database Comparison: PFX (new ingestion) vs Prod
Compares src_* tables and queue_health tables across dexes, exponent, kamino_lend schemas
on two separate TimescaleDB instances.

Exponent comparison is market-aware: normalizes metrics per base-token universe
since PFX tracks ONyc only while prod tracks a broader set (eUSX, USX, etc.).
"""

import psycopg2
from psycopg2.extras import RealDictCursor
from tabulate import tabulate
from datetime import datetime

# ── Connection configs ────────────────────────────────────────────────────────
PFX_DB = {
    'host': 'fd3cdmjulb.p56ar8nomm.tsdb.cloud.timescale.com',
    'port': 33971,
    'dbname': 'tsdb',
    'user': 'tsdbadmin',
    'password': 'ner5q1iamtwzkmmd',
    'sslmode': 'require',
    'connect_timeout': 30,
    'options': '-c statement_timeout=120000',  # 120s per-query safety net
}

PROD_DB = {
    'host': 'a8jzqfbmtz.ejn3vb45tt.tsdb.cloud.timescale.com',
    'port': 38924,
    'dbname': 'tsdb',
    'user': 'tsdbadmin',
    'password': 'ki32cz600lzoo9lc',
    'sslmode': 'require',
    'connect_timeout': 30,
    'options': '-c statement_timeout=120000',  # 120s per-query safety net
}

SCHEMAS = ['dexes', 'exponent', 'kamino_lend']

# ── Table definitions (from v_health_base_table) ─────────────────────────────
# schema -> [(table, time_col), ...]
KNOWN_SRC_TABLES = {
    'dexes': [
        ('src_acct_pool', 'time'),
        ('src_acct_vaults', 'time'),
        ('src_tx_events', 'time'),
        ('src_transactions', 'time'),
        ('src_acct_tickarray_queries', 'time'),
        ('src_acct_position', 'time'),
    ],
    'exponent': [
        ('src_vaults', 'time'),
        ('src_market_twos', 'time'),
        ('src_sy_meta_account', 'time'),
        ('src_sy_token_account', 'time'),
        ('src_vault_yield_position', 'time'),
        ('src_vault_yt_escrow', 'time'),
        ('src_base_token_escrow', 'time'),
        ('src_tx_events', 'time'),
        ('src_txns', 'time'),
    ],
    'kamino_lend': [
        ('src_reserves', 'time'),
        ('src_obligations', 'block_time'),
        ('src_obligations_agg', 'time'),
        ('src_lending_market', 'time'),
        ('src_txn', 'time'),
        ('src_txn_events', 'time'),
    ],
}

# ── Child tables that derive time from a parent via JOIN on query_id ──────────
# schema -> {child_table: (parent_table, join_col, parent_time_col)}
JOINED_TIME_TABLES = {
    'dexes': {
        'src_acct_tickarray_tokendist':        ('src_acct_tickarray_queries', 'query_id', 'time'),
        'src_acct_tickarray_tokendist_latest':  ('src_acct_tickarray_queries', 'query_id', 'time'),
    },
}

# ── Exponent: tables with meta_base_mint for per-token-universe breakdown ─────
# table -> (time_col, entity_col) where entity_col is the unique entity per poll cycle
EXPONENT_MARKET_TABLES = {
    'src_vaults':               ('time', 'vault_address', 'meta_base_mint'),
    'src_market_twos':          ('time', 'market_address', 'meta_base_mint'),
    'src_sy_meta_account':      ('time', 'sy_meta_address', 'meta_base_mint'),
    'src_sy_token_account':     ('time', 'mint_sy',         'meta_base_mint'),
    'src_vault_yield_position': ('time', 'yield_position_address', 'meta_base_mint'),
    'src_vault_yt_escrow':      ('time', 'escrow_yt_address',      'meta_base_mint'),
}

# ── Exponent: tables needing JOIN to resolve meta_base_mint ──────────────────
# These tables don't have meta_base_mint directly; derive via JOIN.
# join_sql uses {schema} placeholder; aliases: t = main table, mint_map = mapping subquery
# mint_map must provide a meta_base_mint column.
# entity_col: column for per-entity normalization.  Prefix with 'mint_map.' when the
#   entity comes from the joined mapping rather than the main table.
EXPONENT_JOINED_TABLES = {
    'src_tx_events': {
        'time_col': 'time',
        'entity_col': 't.vault_address',
        'join_sql': """
            JOIN (SELECT DISTINCT vault_address, meta_base_mint
                  FROM {schema}.src_vaults WHERE meta_base_mint IS NOT NULL) mint_map
            ON t.vault_address = mint_map.vault_address""",
    },
    'src_base_token_escrow': {
        'time_col': 'time',
        'entity_col': 't.escrow_address',
        'join_sql': """
            JOIN (SELECT DISTINCT ON (sy_meta_address) sy_meta_address, meta_base_mint
                  FROM {schema}.src_sy_meta_account
                  WHERE meta_base_mint IS NOT NULL
                  ORDER BY sy_meta_address, time DESC) mint_map
            ON t.owner = mint_map.sy_meta_address""",
    },
    'src_txns': {
        'time_col': 'time',
        'entity_col': 'mint_map.vault_address',
        'join_sql': """
            JOIN (SELECT DISTINCT ON (e.signature) e.signature, e.vault_address, v.meta_base_mint
                  FROM {schema}.src_tx_events e
                  JOIN (SELECT DISTINCT vault_address, meta_base_mint
                        FROM {schema}.src_vaults WHERE meta_base_mint IS NOT NULL) v
                  ON e.vault_address = v.vault_address
                  WHERE e.vault_address IS NOT NULL) mint_map
            ON t.signature = mint_map.signature""",
    },
}


def get_conn(cfg, label):
    print(f"  Connecting to {label} ({cfg['host'][:20]}...)...", end=" ", flush=True)
    conn = psycopg2.connect(**cfg)
    print("OK")
    return conn


def safe_query(conn, query, params=None):
    """Execute query and return results, or None on error."""
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(query, params)
            return [dict(r) for r in cur.fetchall()]
    except Exception as e:
        conn.rollback()
        return [{'_error': str(e)}]


def get_src_tables(conn, schema):
    """Discover all src_* tables in a schema."""
    rows = safe_query(conn, """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = %s AND table_name LIKE 'src_%%' AND table_type = 'BASE TABLE'
        ORDER BY table_name
    """, (schema,))
    if rows and '_error' not in rows[0]:
        return [r['table_name'] for r in rows]
    return []


def get_table_stats(conn, schema, table, time_col):
    """Get row count, latest time, rows in last 1h/24h for a table."""
    q = f"""
        SELECT
            (SELECT COUNT(*) FROM {schema}.{table}) AS total_rows,
            (SELECT MAX({time_col}) FROM {schema}.{table}) AS latest_time,
            (SELECT COUNT(*) FROM {schema}.{table} WHERE {time_col} > NOW() - INTERVAL '1 hour') AS rows_1h,
            (SELECT COUNT(*) FROM {schema}.{table} WHERE {time_col} > NOW() - INTERVAL '24 hours') AS rows_24h,
            (SELECT MIN({time_col}) FROM {schema}.{table}) AS earliest_time
    """
    rows = safe_query(conn, q)
    if rows and '_error' not in rows[0]:
        r = rows[0]
        mins_since = None
        if r['latest_time']:
            # query for server-side time diff
            td = safe_query(conn, f"SELECT EXTRACT(EPOCH FROM (NOW() - %s::timestamptz))/60.0 AS mins", (r['latest_time'],))
            if td and '_error' not in td[0]:
                mins_since = td[0]['mins']
        r['mins_since_latest'] = mins_since
        return r
    return rows[0] if rows else {'_error': 'no result'}


def get_table_stats_joined(conn, schema, table, parent_table, join_col, parent_time_col):
    """Get stats for a child table that has no time column of its own.

    Uses pg_class.reltuples for an approximate row count (instant, avoids full
    table scan on multi-million-row detail tables).  Falls back to exact COUNT(*)
    when reltuples is 0 (un-analyzed small tables).  Time-based metrics come from
    the parent table directly -- valid proxy since every parent row generates child
    rows in the same pipeline.  1h/24h counts reflect parent query activity.
    """
    q = f"""
        SELECT
            COALESCE(
                NULLIF(
                    (SELECT c.reltuples::bigint
                     FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
                     WHERE n.nspname = '{schema}' AND c.relname = '{table}'
                       AND c.reltuples > 0),
                    0),
                (SELECT COUNT(*) FROM {schema}.{table})
            ) AS total_rows,
            (SELECT MAX({parent_time_col})  FROM {schema}.{parent_table}) AS latest_time,
            (SELECT MIN({parent_time_col})  FROM {schema}.{parent_table}) AS earliest_time,
            (SELECT COUNT(*)            FROM {schema}.{parent_table}
             WHERE {parent_time_col} > NOW() - INTERVAL '1 hour')   AS rows_1h,
            (SELECT COUNT(*)            FROM {schema}.{parent_table}
             WHERE {parent_time_col} > NOW() - INTERVAL '24 hours') AS rows_24h
    """
    rows = safe_query(conn, q)
    if rows and '_error' not in rows[0]:
        r = rows[0]
        mins_since = None
        if r['latest_time']:
            td = safe_query(conn, f"SELECT EXTRACT(EPOCH FROM (NOW() - %s::timestamptz))/60.0 AS mins", (r['latest_time'],))
            if td and '_error' not in td[0]:
                mins_since = td[0]['mins']
        r['mins_since_latest'] = mins_since
        return r
    return rows[0] if rows else {'_error': 'no result'}


def get_queue_health_current(conn, schema):
    """Get current queue health from queue_health_current view."""
    q = f"""
        SELECT queue_name, queue_size, max_queue_size,
               queue_utilization_pct, write_rate_per_min,
               seconds_since_last_write, consecutive_failures,
               warning_level, time AS snapshot_time
        FROM {schema}.queue_health_current
        ORDER BY queue_name
    """
    return safe_query(conn, q)


def get_queue_health_stats_7d(conn, schema):
    """Get 7-day queue health statistics."""
    q = f"""
        SELECT queue_name,
               COUNT(*) AS sample_count_7d,
               PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY seconds_since_last_write) AS p50_staleness,
               PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY seconds_since_last_write) AS p95_staleness,
               PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY queue_utilization_pct)    AS p95_util,
               MAX(consecutive_failures) AS max_failures_7d,
               AVG(write_rate_per_min) AS avg_write_rate
        FROM {schema}.queue_health
        WHERE time > NOW() - INTERVAL '7 days'
          AND seconds_since_last_write IS NOT NULL
        GROUP BY queue_name
        ORDER BY queue_name
    """
    return safe_query(conn, q)


def fmt_time(dt):
    if dt is None:
        return "-"
    return dt.strftime('%Y-%m-%d %H:%M')


def fmt_num(v, decimals=0):
    if v is None:
        return "-"
    if isinstance(v, float):
        if decimals == 0:
            return f"{int(v):,}"
        return f"{v:,.{decimals}f}"
    return f"{v:,}"


def fmt_mins(m):
    if m is None:
        return "-"
    m = float(m)
    if m < 60:
        return f"{m:.1f}m"
    if m < 1440:
        return f"{m/60:.1f}h"
    return f"{m/1440:.1f}d"


def print_header(text, char='='):
    width = 100
    print(f"\n{char * width}")
    print(f"  {text}")
    print(f"{char * width}")


def get_exponent_base_token_universe(conn, schema):
    """Discover all base tokens being tracked, with human-readable symbols from src_sy_meta_account."""
    q = f"""
        WITH base_mints AS (
            SELECT DISTINCT meta_base_mint
            FROM {schema}.src_vaults
            WHERE meta_base_mint IS NOT NULL
        )
        SELECT
            bm.meta_base_mint AS base_mint,
            COALESCE(
                (SELECT DISTINCT meta_base_symbol FROM {schema}.src_sy_meta_account
                 WHERE meta_base_mint = bm.meta_base_mint AND meta_base_symbol IS NOT NULL
                 LIMIT 1),
                LEFT(bm.meta_base_mint, 8) || '...'
            ) AS symbol
        FROM base_mints bm
        ORDER BY symbol
    """
    return safe_query(conn, q)


def get_exponent_per_token_stats(conn, schema, table, time_col, entity_col, mint_col):
    """Get per-base-token breakdown: distinct entities, rows, freshness."""
    q = f"""
        SELECT
            {mint_col} AS base_mint,
            COUNT(DISTINCT {entity_col}) AS distinct_entities,
            COUNT(*) AS total_rows,
            MAX({time_col}) AS latest_time,
            SUM(CASE WHEN {time_col} > NOW() - INTERVAL '1 hour' THEN 1 ELSE 0 END) AS rows_1h,
            SUM(CASE WHEN {time_col} > NOW() - INTERVAL '24 hours' THEN 1 ELSE 0 END) AS rows_24h,
            EXTRACT(EPOCH FROM (NOW() - MAX({time_col})))/60.0 AS mins_since_latest
        FROM {schema}.{table}
        WHERE {mint_col} IS NOT NULL
        GROUP BY {mint_col}
        ORDER BY total_rows DESC
    """
    return safe_query(conn, q)


def get_exponent_per_entity_rates(conn, schema, table, time_col, entity_col, mint_col):
    """
    Compute per-entity average rows/hour in the last 24h for each base token.
    This normalizes for different numbers of markets being tracked.
    """
    q = f"""
        WITH entity_rates AS (
            SELECT
                {mint_col} AS base_mint,
                {entity_col} AS entity,
                COUNT(*) AS rows_24h,
                COUNT(*)::float / 24.0 AS rows_per_hour
            FROM {schema}.{table}
            WHERE {time_col} > NOW() - INTERVAL '24 hours'
              AND {mint_col} IS NOT NULL
            GROUP BY {mint_col}, {entity_col}
        )
        SELECT
            base_mint,
            COUNT(*) AS active_entities,
            AVG(rows_per_hour) AS avg_rows_per_entity_per_hour,
            MIN(rows_per_hour) AS min_rows_per_entity_per_hour,
            MAX(rows_per_hour) AS max_rows_per_entity_per_hour,
            SUM(rows_24h) AS total_rows_24h
        FROM entity_rates
        GROUP BY base_mint
        ORDER BY total_rows_24h DESC
    """
    return safe_query(conn, q)


def get_exponent_per_token_stats_joined(conn, schema, table, cfg):
    """Get per-base-token breakdown for tables that need a JOIN to resolve meta_base_mint."""
    time_col = cfg['time_col']
    entity_ref = cfg['entity_col']  # fully qualified, e.g. 't.vault_address' or 'mint_map.vault_address'
    join_sql = cfg['join_sql'].format(schema=schema)

    q = f"""
        SELECT
            mint_map.meta_base_mint AS base_mint,
            COUNT(DISTINCT {entity_ref}) AS distinct_entities,
            COUNT(*) AS total_rows,
            MAX(t.{time_col}) AS latest_time,
            SUM(CASE WHEN t.{time_col} > NOW() - INTERVAL '1 hour' THEN 1 ELSE 0 END) AS rows_1h,
            SUM(CASE WHEN t.{time_col} > NOW() - INTERVAL '24 hours' THEN 1 ELSE 0 END) AS rows_24h,
            EXTRACT(EPOCH FROM (NOW() - MAX(t.{time_col})))/60.0 AS mins_since_latest
        FROM {schema}.{table} t
        {join_sql}
        GROUP BY mint_map.meta_base_mint
        ORDER BY total_rows DESC
    """
    return safe_query(conn, q)


def get_exponent_per_entity_rates_joined(conn, schema, table, cfg):
    """Compute per-entity rows/hour for tables needing JOIN to resolve meta_base_mint."""
    time_col = cfg['time_col']
    entity_ref = cfg['entity_col']  # fully qualified, e.g. 't.vault_address' or 'mint_map.vault_address'
    join_sql = cfg['join_sql'].format(schema=schema)

    q = f"""
        WITH entity_rates AS (
            SELECT
                mint_map.meta_base_mint AS base_mint,
                {entity_ref} AS entity,
                COUNT(*) AS rows_24h,
                COUNT(*)::float / 24.0 AS rows_per_hour
            FROM {schema}.{table} t
            {join_sql}
            WHERE t.{time_col} > NOW() - INTERVAL '24 hours'
            GROUP BY mint_map.meta_base_mint, {entity_ref}
        )
        SELECT
            base_mint,
            COUNT(*) AS active_entities,
            AVG(rows_per_hour) AS avg_rows_per_entity_per_hour,
            MIN(rows_per_hour) AS min_rows_per_entity_per_hour,
            MAX(rows_per_hour) AS max_rows_per_entity_per_hour,
            SUM(rows_24h) AS total_rows_24h
        FROM entity_rates
        GROUP BY base_mint
        ORDER BY total_rows_24h DESC
    """
    return safe_query(conn, q)


def run_exponent_market_comparison(pfx_conn, prod_conn, schema='exponent'):
    """
    Market-aware comparison for Exponent:
    - Shows what base tokens each DB is tracking
    - Normalizes per-entity throughput so PFX (ONyc only) can be fairly compared
      to prod (eUSX, USX, and potentially others)
    """
    print_header(f"SCHEMA: {schema} - Exponent Market-Aware Comparison")

    # 1. Discover token universes
    pfx_tokens = get_exponent_base_token_universe(pfx_conn, schema)
    prod_tokens = get_exponent_base_token_universe(prod_conn, schema)

    pfx_tok_err = pfx_tokens and '_error' in pfx_tokens[0]
    prod_tok_err = prod_tokens and '_error' in prod_tokens[0]

    if pfx_tok_err:
        print(f"\n  PFX error: {pfx_tokens[0]['_error']}")
    if prod_tok_err:
        print(f"\n  PROD error: {prod_tokens[0]['_error']}")

    pfx_tok_map = {r['base_mint']: r['symbol'] for r in pfx_tokens} if not pfx_tok_err else {}
    prod_tok_map = {r['base_mint']: r['symbol'] for r in prod_tokens} if not prod_tok_err else {}

    all_mints = sorted(set(pfx_tok_map.keys()) | set(prod_tok_map.keys()))

    print(f"\n  PFX base tokens:  {len(pfx_tok_map)} - {', '.join(pfx_tok_map.values()) or 'none'}")
    print(f"  PROD base tokens: {len(prod_tok_map)} - {', '.join(prod_tok_map.values()) or 'none'}")

    tok_rows = []
    for mint in all_mints:
        pfx_sym = pfx_tok_map.get(mint, '-')
        prod_sym = prod_tok_map.get(mint, '-')
        in_pfx = 'Y' if mint in pfx_tok_map else '-'
        in_prod = 'Y' if mint in prod_tok_map else '-'
        tok_rows.append([pfx_sym or prod_sym, mint[:16] + '...', in_pfx, in_prod])

    print()
    print(tabulate(tok_rows,
                   headers=['Symbol', 'Base Mint', 'In PFX', 'In PROD'],
                   tablefmt='simple'))

    # 2. Per-table, per-base-token breakdown
    for table, (time_col, entity_col, mint_col) in EXPONENT_MARKET_TABLES.items():
        print_header(f"  exponent.{table} - Per-Token Breakdown", char='-')

        pfx_stats = get_exponent_per_token_stats(pfx_conn, schema, table, time_col, entity_col, mint_col)
        prod_stats = get_exponent_per_token_stats(prod_conn, schema, table, time_col, entity_col, mint_col)

        pfx_err = pfx_stats and pfx_stats[0].get('_error')
        prod_err = prod_stats and prod_stats[0].get('_error')

        if pfx_err:
            print(f"\n  PFX: {pfx_stats[0]['_error']}")
        if prod_err:
            print(f"\n  PROD: {prod_stats[0]['_error']}")

        pfx_by_mint = {r['base_mint']: r for r in pfx_stats} if not pfx_err else {}
        prod_by_mint = {r['base_mint']: r for r in prod_stats} if not prod_err else {}
        all_m = sorted(set(pfx_by_mint.keys()) | set(prod_by_mint.keys()),
                       key=lambda m: pfx_tok_map.get(m, prod_tok_map.get(m, m)))

        if not all_m:
            print("\n  No data with meta_base_mint in this table.")
            continue

        breakdown_rows = []
        for mint in all_m:
            sym = pfx_tok_map.get(mint, prod_tok_map.get(mint, mint[:12] + '...'))
            p = pfx_by_mint.get(mint, {})
            r = prod_by_mint.get(mint, {})

            breakdown_rows.append([
                sym,
                fmt_num(p.get('distinct_entities')) if p else '-',
                fmt_num(r.get('distinct_entities')) if r else '-',
                fmt_num(p.get('total_rows')) if p else '-',
                fmt_num(r.get('total_rows')) if r else '-',
                fmt_num(p.get('rows_1h')) if p else '-',
                fmt_num(r.get('rows_1h')) if r else '-',
                fmt_num(p.get('rows_24h')) if p else '-',
                fmt_num(r.get('rows_24h')) if r else '-',
                fmt_mins(p.get('mins_since_latest')) if p else '-',
                fmt_mins(r.get('mins_since_latest')) if r else '-',
            ])

        print()
        print(tabulate(
            breakdown_rows,
            headers=['Token', 'PFX #Ent', 'PROD #Ent', 'PFX Rows', 'PROD Rows',
                     'PFX 1h', 'PROD 1h', 'PFX 24h', 'PROD 24h',
                     'PFX Age', 'PROD Age'],
            tablefmt='simple',
            colalign=('left', 'right', 'right', 'right', 'right',
                      'right', 'right', 'right', 'right', 'right', 'right'),
        ))

        # 3. Per-entity normalized rates (the fair comparison)
        pfx_rates = get_exponent_per_entity_rates(pfx_conn, schema, table, time_col, entity_col, mint_col)
        prod_rates = get_exponent_per_entity_rates(prod_conn, schema, table, time_col, entity_col, mint_col)

        pfx_r_err = pfx_rates and pfx_rates[0].get('_error')
        prod_r_err = prod_rates and prod_rates[0].get('_error')

        pfx_r_by_mint = {r['base_mint']: r for r in pfx_rates} if not pfx_r_err else {}
        prod_r_by_mint = {r['base_mint']: r for r in prod_rates} if not prod_r_err else {}
        all_r_m = sorted(set(pfx_r_by_mint.keys()) | set(prod_r_by_mint.keys()),
                         key=lambda m: pfx_tok_map.get(m, prod_tok_map.get(m, m)))

        if all_r_m:
            rate_rows = []
            for mint in all_r_m:
                sym = pfx_tok_map.get(mint, prod_tok_map.get(mint, mint[:12] + '...'))
                p = pfx_r_by_mint.get(mint, {})
                r = prod_r_by_mint.get(mint, {})

                rate_rows.append([
                    sym,
                    fmt_num(p.get('active_entities')) if p else '-',
                    fmt_num(r.get('active_entities')) if r else '-',
                    f"{p.get('avg_rows_per_entity_per_hour', 0):.1f}" if p else '-',
                    f"{r.get('avg_rows_per_entity_per_hour', 0):.1f}" if r else '-',
                    f"{p.get('min_rows_per_entity_per_hour', 0):.1f}" if p else '-',
                    f"{r.get('min_rows_per_entity_per_hour', 0):.1f}" if r else '-',
                    f"{p.get('max_rows_per_entity_per_hour', 0):.1f}" if p else '-',
                    f"{r.get('max_rows_per_entity_per_hour', 0):.1f}" if r else '-',
                ])

            print(f"\n  Per-entity rows/hour (last 24h) - normalized for market count:")
            print()
            print(tabulate(
                rate_rows,
                headers=['Token', 'PFX Ent', 'PROD Ent',
                         'PFX Avg/e/h', 'PROD Avg/e/h',
                         'PFX Min/e/h', 'PROD Min/e/h',
                         'PFX Max/e/h', 'PROD Max/e/h'],
                tablefmt='simple',
                colalign=('left', 'right', 'right', 'right', 'right',
                          'right', 'right', 'right', 'right'),
            ))

    # 4. Tables that need a JOIN to resolve meta_base_mint (tx_events, txns, base_token_escrow)
    for table, cfg in EXPONENT_JOINED_TABLES.items():
        print_header(f"  exponent.{table} - Per-Token Breakdown (via JOIN)", char='-')

        pfx_stats = get_exponent_per_token_stats_joined(pfx_conn, schema, table, cfg)
        prod_stats = get_exponent_per_token_stats_joined(prod_conn, schema, table, cfg)

        pfx_err = pfx_stats and pfx_stats[0].get('_error')
        prod_err = prod_stats and prod_stats[0].get('_error')

        if pfx_err:
            print(f"\n  PFX: {pfx_stats[0]['_error']}")
        if prod_err:
            print(f"\n  PROD: {prod_stats[0]['_error']}")

        pfx_by_mint = {r['base_mint']: r for r in pfx_stats} if not pfx_err else {}
        prod_by_mint = {r['base_mint']: r for r in prod_stats} if not prod_err else {}
        all_m = sorted(set(pfx_by_mint.keys()) | set(prod_by_mint.keys()),
                       key=lambda m: pfx_tok_map.get(m, prod_tok_map.get(m, m)))

        if not all_m:
            print("\n  No data with meta_base_mint resolvable via JOIN in this table.")
            continue

        breakdown_rows = []
        for mint in all_m:
            sym = pfx_tok_map.get(mint, prod_tok_map.get(mint, mint[:12] + '...'))
            p = pfx_by_mint.get(mint, {})
            r = prod_by_mint.get(mint, {})

            breakdown_rows.append([
                sym,
                fmt_num(p.get('distinct_entities')) if p else '-',
                fmt_num(r.get('distinct_entities')) if r else '-',
                fmt_num(p.get('total_rows')) if p else '-',
                fmt_num(r.get('total_rows')) if r else '-',
                fmt_num(p.get('rows_1h')) if p else '-',
                fmt_num(r.get('rows_1h')) if r else '-',
                fmt_num(p.get('rows_24h')) if p else '-',
                fmt_num(r.get('rows_24h')) if r else '-',
                fmt_mins(p.get('mins_since_latest')) if p else '-',
                fmt_mins(r.get('mins_since_latest')) if r else '-',
            ])

        print()
        print(tabulate(
            breakdown_rows,
            headers=['Token', 'PFX #Ent', 'PROD #Ent', 'PFX Rows', 'PROD Rows',
                     'PFX 1h', 'PROD 1h', 'PFX 24h', 'PROD 24h',
                     'PFX Age', 'PROD Age'],
            tablefmt='simple',
            colalign=('left', 'right', 'right', 'right', 'right',
                      'right', 'right', 'right', 'right', 'right', 'right'),
        ))

        # Per-entity normalized rates
        pfx_rates = get_exponent_per_entity_rates_joined(pfx_conn, schema, table, cfg)
        prod_rates = get_exponent_per_entity_rates_joined(prod_conn, schema, table, cfg)

        pfx_r_err = pfx_rates and pfx_rates[0].get('_error')
        prod_r_err = prod_rates and prod_rates[0].get('_error')

        pfx_r_by_mint = {r['base_mint']: r for r in pfx_rates} if not pfx_r_err else {}
        prod_r_by_mint = {r['base_mint']: r for r in prod_rates} if not prod_r_err else {}
        all_r_m = sorted(set(pfx_r_by_mint.keys()) | set(prod_r_by_mint.keys()),
                         key=lambda m: pfx_tok_map.get(m, prod_tok_map.get(m, m)))

        if all_r_m:
            rate_rows = []
            for mint in all_r_m:
                sym = pfx_tok_map.get(mint, prod_tok_map.get(mint, mint[:12] + '...'))
                p = pfx_r_by_mint.get(mint, {})
                r = prod_r_by_mint.get(mint, {})

                rate_rows.append([
                    sym,
                    fmt_num(p.get('active_entities')) if p else '-',
                    fmt_num(r.get('active_entities')) if r else '-',
                    f"{p.get('avg_rows_per_entity_per_hour', 0):.1f}" if p else '-',
                    f"{r.get('avg_rows_per_entity_per_hour', 0):.1f}" if r else '-',
                    f"{p.get('min_rows_per_entity_per_hour', 0):.1f}" if p else '-',
                    f"{r.get('min_rows_per_entity_per_hour', 0):.1f}" if r else '-',
                    f"{p.get('max_rows_per_entity_per_hour', 0):.1f}" if p else '-',
                    f"{r.get('max_rows_per_entity_per_hour', 0):.1f}" if r else '-',
                ])

            print(f"\n  Per-entity rows/hour (last 24h) - normalized for market count:")
            print()
            print(tabulate(
                rate_rows,
                headers=['Token', 'PFX Ent', 'PROD Ent',
                         'PFX Avg/e/h', 'PROD Avg/e/h',
                         'PFX Min/e/h', 'PROD Min/e/h',
                         'PFX Max/e/h', 'PROD Max/e/h'],
                tablefmt='simple',
                colalign=('left', 'right', 'right', 'right', 'right',
                          'right', 'right', 'right', 'right'),
            ))


def run_comparison():
    print("=" * 100)
    print(f"  PFX vs PROD - Cross-Database Ingestion Comparison")
    print(f"  Timestamp: {datetime.now().isoformat()}")
    print(f"  Schemas: {', '.join(SCHEMAS)}")
    print("=" * 100)

    pfx_conn = get_conn(PFX_DB, "PFX")
    prod_conn = get_conn(PROD_DB, "PROD")

    try:
        # ──────────────────────────────────────────────────────────────────
        # PART 1: src_* Table Comparison
        # ──────────────────────────────────────────────────────────────────
        for schema in SCHEMAS:
            print_header(f"SCHEMA: {schema} - src_* Tables")

            # Discover tables on both sides
            pfx_tables = set(get_src_tables(pfx_conn, schema))
            prod_tables = set(get_src_tables(prod_conn, schema))
            all_tables = sorted(pfx_tables | prod_tables)

            only_pfx = pfx_tables - prod_tables
            only_prod = prod_tables - pfx_tables

            if only_pfx:
                print(f"\n  Tables ONLY in PFX:  {sorted(only_pfx)}")
            if only_prod:
                print(f"  Tables ONLY in PROD: {sorted(only_prod)}")

            # Use known time columns, fallback to 'time'
            known = {t: tc for t, tc in KNOWN_SRC_TABLES.get(schema, [])}
            joined = JOINED_TIME_TABLES.get(schema, {})

            summary_rows = []
            for tbl in all_tables:
                in_pfx = tbl in pfx_tables
                in_prod = tbl in prod_tables

                # Check if this child table needs a JOIN to derive time
                if tbl in joined:
                    parent_table, join_col, parent_time_col = joined[tbl]
                    pfx_stats = get_table_stats_joined(pfx_conn, schema, tbl, parent_table, join_col, parent_time_col) if in_pfx else {}
                    prod_stats = get_table_stats_joined(prod_conn, schema, tbl, parent_table, join_col, parent_time_col) if in_prod else {}
                else:
                    tc = known.get(tbl, 'time')
                    pfx_stats = get_table_stats(pfx_conn, schema, tbl, tc) if in_pfx else {}
                    prod_stats = get_table_stats(prod_conn, schema, tbl, tc) if in_prod else {}

                pfx_err = pfx_stats.get('_error')
                prod_err = prod_stats.get('_error')

                summary_rows.append([
                    tbl,
                    fmt_num(pfx_stats.get('total_rows')) if not pfx_err else f"ERR",
                    fmt_num(prod_stats.get('total_rows')) if not prod_err else f"ERR",
                    fmt_num(pfx_stats.get('rows_1h')) if not pfx_err else "-",
                    fmt_num(prod_stats.get('rows_1h')) if not prod_err else "-",
                    fmt_num(pfx_stats.get('rows_24h')) if not pfx_err else "-",
                    fmt_num(prod_stats.get('rows_24h')) if not prod_err else "-",
                    fmt_mins(pfx_stats.get('mins_since_latest')) if not pfx_err else "-",
                    fmt_mins(prod_stats.get('mins_since_latest')) if not prod_err else "-",
                    fmt_time(pfx_stats.get('latest_time')) if not pfx_err else "-",
                    fmt_time(prod_stats.get('latest_time')) if not prod_err else "-",
                ])

            print()
            print(tabulate(
                summary_rows,
                headers=['Table', 'PFX Rows', 'PROD Rows',
                         'PFX 1h', 'PROD 1h', 'PFX 24h', 'PROD 24h',
                         'PFX Age', 'PROD Age', 'PFX Latest', 'PROD Latest'],
                tablefmt='simple',
                colalign=('left', 'right', 'right', 'right', 'right', 'right', 'right',
                          'right', 'right', 'right', 'right'),
            ))

        # ──────────────────────────────────────────────────────────────────
        # PART 1b: Exponent Market-Aware Comparison
        # ──────────────────────────────────────────────────────────────────
        run_exponent_market_comparison(pfx_conn, prod_conn, 'exponent')

        # ──────────────────────────────────────────────────────────────────
        # PART 2: Queue Health Comparison
        # ──────────────────────────────────────────────────────────────────
        for schema in SCHEMAS:
            print_header(f"SCHEMA: {schema} - Queue Health (Current)")

            pfx_qh = get_queue_health_current(pfx_conn, schema)
            prod_qh = get_queue_health_current(prod_conn, schema)

            pfx_has_err = pfx_qh and '_error' in pfx_qh[0]
            prod_has_err = prod_qh and '_error' in prod_qh[0]

            if pfx_has_err:
                print(f"\n  PFX: {pfx_qh[0]['_error']}")
            if prod_has_err:
                print(f"\n  PROD: {prod_qh[0]['_error']}")

            if pfx_has_err and prod_has_err:
                continue

            # Build a unified view: queue_name -> {pfx: ..., prod: ...}
            pfx_by_q = {r['queue_name']: r for r in pfx_qh} if not pfx_has_err else {}
            prod_by_q = {r['queue_name']: r for r in prod_qh} if not prod_has_err else {}
            all_queues = sorted(set(pfx_by_q.keys()) | set(prod_by_q.keys()))

            if not all_queues:
                print("\n  No queue_health data found in either DB for this schema.")
                continue

            qh_rows = []
            for qn in all_queues:
                p = pfx_by_q.get(qn, {})
                r = prod_by_q.get(qn, {})
                qh_rows.append([
                    qn,
                    # Queue size / util
                    f"{p.get('queue_size', '-')}/{p.get('max_queue_size', '-')}" if p else "-",
                    f"{r.get('queue_size', '-')}/{r.get('max_queue_size', '-')}" if r else "-",
                    f"{p.get('queue_utilization_pct', 0):.1f}%" if p else "-",
                    f"{r.get('queue_utilization_pct', 0):.1f}%" if r else "-",
                    # Write rate
                    f"{p.get('write_rate_per_min', 0):.1f}" if p else "-",
                    f"{r.get('write_rate_per_min', 0):.1f}" if r else "-",
                    # Staleness
                    fmt_mins(p.get('seconds_since_last_write', None) / 60.0) if p and p.get('seconds_since_last_write') is not None else "-",
                    fmt_mins(r.get('seconds_since_last_write', None) / 60.0) if r and r.get('seconds_since_last_write') is not None else "-",
                    # Failures
                    p.get('consecutive_failures', '-') if p else "-",
                    r.get('consecutive_failures', '-') if r else "-",
                    # Warning
                    p.get('warning_level', '-') if p else "-",
                    r.get('warning_level', '-') if r else "-",
                ])

            print()
            print(tabulate(
                qh_rows,
                headers=['Queue', 'PFX Q', 'PROD Q', 'PFX Util', 'PROD Util',
                         'PFX Wr/m', 'PROD Wr/m', 'PFX Stale', 'PROD Stale',
                         'PFX Fail', 'PROD Fail', 'PFX Warn', 'PROD Warn'],
                tablefmt='simple',
                colalign=('left', 'right', 'right', 'right', 'right',
                          'right', 'right', 'right', 'right',
                          'right', 'right', 'right', 'right'),
            ))

            # Also show 7-day P95 benchmarks
            print_header(f"SCHEMA: {schema} - Queue Health (7-day P95 Benchmarks)", char='-')

            pfx_bench = get_queue_health_stats_7d(pfx_conn, schema)
            prod_bench = get_queue_health_stats_7d(prod_conn, schema)

            pfx_b_err = pfx_bench and '_error' in pfx_bench[0]
            prod_b_err = prod_bench and '_error' in prod_bench[0]

            if pfx_b_err:
                print(f"\n  PFX: {pfx_bench[0]['_error']}")
            if prod_b_err:
                print(f"\n  PROD: {prod_bench[0]['_error']}")

            pfx_b_by_q = {r['queue_name']: r for r in pfx_bench} if not pfx_b_err else {}
            prod_b_by_q = {r['queue_name']: r for r in prod_bench} if not prod_b_err else {}
            all_bq = sorted(set(pfx_b_by_q.keys()) | set(prod_b_by_q.keys()))

            if all_bq:
                bench_rows = []
                for qn in all_bq:
                    p = pfx_b_by_q.get(qn, {})
                    r = prod_b_by_q.get(qn, {})
                    bench_rows.append([
                        qn,
                        fmt_num(p.get('sample_count_7d'), 0) if p else "-",
                        fmt_num(r.get('sample_count_7d'), 0) if r else "-",
                        f"{p.get('p50_staleness', 0):.0f}s" if p else "-",
                        f"{r.get('p50_staleness', 0):.0f}s" if r else "-",
                        f"{p.get('p95_staleness', 0):.0f}s" if p else "-",
                        f"{r.get('p95_staleness', 0):.0f}s" if r else "-",
                        f"{p.get('p95_util', 0):.1f}%" if p else "-",
                        f"{r.get('p95_util', 0):.1f}%" if r else "-",
                        f"{p.get('avg_write_rate', 0):.1f}" if p else "-",
                        f"{r.get('avg_write_rate', 0):.1f}" if r else "-",
                        p.get('max_failures_7d', '-') if p else "-",
                        r.get('max_failures_7d', '-') if r else "-",
                    ])

                print()
                print(tabulate(
                    bench_rows,
                    headers=['Queue', 'PFX #7d', 'PROD #7d',
                             'PFX p50 Stale', 'PROD p50 Stale',
                             'PFX p95 Stale', 'PROD p95 Stale',
                             'PFX p95 Util', 'PROD p95 Util',
                             'PFX Avg Wr/m', 'PROD Avg Wr/m',
                             'PFX Max Fail', 'PROD Max Fail'],
                    tablefmt='simple',
                    colalign=('left', 'right', 'right', 'right', 'right',
                              'right', 'right', 'right', 'right',
                              'right', 'right', 'right', 'right'),
                ))

    finally:
        pfx_conn.close()
        prod_conn.close()

    print("\n" + "=" * 100)
    print("  Comparison complete.")
    print("=" * 100)


if __name__ == '__main__':
    run_comparison()

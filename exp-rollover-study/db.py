"""Reusable DB connection helper for the rollover study."""
import os
import psycopg2
import psycopg2.extras

DB_CONFIG = {
    "host": "a8jzqfbmtz.ejn3vb45tt.tsdb.cloud.timescale.com",
    "port": 38924,
    "dbname": "tsdb",
    "user": "tsdbadmin",
    "password": "ki32cz600lzoo9lc",
    "sslmode": "require",
}

def get_conn():
    return psycopg2.connect(**DB_CONFIG)

def run_query(sql, params=None):
    """Run a query and return (columns, rows)."""
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
    return cols, rows

def run_query_dict(sql, params=None):
    """Run a query and return list of dicts."""
    with get_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            return cur.fetchall()

def md_table(cols, rows, max_col_width=60):
    """Format columns + rows as a markdown table string."""
    str_rows = []
    for r in rows:
        str_rows.append([str(v)[:max_col_width] if v is not None else "" for v in r])
    widths = [max(len(c), *(len(r[i]) for r in str_rows)) for i, c in enumerate(cols)] if str_rows else [len(c) for c in cols]
    header = "| " + " | ".join(c.ljust(w) for c, w in zip(cols, widths)) + " |"
    sep = "| " + " | ".join("-" * w for w in widths) + " |"
    lines = [header, sep]
    for r in str_rows:
        lines.append("| " + " | ".join(v.ljust(w) for v, w in zip(r, widths)) + " |")
    return "\n".join(lines)

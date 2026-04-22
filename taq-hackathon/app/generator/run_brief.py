"""Brief generator CLI.

Calls hackathon.get_brief(as_of) and upserts the resulting jsonb payload into
hackathon.brief for a single calendar date (UTC).

Usage:
    python -m app.generator.run_brief                  # today (UTC)
    python -m app.generator.run_brief --date 2026-04-21
    python -m app.generator.run_brief --dry-run        # prints payload; no write

Failure posture:
    Fail-closed. On any exception the runner exits 1 with a stack trace and
    the hackathon.brief table is left untouched.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from datetime import date, datetime, time, timezone

from app import db
from app.generator.narrative import (
    PLACEHOLDER_NARRATIVE,
    PLACEHOLDER_SLACK_DIGEST,
    QUIET_DAY_NARRATIVE,
    synthesise_narrative,
)


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("run_brief")


def _parse_date(s: str) -> date:
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError as exc:
        raise SystemExit(f"invalid --date (expected YYYY-MM-DD): {s}") from exc


def _as_of(brief_date: date) -> datetime:
    """End-of-day anchor in UTC for the given date. For today, we use now()."""
    today_utc = datetime.now(timezone.utc).date()
    if brief_date == today_utc:
        return datetime.now(timezone.utc)
    # End-of-day for historical dates
    return datetime.combine(brief_date, time(23, 59, 59), tzinfo=timezone.utc)


def generate(brief_date: date, dry_run: bool = False) -> int:
    as_of = _as_of(brief_date)
    log.info("generating brief for %s (as_of=%s)", brief_date.isoformat(), as_of.isoformat())

    with db.connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT hackathon.get_brief(%s);", (as_of,))
        row = cur.fetchone()
        if row is None or row[0] is None:
            log.error("hackathon.get_brief() returned NULL")
            return 1
        payload = row[0]

        # Wrap an analyst-voice narrative around the structured items. When
        # PERPLEXITY_API_KEY is unset (stub no-op), fall through to the sample
        # PLACEHOLDER_NARRATIVE so the detail page still has prose to show; the
        # frontend labels this as a sample. Once the key is set, real LLM
        # output replaces the sample automatically.
        narrative = synthesise_narrative(payload)
        if narrative is None:
            payload["narrative"]        = PLACEHOLDER_NARRATIVE
            payload["narrative_source"] = "placeholder"
        elif narrative == QUIET_DAY_NARRATIVE:
            payload["narrative"]        = narrative
            payload["narrative_source"] = "canned-quiet"
        else:
            payload["narrative"]        = narrative
            payload["narrative_source"] = "perplexity"

        # Slack digest: static mockup for now. When the Slack webhook
        # integration lands in phase-2, this slot will carry an LLM-generated
        # short-form digest. The frontend renders it as a "Slack preview"
        # card on the detail page, labelled as a sample while it is static.
        payload["slack_digest"]        = PLACEHOLDER_SLACK_DIGEST
        payload["slack_digest_source"] = "placeholder"

        n_items = int(payload.get("items_fired", 0) or 0)
        n_sections = sum(
            1 for s in (payload.get("sections") or {}).values() if s and s.get("n_fired", 0) > 0
        )

        if dry_run:
            print(json.dumps(payload, indent=2, default=str))
            log.info("dry-run: %d item(s) fired across %d section(s), NOT persisted", n_items, n_sections)
            return 0

        cur.execute(
            """
            INSERT INTO hackathon.brief (brief_date, generated_at, items_fired, payload)
            VALUES (%s, now(), %s, %s)
            ON CONFLICT (brief_date) DO UPDATE SET
                generated_at = EXCLUDED.generated_at,
                items_fired  = EXCLUDED.items_fired,
                payload      = EXCLUDED.payload;
            """,
            (brief_date, n_items, json.dumps(payload, default=str)),
        )
        conn.commit()

    log.info(
        "brief for %s generated and persisted: %d item(s) fired across %d section(s)",
        brief_date.isoformat(), n_items, n_sections,
    )
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate a daily brief.")
    parser.add_argument("--date", type=_parse_date, default=datetime.now(timezone.utc).date(),
                        help="UTC calendar date (YYYY-MM-DD); defaults to today")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print the payload and exit without writing to the brief table")
    args = parser.parse_args()

    try:
        sys.exit(generate(args.date, dry_run=args.dry_run))
    except Exception:  # noqa: BLE001
        log.exception("brief generation failed")
        sys.exit(1)


if __name__ == "__main__":
    main()

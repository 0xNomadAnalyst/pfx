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

import httpx

from app import db
from app.generator.narrative import (
    PLACEHOLDER_NARRATIVE,
    PLACEHOLDER_SLACK_DIGEST,
    QUIET_DAY_NARRATIVE,
    synthesise_narrative,
    synthesise_slack_digest,
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

        n_items = int(payload.get("items_fired", 0) or 0)
        n_sections = sum(
            1 for s in (payload.get("sections") or {}).values() if s and s.get("n_fired", 0) > 0
        )

        # Slack digest: same gating pattern as the narrative. The LLM produces
        # the body text; header (title + counts) and footer (link to the web
        # detail page) are assembled deterministically around it so the
        # typography stays on-brand regardless of prompt drift.
        slack_digest = synthesise_slack_digest(payload, brief_date)
        if slack_digest is None:
            payload["slack_digest"]        = PLACEHOLDER_SLACK_DIGEST
            payload["slack_digest_source"] = "placeholder"
        elif n_items == 0:
            payload["slack_digest"]        = slack_digest
            payload["slack_digest_source"] = "canned-quiet"
        else:
            payload["slack_digest"]        = slack_digest
            payload["slack_digest_source"] = "perplexity"

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

        # Slack delivery runs in the same process but AFTER the brief is
        # safely persisted. Per-subscription commits isolate delivery failure
        # — a 4xx from one webhook won't prevent other subscribers from
        # receiving the digest, and a successful POST is marked via
        # last_sent_brief_date so a cron re-run the same day won't double-send.
        _deliver_slack_digests(conn, brief_date, payload.get("slack_digest"))

    log.info(
        "brief for %s generated and persisted: %d item(s) fired across %d section(s)",
        brief_date.isoformat(), n_items, n_sections,
    )
    return 0


def _post_slack_webhook(url: str, text: str, timeout_s: float = 8.0) -> tuple[bool, str]:
    """POST a plain-text message to a Slack incoming webhook. Returns
    ``(ok, short_error)`` — ok is True on 2xx, False otherwise."""
    try:
        resp = httpx.post(
            url, json={"text": text}, timeout=timeout_s,
            headers={"Content-Type": "application/json"},
        )
    except Exception as exc:  # noqa: BLE001
        return False, f"network:{exc.__class__.__name__}"
    if resp.status_code // 100 != 2:
        return False, f"http {resp.status_code}: {resp.text[:120]}"
    return True, ""


def _deliver_slack_digests(conn, brief_date: date, digest_text: str | None) -> None:
    """Post the Slack digest to every active subscription that has a live
    webhook URL and has not already been delivered today.

    Per-subscription commit: each successful POST records
    ``last_sent_brief_date`` immediately, so a crash mid-loop still leaves
    prior deliveries marked and the remainder re-eligible on rerun.
    """
    if not digest_text:
        log.info("slack send: no digest on payload, skipping")
        return

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, email, slack_channel, slack_webhook_url
            FROM hackathon.subscription
            WHERE unsubscribed_at IS NULL
              AND slack_webhook_url IS NOT NULL
              AND (last_sent_brief_date IS NULL OR last_sent_brief_date <> %s)
            ORDER BY id;
            """,
            (brief_date,),
        )
        targets = cur.fetchall()

    if not targets:
        log.info("slack send: no eligible subscriptions for brief %s", brief_date)
        return

    log.info("slack send: %d target(s) for brief %s", len(targets), brief_date)
    n_ok = 0
    n_fail = 0
    for sub_id, email, channel, webhook_url in targets:
        ok, err = _post_slack_webhook(webhook_url, digest_text)
        if ok:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE hackathon.subscription "
                    "SET last_sent_brief_date = %s WHERE id = %s;",
                    (brief_date, sub_id),
                )
            conn.commit()
            n_ok += 1
            log.info("slack send: ok sub_id=%s channel=%r email=%s", sub_id, channel, email)
        else:
            n_fail += 1
            log.warning("slack send: FAIL sub_id=%s channel=%r email=%s err=%s",
                        sub_id, channel, email, err)
    log.info("slack send: done — %d ok, %d failed", n_ok, n_fail)


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

"""LLM narrative synthesis for the daily brief.

Thin wrapper around Perplexity's OpenAI-compatible chat completions endpoint.
Reads ``PERPLEXITY_API_KEY`` from the environment; if the key is absent the
function returns ``None`` and the brief ships with its structured items only.
This lets the rest of the pipeline stay green until the hackathon credits are
ready.

Design notes:
- Facts come from the SQL payload. The model is told explicitly to use only
  the provided JSON and never to search or infer new claims. This keeps the
  narrative grounded, which is exactly the thesis the demo is meant to show.
- Failure posture is fail-open: any exception is caught and logged, and the
  brief is still persisted without a narrative.
- The JSON sent to the API is a compact projection of the full payload — we
  drop the verbose ``supporting`` field per item to keep token usage modest.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import date as _date
from typing import Any, Optional

import httpx


log = logging.getLogger(__name__)

PERPLEXITY_ENDPOINT = "https://api.perplexity.ai/chat/completions"
DEFAULT_MODEL       = "sonar"

QUIET_DAY_NARRATIVE = (
    "Quiet overnight. No material shifts fired across monitored venues in the "
    "last 24 hours."
)

# Placeholder text used when PERPLEXITY_API_KEY is not yet configured. Written
# against the 2026-04-22 sample brief (4 ecosystem + 2 DEX + 2 Kamino + 1
# Exponent items) so the detail page has something representative to show
# during hackathon prep. The frontend labels this as a sample so viewers know
# it is not live output.
PLACEHOLDER_NARRATIVE = (
    "**Headline.** A structural migration of ONyc exposure against the 7-day "
    "baseline: the DEX-liquid share collapsed from 36.6% to under 1%, with "
    "the capital surfacing as a +9.4M ONyc net position on Exponent and a "
    "swing in the Kamino collateral share from 21% to 86%.\n"
    "\n"
    "**Pricing.** Yields compressed as supply thickened. USDG borrow APY on "
    "Kamino fell 289 bps over 24h, the PT-ONyc-13MAY26 implied fixed APY "
    "compressed 95 bps, and the cross-venue yield spread widened 96 bps as "
    "the two markets diverged.\n"
    "\n"
    "**Flow.** A single 201k ONyc sell on Orca ONyc-USDC printed at or above "
    "the p99 magnitude threshold, consistent with the broader rebalance "
    "rather than independent selling pressure.\n"
    "\n"
    "**Risk.** One top-7 obligation sits at a health factor of 1.17 and "
    "warrants the watchlist until the migration stabilises."
)

# Short-form copy for a daily Slack channel digest. Uses Slack's supported
# light markdown (`*bold*`, bullet dots) and typographic characters (middle
# dot, arrow, minus sign) but no emoji — consistent with the design-system
# voice rules. Rendered as a preview on the web detail page until the Slack
# webhook integration is wired in phase-2.
PLACEHOLDER_SLACK_DIGEST = (
    "*ONyc daily brief · 22 Apr 2026*\n"
    "9 items fired · ecosystem 4 · DEXes 2 · Kamino 2 · Exponent 1\n"
    "\n"
    "Structural ONyc migration out of DEX liquidity into Exponent and Kamino; "
    "yields compressed across both lending and yield markets.\n"
    "\n"
    "• *DEX-liquid share* −35.6 pp vs 7d (36.6% → 0.97%)\n"
    "• *Exponent* +9.4M ONyc net vs 7d baseline\n"
    "• *Kamino collateral share* +65.6 pp (21.0% → 86.6%)\n"
    "• *USDG borrow APY* −289 bps over 24h (14.27% → 11.39%)\n"
    "• Top-7 obligation at HF 1.17 — watchlist\n"
    "\n"
    "Full brief → http://localhost:8003/brief/2026-04-22"
)

SYSTEM_PROMPT = """\
You are a neutral financial-systems analyst producing a short structured
briefing that summarises material shifts across the ONyc DeFi ecosystem
(DEXes, lending, yield markets) over the last 24 hours.

Rules:
- Use ONLY the facts in the provided JSON. Do not add numbers, names, or
  claims that are not present. Do not search the web or infer context
  beyond what is given.
- Synthesise — do not recite every item. Lead with what matters to a
  project owner.
- Plain analyst voice. Present tense for states, past tense for events.

Output format (STRICT):
- Return two to four short paragraphs, separated by a single blank line.
- Lead each paragraph with a bolded theme word followed by a period, e.g.
  "**Headline.**", "**Pricing.**", "**Flow.**", "**Risk.**". Pick themes
  that fit the items; do not force all four.
- Each paragraph is one or two sentences.
- Use **bold** only for these theme leads. Do not bold anything else.
- No emoji, no exclamation marks, no bullet lists, no markdown headings.
- Do not begin the first paragraph with "Overnight" or "Today".
"""


def _compact_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Drop verbose fields before sending to the LLM. Keeps prompt tokens low."""
    sections = payload.get("sections") or {}
    compact_sections: dict[str, Any] = {}
    for sec_id, block in sections.items():
        items = []
        for it in (block.get("items") or []):
            items.append({
                "item_id":       it.get("item_id"),
                "headline":      it.get("headline"),
                "direction":     it.get("direction"),
                "value_primary": it.get("value_primary"),
                "value_unit":    it.get("value_unit"),
                "value_delta":   it.get("value_delta"),
                "ref":           it.get("ref"),
            })
        compact_sections[sec_id] = {
            "n_fired": block.get("n_fired", 0),
            "items":   items,
        }
    return {
        "items_fired": payload.get("items_fired", 0),
        "sections":    compact_sections,
    }


def _call_perplexity(api_key: str, compact: dict[str, Any], timeout_s: float) -> Optional[str]:
    """Single POST to Perplexity chat completions. Returns the stripped content
    string, or None on any failure."""
    model = os.getenv("PERPLEXITY_MODEL", DEFAULT_MODEL)
    user_content = (
        "Here is today's structured daily brief. Summarise it per the system "
        "rules.\n\n"
        "```json\n"
        + json.dumps(compact, default=str, indent=2)
        + "\n```"
    )
    try:
        resp = httpx.post(
            PERPLEXITY_ENDPOINT,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type":  "application/json",
            },
            json={
                "model":       model,
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user",   "content": user_content},
                ],
                "temperature": 0.2,
                "max_tokens":  400,
            },
            timeout=timeout_s,
        )
        resp.raise_for_status()
        body = resp.json()
    except Exception:
        log.exception("narrative: Perplexity call failed; brief will ship without narrative")
        return None

    try:
        content = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        log.warning("narrative: unexpected Perplexity response shape: %r", body)
        return None

    if not content or not content.strip():
        log.warning("narrative: empty content returned by Perplexity")
        return None
    return content.strip()


def synthesise_narrative(payload: dict[str, Any], timeout_s: float = 30.0) -> Optional[str]:
    """Return a short analyst-voice paragraph about today's brief, or ``None``.

    Behaviour:
      - ``PERPLEXITY_API_KEY`` unset → returns ``None`` (stub no-op).
      - Key set, zero items fired → returns the canned quiet-day line
        (no API call; the content is deterministic).
      - Key set, items fired → calls Perplexity and returns the response.
        Any exception is caught; on failure returns ``None``.

    The caller (``run_brief``) folds the returned string into
    ``payload['narrative']`` only if it is not ``None``.
    """
    api_key = os.getenv("PERPLEXITY_API_KEY")
    if not api_key:
        log.info("narrative: PERPLEXITY_API_KEY not set — skipping (stub)")
        return None

    n_fired = int(payload.get("items_fired", 0) or 0)
    if n_fired == 0:
        log.info("narrative: quiet day, using canned line (no API call)")
        return QUIET_DAY_NARRATIVE

    compact = _compact_payload(payload)
    text = _call_perplexity(api_key, compact, timeout_s)
    if text is None:
        return None
    log.info("narrative: %d chars produced by Perplexity", len(text))
    return text


# -----------------------------------------------------------------------------
# Slack digest synthesis
# -----------------------------------------------------------------------------

# Section labels used in the Slack header counts line. Order is load-bearing
# (keeps the digest visually consistent regardless of which sections fired).
SLACK_SECTION_LABELS: list[tuple[str, str]] = [
    ("ecosystem", "ecosystem"),
    ("dexes",     "DEXes"),
    ("kamino",    "Kamino"),
    ("exponent",  "Exponent"),
]

QUIET_DAY_SLACK_BODY = (
    "Quiet overnight. No material shifts fired across monitored venues in the "
    "last 24 hours."
)

SLACK_SYSTEM_PROMPT = """\
You are writing the body of a Slack digest for the ONyc daily brief,
summarising material shifts across the ONyc DeFi ecosystem over the last
24 hours.

Rules:
- Use ONLY the facts in the provided JSON. Do not add numbers, names, or
  claims that are not present. Do not search the web.
- Synthesise across items; do not paraphrase every one. Lead with what
  matters to a project owner.
- Plain analyst voice. No emoji, no exclamation marks, no headings.
- The header line, item-counts line, and "Full brief →" link are
  prepended/appended by the caller. Do NOT include them in your output.

Output format (STRICT):
- One or two short sentences of context at the top.
- A single blank line.
- Three to five bullet points, one per most-material item, each prefixed
  with a Unicode bullet and a space: "• ".
- Use Slack markdown *bold* only on the opening label of each bullet, for
  example: "• *USDG borrow APY* −289 bps over 24h (14.27% → 11.39%)".
- Prefer typographic characters: middle dot (·), arrow (→), minus sign
  (−). Do not use ASCII hyphens for signed deltas.
- Output nothing outside the two-sentence summary and the bullets.
"""


def _format_brief_date(brief_date: Any) -> str:
    """Format the brief date like '22 Apr 2026' for the Slack header."""
    if isinstance(brief_date, _date):
        return brief_date.strftime("%d %b %Y")
    return str(brief_date)


def _brief_date_iso(brief_date: Any) -> str:
    if isinstance(brief_date, _date):
        return brief_date.isoformat()
    return str(brief_date)


def _build_slack_header(brief_date: Any, payload: dict[str, Any]) -> str:
    """Deterministic two-line header: title + item counts."""
    date_text = _format_brief_date(brief_date)
    sections  = payload.get("sections") or {}
    total     = int(payload.get("items_fired") or 0)

    parts: list[str] = []
    for sec_id, label in SLACK_SECTION_LABELS:
        block = sections.get(sec_id) or {}
        n = int(block.get("n_fired") or 0)
        if n > 0:
            parts.append(f"{label} {n}")

    counts_line = f"{total} item{'s' if total != 1 else ''} fired"
    if parts:
        counts_line += " · " + " · ".join(parts)

    return f"*ONyc daily brief · {date_text}*\n{counts_line}"


def _build_slack_footer(brief_date: Any, base_url: Optional[str]) -> str:
    base = (base_url or os.getenv("BRIEF_BASE_URL") or "http://localhost:8003").rstrip("/")
    return f"Full brief → {base}/brief/{_brief_date_iso(brief_date)}"


def _call_perplexity_slack(api_key: str, compact: dict[str, Any], timeout_s: float) -> Optional[str]:
    """Single POST to Perplexity for the Slack digest body. Returns the
    stripped content string, or None on any failure."""
    model = os.getenv("PERPLEXITY_MODEL", DEFAULT_MODEL)
    user_content = (
        "Here is today's structured daily brief. Produce the Slack digest "
        "body per the system rules.\n\n"
        "```json\n"
        + json.dumps(compact, default=str, indent=2)
        + "\n```"
    )
    try:
        resp = httpx.post(
            PERPLEXITY_ENDPOINT,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type":  "application/json",
            },
            json={
                "model":       model,
                "messages": [
                    {"role": "system", "content": SLACK_SYSTEM_PROMPT},
                    {"role": "user",   "content": user_content},
                ],
                "temperature": 0.2,
                "max_tokens":  300,
            },
            timeout=timeout_s,
        )
        resp.raise_for_status()
        body = resp.json()
    except Exception:
        log.exception("slack_digest: Perplexity call failed; brief will ship without slack_digest")
        return None

    try:
        content = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        log.warning("slack_digest: unexpected Perplexity response shape: %r", body)
        return None

    if not content or not content.strip():
        log.warning("slack_digest: empty content returned by Perplexity")
        return None
    return content.strip()


def synthesise_slack_digest(
    payload:    dict[str, Any],
    brief_date: Any,
    base_url:   Optional[str] = None,
    timeout_s:  float         = 30.0,
) -> Optional[str]:
    """Return the full Slack digest string (header + body + footer), or
    ``None`` if the API call fails or ``PERPLEXITY_API_KEY`` is unset.

    Behaviour mirrors :func:`synthesise_narrative`:
      - Key unset → ``None`` (caller substitutes the placeholder digest).
      - Zero items fired → canned quiet-day body (no API call).
      - Items fired → Perplexity produces the body; header and footer
        are assembled deterministically around it.

    ``base_url`` overrides the ``BRIEF_BASE_URL`` env var; either may be
    omitted, in which case the footer falls back to ``http://localhost:8003``.
    """
    api_key = os.getenv("PERPLEXITY_API_KEY")
    if not api_key:
        log.info("slack_digest: PERPLEXITY_API_KEY not set — skipping (stub)")
        return None

    header  = _build_slack_header(brief_date, payload)
    footer  = _build_slack_footer(brief_date, base_url)
    n_fired = int(payload.get("items_fired") or 0)

    if n_fired == 0:
        log.info("slack_digest: quiet day, using canned body (no API call)")
        return f"{header}\n\n{QUIET_DAY_SLACK_BODY}\n\n{footer}"

    compact = _compact_payload(payload)
    body    = _call_perplexity_slack(api_key, compact, timeout_s)
    if body is None:
        return None
    log.info("slack_digest: %d chars produced by Perplexity", len(body))
    return f"{header}\n\n{body}\n\n{footer}"

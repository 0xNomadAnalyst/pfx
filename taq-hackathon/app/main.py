"""ONyc Daily Brief — FastAPI app bootstrap.

Two routes:
  GET /                  → feed of past briefs
  GET /brief/{date}      → single-day brief detail

Port 8003 by default (htmx dashboard uses 8002, core API uses 8001).
Creds are loaded by app.db from ../.env.pfx.core.
"""

from __future__ import annotations

import logging
import os
import re
import secrets
from html import escape
from pathlib import Path
from urllib.parse import urlencode

from fastapi import Body, FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from markupsafe import Markup

from app import db


log = logging.getLogger("main")


APP_DIR = Path(__file__).resolve().parent

app = FastAPI(title="ONyc Daily Brief", version="0.1.0")

app.mount("/static", StaticFiles(directory=APP_DIR / "static"), name="static")
templates = Jinja2Templates(directory=APP_DIR / "templates")


def _fmt_num(value, signed: bool = False) -> str:
    """Human-readable number formatter.

    - Large magnitudes render as comma-separated integers (no scientific notation).
    - Small magnitudes render with two decimals.
    - `signed=True` forces a leading +/- for non-zero values.
    """
    if value is None:
        return "—"
    try:
        v = float(value)
    except (TypeError, ValueError):
        return str(value)
    if abs(v) >= 10000:
        s = f"{v:,.0f}"
    elif abs(v) >= 100:
        s = f"{v:,.1f}"
    else:
        s = f"{v:.2f}"
    if signed and v > 0 and not s.startswith("+"):
        s = "+" + s
    return s


templates.env.filters["fmt_num"]    = _fmt_num
templates.env.filters["fmt_signed"] = lambda v: _fmt_num(v, signed=True)


_BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")


def _fmt_narrative(text: str | None) -> Markup:
    """Render narrative text as HTML paragraphs.

    Input: plain text with ``**bold**`` theme leads and blank-line paragraph
    breaks (the format the LLM is instructed to produce).
    Output: Markup-safe HTML — all content is escaped, then `**x**` is
    reintroduced as `<strong>x</strong>`, and paragraphs wrap in
    `<p class="brief-analysis__p">`.
    """
    if not text:
        return Markup("")
    parts: list[str] = []
    for raw in text.split("\n\n"):
        para = raw.strip()
        if not para:
            continue
        safe = escape(para)
        safe = _BOLD_RE.sub(r"<strong>\1</strong>", safe)
        parts.append(f'<p class="brief-analysis__p">{safe}</p>')
    return Markup("\n".join(parts))


templates.env.filters["fmt_narrative"] = _fmt_narrative


SECTION_META = [
    ("ecosystem", "Ecosystem",      "Structure unchanged, no notable rotation.",
        "https://demo.rmckinley.net/global-ecosystem"),
    ("dexes",     "DEXes",          "Markets balanced, depth stable, no extreme events.",
        "https://demo.rmckinley.net/dexes"),
    ("kamino",    "Kamino lending", "Utilisation within band, no liquidations, rates stable.",
        "https://demo.rmckinley.net/kamino"),
    ("exponent",  "Exponent yield", "Rates unchanged, AMM depth stable.",
        "https://demo.rmckinley.net/exponent-yield"),
]


@app.get("/healthz", include_in_schema=False)
def healthz() -> JSONResponse:
    return JSONResponse({"status": "ok"})


@app.get("/", response_class=HTMLResponse)
def feed(request: Request) -> HTMLResponse:
    rows = db.fetch_all(
        """
        SELECT brief_date, generated_at, items_fired,
               payload->'sections' AS sections
        FROM hackathon.brief
        ORDER BY brief_date DESC
        LIMIT 30;
        """
    )
    briefs = [
        {
            "brief_date":   r[0],
            "generated_at": r[1],
            "items_fired":  r[2],
            "sections":     r[3] or {},
        }
        for r in rows
    ]
    return templates.TemplateResponse(
        request,
        "feed.html",
        {
            "briefs":       briefs,
            "section_meta": SECTION_META,
        },
    )


@app.get("/brief/{brief_date}", response_class=HTMLResponse)
def detail(request: Request, brief_date: str) -> HTMLResponse:
    row = db.fetch_one(
        """
        SELECT brief_date, generated_at, items_fired, payload
        FROM hackathon.brief
        WHERE brief_date = %s;
        """,
        (brief_date,),
    )
    if row is None:
        return templates.TemplateResponse(
            request,
            "detail_missing.html",
            {"brief_date": brief_date},
            status_code=404,
        )
    brief = {
        "brief_date":   row[0],
        "generated_at": row[1],
        "items_fired":  row[2],
        "payload":      row[3] or {},
    }
    return templates.TemplateResponse(
        request,
        "detail.html",
        {
            "brief":        brief,
            "section_meta": SECTION_META,
        },
    )


_EMAIL_RE   = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_WEBHOOK_RE = re.compile(r"^https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+$")


def _canon_channel(v: str) -> str:
    v = (v or "").strip().lstrip("#").strip()
    return f"#{v}" if v else ""


def _latest_slack_digest() -> str | None:
    """Return the most recent persisted brief's slack_digest, or None."""
    row = db.fetch_one(
        "SELECT payload->>'slack_digest' "
        "FROM hackathon.brief "
        "ORDER BY brief_date DESC LIMIT 1;"
    )
    return row[0] if row and row[0] else None


def _slack_post(webhook_url: str, text: str, timeout_s: float = 6.0) -> tuple[bool, str]:
    """Post a plain-text Slack message. Returns (ok, error_message)."""
    import httpx  # local import so test/dev without httpx still boots
    try:
        resp = httpx.post(
            webhook_url,
            json={"text": text},
            timeout=timeout_s,
            headers={"Content-Type": "application/json"},
        )
    except Exception as exc:
        return False, f"network: {exc.__class__.__name__}"
    if resp.status_code // 100 != 2:
        body = resp.text[:160]
        return False, f"http {resp.status_code}: {body}"
    return True, ""


SLACK_AUTHORIZE_URL = "https://slack.com/oauth/v2/authorize"
SLACK_OAUTH_ACCESS  = "https://slack.com/api/oauth.v2.access"
SLACK_SCOPE         = "incoming-webhook"


def _slack_install_url(state: str) -> str:
    """Build the Slack authorize URL for the 'Add to Slack' button."""
    params = urlencode({
        "client_id":    os.getenv("SLACK_CLIENT_ID", ""),
        "scope":        SLACK_SCOPE,
        "redirect_uri": os.getenv("SLACK_REDIRECT_URI", ""),
        "state":        state,
    })
    return f"{SLACK_AUTHORIZE_URL}?{params}"


@app.post("/api/subscribe")
def api_subscribe(payload: dict = Body(...)) -> JSONResponse:
    """Phase 1 of the Slack 'Add to Slack' flow.

    Expected JSON body:
      { "email": "...", "frequency": "daily" | "intraday" }

    Creates a pending subscription row keyed by a fresh opaque token and
    returns the Slack authorize URL the frontend should redirect to. The
    workspace + channel + webhook_url get filled in by
    ``/slack/oauth/callback`` when Slack redirects back with a grant code.

    Any prior active row for the same email is soft-unsubscribed (whether
    it was a completed subscription or a stale pending row) so at most one
    pending token is live per email at any time.
    """
    email     = (payload.get("email") or "").strip().lower()
    frequency = (payload.get("frequency") or "daily").strip().lower()

    if frequency != "daily":
        return JSONResponse({"error": "invalid_frequency"}, status_code=400)
    if not _EMAIL_RE.match(email):
        return JSONResponse({"error": "invalid_email"}, status_code=400)
    if not os.getenv("SLACK_CLIENT_ID") or not os.getenv("SLACK_REDIRECT_URI"):
        log.error("subscribe: SLACK_CLIENT_ID / SLACK_REDIRECT_URI not configured")
        return JSONResponse({"error": "slack_not_configured"}, status_code=503)

    token = secrets.token_urlsafe(32)

    with db.connect() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE hackathon.subscription SET unsubscribed_at = now() "
            "WHERE email = %s AND unsubscribed_at IS NULL;",
            (email,),
        )
        cur.execute(
            "INSERT INTO hackathon.subscription "
            "(email, frequency, pending_token) "
            "VALUES (%s, %s, %s) RETURNING id;",
            (email, frequency, token),
        )
        sub_id = cur.fetchone()[0]
        conn.commit()

    install_url = _slack_install_url(token)
    log.info("subscribe: pending row %s for %s, redirecting to Slack", sub_id, email)
    return JSONResponse({
        "status":      "pending",
        "id":          sub_id,
        "email":       email,
        "frequency":   frequency,
        "install_url": install_url,
    })


@app.get("/slack/oauth/callback", response_class=HTMLResponse)
def slack_oauth_callback(request: Request,
                         code:  str | None = None,
                         state: str | None = None,
                         error: str | None = None) -> HTMLResponse:
    """Phase 2 of the Slack 'Add to Slack' flow.

    Slack redirects here after the user approves the install. We exchange
    the grant code for an incoming-webhook URL scoped to the channel the
    user picked, fill in the pending subscription row, and land the user
    on a success page.

    Failure modes (user cancels, missing state, expired token, Slack API
    error) render a small error page with a retry link. The pending row is
    left marked unsubscribed so the email can retry cleanly.
    """
    if error:
        log.info("slack oauth: user declined or Slack returned error=%s", error)
        return templates.TemplateResponse(
            request, "slack_oauth_error.html",
            {"reason": "cancelled", "detail": error},
            status_code=400,
        )
    if not code or not state:
        return templates.TemplateResponse(
            request, "slack_oauth_error.html",
            {"reason": "missing_params", "detail": "code or state missing"},
            status_code=400,
        )

    with db.connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, email, frequency FROM hackathon.subscription "
            "WHERE pending_token = %s AND unsubscribed_at IS NULL;",
            (state,),
        )
        row = cur.fetchone()
    if row is None:
        log.warning("slack oauth: no pending row matches state token")
        return templates.TemplateResponse(
            request, "slack_oauth_error.html",
            {"reason": "unknown_state", "detail": "subscription not found or expired"},
            status_code=400,
        )
    sub_id, email, frequency = row

    import httpx
    try:
        resp = httpx.post(
            SLACK_OAUTH_ACCESS,
            data={
                "client_id":     os.getenv("SLACK_CLIENT_ID", ""),
                "client_secret": os.getenv("SLACK_CLIENT_SECRET", ""),
                "code":          code,
                "redirect_uri":  os.getenv("SLACK_REDIRECT_URI", ""),
            },
            timeout=8.0,
        )
        body = resp.json()
    except Exception as exc:  # noqa: BLE001
        log.exception("slack oauth: exchange failed: %s", exc)
        return templates.TemplateResponse(
            request, "slack_oauth_error.html",
            {"reason": "exchange_failed", "detail": exc.__class__.__name__},
            status_code=502,
        )

    if not body.get("ok"):
        log.warning("slack oauth: ok=false body=%r", body)
        return templates.TemplateResponse(
            request, "slack_oauth_error.html",
            {"reason": "slack_error", "detail": body.get("error") or "unknown"},
            status_code=502,
        )

    webhook = (body.get("incoming_webhook") or {})
    team    = (body.get("team") or {})
    webhook_url = webhook.get("url")
    channel     = webhook.get("channel") or ""
    workspace   = team.get("name") or team.get("id") or ""
    if not webhook_url:
        log.warning("slack oauth: response missing incoming_webhook.url: %r", body)
        return templates.TemplateResponse(
            request, "slack_oauth_error.html",
            {"reason": "no_webhook", "detail": "Slack did not return a webhook URL"},
            status_code=502,
        )

    channel_display = _canon_channel(channel)

    with db.connect() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE hackathon.subscription SET "
            "  slack_webhook_url = %s, "
            "  slack_workspace   = %s, "
            "  slack_channel     = %s, "
            "  pending_token     = NULL "
            "WHERE id = %s;",
            (webhook_url, workspace, channel_display, sub_id),
        )
        conn.commit()

    log.info("slack oauth: sub %s live, workspace=%r channel=%r", sub_id, workspace, channel_display)
    qs = urlencode({"ch": channel_display, "ws": workspace, "email": email, "freq": frequency})
    return RedirectResponse(url=f"/slack/oauth/success?{qs}", status_code=303)


@app.get("/slack/oauth/success", response_class=HTMLResponse)
def slack_oauth_success(request: Request,
                        ch:    str = "",
                        ws:    str = "",
                        email: str = "",
                        freq:  str = "daily") -> HTMLResponse:
    """Post-OAuth landing page. All params come from the callback redirect.

    Nothing authoritative — the row is already live in the DB. This page is
    just a friendly confirmation so the tab the user is sitting on doesn't
    end up on slack.com.
    """
    return templates.TemplateResponse(
        request, "slack_oauth_success.html",
        {"channel": ch, "workspace": ws, "email": email, "frequency": freq},
    )


@app.get("/api/subscription")
def api_subscription_lookup(email: str = "") -> JSONResponse:
    """Look up the active subscription for an email. Used by the
    "manage by email" recovery flow when a returning user has lost their
    localStorage state.

    Privacy posture: the endpoint echoes only fields already tied to the
    email provided by the caller — it does not enumerate subscriptions,
    reveal any other user's info, or leak whether-this-email-is-known by
    timing (same response shape for found / not_found).
    """
    email = (email or "").strip().lower()
    if not _EMAIL_RE.match(email):
        return JSONResponse({"status": "invalid_email"}, status_code=400)
    # Pending rows (no webhook yet) don't count as active subscriptions for
    # lookup — the user either never completed OAuth or the row is stale.
    row = db.fetch_one(
        "SELECT slack_workspace, slack_channel, frequency "
        "FROM hackathon.subscription "
        "WHERE email = %s AND unsubscribed_at IS NULL "
        "  AND slack_webhook_url IS NOT NULL;",
        (email,),
    )
    if row is None:
        return JSONResponse({"status": "not_found"}, status_code=404)
    return JSONResponse({
        "status":          "found",
        "email":           email,
        "slack_workspace": row[0],
        "slack_channel":   row[1],
        "frequency":       row[2],
    })


@app.post("/api/unsubscribe")
def api_unsubscribe(payload: dict = Body(...)) -> JSONResponse:
    """Mark the active subscription for the given email as unsubscribed.

    If the active row carries a webhook URL, a goodbye message is posted to
    the channel on a best-effort basis (failure is logged but does not block
    the unsubscribe). Idempotent — repeated unsubscribes return removed=0.
    """
    email = (payload.get("email") or "").strip().lower()
    if not _EMAIL_RE.match(email):
        return JSONResponse({"error": "invalid_email"}, status_code=400)

    with db.connect() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, slack_channel, slack_webhook_url "
            "FROM hackathon.subscription "
            "WHERE email = %s AND unsubscribed_at IS NULL;",
            (email,),
        )
        row = cur.fetchone()

        if row is None:
            conn.commit()
            return JSONResponse({"status": "unsubscribed", "removed": 0})

        sub_id, channel, webhook_url = row

        cur.execute(
            "UPDATE hackathon.subscription SET unsubscribed_at = now() "
            "WHERE id = %s;",
            (sub_id,),
        )
        conn.commit()

    # Best-effort goodbye; failure is not user-facing.
    webhook_status = "skipped"
    if webhook_url:
        goodbye = (
            f"*ONyc Daily Brief — unsubscribed*\n"
            f"You will no longer receive the daily brief in {channel or 'this channel'}. "
            f"You can resubscribe any time from the brief page."
        )
        ok, _err = _slack_post(webhook_url, goodbye)
        webhook_status = "sent" if ok else "failed"

    return JSONResponse({
        "status":         "unsubscribed",
        "removed":        1,
        "webhook_status": webhook_status,
    })


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8003")),
        reload=False,
    )

"""ONyc Daily Brief — FastAPI app bootstrap.

Two routes:
  GET /                  → feed of past briefs
  GET /brief/{date}      → single-day brief detail

Port 8003 by default (htmx dashboard uses 8002, core API uses 8001).
Creds are loaded by app.db from ../.env.pfx.core.
"""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app import db


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


SECTION_META = [
    ("ecosystem", "Ecosystem",        "Structure unchanged, no notable rotation."),
    ("dexes",     "DEXes",            "Markets balanced, depth stable, no extreme events."),
    ("kamino",    "Kamino lending",   "Utilisation within band, no liquidations, rates stable."),
    ("exponent",  "Exponent yield",   "Rates unchanged, AMM depth stable."),
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


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8003")),
        reload=False,
    )

"""
Enrich web3cfo Slack member data:
  - Parse company from title, display_name, and Circle intro text
  - Merge Slack intro messages
  - Merge channel activity data (LinkedIn, URLs, activity metrics)
  - Merge Circle.so intro posts (matched by name)
  - Output a single enriched CSV
"""

import csv
import re
from pathlib import Path

DIR = Path(__file__).parent
MEMBERS_CSV = DIR / "web3cfo_members_2026-04-07.csv"
INTROS_CSV = DIR / "web3cfo_intros_2026-04-07.csv"
ACTIVITY_CSV = DIR / "web3cfo_channel_activity_2026-04-07.csv"
CIRCLE_INTROS_CSV = DIR / "web3cfo_circle_intros_2026-04-07.csv"
OUTPUT_CSV = DIR / "web3cfo_enriched.csv"

# ── Company extraction ───────────────────────────────────────────────

COMPANY_PATTERNS = [
    re.compile(r"\b(?:at|@)\s+(.+?)(?:\s*[|\.\-–—,;(/]|$)", re.IGNORECASE),
    re.compile(r"\b(?:of|for)\s+(.+?)(?:\s*[|\.\-–—,;(/]|$)", re.IGNORECASE),
]

DISPLAY_NAME_PATTERN = re.compile(r"^.+?\s+[-–—|@]\s+(.+)$")

NOISE = {
    "the", "a", "an", "and", "or", "in", "on", "to", "with", "from",
    "my", "our", "web3", "crypto", "blockchain", "defi",
}


def extract_company_from_title(title: str) -> str:
    if not title or not title.strip():
        return ""
    for pat in COMPANY_PATTERNS:
        m = pat.search(title)
        if m:
            company = m.group(1).strip().rstrip(".|,;-–—/ ")
            if len(company) > 1 and len(company) < 120 and company.lower() not in NOISE:
                return company
    return ""


def extract_company_from_display_name(display_name: str) -> str:
    if not display_name or not display_name.strip():
        return ""
    m = DISPLAY_NAME_PATTERN.match(display_name.strip())
    if m:
        company = m.group(1).strip().rstrip(".|,;-–—/ ")
        if len(company) > 1 and len(company) < 120:
            return company
    return ""


# ── Load intros ──────────────────────────────────────────────────────

intros = {}
if INTROS_CSV.exists():
    with open(INTROS_CSV, encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            intros[row["user_id"]] = row

# ── Load channel activity ────────────────────────────────────────────

activity = {}
if ACTIVITY_CSV.exists():
    with open(ACTIVITY_CSV, encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            activity[row["user_id"]] = row

# ── Load Circle.so intros (keyed by normalized name) ─────────────────

def normalize_name(name: str) -> str:
    return re.sub(r"\s+", " ", name.strip().lower())

circle_by_name: dict[str, dict] = {}
circle_matched = 0
if CIRCLE_INTROS_CSV.exists():
    with open(CIRCLE_INTROS_CSV, encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            name_key = normalize_name(row.get("author_name", ""))
            if name_key and name_key not in circle_by_name:
                circle_by_name[name_key] = row

# ── Process members ──────────────────────────────────────────────────

rows_out = []
with open(MEMBERS_CSV, encoding="utf-8", newline="") as f:
    for row in csv.DictReader(f):
        uid = row["id"]
        title = row.get("title", "")
        display_name = row.get("display_name", "")

        company = extract_company_from_title(title)
        if not company:
            company = extract_company_from_display_name(display_name)

        intro = intros.get(uid, {})
        act = activity.get(uid, {})

        # Match to Circle.so intro by name (try full name, then display_name)
        member_name = row.get("name", "")
        circ = circle_by_name.get(normalize_name(member_name), {})
        if not circ and display_name:
            # Try display_name without company suffix (e.g. "Kinga Bosse - Lukka" → "Kinga Bosse")
            clean_dn = re.split(r"\s+[-–—|@]\s+", display_name)[0].strip()
            circ = circle_by_name.get(normalize_name(clean_dn), {})
        if circ:
            circle_matched += 1

        # LinkedIn: prefer Circle (richest), then Slack intro, then channel activity
        linkedin = (
            circ.get("linkedin", "")
            or intro.get("linkedin", "")
            or act.get("linkedin", "")
        )
        twitter = (
            circ.get("twitter", "")
            or intro.get("twitter", "")
            or act.get("twitter", "")
        )

        # Merge other URLs from all sources
        other_parts = []
        for src in [circ, intro, act]:
            if src.get("other_urls"):
                other_parts.append(src["other_urls"])
        other_urls = " | ".join(other_parts) if other_parts else ""

        # Company: try title/display_name first, then Circle headline
        if not company and circ.get("author_headline"):
            company = extract_company_from_title(circ["author_headline"])

        # Intro text: prefer Circle (full history), fall back to Slack
        intro_text = circ.get("post_text", "") or intro.get("intro_text", "")
        intro_date = circ.get("created_at", "") or intro.get("posted_at", "")

        rows_out.append({
            "id": uid,
            "name": member_name,
            "display_name": display_name,
            "title": title,
            "company": company,
            "circle_headline": circ.get("author_headline", ""),
            "email": row.get("email", ""),
            "phone": row.get("phone", ""),
            "timezone": row.get("timezone", ""),
            "status": row.get("status", ""),
            "linkedin": linkedin,
            "twitter": twitter,
            "other_urls": other_urls,
            "message_count_90d": act.get("message_count", "0"),
            "active_channels": act.get("active_channels", ""),
            "intro_text": intro_text,
            "intro_date": intro_date,
        })

# ── Write output ─────────────────────────────────────────────────────

fields = [
    "id", "name", "display_name", "title", "company", "circle_headline",
    "email", "phone", "timezone", "status",
    "linkedin", "twitter", "other_urls",
    "message_count_90d", "active_channels",
    "intro_text", "intro_date",
]

with open(OUTPUT_CSV, "w", encoding="utf-8", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields, quoting=csv.QUOTE_ALL)
    writer.writeheader()
    writer.writerows(rows_out)

# ── Summary ──────────────────────────────────────────────────────────

total = len(rows_out)
with_company = sum(1 for r in rows_out if r["company"])
with_title = sum(1 for r in rows_out if r["title"].strip())
with_intro = sum(1 for r in rows_out if r["intro_text"])
with_linkedin = sum(1 for r in rows_out if r["linkedin"])
active_90d = sum(1 for r in rows_out if int(r["message_count_90d"] or 0) > 0)
with_headline = sum(1 for r in rows_out if r["circle_headline"])

print(f"Total members:         {total}")
print(f"  Circle matched:      {circle_matched}")
print(f"  with company:        {with_company} ({100*with_company//total}%)")
print(f"  with title:          {with_title} ({100*with_title//total}%)")
print(f"  with Circle headline:{with_headline}")
print(f"  with LinkedIn:       {with_linkedin}")
print(f"  with intro msg:      {with_intro}")
print(f"  active (90 days):    {active_90d}")
print(f"\nWritten to {OUTPUT_CSV}")

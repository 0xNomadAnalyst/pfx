"""
Build scored prospect list from web3cfo Slack + Circle data.

Reads:
    web3cfo_members_2026-04-07.csv          (Slack member profiles)
    web3cfo_intros_2026-04-07.csv           (Slack #01-introduce-yourself, 90-day)
    web3cfo_channel_activity_2026-04-07.csv  (Slack all-channel activity, 90-day)
    web3cfo_circle_intros_2026-04-07.csv    (Circle.so full intro history)

Writes:
    web3cfo_prospects.csv                   (enriched, scored output)
"""

import csv
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

DIR = Path(__file__).parent
MEMBERS_CSV = DIR / "web3cfo_members_2026-04-07.csv"
SLACK_INTROS_CSV = DIR / "web3cfo_intros_2026-04-07.csv"
ACTIVITY_CSV = DIR / "web3cfo_channel_activity_2026-04-07.csv"
CIRCLE_INTROS_CSV = DIR / "web3cfo_circle_intros_2026-04-07.csv"
OUTPUT_CSV = DIR / "web3cfo_prospects.csv"

NOW = datetime.now(timezone.utc)

# ── Seniority mapping ────────────────────────────────────────────────

SENIORITY_PATTERNS = [
    (r"\b(?:CEO|Chief Executive|Co-?Founder|Founder\s*(?:&|and)\s*CEO)\b", "C-Suite"),
    (r"\b(?:CFO|Chief Financial|COO|Chief Operating|CTO|Chief Technology)\b", "C-Suite"),
    (r"\b(?:Managing Partner|Managing Director|General Partner)\b", "C-Suite"),
    (r"\bCo-?Founder\b", "Founder"),
    (r"\bFounder\b", "Founder"),
    (r"\b(?:SVP|Senior Vice President)\b", "VP"),
    (r"\b(?:VP|Vice President)\b", "VP"),
    (r"\bHead of\b", "Head"),
    (r"\bDirector\b", "Director"),
    (r"\bPartner\b", "Partner"),
    (r"\bController\b", "Controller"),
    (r"\bManager\b", "Manager"),
    (r"\bLead\b", "Lead"),
    (r"\bSenior\b", "Senior IC"),
    (r"\b(?:Associate|Analyst|Specialist|Accountant|Auditor|Intern|Assistant)\b", "IC"),
]

# ── Company-type classification ──────────────────────────────────────

COMPANY_TYPE_RULES = [
    (r"\b(?:Foundation|Protocol|DAO|Network|Labs)\b", "Protocol / Foundation"),
    (r"\b(?:Exchange|CEX|DEX|Trading|Perps)\b", "Exchange / Trading"),
    (r"\b(?:Venture|VC|Capital|Fund|Investment)\b", "Fund / VC"),
    (r"\b(?:PwC|Deloitte|EY|KPMG|Big\s*4|BDO|RSM|Moore|Grant Thornton|Baker Tilly|Forvis Mazars|HLB)\b", "Audit / Big4+"),
    (r"\b(?:Advisory|Consulting|Advisors|Fractional CFO)\b", "Advisory / Consulting"),
    (r"\b(?:CPA|Bookkeep|Accounting Services|Accounting Practice|Accounting firm)\b", "Accounting Services"),
    (r"\b(?:Wallet|Custody|Infrastructure|Oracle|Staking)\b", "Infrastructure"),
    (r"\b(?:DeFi|Lending|Yield|Liquidity)\b", "DeFi"),
    (r"\b(?:Payment|Payroll|Invoice|Billing|Fintech)\b", "Payments / Fintech"),
    (r"\b(?:NFT|Gaming|Metaverse|Studio)\b", "NFT / Gaming"),
    (r"\b(?:Insurance|Insur)\b", "Insurance"),
]

# ── Prospect-type classification ─────────────────────────────────────

JOB_SEEKING_PATTERNS = [
    r"looking for.*(?:opportunit|role|position)",
    r"open to.*(?:opportunit|role|new)",
    r"exploring.*(?:web3|opportunit|crypto)",
    r"currently looking",
    r"seeking.*(?:role|opportunit)",
    r"next (?:role|opportunit|adventure)",
    r"available for",
]

SERVICE_PROVIDER_PATTERNS = [
    r"offering.*(?:accounting|CFO|bookkeep|tax|audit|consulting|advisory|services)",
    r"fractional\s+CFO",
    r"providing.*(?:services|consulting|advisory)",
    r"boutique.*firm",
    r"my (?:own\s+)?(?:firm|practice|company|business)",
    r"founder.*(?:consulting|advisory|accounting|tax|CPA)",
]

COMPANY_PATTERNS = [
    re.compile(r"\b(?:at|@)\s+(.+?)(?:\s*[|\.\-–—,;(/]|$)", re.IGNORECASE),
    re.compile(r"\b(?:of|for)\s+(.+?)(?:\s*[|\.\-–—,;(/]|$)", re.IGNORECASE),
]

DISPLAY_NAME_PATTERN = re.compile(r"^.+?\s+[-–—|@]\s+(.+)$")


def parse_date(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def days_ago(date_str):
    dt = parse_date(date_str)
    return (NOW - dt).days if dt else None


def extract_seniority(text):
    for pattern, level in SENIORITY_PATTERNS:
        if re.search(pattern, text, re.IGNORECASE):
            return level
    return ""


def extract_company_type(text):
    for pattern, label in COMPANY_TYPE_RULES:
        if re.search(pattern, text, re.IGNORECASE):
            return label
    return ""


def extract_role(text):
    if not text or not text.strip():
        return ""
    m = re.match(r"^(.+?)\s+(?:at|@)\s+", text, re.IGNORECASE)
    if m:
        role = m.group(1).strip().strip("|–—-").strip()
        if 2 < len(role) < 80:
            return role
    return ""


def extract_company(text):
    if not text or not text.strip():
        return ""
    for pat in COMPANY_PATTERNS:
        m = pat.search(text)
        if m:
            company = m.group(1).strip().rstrip("|.,;-–—/ ")
            if 1 < len(company) < 120:
                return company
    return ""


def extract_company_from_display_name(dn):
    if not dn:
        return ""
    m = DISPLAY_NAME_PATTERN.match(dn.strip())
    if m:
        company = m.group(1).strip().rstrip("|.,;-–—/ ")
        if 1 < len(company) < 120:
            return company
    return ""


def classify_prospect(combined, seniority):
    lower = combined.lower()
    for p in SERVICE_PROVIDER_PATTERNS:
        if re.search(p, lower):
            return "Service Provider"
    for p in JOB_SEEKING_PATTERNS:
        if re.search(p, lower):
            return "Job Seeker"
    if seniority in ("C-Suite", "Founder", "VP", "Head", "Director", "Partner", "Controller"):
        return "Decision Maker"
    if seniority in ("Manager", "Lead", "Senior IC"):
        return "Influencer"
    if seniority == "IC":
        return "Practitioner"
    return "Unknown"


def normalize_name(name):
    return re.sub(r"\s+", " ", name.strip().lower())


# ── Load data sources ────────────────────────────────────────────────

def load_csv(path):
    if not path.exists():
        return []
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def main():
    members = load_csv(MEMBERS_CSV)
    slack_intros = {r["user_id"]: r for r in load_csv(SLACK_INTROS_CSV)}
    activity = {r["user_id"]: r for r in load_csv(ACTIVITY_CSV)}

    # Circle intros keyed by normalized name (most recent per name)
    circle_by_name = {}
    for r in load_csv(CIRCLE_INTROS_CSV):
        key = normalize_name(r.get("author_name", ""))
        if key and key not in circle_by_name:
            circle_by_name[key] = r

    print(f"Loaded: {len(members)} members, {len(slack_intros)} Slack intros, "
          f"{len(activity)} active users, {len(circle_by_name)} Circle intros")

    # ── Process each member ──────────────────────────────────────────
    results = []

    for m in members:
        uid = m["id"]
        name = m.get("name", "")
        title = m.get("title", "").strip()
        display_name = m.get("display_name", "").strip()

        si = slack_intros.get(uid, {})
        act = activity.get(uid, {})

        # Match Circle intro by name
        circ = circle_by_name.get(normalize_name(name), {})
        if not circ and display_name:
            clean_dn = re.split(r"\s+[-–—|@]\s+", display_name)[0].strip()
            circ = circle_by_name.get(normalize_name(clean_dn), {})

        # Combine all text sources for classification
        circle_headline = circ.get("author_headline", "")
        circle_text = circ.get("post_text", "")
        slack_intro_text = si.get("intro_text", "")
        intro_text = circle_text or slack_intro_text
        combined = f"{title} {display_name} {circle_headline} {intro_text}"

        # Extract fields
        role = extract_role(title) or extract_role(circle_headline)
        company = (
            extract_company(title)
            or extract_company_from_display_name(display_name)
            or extract_company(circle_headline)
        )
        seniority = extract_seniority(combined)
        company_type = extract_company_type(combined)
        prospect_type = classify_prospect(combined, seniority)

        # LinkedIn / Twitter / URLs: merge all sources
        linkedin = (
            circ.get("linkedin", "")
            or si.get("linkedin", "")
            or act.get("linkedin", "")
        )
        twitter = (
            circ.get("twitter", "")
            or si.get("twitter", "")
            or act.get("twitter", "")
        )
        url_parts = []
        for src in [circ, si, act]:
            u = src.get("other_urls", "")
            if u:
                url_parts.append(u)
        other_urls = " | ".join(url_parts)

        # Intro date: Circle (full history) preferred
        intro_date = circ.get("created_at", "") or si.get("posted_at", "")

        # Activity: Slack message count in last 90 days
        msg_count_90d = int(act.get("message_count", 0) or 0)
        active_channels = act.get("active_channels", "")

        # Days calculations
        days_since_intro = days_ago(intro_date)

        results.append({
            "name": name,
            "role": role,
            "company": company,
            "seniority": seniority,
            "company_type": company_type,
            "prospect_type": prospect_type,
            "title": title,
            "circle_headline": circle_headline,
            "timezone": m.get("timezone", ""),
            "intro_message": intro_text[:2000] if intro_text else "",
            "intro_date": intro_date,
            "days_since_intro": days_since_intro if days_since_intro is not None else "",
            "messages_90d": msg_count_90d,
            "active_channels": active_channels,
            "linkedin": linkedin,
            "twitter": twitter,
            "other_urls": other_urls,
            "slack_id": uid,
        })

    # ── Sort: decision makers first, then by engagement/recency ──────
    type_order = {
        "Decision Maker": 0,
        "Influencer": 1,
        "Service Provider": 2,
        "Practitioner": 3,
        "Job Seeker": 4,
        "Unknown": 5,
    }

    results.sort(key=lambda r: (
        type_order.get(r["prospect_type"], 6),
        -(r["messages_90d"] or 0),
        r["days_since_intro"] if isinstance(r["days_since_intro"], int) else 9999,
    ))

    # ── Write output ─────────────────────────────────────────────────
    fieldnames = [
        "name", "role", "company", "seniority", "company_type",
        "prospect_type", "title", "circle_headline", "timezone",
        "intro_message", "intro_date", "days_since_intro",
        "messages_90d", "active_channels",
        "linkedin", "twitter", "other_urls", "slack_id",
    ]

    with open(OUTPUT_CSV, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, quoting=csv.QUOTE_ALL)
        writer.writeheader()
        writer.writerows(results)

    # ── Summary stats ────────────────────────────────────────────────
    type_counts = Counter(r["prospect_type"] for r in results)
    seniority_counts = Counter(r["seniority"] for r in results if r["seniority"])
    company_type_counts = Counter(r["company_type"] for r in results if r["company_type"])
    has_company = sum(1 for r in results if r["company"])
    has_intro = sum(1 for r in results if r["intro_message"])
    has_linkedin = sum(1 for r in results if r["linkedin"])
    active_slack = sum(1 for r in results if r["messages_90d"] > 0)

    print(f"\n{'='*60}")
    print(f"  Output: {OUTPUT_CSV.name}")
    print(f"  Total prospects: {len(results)}")
    print(f"  With company:        {has_company}")
    print(f"  With intro message:  {has_intro}")
    print(f"  With LinkedIn:       {has_linkedin}")
    print(f"  Active on Slack 90d: {active_slack}")
    print(f"{'='*60}")
    print(f"\n  Prospect Type:")
    for t, c in sorted(type_counts.items(), key=lambda x: type_order.get(x[0], 6)):
        print(f"    {t:25s} {c:>4}")
    print(f"\n  Seniority:")
    for s, c in seniority_counts.most_common():
        print(f"    {s:25s} {c:>4}")
    print(f"\n  Company Type:")
    for ct, c in company_type_counts.most_common():
        print(f"    {ct:25s} {c:>4}")
    print()


if __name__ == "__main__":
    main()

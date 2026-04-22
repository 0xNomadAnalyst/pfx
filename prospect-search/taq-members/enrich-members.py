"""
Enrich TAQ member data by merging member profiles with intro messages,
extracting structured role/company info, and scoring prospect appeal.

Usage:
    python enrich-members.py

Reads:
    taq_members_2026-04-07.csv   (member profiles)
    taq_intros_2026-04-07.csv    (introduce-yourself messages)

Writes:
    taq_prospects.csv            (enriched, scored output)
"""

import csv
import re
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
MEMBERS_CSV = SCRIPT_DIR / "taq_members_2026-04-07.csv"
INTROS_CSV = SCRIPT_DIR / "taq_intros_2026-04-07.csv"
OUTPUT_CSV = SCRIPT_DIR / "taq_prospects.csv"

NOW = datetime.now(timezone.utc)

# ── Internal / staff accounts to exclude ─────────────────────────────
SKIP_IDS = {"31637953", "33111609", "34533572"}
STAFF_KEYWORDS = [
    "the accountant quits",
    "community moderator",
    "community builder",
    "instructor at the accountant",
]

# ── Seniority mapping ───────────────────────────────────────────────
SENIORITY_PATTERNS = [
    (r"\b(?:CEO|Chief Executive|Co-?Founder|Founder & CEO)\b", "C-Suite"),
    (r"\b(?:CFO|Chief Financial|COO|Chief Operating|CTO|Chief Technology)\b", "C-Suite"),
    (r"\b(?:Managing Partner|Managing Director|General Partner)\b", "C-Suite"),
    (r"\bCo-?Founder\b", "Founder"),
    (r"\bFounder\b", "Founder"),
    (r"\b(?:VP|Vice President)\b", "VP"),
    (r"\b(?:SVP|Senior Vice President)\b", "VP"),
    (r"\bHead of\b", "Head"),
    (r"\bDirector\b", "Director"),
    (r"\bPartner\b", "Partner"),
    (r"\bController\b", "Controller"),
    (r"\bManager\b", "Manager"),
    (r"\bSenior\b", "Senior IC"),
    (r"\bLead\b", "Lead"),
    (r"\b(?:Associate|Analyst|Specialist|Accountant|Auditor|Consultant)\b", "IC"),
]

# ── Company-type classification keywords ─────────────────────────────
COMPANY_TYPE_RULES = [
    (r"\b(?:Foundation|Protocol|DAO|Network|Labs)\b", "Protocol / Foundation"),
    (r"\b(?:Exchange|CEX|DEX|Trading|Perps)\b", "Exchange / Trading"),
    (r"\b(?:Venture|VC|Capital|Fund|Investment)\b", "Fund / VC"),
    (r"\b(?:PwC|Deloitte|EY|KPMG|Big\s*4|BDO|RSM|Moore|Grant Thornton|Baker Tilly|Forvis Mazars|HLB)\b", "Audit / Big4+"),
    (r"\b(?:Advisory|Consulting|Advisors|Fractional CFO|Accounting firm|Tax)\b", "Advisory / Consulting"),
    (r"\b(?:CPA|Bookkeep|Accounting Services|Accounting Practice)\b", "Accounting Services"),
    (r"\b(?:Wallet|Custody|Infrastructure|Oracle|Staking)\b", "Infrastructure"),
    (r"\b(?:DeFi|Lending|Yield|Liquidity)\b", "DeFi"),
    (r"\b(?:Payment|Payroll|Invoice|Billing)\b", "Payments / Fintech"),
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
    r"on a.*break",
]

SERVICE_PROVIDER_PATTERNS = [
    r"offering.*(?:accounting|CFO|bookkeep|tax|audit|consulting|advisory|services)",
    r"fractional\s+CFO",
    r"providing.*(?:services|consulting|advisory)",
    r"boutique.*firm",
    r"my (?:own|) (?:firm|practice|company|business)",
    r"founder.*(?:consulting|advisory|accounting|tax|CPA)",
]


def parse_date(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def days_ago(date_str):
    dt = parse_date(date_str)
    if not dt:
        return None
    return (NOW - dt).days


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


def extract_role(bio):
    """Try to extract the role/title portion before 'at' or '@'."""
    if not bio or not bio.strip():
        return ""
    m = re.match(r"^(.+?)\s+(?:at|@)\s+", bio, re.IGNORECASE)
    if m:
        role = m.group(1).strip().strip("|–—-").strip()
        if 2 < len(role) < 80:
            return role
    return ""


def extract_company_from_bio(bio):
    """Extract company from short_bio using at/@/for patterns."""
    if not bio or not bio.strip():
        return ""
    patterns = [
        r"\b(?:at|@)\s+(.+?)(?:\s*[|\.\-–—,;(]|$)",
        r"\b(?:for)\s+(.+?)(?:\s*[|\.\-–—,;(]|$)",
    ]
    for p in patterns:
        m = re.search(p, bio, re.IGNORECASE)
        if m:
            company = m.group(1).strip().rstrip("|.").strip()
            if 1 < len(company) < 100:
                return company
    return ""


def classify_prospect(bio, intro, seniority):
    combined = f"{bio} {intro}".lower()

    for p in STAFF_KEYWORDS:
        if p in combined:
            return "Staff / Internal"

    for p in SERVICE_PROVIDER_PATTERNS:
        if re.search(p, combined, re.IGNORECASE):
            return "Service Provider"

    for p in JOB_SEEKING_PATTERNS:
        if re.search(p, combined, re.IGNORECASE):
            return "Job Seeker"

    if seniority in ("C-Suite", "Founder", "VP", "Head", "Director", "Partner", "Controller"):
        return "Decision Maker"

    if seniority in ("Manager", "Lead", "Senior IC"):
        return "Influencer"

    if seniority == "IC":
        return "Practitioner"

    return "Unknown"


def main():
    # ── Load members ─────────────────────────────────────────────────
    members = {}
    with open(MEMBERS_CSV, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            mid = row["id"]
            if mid in SKIP_IDS:
                continue
            members[mid] = row

    print(f"Loaded {len(members)} members")

    # ── Load intros ──────────────────────────────────────────────────
    intros = {}
    with open(INTROS_CSV, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            mid = row["member_id"]
            if mid not in intros:
                intros[mid] = row
            else:
                existing_msg = intros[mid].get("message", "")
                new_msg = row.get("message", "")
                if len(new_msg) > len(existing_msg):
                    intros[mid] = row

    print(f"Loaded {len(intros)} intro messages")

    # ── Enrich and merge ─────────────────────────────────────────────
    results = []

    for mid, m in members.items():
        intro = intros.get(mid, {})
        bio = m.get("short_bio", "").strip()
        intro_msg = intro.get("message", "").strip()
        combined_text = f"{bio} {intro_msg}"

        # Core fields
        name = m.get("name", "")
        location = m.get("location", "")
        last_active = m.get("last_active", "")
        member_since = m.get("member_since", "")

        # Extracted fields
        role = extract_role(bio)
        company = m.get("company", "").strip() or extract_company_from_bio(bio)
        seniority = extract_seniority(combined_text)
        company_type = extract_company_type(combined_text)
        prospect_type = classify_prospect(bio, intro_msg, seniority)

        # Activity metrics
        days_since_active = days_ago(last_active)
        days_as_member = days_ago(member_since)

        # Merge URLs: prefer intro linkedin/twitter if member csv is empty
        linkedin = m.get("linkedin", "").strip() or intro.get("linkedin", "").strip()
        twitter = m.get("twitter", "").strip() or intro.get("twitter", "").strip()
        other_urls = m.get("other_urls", "").strip()
        intro_urls = intro.get("other_urls", "").strip()
        if intro_urls and intro_urls not in other_urls:
            other_urls = f"{other_urls} | {intro_urls}".strip(" |")

        results.append({
            "id": mid,
            "name": name,
            "role": role,
            "company": company,
            "seniority": seniority,
            "company_type": company_type,
            "prospect_type": prospect_type,
            "location": location,
            "short_bio": bio,
            "intro_message": intro_msg[:2000] if intro_msg else "",
            "last_active": last_active,
            "days_since_active": days_since_active if days_since_active is not None else "",
            "member_since": member_since,
            "days_as_member": days_as_member if days_as_member is not None else "",
            "linkedin": linkedin,
            "twitter": twitter,
            "other_urls": other_urls,
        })

    # Sort: decision makers first, then by days_since_active (most recent first)
    type_order = {
        "Decision Maker": 0,
        "Influencer": 1,
        "Service Provider": 2,
        "Practitioner": 3,
        "Job Seeker": 4,
        "Unknown": 5,
        "Staff / Internal": 9,
    }
    results.sort(key=lambda r: (
        type_order.get(r["prospect_type"], 6),
        r["days_since_active"] if isinstance(r["days_since_active"], int) else 9999,
    ))

    # ── Write output ─────────────────────────────────────────────────
    fieldnames = [
        "id", "name", "role", "company", "seniority", "company_type",
        "prospect_type", "location", "short_bio", "intro_message",
        "last_active", "days_since_active", "member_since", "days_as_member",
        "linkedin", "twitter", "other_urls",
    ]

    with open(OUTPUT_CSV, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, quoting=csv.QUOTE_ALL)
        writer.writeheader()
        writer.writerows(results)

    # ── Summary stats ────────────────────────────────────────────────
    from collections import Counter
    type_counts = Counter(r["prospect_type"] for r in results)
    seniority_counts = Counter(r["seniority"] for r in results if r["seniority"])
    company_type_counts = Counter(r["company_type"] for r in results if r["company_type"])
    has_company = sum(1 for r in results if r["company"])
    has_intro = sum(1 for r in results if r["intro_message"])
    has_linkedin = sum(1 for r in results if r["linkedin"])
    active_30d = sum(1 for r in results if isinstance(r["days_since_active"], int) and r["days_since_active"] <= 30)

    print(f"\n{'='*60}")
    print(f"  Output: {OUTPUT_CSV.name}")
    print(f"  Total prospects: {len(results)}")
    print(f"  With company: {has_company}")
    print(f"  With intro message: {has_intro}")
    print(f"  With LinkedIn: {has_linkedin}")
    print(f"  Active last 30 days: {active_30d}")
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

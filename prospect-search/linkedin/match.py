"""
Fuzzy name matching, LinkedIn title parsing, and confidence scoring.

Parses Google result titles in the standard LinkedIn format:
    "First Last - Role - Company | LinkedIn"
and scores how well each result matches a known prospect.
"""

import re

from thefuzz import fuzz

_LI_SUFFIX_RE = re.compile(r"\s*(?:\||-|–|—)\s*LinkedIn\s*$", re.IGNORECASE)
_SEPARATOR_RE = re.compile(r"\s*[-–—]\s*")

# Patterns to recognise "Role at Company" style strings
_ROLE_AT_COMPANY_RE = re.compile(
    r"^(?P<role>.+?)\s+(?:at|@)\s+(?P<company>.+)$", re.IGNORECASE
)

# Snippet patterns that Serper returns for LinkedIn profiles
_SNIPPET_EXPERIENCE_RE = re.compile(r"Experience:\s*(.+?)(?:\s*[·|]|$)", re.IGNORECASE)
_SNIPPET_AT_RE = re.compile(r"\b(?:at|@)\s+(.+?)(?:\s*[·|.\-–—,;(]|$)", re.IGNORECASE)

BLOCKCHAIN_KEYWORDS = [
    "blockchain", "crypto", "web3", "defi", "nft", "token", "dao",
    "protocol", "foundation", "solana", "ethereum", "bitcoin", "layer",
    "chain", "wallet", "staking", "digital asset", "onchain", "on-chain",
    "decentrali", "smart contract", "dapp", "exchange",
]

DECISION_MAKER_TITLES = re.compile(
    r"\b(?:ceo|cfo|coo|cto|cpo|cro|ciso|chief|founder|co-?founder"
    r"|president|partner|managing director"
    r"|vp|vice president|svp|evp"
    r"|head of|director|controller|treasurer)\b",
    re.IGNORECASE,
)


def parse_linkedin_title(title: str) -> dict:
    """
    Parse a Google result title into name, role, company.

    LinkedIn title formats:
      "Name - Role - Company | LinkedIn"      (3 segments)
      "Name - Role at Company | LinkedIn"      (2 segments, role contains company)
      "Name - Company | LinkedIn"              (2 segments, just company)
      "Name | LinkedIn"                        (1 segment)

    Returns dict with keys: name, role, company (any may be empty).
    """
    if not title:
        return {"name": "", "role": "", "company": ""}

    # Strip the "| LinkedIn" or "- LinkedIn" suffix
    cleaned = _LI_SUFFIX_RE.sub("", title).strip()
    if not cleaned:
        return {"name": title.strip(), "role": "", "company": ""}

    # Split on dash separators
    segments = [s.strip() for s in _SEPARATOR_RE.split(cleaned) if s.strip()]

    if len(segments) >= 3:
        # "Name - Role - Company" (standard 3-part)
        name = segments[0]
        role = segments[1]
        company = segments[2]
        return {"name": name, "role": role, "company": company}

    if len(segments) == 2:
        name = segments[0]
        second = segments[1]

        # Check if second segment is "Role at Company"
        m = _ROLE_AT_COMPANY_RE.match(second)
        if m:
            return {"name": name, "role": m.group("role").strip(), "company": m.group("company").strip()}

        # Otherwise the second segment is typically the company/org
        # (LinkedIn titles show "Name - Company" not "Name - Role")
        return {"name": name, "role": "", "company": second}

    # Single segment = just the name
    return {"name": segments[0] if segments else cleaned, "role": "", "company": ""}


def _normalise(s: str) -> str:
    """Lowercase, strip punctuation for comparison."""
    return re.sub(r"[^\w\s]", "", s.lower()).strip()


def name_similarity(name_a: str, name_b: str) -> int:
    """Fuzzy similarity score (0-100) between two names."""
    if not name_a or not name_b:
        return 0
    return fuzz.token_sort_ratio(_normalise(name_a), _normalise(name_b))


def company_mentioned(company: str, text: str) -> bool:
    """Check if a company name appears (case-insensitive) in text."""
    if not company or not text:
        return False
    return _normalise(company) in _normalise(text)


def is_blockchain_relevant(text: str) -> bool:
    """Check if text mentions blockchain/crypto/web3 keywords."""
    lower = text.lower()
    return any(kw in lower for kw in BLOCKCHAIN_KEYWORDS)


def is_decision_maker_title(role: str) -> bool:
    """Check if a role string suggests decision-making authority."""
    if not role:
        return False
    return bool(DECISION_MAKER_TITLES.search(role))


def score_result(
    prospect_name: str,
    prospect_company: str,
    result: dict,
) -> dict:
    """
    Score a single Google/LinkedIn result against a known prospect.

    Returns a dict with:
        - linkedin_url
        - linkedin_name, linkedin_role, linkedin_company
        - name_score (0-100)
        - company_match (bool)
        - match_confidence: "high" / "medium" / "low"
        - blockchain_relevant (bool)
        - decision_maker (bool)
        - snippet
    """
    parsed = parse_linkedin_title(result.get("title", ""))
    snippet = result.get("snippet", "")
    combined_text = f"{result.get('title', '')} {snippet}"

    n_score = name_similarity(prospect_name, parsed["name"])

    linkedin_role = parsed["role"]
    linkedin_company = parsed["company"]

    # Enrich from snippet when title parsing is incomplete
    if not linkedin_company or not linkedin_role:
        # Try "Experience: Company" pattern (very reliable in Serper snippets)
        exp_match = _SNIPPET_EXPERIENCE_RE.search(snippet)
        if exp_match and not linkedin_company:
            linkedin_company = exp_match.group(1).strip().rstrip(".")

        # Try "Role at Company" in the snippet text
        if not linkedin_role:
            at_match = _ROLE_AT_COMPANY_RE.search(snippet)
            if at_match:
                linkedin_role = linkedin_role or at_match.group("role").strip()
                linkedin_company = linkedin_company or at_match.group("company").strip()

        # Last resort: "at Company" pattern in snippet
        if not linkedin_company:
            at_match = _SNIPPET_AT_RE.search(snippet)
            if at_match:
                linkedin_company = at_match.group(1).strip()

    c_match = False
    if prospect_company:
        c_match = (
            company_mentioned(prospect_company, linkedin_company)
            or company_mentioned(prospect_company, snippet)
        )

    # Confidence scoring
    if n_score >= 90 and c_match:
        confidence = "high"
    elif n_score >= 85 and (c_match or prospect_company == ""):
        confidence = "high"
    elif n_score >= 80:
        confidence = "medium"
    elif n_score >= 70:
        confidence = "low"
    else:
        confidence = "low"

    return {
        "linkedin_url": result.get("link", ""),
        "linkedin_name": parsed["name"],
        "linkedin_role": linkedin_role,
        "linkedin_company": linkedin_company,
        "name_score": n_score,
        "company_match": c_match,
        "match_confidence": confidence,
        "blockchain_relevant": is_blockchain_relevant(combined_text),
        "decision_maker": is_decision_maker_title(linkedin_role) or is_decision_maker_title(parsed.get("role", "")),
        "snippet": snippet,
    }


def best_match(
    prospect_name: str,
    prospect_company: str,
    results: list[dict],
    llm_scorer=None,
) -> dict | None:
    """
    Pick the single best-matching result from a list of Google results.

    When multiple viable candidates exist and an llm_scorer is provided,
    uses LLM-based crypto relevance scoring to select the best match.

    llm_scorer: callable(list[dict]) -> list[int]  (crypto scores 0-10)
    """
    if not results:
        return None

    scored = [score_result(prospect_name, prospect_company, r) for r in results]

    viable = [s for s in scored if s["name_score"] >= 60]
    if not viable:
        return None

    # If only one candidate or company already confirmed, skip LLM
    if len(viable) == 1:
        return viable[0]

    company_confirmed = [s for s in viable if s["company_match"]]
    if company_confirmed:
        return company_confirmed[0]

    # Multiple ambiguous candidates -- use LLM scoring if available
    if llm_scorer and len(viable) > 1:
        crypto_scores = llm_scorer(viable)
        for s, cs in zip(viable, crypto_scores):
            s["crypto_score"] = cs
    else:
        for s in viable:
            s["crypto_score"] = 10 if s["blockchain_relevant"] else 0

    viable.sort(key=lambda s: (
        -s["crypto_score"],
        -s["name_score"],
    ))

    return viable[0]

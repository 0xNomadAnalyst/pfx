"""
Google search client for LinkedIn profile discovery.

Supports Searlo (primary) and Serper.dev (fallback) as search providers.
Builds targeted queries and returns structured results with LinkedIn
profile URLs and snippets.
"""

import os
import time
import logging
from urllib.parse import quote_plus

import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

log = logging.getLogger(__name__)

SEARLO_URL = "https://api.searlo.tech/api/v1/search/web"
SEARLO_API_KEY = os.getenv("SEARLO_API_KEY", "")

SERPER_URL = "https://google.serper.dev/search"
SERPER_API_KEY = os.getenv("SERPER_API_KEY", "")

REQUEST_DELAY = 1.0  # base delay; Searlo needs ~18s pacing (200/hr limit)

_searlo_last_call = 0.0
_SEARLO_MIN_INTERVAL = 20.0  # 200 requests/hour ≈ 1 every 18s; 20s for safety


def _searlo_search(query: str, num_results: int = 5) -> list[dict]:
    """Execute a Searlo search with rate-limit pacing and single long retry."""
    global _searlo_last_call
    elapsed = time.time() - _searlo_last_call
    if elapsed < _SEARLO_MIN_INTERVAL:
        time.sleep(_SEARLO_MIN_INTERVAL - elapsed)

    _searlo_last_call = time.time()
    resp = requests.get(
        SEARLO_URL,
        params={"q": query, "num": min(num_results, 10)},
        headers={"x-api-key": SEARLO_API_KEY},
        timeout=15,
    )
    if resp.status_code == 429:
        remaining_hour = resp.headers.get("x-ratelimit-remaining-hour", "?")
        wait = 1800 if remaining_hour == "0" else int(resp.headers.get("retry-after", 120))
        log.info("Searlo 429 (hour-remaining=%s), sleeping %ds (%.0fmin)...",
                 remaining_hour, wait, wait / 60)
        time.sleep(wait)
        _searlo_last_call = time.time()
        resp = requests.get(
            SEARLO_URL,
            params={"q": query, "num": min(num_results, 10)},
            headers={"x-api-key": SEARLO_API_KEY},
            timeout=15,
        )
    resp.raise_for_status()
    data = resp.json()
    items = data.get("organic", []) or data.get("items", [])
    return [
        {"link": item.get("link", ""), "title": item.get("title", ""), "snippet": item.get("snippet", "")}
        for item in items
    ]


def _serper_search(query: str, num_results: int = 5) -> list[dict]:
    """Execute a Serper.dev search and normalise results."""
    resp = requests.post(
        SERPER_URL,
        json={"q": query, "num": num_results},
        headers={"X-API-KEY": SERPER_API_KEY, "Content-Type": "application/json"},
        timeout=15,
    )
    resp.raise_for_status()
    data = resp.json()
    return data.get("organic", [])


def _web_search(query: str, num_results: int = 5) -> list[dict]:
    """Route to available search provider."""
    if SEARLO_API_KEY:
        return _searlo_search(query, num_results)
    if SERPER_API_KEY:
        return _serper_search(query, num_results)
    raise RuntimeError("No search API key set. Add SEARLO_API_KEY or SERPER_API_KEY to .env")


def _is_linkedin_profile(url: str) -> bool:
    """Check if a URL is a LinkedIn personal profile (not company/posts)."""
    if not url:
        return False
    url_lower = url.lower()
    return "linkedin.com/in/" in url_lower


def _filter_linkedin_results(results: list[dict]) -> list[dict]:
    """Keep only results that point to LinkedIn profile pages."""
    return [r for r in results if _is_linkedin_profile(r.get("link", ""))]


def build_queries(name: str, company: str = "", role: str = "", bio: str = "") -> list[str]:
    """
    Build a prioritised list of Google queries for a prospect.

    Returns 1-3 queries in order of specificity (most specific first).
    The caller should try them in order and stop when a good match is found.
    """
    queries = []
    quoted_name = f'"{name}"'

    if company:
        clean_company = company.strip().rstrip(".").strip()
        if len(clean_company) > 2:
            queries.append(f'{quoted_name} "{clean_company}" site:linkedin.com/in')

    if role:
        clean_role = role.strip()
        if len(clean_role) > 2:
            queries.append(f'{quoted_name} "{clean_role}" site:linkedin.com/in')

    queries.append(f"{quoted_name} site:linkedin.com/in")

    # Deduplicate while preserving order
    seen = set()
    unique = []
    for q in queries:
        if q not in seen:
            seen.add(q)
            unique.append(q)
    return unique


def search_prospect(
    name: str,
    company: str = "",
    role: str = "",
    bio: str = "",
    max_results_per_query: int = 5,
) -> list[dict]:
    """
    Search Google for LinkedIn profiles matching a prospect.

    Tries queries from most specific to least specific, stopping
    when LinkedIn profile results are found.

    Returns a list of dicts with keys:
        - link: LinkedIn profile URL
        - title: Google result title
        - snippet: Google result snippet
        - query_used: which query produced this result
    """
    queries = build_queries(name, company, role, bio)

    for i, query in enumerate(queries):
        log.debug("Query %d/%d: %s", i + 1, len(queries), query)

        try:
            raw_results = _web_search(query, num_results=max_results_per_query)
        except requests.RequestException as e:
            log.warning("Search failed for query '%s': %s", query, e)
            time.sleep(REQUEST_DELAY)
            continue

        linkedin_results = _filter_linkedin_results(raw_results)

        if linkedin_results:
            return [
                {
                    "link": r.get("link", ""),
                    "title": r.get("title", ""),
                    "snippet": r.get("snippet", ""),
                    "query_used": query,
                }
                for r in linkedin_results
            ]

        time.sleep(REQUEST_DELAY)

    return []


def build_linkedin_search_url(name: str, company: str = "") -> str:
    """Generate a one-click LinkedIn people-search URL for manual verification."""
    parts = [name]
    if company:
        parts.append(company)
    keywords = " ".join(parts)
    return f"https://www.linkedin.com/search/results/people/?keywords={quote_plus(keywords)}"

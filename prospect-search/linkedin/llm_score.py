"""
LLM-based crypto/blockchain relevance scoring for companies.

Uses Google Gemini API with Google Search grounding to determine whether
a company is in the blockchain/crypto/web3 space.  Search grounding lets
the model look up unfamiliar or newer companies in real time rather than
relying solely on pretrained knowledge.
"""

import json
import logging
import os
import re
import time

import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

log = logging.getLogger(__name__)

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
GEMINI_URL = (
    f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"
)

_SYSTEM_PROMPT = """You are a classifier that determines whether companies are in the blockchain, cryptocurrency, or web3 industry.
Use Google Search to look up any company you are unsure about before scoring.

Given a list of candidates (each with a company name and context snippet), return a JSON array with a crypto_score (0-10) for each.

Scoring guide:
- 10: Core blockchain/crypto company (e.g. Solana Foundation, Coinbase, Uniswap)
- 7-9: Strongly crypto-adjacent (e.g. crypto accounting firm, digital asset fund, web3 consultancy)
- 4-6: Some crypto involvement but mainly traditional (e.g. Big4 with a crypto practice)
- 1-3: Unlikely crypto connection
- 0: Definitely not crypto (e.g. Ford Motor Company, US Army)

Return ONLY a JSON array like: [{"index": 0, "crypto_score": 8}, {"index": 1, "crypto_score": 0}]"""

_MAX_RETRIES = 4
_TIMEOUT_S = 45


def _extract_text(data: dict) -> str:
    """Pull the text part from a Gemini response, skipping thought parts."""
    for part in data["candidates"][0]["content"]["parts"]:
        if "text" in part and "thought" not in part:
            return part["text"]
    return ""


def score_candidates(candidates: list[dict]) -> list[int]:
    """
    Score a list of candidate matches for crypto relevance.

    Each candidate should have keys: linkedin_company, linkedin_role, snippet.
    Returns a list of scores (0-10), one per candidate, in the same order.
    Falls back to 5 for all candidates if the API call fails.
    """
    if not GEMINI_API_KEY:
        log.warning("GEMINI_API_KEY not set, returning neutral scores")
        return [5] * len(candidates)

    prompt_lines = []
    for i, c in enumerate(candidates):
        company = c.get("linkedin_company", "") or "(unknown)"
        role = c.get("linkedin_role", "") or ""
        snippet = (c.get("snippet", "") or "")[:200]
        prompt_lines.append(f"Candidate {i}: company={company}, role={role}, context={snippet}")

    user_prompt = "\n".join(prompt_lines)

    payload = {
        "contents": [{"parts": [{"text": f"{_SYSTEM_PROMPT}\n\n{user_prompt}"}]}],
        "tools": [{"google_search": {}}],
        "generationConfig": {
            "temperature": 0.0,
            "maxOutputTokens": 2048,
            "thinkingConfig": {"thinkingBudget": 0},
        },
    }

    for attempt in range(_MAX_RETRIES):
        try:
            resp = requests.post(
                GEMINI_URL,
                params={"key": GEMINI_API_KEY},
                json=payload,
                timeout=_TIMEOUT_S,
            )
            if resp.status_code in (429, 503):
                wait = 2 ** (attempt + 1)
                log.debug("Gemini %d, retrying in %ds...", resp.status_code, wait)
                time.sleep(wait)
                continue
            resp.raise_for_status()
            data = resp.json()

            text = _extract_text(data)
            text = re.sub(r"```(?:json)?\s*", "", text).strip().rstrip("`")
            scores_list = json.loads(text)

            score_map = {item["index"]: item["crypto_score"] for item in scores_list}
            return [score_map.get(i, 5) for i in range(len(candidates))]

        except requests.exceptions.HTTPError as e:
            if any(code in str(e) for code in ("429", "503")) and attempt < _MAX_RETRIES - 1:
                time.sleep(2 ** (attempt + 1))
                continue
            log.warning("Gemini scoring failed: %s", e)
            return [5] * len(candidates)
        except Exception as e:
            log.warning("Gemini scoring failed: %s", e)
            return [5] * len(candidates)

    log.warning("Gemini scoring exhausted retries")
    return [5] * len(candidates)


# ---------------------------------------------------------------------------
# LLM-based LinkedIn title parsing
# ---------------------------------------------------------------------------

_PARSE_PROMPT = """You extract structured job information from LinkedIn search result titles and snippets.

For each entry, extract:
- "company": the employer/organization name (NOT a role, NOT a location, NOT certifications)
- "role": the job title
- "crypto_score": 0-10 how likely this company is blockchain/crypto/web3 (use Google Search if unsure)

Rules:
- If the title is just a location like "Bali, Indonesia | Professional Profile", company and role are both ""
- Strings like "CPA | FCCA | Big 4" are certifications/descriptors, NOT a company
- "CFO | Crypto, Web3, Finance" → role="CFO", company="" (the rest are tags, not a company)
- "Quant Research and Portfolio Management" is a department/function, not a company — put it in role
- Use the snippet text to disambiguate when the title is unclear

Return ONLY a JSON array: [{"index": 0, "company": "Acme Corp", "role": "CFO", "crypto_score": 8}, ...]"""


def parse_titles(entries: list[dict]) -> list[dict]:
    """
    Use the LLM to extract clean company/role from LinkedIn titles + snippets.

    Each entry should have: linkedin_name, linkedin_role, linkedin_company, snippet.
    Returns list of dicts with keys: company, role, crypto_score — same order.
    Falls back to originals on failure.
    """
    if not GEMINI_API_KEY or not entries:
        return [
            {
                "company": e.get("linkedin_company", ""),
                "role": e.get("linkedin_role", ""),
                "crypto_score": 5,
            }
            for e in entries
        ]

    prompt_lines = []
    for i, e in enumerate(entries):
        title_parts = " - ".join(
            filter(None, [e.get("linkedin_name", ""), e.get("linkedin_role", ""), e.get("linkedin_company", "")])
        )
        snippet = (e.get("snippet", "") or "")[:300]
        prompt_lines.append(f"Entry {i}: title=\"{title_parts}\", snippet=\"{snippet}\"")

    user_prompt = "\n".join(prompt_lines)

    payload = {
        "contents": [{"parts": [{"text": f"{_PARSE_PROMPT}\n\n{user_prompt}"}]}],
        "tools": [{"google_search": {}}],
        "generationConfig": {
            "temperature": 0.0,
            "maxOutputTokens": 4096,
            "thinkingConfig": {"thinkingBudget": 0},
        },
    }

    fallback = [
        {
            "company": e.get("linkedin_company", ""),
            "role": e.get("linkedin_role", ""),
            "crypto_score": 5,
        }
        for e in entries
    ]

    for attempt in range(_MAX_RETRIES):
        try:
            resp = requests.post(
                GEMINI_URL,
                params={"key": GEMINI_API_KEY},
                json=payload,
                timeout=_TIMEOUT_S,
            )
            if resp.status_code in (429, 503):
                wait = 2 ** (attempt + 1)
                log.debug("Gemini %d (parse_titles), retrying in %ds...", resp.status_code, wait)
                time.sleep(wait)
                continue
            resp.raise_for_status()
            data = resp.json()

            text = _extract_text(data)
            text = re.sub(r"```(?:json)?\s*", "", text).strip().rstrip("`")
            parsed = json.loads(text)

            result_map = {item["index"]: item for item in parsed}
            return [
                {
                    "company": result_map.get(i, {}).get("company", fallback[i]["company"]),
                    "role": result_map.get(i, {}).get("role", fallback[i]["role"]),
                    "crypto_score": result_map.get(i, {}).get("crypto_score", 5),
                }
                for i in range(len(entries))
            ]

        except requests.exceptions.HTTPError as e:
            if any(code in str(e) for code in ("429", "503")) and attempt < _MAX_RETRIES - 1:
                time.sleep(2 ** (attempt + 1))
                continue
            log.warning("Gemini parse_titles failed: %s", e)
            return fallback
        except Exception as e:
            log.warning("Gemini parse_titles failed: %s", e)
            return fallback

    log.warning("Gemini parse_titles exhausted retries")
    return fallback

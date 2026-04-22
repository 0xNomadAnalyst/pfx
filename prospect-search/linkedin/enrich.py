"""
CLI tool to enrich any prospect CSV with LinkedIn profile data via Google search.

Usage:
    python enrich.py --input prospects.csv --name-col name --company-col company --output enriched.csv

Reads a CSV of prospects, searches Google for their LinkedIn profiles,
parses and scores results, and writes an enriched CSV.
"""

import argparse
import csv
import json
import logging
import os
import sys
import time
from collections import Counter
from pathlib import Path

from search import search_prospect, build_linkedin_search_url, REQUEST_DELAY
from match import best_match, is_blockchain_relevant, is_decision_maker_title  # noqa: F401
from llm_score import score_candidates

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

CACHE_FILE = "search_cache.json"


def load_cache(cache_path: str) -> dict:
    if os.path.exists(cache_path):
        with open(cache_path, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_cache(cache: dict, cache_path: str):
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)


def enrich_prospect(
    name: str,
    company: str,
    role: str,
    bio: str,
    cache: dict,
    input_is_crypto: bool = False,
    llm_scorer=None,
) -> dict:
    """
    Look up a single prospect on LinkedIn via Google and return enriched data.
    Uses a cache keyed by name to avoid repeat API calls.
    """
    cache_key = name.strip().lower()

    if cache_key in cache:
        log.debug("Cache hit: %s", name)
        cached = cache[cache_key]
        if input_is_crypto and not cached.get("blockchain_relevant"):
            cached["blockchain_relevant"] = True
            cached["still_relevant"] = cached.get("decision_maker", False)
        return cached

    results = search_prospect(
        name=name,
        company=company,
        role=role,
        bio=bio,
        max_results_per_query=5,
    )

    matched = best_match(name, company, results, llm_scorer=llm_scorer)

    if matched:
        crypto = matched["blockchain_relevant"] or input_is_crypto
        still_relevant = crypto and matched["decision_maker"]
        row = {
            "linkedin_url": matched["linkedin_url"],
            "linkedin_name": matched["linkedin_name"],
            "linkedin_role": matched["linkedin_role"],
            "linkedin_company": matched["linkedin_company"],
            "name_score": matched["name_score"],
            "company_match": matched["company_match"],
            "match_confidence": matched["match_confidence"],
            "blockchain_relevant": crypto,
            "decision_maker": matched["decision_maker"],
            "still_relevant": still_relevant,
            "snippet": matched["snippet"],
        }
    else:
        row = {
            "linkedin_url": "",
            "linkedin_name": "",
            "linkedin_role": "",
            "linkedin_company": "",
            "name_score": 0,
            "company_match": False,
            "match_confidence": "none",
            "blockchain_relevant": input_is_crypto,
            "decision_maker": False,
            "still_relevant": False,
            "snippet": "",
        }

    cache[cache_key] = row
    return row


def main():
    parser = argparse.ArgumentParser(
        description="Enrich a prospect CSV with LinkedIn data via Google search"
    )
    parser.add_argument("--input", required=True, help="Path to input CSV")
    parser.add_argument("--output", required=True, help="Path to output CSV")
    parser.add_argument("--name-col", default="name", help="Column name for prospect name")
    parser.add_argument("--company-col", default="company", help="Column name for company")
    parser.add_argument("--role-col", default="role", help="Column name for role/title")
    parser.add_argument("--bio-col", default="short_bio", help="Column name for bio text")
    parser.add_argument("--id-col", default="id", help="Column name for unique ID (passed through)")
    parser.add_argument("--limit", type=int, default=0, help="Limit number of prospects to process (0 = all)")
    parser.add_argument("--crypto-source", action="store_true", help="Assume all input prospects are crypto/blockchain professionals")
    parser.add_argument("--no-llm", action="store_true", help="Disable LLM-based crypto scoring for candidate selection")
    parser.add_argument("--cache-dir", default="", help="Directory for search cache (default: same as output)")

    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        log.error("Input file not found: %s", input_path)
        sys.exit(1)

    cache_dir = Path(args.cache_dir) if args.cache_dir else output_path.parent
    cache_path = cache_dir / CACHE_FILE
    cache = load_cache(str(cache_path))
    log.info("Loaded %d cached results from %s", len(cache), cache_path)

    # Read input
    with open(input_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    if args.limit > 0:
        rows = rows[: args.limit]

    llm_scorer = None if args.no_llm else score_candidates
    log.info("Processing %d prospects from %s (LLM scoring: %s)", len(rows), input_path, "off" if args.no_llm else "on")

    # Enrich
    output_fields = [
        args.id_col, args.name_col, "input_company", "input_role",
        "linkedin_url", "linkedin_name", "linkedin_role", "linkedin_company",
        "name_score", "company_match", "match_confidence",
        "blockchain_relevant", "decision_maker", "still_relevant",
        "linkedin_search_url", "snippet",
    ]

    results = []
    cached_hits = 0
    api_calls = 0

    for i, row in enumerate(rows):
        name = row.get(args.name_col, "").strip()
        company = row.get(args.company_col, "").strip()
        role = row.get(args.role_col, "").strip()
        bio = row.get(args.bio_col, "").strip()
        prospect_id = row.get(args.id_col, "")

        if not name:
            continue

        was_cached = name.strip().lower() in cache
        enriched = enrich_prospect(name, company, role, bio, cache, input_is_crypto=args.crypto_source, llm_scorer=llm_scorer)

        if was_cached:
            cached_hits += 1
        else:
            api_calls += 1
            # Save cache periodically
            if api_calls % 25 == 0:
                save_cache(cache, str(cache_path))
                log.info("Cache saved (%d entries)", len(cache))

        linkedin_search = build_linkedin_search_url(name, company)

        out_row = {
            args.id_col: prospect_id,
            args.name_col: name,
            "input_company": company,
            "input_role": role,
            **enriched,
            "linkedin_search_url": linkedin_search,
        }
        results.append(out_row)

        status = enriched["match_confidence"]
        symbol = {"high": "+", "medium": "~", "low": "?", "none": "-"}.get(status, "?")
        match_label = (
            enriched.get("linkedin_company", "")
            or enriched.get("linkedin_role", "")
            or ("no match" if not enriched.get("linkedin_url") else "profile found")
        )
        log.info(
            "[%d/%d] %s %s → %s (%s)%s",
            i + 1, len(rows), symbol, name,
            match_label, status,
            " [cached]" if was_cached else "",
        )

        if not was_cached:
            time.sleep(REQUEST_DELAY)

    # Final cache save
    save_cache(cache, str(cache_path))

    # Write output
    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=output_fields, quoting=csv.QUOTE_ALL, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(results)

    # Summary
    confidence_counts = Counter(r["match_confidence"] for r in results)
    matched = sum(1 for r in results if r["linkedin_url"])
    relevant = sum(1 for r in results if r["still_relevant"])

    log.info("")
    log.info("=" * 60)
    log.info("  Output: %s", output_path)
    log.info("  Total prospects: %d", len(results))
    log.info("  API calls: %d (cached: %d)", api_calls, cached_hits)
    log.info("  LinkedIn matched: %d", matched)
    log.info("  Confidence: high=%d  medium=%d  low=%d  none=%d",
             confidence_counts.get("high", 0),
             confidence_counts.get("medium", 0),
             confidence_counts.get("low", 0),
             confidence_counts.get("none", 0))
    log.info("  Still relevant (blockchain + decision-maker): %d", relevant)
    log.info("=" * 60)


if __name__ == "__main__":
    main()

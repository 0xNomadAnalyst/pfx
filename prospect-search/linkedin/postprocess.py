"""
Post-process an enriched LinkedIn CSV to fix company/role parsing using LLM.

Reads the output of enrich.py, sends batches of linkedin titles+snippets
to Gemini for proper company/role extraction, and writes a corrected CSV.

Usage:
    python postprocess.py --input taq_linkedin_v4.csv --output taq_linkedin_v4_clean.csv
"""

import argparse
import csv
import logging
import sys
import time
from pathlib import Path

from llm_score import parse_titles

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

BATCH_SIZE = 20


def main():
    parser = argparse.ArgumentParser(description="Fix linkedin_company/role via LLM")
    parser.add_argument("--input", required=True, help="Enriched CSV from enrich.py")
    parser.add_argument("--output", required=True, help="Corrected output CSV")
    parser.add_argument("--batch-size", type=int, default=BATCH_SIZE)
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        log.error("Input not found: %s", input_path)
        sys.exit(1)

    with open(input_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        rows = list(reader)

    if "llm_company" not in fieldnames:
        fieldnames = list(fieldnames) + ["llm_company", "llm_role", "crypto_score"]

    has_url = [r for r in rows if r.get("linkedin_url", "").strip()]
    no_url = [r for r in rows if not r.get("linkedin_url", "").strip()]
    log.info("Total rows: %d  (with LinkedIn match: %d, without: %d)", len(rows), len(has_url), len(no_url))

    changes = 0
    for batch_start in range(0, len(has_url), args.batch_size):
        batch = has_url[batch_start : batch_start + args.batch_size]
        entries = [
            {
                "linkedin_name": r.get("linkedin_name", ""),
                "linkedin_role": r.get("linkedin_role", ""),
                "linkedin_company": r.get("linkedin_company", ""),
                "snippet": r.get("snippet", ""),
            }
            for r in batch
        ]

        parsed = parse_titles(entries)

        for r, p in zip(batch, parsed):
            r["llm_company"] = p["company"]
            r["llm_role"] = p["role"]
            r["crypto_score"] = p["crypto_score"]
            old_co = r.get("linkedin_company", "").strip()
            if p["company"] != old_co:
                changes += 1

        batch_end = min(batch_start + args.batch_size, len(has_url))
        log.info(
            "Batch %d-%d/%d processed (%d corrections so far)",
            batch_start + 1, batch_end, len(has_url), changes,
        )
        time.sleep(1)

    for r in no_url:
        r["llm_company"] = ""
        r["llm_role"] = ""
        r["crypto_score"] = ""

    all_rows = has_url + no_url

    output_path = Path(args.output)
    with open(output_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, quoting=csv.QUOTE_ALL, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(all_rows)

    log.info("")
    log.info("=" * 60)
    log.info("  Output: %s", output_path)
    log.info("  Total rows: %d", len(all_rows))
    log.info("  Company corrections: %d", changes)
    log.info("=" * 60)


if __name__ == "__main__":
    main()

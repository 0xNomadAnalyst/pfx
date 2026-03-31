# Phase 1: Exponent Market State and Flows at Maturity

## Summary

Analysis window: T-7d to T+14d around each maturity date.

---

## PT-USX (Maturity: 2026-02-09 10:58 UTC)

### Market State at Maturity

| Metric | Last Pre-Maturity Hour | First Post-Maturity Hour |
|--------|----------------------|-------------------------|
| PT price (SY units) | 0.9991 | 1.0000 |
| Implied APY | 38.2% | 38.2% (frozen) |
| PT reserve (AMM) | 7,534,497 | 7,502,154 |
| SY reserve (AMM) | 1,551,963 | 1,545,301 |
| LP supply | 0.0 | 0.0 |

PT price converged smoothly from ~0.9978 (T-7d) to 1.0 at maturity. LP supply was 0 throughout — liquidity had already been withdrawn before the analysis window.

### Vault State

| Metric | At Maturity | T+14d | Change |
|--------|------------|-------|--------|
| Total SY in escrow | 38,447,214 | 1,869,055 | -95.1% |
| PT supply | 38,447,214 | 1,869,055 | -95.1% |
| Collateralization ratio | 1.0 | 1.0 | unchanged |
| SY exchange rate | 1.0 | 1.0 | n/a (USX 1:1) |

Peak PT supply during vault lifetime: **41,250,743**. At maturity: **39,492,517**.

### Event Flows (T-7d to T+14d)

| Market | Event | Count | SY Flow | PT Flow |
|--------|-------|-------|---------|---------|
| Expired | merge | 1,274 | 53,102,440 out | 53,102,440 in |
| Expired | strip | 239 | 15,488,833 in | 15,488,833 out |
| New | strip | 666 | 17,735,636 in | 17,735,636 out |
| New | merge | 106 | 943,427 out | 943,427 in |

**Maturity day (Feb 9) was the peak:** 28,907,181 SY merged from expired vault in a single day (415 events) — 75% of remaining PT supply. Follow-up: 9,626,539 merged on Feb 10 (221 events).

### Rollover Analysis

- **Expired vault merges (total window):** 53,102,440 SY released
- **New vault strips (total window):** 17,735,636 SY deposited
- **Net new merges on new vault:** 943,427 SY (users exiting new positions, minor)
- **Expired vault strips (pre-maturity):** 15,488,833 SY — early entrants still minting on the expired market before maturity

**Approximate rollover rate:** ~33% of expired merge volume appeared as new market strips in the same window. The remaining ~67% of SY either exited via redeem_sy (unwrap to USX) or remains as SY. Some "new market" strips may represent fresh capital rather than rollover.

### Drawdown Curve

95.1% of PT supply redeemed within 14 days of maturity. The vast majority of activity concentrated on maturity day and the day after (T+0 and T+1), accounting for ~38.5M of 53.1M total merges (73%).

---

## PT-eUSX (Maturity: 2026-03-11 10:58 UTC)

### Market State at Maturity

| Metric | Last Pre-Maturity Hour | First Post-Maturity Hour |
|--------|----------------------|-------------------------|
| PT price (SY units) | 0.9996 | 1.0000 |
| Implied APY | 17.8% | 17.8% (frozen) |
| PT reserve (AMM) | 3,230,288 | 3,068,937 |
| SY reserve (AMM) | 2,659,236 | 2,526,409 |
| LP supply | 0.0 | 0.0 |

### Vault State

| Metric | At Maturity | T+14d | Change |
|--------|------------|-------|--------|
| Total SY in escrow | 19,747,467 | 1,361,164 | -93.1% |
| PT supply | 20,143,076 | 1,308,017 | -93.5% |
| Collateralization ratio | 0.9749 | 0.9736 | -0.1% |
| Final SY exchange rate | 1.025783 | 1.025783 | frozen |

Peak PT supply: **21,984,332**. At maturity: **21,983,766** (virtually unchanged — no pre-maturity exits from vault).

Note: eUSX has a collateralization ratio below 1.0 because the SY exchange rate means 1 SY backs more than 1 PT in underlying terms. The vault is fully collateralized in underlying terms.

### Event Flows (T-7d to T+14d)

| Market | Event | Count | SY Flow | PT Flow |
|--------|-------|-------|---------|---------|
| Expired | merge | 849 | 25,989,485 out | 25,989,485 in |
| Expired | strip | 236 | 6,338,149 in | 6,338,149 out |
| New | strip | 419 | 2,505,032 in | 2,505,032 out |
| New | merge | 151 | 1,071,645 out | 1,071,645 in |

**Maturity day (Mar 11):** 16,781,603 SY merged (243 events) — 76% of outstanding PT.

### Rollover Analysis

- **Expired vault merges (total window):** 25,989,485 SY released
- **New vault strips (total window):** 2,505,032 SY deposited
- **Approximate rollover rate:** ~9.6% of expired merge volume went to new market

**eUSX rollover was dramatically lower than USX** (9.6% vs 33%). This suggests the majority of eUSX holders exited to underlying eUSX rather than rolling into the next market — consistent with the "cascade" hypothesis where eUSX is further unwound into USX redemptions.

### Drawdown Curve

93.5% of PT supply redeemed within 14 days. Similar to USX, the peak activity was on maturity day, with the tail drawn out over 2 weeks.

---

## Key Conclusions

1. **Both markets experienced orderly maturity events** with smooth PT price convergence and rapid post-maturity redemption (>93% within 14 days).
2. **USX rollover rate (~33%)** was significantly higher than **eUSX rollover rate (~10%)**, suggesting eUSX holders had stronger exit intent.
3. **LP was already at zero** for both markets before the analysis window, meaning there was no LP withdrawal shock at maturity.
4. **The maturity day itself was the peak event**, with 73-76% of all merge activity concentrated on T+0 and T+1.
5. **~67% of USX and ~90% of eUSX** merge volume did not appear as new market strips — this volume exited the Exponent ecosystem and potentially cascaded into DEX sell pressure or primary market redemptions.

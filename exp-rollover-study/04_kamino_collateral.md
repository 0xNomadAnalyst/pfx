# Phase 4: Kamino Collateral Activity

## Reserves Identified

| Symbol | Type | LTV | Liq Threshold | Reserve Address (prefix) |
|--------|------|-----|--------------|-------------------------|
| PT-USX (expired) | collateral | 80% | 95% | DARCdqsV1... |
| PT-USX (new) | collateral | 80% | 95% | BLKW7xCY5... |
| PT-eUSX (expired) | collateral | 80% | 95% | 4Z7Jhj7iA... |
| PT-eUSX (new) | collateral | 80% | 95% | EzmztxShS... |
| USX | borrow | 0% | 0% | H2pmnDSjf... |
| eUSX | collateral | 75% | 80% | ARQFJTiUJ... |

Both expired and new PT tokens have their own Kamino reserves. PT tokens are collateral-only (80% LTV, 95% liquidation threshold). USX is borrowable. eUSX is collateral (75% LTV).

---

## PT-USX Collateral Around USX Maturity (2026-02-09)

### Total PT-USX Collateral Supply (sum of both reserves)

| Date | PT-USX Supply | Change | Note |
|------|-------------|--------|------|
| Feb 2 (T-7d) | 7,024,591 | - | baseline |
| Feb 8 (T-1d) | 6,852,820 | -171,771 | mild pre-maturity exit |
| **Feb 9 (T+0)** | **4,709,014** | **-2,143,806** | **maturity day: -31% drop** |
| Feb 10 (T+1) | 4,192,256 | -516,758 | continued withdrawal |
| **Feb 11 (T+2)** | **7,339,914** | **+3,147,658** | **massive re-deposit of new PT** |
| Feb 13 (T+4) | 7,604,844 | +264,930 | new PT deposits continue |
| Feb 18 (T+9) | 8,473,924 | +869,080 | growing beyond pre-maturity |
| Feb 23 (T+14d) | 8,480,860 | +6,936 | stable, 20% above baseline |

**Pattern:** Withdraw expired PT → merge on Exponent → strip new PT → re-deposit new PT as Kamino collateral. The cycle completed within 2 days, and total PT-USX collateral ended **20% higher** than pre-maturity levels.

### Deposit Activity

| Date | PT-USX Deposits | Count |
|------|----------------|-------|
| Feb 6 | 1,180,061 | 26 |
| Feb 9 (T+0) | 1,813,880 | 92 |
| Feb 10 (T+1) | 462,933 | 35 |
| Feb 11 (T+2) | 3,306,351 | 61 |
| Feb 13 (T+4) | 1,018,933 | 5 |

Maturity day saw the highest deposit count (92), but T+2 had the largest single-day volume (3.3M), suggesting users needed time to process the rollover.

---

## PT-eUSX Collateral Around eUSX Maturity (2026-03-11)

### Total PT-eUSX Collateral Supply (sum of both reserves)

| Date | PT-eUSX Supply | Change | Note |
|------|---------------|--------|------|
| Mar 4 (T-7d) | 10,368,217 | - | baseline |
| Mar 10 (T-1d) | 10,141,966 | -226,251 | mild pre-maturity exit |
| **Mar 11 (T+0)** | **1,491,001** | **-8,650,965** | **maturity day: -85% drop** |
| Mar 12 (T+1) | 1,222,649 | -268,352 | continued withdrawal |
| Mar 15 (T+4) | 1,219,795 | -2,854 | stabilized at ~12% of baseline |
| Mar 20 (T+9) | 1,307,902 | +88,107 | slow new PT deposits |
| Mar 25 (T+14d) | 1,330,280 | +22,378 | still only 13% of baseline |

**Dramatically different from PT-USX:** The PT-eUSX collateral dropped 85% and never recovered. Only ~1.3M of the original 10.4M was replaced with new PT-eUSX collateral — consistent with the 10% rollover rate observed in Phase 1.

### eUSX Collateral (not PT) on Kamino

| Date | eUSX Supply | Note |
|------|-----------|------|
| Mar 4 (T-7d) | 1,960,503 | baseline |
| Mar 11 (T+0) | 2,308,181 | +348K (some eUSX from PT-eUSX unwind deposited as eUSX) |
| Mar 19 (T+8) | 4,225,228 | +2.3M — significant migration from PT-eUSX to raw eUSX collateral |
| Mar 25 (T+14d) | 4,362,089 | stabilized at 2.2x baseline |

Interesting — **eUSX collateral on Kamino more than doubled**, suggesting many PT-eUSX collateral users migrated to depositing raw eUSX instead of rolling into the new PT-eUSX market.

---

## USX Borrowing Pool State

### Around USX Maturity

| Date | USX Supply | USX Available | USX Borrowed | Utilization |
|------|-----------|--------------|-------------|------------|
| Feb 2 | 8,772,659 | 501,291 | 8,279,375 | 94.4% |
| Feb 9 (T+0) | 14,236,052 | 6,325,058 | 7,919,582 | 55.6% |
| Feb 13 | 12,889,610 | 3,293,779 | 9,604,647 | 74.5% |
| Feb 23 | 12,851,694 | 2,637,733 | 10,223,686 | 79.6% |

Utilization was extremely high (94%) pre-maturity, then **dropped sharply to 56% on maturity day** as fresh USX was deposited into the lending pool. Utilization slowly climbed back to ~80% as borrowing demand resumed.

### Around eUSX Maturity

| Date | USX Supply | USX Available | Utilization |
|------|-----------|--------------|------------|
| Mar 4 | 14,752,577 | 4,768,732 | 67.7% |
| Mar 11 (T+0) | 17,686,885 | 9,572,737 | 45.9% |
| Mar 25 | 17,570,433 | 7,786,972 | 55.7% |

Again, utilization dropped on maturity day (68% → 46%) as USX was deposited. Supply grew by ~3M on maturity day, consistent with PT-eUSX unwind → eUSX → USX flow being deposited into Kamino.

---

## Liquidation Events

**Zero liquidations** in either maturity window across all PT-USX, PT-eUSX, USX, and eUSX reserves. Despite the massive collateral movements, no positions became unhealthy. The 80% LTV and 95% liquidation threshold provided sufficient buffer.

---

## Key Conclusions

1. **PT-USX collateral had a clean rollover cycle:** -31% on maturity day, fully recovered (and exceeded) within 2 days. Most PT-USX collateral users rolled into the new market.
2. **PT-eUSX collateral collapsed 85% and stayed low:** Only ~13% was replaced with new PT-eUSX. Many users migrated to depositing **raw eUSX** instead (2.2x increase).
3. **USX borrowing utilization dropped sharply** at both maturities as fresh USX entered the lending pool from unwinds.
4. **No liquidations occurred** despite the massive collateral movements. The Kamino risk parameters (80% LTV, 95% liq) were sufficient.
5. **The Kamino flows mirror the Exponent data:** high USX rollover/re-collateralization, low eUSX rollover with a migration to direct eUSX collateral.

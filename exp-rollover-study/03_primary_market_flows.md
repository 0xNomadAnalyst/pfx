# Phase 3: Primary Market Activity (Solstice USX/eUSX)

All raw amounts are in 6-decimal format (divide by 1e6 for human-readable USX/eUSX).

---

## 3a. USX Mint/Redeem Flows

### Around PT-USX Maturity (2026-02-09)

| Day | Redeem Events | USX Redeemed | Mint Events | USX Minted | Net |
|-----|-------------|-------------|------------|-----------|-----|
| Feb 5 | 28 | 1,759,646 | 2 | 457,156 | -1,302,490 |
| Feb 9 (T+0) | 21 | 1,367,280 | 0 | 0 | -1,367,280 |
| Feb 10 (T+1) | 61 | 5,860,912 | 0 | 0 | -5,860,912 |
| Feb 11 (T+2) | 0 | 0 | 1 | 29,996,137 | +29,996,137 |
| Feb 12 | 3 | 9,142,545 | 1 | 6,681 | -9,135,864 |
| Feb 17 | 53 | 3,471,337 | 1 | 11,999,443 | +8,528,106 |
| Feb 18 | 0 | 0 | 1 | 17,499,128 | +17,499,128 |
| Feb 23 | 61 | 4,033,014 | 0 | 0 | -4,033,014 |

**Baseline daily avg:** ~294,909 USX redeemed, ~193,490 USX minted per day.

**Key observation:** Redemptions spiked 5-20x on maturity day and the days following, but were rapidly offset by **large institutional mints** (e.g., ~30M on Feb 11, ~18M on Feb 18). The USX circulating supply actually **grew** from ~302M to ~341M through the maturity event.

### Around PT-eUSX Maturity (2026-03-11)

| Day | Redeem Events | USX Redeemed | Mint Events | USX Minted |
|-----|-------------|-------------|------------|-----------|
| Mar 9 | 36 | 2,380,011 | 0 | 0 |
| Mar 11 (T+0) | 71 | 5,383,110 | 5 | 8,962,146 |
| Mar 13 | 112 | 2,009,248 | 1 | 7,999,533 |
| Mar 18 | 30 | 2,768,144 | 0 | 0 |
| Mar 19 | 126 | 5,051,972 | 1 | 92,320 |
| Mar 20 | 83 | 4,282,958 | 0 | 0 |

Again, large redemption waves were partially offset by mints, but the eUSX maturity window saw more persistent net redemptions. USX supply dropped from ~366M to ~359M.

---

## 3b. eUSX Lock/Unlock/Withdraw Flows

### Around PT-USX Maturity (2026-02-09)

eUSX activity was **not obviously elevated** relative to baseline during the USX maturity event. Baseline daily averages: ~427M locked, ~383M unlocked, ~450M withdrawn.

The eUSX yield pool was essentially unchanged (~122M USX in assets, ~120M eUSX supply) throughout the USX maturity window. This is expected — USX PT maturity does not directly trigger eUSX flows.

### Around PT-eUSX Maturity (2026-03-11)

This is where the cascade becomes visible:

| Day | eUSX Unlocked (raw) | eUSX Withdrawn (raw) | Net USX Flow |
|-----|--------------------|--------------------|-------------|
| Mar 10 (T-1) | 5,136,720M | 140,298M | Pre-maturity exit |
| **Mar 11 (T+0)** | **14,255,112M** | **116,282M** | Massive unlock |
| Mar 12 (T+1) | 1,140,117M | 183,516M | Continued |
| Mar 13 (T+2) | 806,891M | 1,216,021M | Withdrawal spike |
| Mar 18 (T+7) | 3,040,162M | 9,140,791M | Second wave withdrawals |
| Mar 19 (T+8) | 10,811M | 1,018,343M | Continued withdrawals |
| Mar 23 (T+12) | 24,122M | 10,563,845M | Late withdrawal burst |

**Baseline:** ~167M unlocked, ~158M withdrawn per day.

**Maturity day unlocks were 85x baseline.** The pattern shows a two-phase exit: (1) massive unlocks on T+0 through T+2, then (2) massive withdrawals in the T+7 to T+12 window (delayed by the eUSX cooldown period).

### eUSX Yield Pool Drawdown

| Date | Total Assets (USX) | Shares (eUSX) | Exchange Rate |
|------|-------------------|--------------|---------------|
| Mar 4 (T-7d) | 121,397M | 118,408M | 1.02524 |
| Mar 10 (T-1d) | 116,331M | 113,411M | 1.02575 |
| Mar 11 (T+0) | 105,981M | 103,312M | 1.02584 |
| Mar 18 (T+7d) | 100,569M | 97,973M | 1.02650 |
| Mar 25 (T+14d) | 101,658M | 98,976M | 1.02709 |

**The yield pool lost ~19.7M USX (16.2%)** during the maturity window (121.4M → 101.7M total assets), with the sharpest drawdown concentrated on maturity day itself (-10.3M in one day, or -8.9%).

Exchange rate continued to grow monotonically throughout (yield accrual), confirming the pool mechanics were healthy — the drawdown was from redemptions, not losses.

---

## 3c. Cascade Detection (eUSX Exit → USX Redeem)

### User-level cascade (same user does both within 48h)

| Maturity | eUSX Exit Users | USX Redeem Users | Overlap |
|----------|----------------|-----------------|---------|
| USX (Feb 9) | 550 | 3 | **0** |
| eUSX (Mar 11) | 577 | 5 | **3** |

**The direct user-level cascade was minimal.** Only 3 users performed both eUSX withdraw and USX primary market redemption during the eUSX maturity window. Most of the 577 eUSX exit users likely sold their USX on DEX rather than redeeming through the primary market.

This aligns with the DEX data from Phase 2 — the sell pressure showed up on DEX rather than the primary redemption mechanism.

### USX Controller Supply

| Event | Pre-Supply | Post-Supply (T+14d) | Net Change |
|-------|-----------|---------------------|-----------|
| USX maturity (Feb 9) | 302M | 337M | **+35M (+11.6%)** |
| eUSX maturity (Mar 11) | 364M | 359M | **-5M (-1.4%)** |

For USX maturity, supply actually grew (large institutional mints offset redemptions). For eUSX maturity, supply dipped modestly, suggesting some of the eUSX → USX cascade did lead to net USX supply contraction, but it was small.

---

## Key Conclusions

1. **USX redemptions spiked sharply around both maturity dates** but were offset by large institutional mints. The primary market mechanism absorbed the flow without stress.
2. **eUSX yield pool experienced a 16.2% drawdown** during the eUSX maturity window, with the sharpest drop on maturity day (-8.9%).
3. **The eUSX → USX cascade was NOT a direct user-level chain** — only 3 users did both eUSX withdraw and USX redeem. Most eUSX exiters sold USX on DEX.
4. **eUSX withdrawals showed a two-phase pattern:** immediate unlocks at maturity, then delayed withdrawals 7-12 days later (consistent with the eUSX cooldown period).
5. **Net effect on USX supply was modest:** +11.6% during USX maturity (growth!), -1.4% during eUSX maturity.

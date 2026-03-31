# Phase 2: DEX Sell Pressure Cascade

## Pools Identified

| Protocol | Pair | Pool Address (prefix) |
|----------|------|----------------------|
| Orca | USX-USDC | 2e3WeM4WwdEqwTtR... |
| Raydium | USX-USDC | EWivkwNtcxuPsU6R... |
| Orca | eUSX-USX | AUr5EVRwGDsKB2Ee... |
| Raydium | eUSX-USX | BkvKpstxgeEJYzvF... |

Convention: t0 = first token in pair (USX for USX-USDC; eUSX for eUSX-USX). "t0 sell" means the first token is being sold (received by the pool).

---

## PT-USX Maturity (2026-02-09) — DEX Impact

### USX-USDC Pools (Direct Sell Pressure)

**Baseline (T-37d to T-7d) daily averages:**

| Pool | Avg Daily USX Sold | Avg Daily USX Bought | Avg Daily Net Sell |
|------|-------------------|---------------------|-------------------|
| Orca USX-USDC | 536,146 | 633,806 | -97,660 (net buy) |
| Raydium USX-USDC | 599,495 | 635,879 | -36,385 (net buy) |
| **Combined** | **1,135,641** | **1,269,685** | **-134,045** |

During baseline, USX-USDC pools were in a mild net-buy regime.

**Maturity day (Feb 9) — USX-USDC only:**

| Pool | USX Sold | USX Bought | Net Sell | vs Baseline |
|------|---------|-----------|---------|------------|
| Orca | 3,776,847 | 1,045,751 | +2,731,096 | **7.0x** sell volume |
| Raydium | 4,152,519 | 943,862 | +3,208,657 | **6.9x** sell volume |
| **Combined** | **7,929,366** | **1,989,613** | **+5,939,753** | massive flip to net sell |

**Peak days post-maturity (USX-USDC combined):**

| Day | Net USX Sell | Note |
|-----|------------|------|
| Feb 9 (T+0) | +5,939,753 | Maturity day |
| Feb 10 (T+1) | ~+2,700,000 | Second wave |
| Feb 11 (T+2) | ~+2,400,000 | Continued pressure |
| Feb 13 (T+4) | ~+3,000,000 | Late redemption wave |
| Feb 16 (T+7) | ~+4,600,000 | Second large wave |

Elevated sell pressure persisted for **~2 weeks** after maturity, consistent with the vault drawdown curve (95.1% redeemed in 14 days).

### eUSX-USX Pools (Cross-Asset Activity)

On USX maturity day (Feb 9), the eUSX-USX pools showed **net eUSX buying** (USX being sold for eUSX):
- Orca: -549,482 net eUSX sell (= eUSX bought)
- Raydium: -456,449 net eUSX sell (= eUSX bought)

This suggests arbitrageurs were buying eUSX with cheap USX during the sell pressure event, or eUSX holders were not exiting at this point.

### Price Impact

Impact was modest for individual swaps (typically <0.1 bps) but several large swaps hit >0.25 bps and the max single USX sell was 1,400,083 (Feb 13 Orca). The max impact recorded was 2.86 bps (Feb 12 Orca) during a high-activity period.

---

## PT-eUSX Maturity (2026-03-11) — DEX Impact

### eUSX-USX Pools

**Baseline (T-37d to T-7d) daily averages:**

| Pool | Avg Daily eUSX Sold | Avg Daily eUSX Bought | Avg Daily Net Sell |
|------|-------------------|---------------------|-------------------|
| Orca eUSX-USX | 46,132 | 83,750 | -37,618 (net buy) |
| Raydium eUSX-USX | 34,105 | 71,013 | -36,908 (net buy) |
| **Combined** | **80,237** | **154,763** | **-74,526** |

Again, baseline was mild net buying of eUSX.

**Maturity day (Mar 11) — eUSX-USX:**

| Pool | eUSX Sold | eUSX Bought | Net Sell | vs Baseline |
|------|---------|-----------|---------|------------|
| Orca | 3,048,310 | 2,644,006 | +404,304 | **66x** sell volume |
| Raydium | 2,911,532 | 2,509,062 | +402,470 | **85x** sell volume |
| **Combined** | **5,959,842** | **5,153,068** | **+806,774** | massive spike |

Volume spiked massively on maturity day (~6M eUSX traded vs baseline ~80K/day), but the net sell pressure was relatively contained at **+807K net eUSX sell** because strong buying absorbed much of it.

**Maturity window totals (22 days):**
- Total eUSX sell: 8,729,803
- Total eUSX buy: 8,991,699
- **Net: -261,896 (slight net BUY over the full window)**

Unlike USX, where sell pressure was persistent and one-directional, eUSX sell pressure was **absorbed within days** and the window actually ended in mild net buying. This suggests:
1. The eUSX sell pressure was more episodic (concentrated on maturity day)
2. Arbitrageurs or new entrants quickly absorbed the selling
3. Much of the eUSX exit may have gone through the primary market (eUSX → USX redemption) rather than DEX

### Price Impact

- Maturity day max impact: 5.2 bps (Raydium), 4.2 bps (Orca) — meaningfully higher than USX
- Max single eUSX sell: 1,052,400 (Orca, Mar 11), 947,600 (Raydium, Mar 11)
- Post-maturity impact spikes: 12.9 bps (Orca, Mar 13), 198.3 bps (Orca, Mar 19) — the latter likely a thin-liquidity spike

---

## Key Conclusions

1. **USX-USDC pools absorbed ~14M net USX sell pressure** over the 22-day window (vs -134K/day baseline net buy). The regime flipped from mild net buy to sustained net sell for ~2 weeks.
2. **eUSX-USX pools saw a massive maturity-day volume spike** (~6M traded vs ~80K/day baseline) but net sell pressure was only ~807K on that day and the full window was actually net-buy.
3. **USX sell pressure was more persistent** (2-week tail), while **eUSX sell pressure was concentrated and quickly absorbed**.
4. **Price impacts were modest for USX** (<3 bps) but **more elevated for eUSX** (up to 5 bps on maturity day, with thin-liquidity spikes later).
5. The **eUSX cascade hypothesis** (eUSX → USX → USDC sell chain) may be visible in the USX-USDC pools around the eUSX maturity date — this needs cross-referencing with Phase 3 primary market data.

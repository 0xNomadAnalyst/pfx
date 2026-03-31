# Phase 5: Synthesis — Exponent Maturity Rollover Study

## Executive Summary

This study examined what happened when the first PT-USX and PT-eUSX markets matured on Exponent, tracking capital flows across four protocol layers: Exponent (yield trading), DEX (secondary market), Solstice (primary market), and Kamino (lending). Both maturity events were orderly, with no liquidations or protocol stress, but the two assets showed starkly different rollover behavior.

---

## The Two Maturity Events

| | PT-USX | PT-eUSX |
|---|--------|---------|
| Maturity date | 2026-02-09 10:58 UTC | 2026-03-11 10:58 UTC |
| PT supply at maturity | ~39.5M | ~22.0M |
| Drawdown at T+14d | 95.1% redeemed | 93.5% redeemed |
| Rollover rate to market 2 | ~33% | ~10% |
| Kamino PT collateral recovery | Exceeded pre-maturity (+20%) | Collapsed (-87%) |

---

## Capital Flow Diagrams

### PT-USX Maturity Flow (39.5M PT supply)

```
PT-USX Matures (39.5M)
  |
  |--[33%]--> Roll to new PT-USX market (17.7M stripped into new vault)
  |              |
  |              +--> ~7.3M re-deposited as Kamino collateral
  |
  |--[67%]--> Redeem SY (merge: 53.1M total, net exit ~35.4M)
                |
                |--[major]--> Sell USX on DEX
                |               Net ~14M USX sell pressure over 22 days
                |               (vs baseline net buy of -134K/day)
                |
                |--[minor]--> USX primary redemption
                |               Spiked but offset by 30M+ institutional mints
                |               Supply grew 302M -> 341M (+13%)
                |
                |--[minor]--> Deposit USX into Kamino lending
                              Utilization dropped 94% -> 56%
```

### PT-eUSX Maturity Flow (22.0M PT supply)

```
PT-eUSX Matures (22.0M)
  |
  |--[10%]--> Roll to new PT-eUSX market (2.5M stripped into new vault)
  |              |
  |              +--> Only 1.3M as Kamino collateral (vs 10.4M pre-maturity)
  |
  |--[90%]--> Redeem SY to eUSX (merge: 26.0M total, net exit ~23.5M)
                |
                |--[significant]--> eUSX yield pool drawdown
                |                    -16.2% (121M -> 102M USX in pool)
                |                    Two-phase: unlocks at T+0, withdrawals at T+7-12
                |
                |--[episodic]--> Sell eUSX on DEX
                |                 6M eUSX traded on maturity day (vs 80K/day baseline)
                |                 But only +807K net sell (quickly absorbed)
                |                 Full window was actually net-buy
                |
                |--[minimal]--> eUSX -> USX cascade via primary market
                |                Only 3 users did both eUSX exit and USX redeem
                |                Most eUSX exiters sold USX on DEX instead
                |
                |--[notable]--> Migration to raw eUSX on Kamino
                                eUSX collateral 2.0M -> 4.4M (+120%)
                                Users chose eUSX collateral over PT-eUSX
```

---

## Key Findings

### 1. USX: High Rollover, Persistent DEX Pressure

USX holders showed strong conviction in the yield product — 33% rolled directly into the new market and PT-USX Kamino collateral fully recovered within 2 days. However, the 67% that exited created significant, sustained sell pressure on USX-USDC DEX pools (14M net sell over 2 weeks, with the regime flipping from mild net-buy to sustained net-sell). This pressure was ultimately absorbed without lasting price impact (<3 bps), supported by large institutional mints that grew USX supply by 13%.

### 2. eUSX: Low Rollover, Absorbed DEX Pressure, Yield Pool Drawdown

Only 10% of eUSX holders rolled over, and Kamino PT-eUSX collateral collapsed 87%. The eUSX yield pool lost 16.2% of assets. However, the DEX sell pressure was surprisingly contained — a massive maturity-day volume spike (75x baseline) was absorbed within the same day, with the full 22-day window ending in slight net buying. This suggests strong arbitrageur or counterparty activity in eUSX-USX pools.

### 3. The eUSX Cascade Was DEX-Routed, Not Primary-Market-Routed

The hypothesized cascade (eUSX PT unwind -> eUSX exit -> USX redemption) was real in aggregate but did NOT flow through the primary redemption mechanism. Only 3 users performed both an eUSX exit and USX redeem in the maturity window. Instead, the cascade manifested as: PT-eUSX merge -> eUSX yield pool withdrawal -> sell USX on DEX. The eUSX cooldown period created a natural buffer, delaying withdrawals by 7-12 days.

### 4. Kamino Was Unaffected — No Liquidations

Despite massive collateral movements (PT-USX: -31% then recovery; PT-eUSX: -85% permanent), zero liquidations occurred. The 80% LTV / 95% liquidation threshold parameters provided adequate buffer. Notable secondary effect: USX lending utilization dropped sharply at both maturities (94% -> 56% and 68% -> 46%) as fresh USX entered the pool from unwinds.

### 5. eUSX Users Migrated Strategy, Not Just Exited

Rather than simply leaving, many PT-eUSX users shifted to depositing raw eUSX as Kamino collateral (supply grew from 2.0M to 4.4M). This suggests a preference shift away from PT-eUSX yield trading toward simpler eUSX collateral strategies.

---

## Timing Patterns

| Phase | USX | eUSX |
|-------|-----|------|
| PT price convergence | Smooth over 7 days (0.998 -> 1.0) | Smooth (0.998 -> 1.0) |
| Peak merge activity | T+0 and T+1 (73% of all merges) | T+0 and T+1 (76% of all merges) |
| DEX sell pressure peak | T+0 (7x baseline), sustained 2 weeks | T+0 (75x baseline), absorbed same day |
| Kamino collateral trough | T+1, recovered by T+2 | T+0, permanent |
| eUSX yield pool trough | n/a | T+7 to T+12 (cooldown-delayed) |
| Full vault drawdown | 95% by T+14d | 93.5% by T+14d |

---

## Risk Implications

1. **Maturity events create predictable, time-bounded sell pressure.** For USX, this lasted ~2 weeks. For eUSX, it was episodic and absorbed quickly. Future maturities can be anticipated.

2. **The eUSX cooldown period is a natural circuit breaker.** It spreads withdrawal pressure over 7-12 days, preventing a single-day cascade event.

3. **Institutional mint activity can offset maturity redemptions.** The 30M+ USX mint on Feb 11 (T+2) effectively neutralized the redemption pressure.

4. **Kamino risk parameters are adequate.** No liquidations despite 85% PT collateral drops. However, the concentration of PT-eUSX collateral (~10M pre-maturity) could be a risk if liquidation parameters were tighter.

5. **Low eUSX rollover rate (10%) is a retention signal.** If future maturities show similarly low rollover, it may indicate structural issues with eUSX yield demand on Exponent — or simply that users prefer direct eUSX collateral strategies on Kamino.

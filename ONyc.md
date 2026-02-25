# ONyc Market Configuration

## Token Details

| Token | Mint | Symbol | Decimals | Source |
|-------|------|--------|----------|--------|
| ONyc | `5Y8NV33Vv7WbnLfq3zBcKSdYPrk7g2KoiQoe7M2tcxp5` | ONyc | 9 | Raydium pool state `mint_decimals_1` |
| USDG | `2u1tszSeqZ3qBWF3uNGPFc8TzMk2tdiwknnRMWGWjGWH` | USDG | 6 | Raydium pool state `mint_decimals_0` |
| USDC | `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v` | USDC | 6 | Known |

## DEX Pools

| Protocol | Pool Address | Pair | Tick Spacing | Fee Rate |
|----------|-------------|------|-------------|----------|
| Raydium CLMM | `A9RdNEf4T9x1eNPnEHFX1ABHS7J4e9kxBm43S3o5r9Kw` | USDG-ONyc | 1 | - |
| Orca Whirlpool | `7jhhyxPUKpu42hPGSYwgMXbR2dtVJHKhs8DW3sAAgAvX` | ONyc-USDC | 1 | 100 (1bp) |

Both pools: tick_spacing=1, tokenA (Orca) = ONyc (9 decimals), tokenB (Orca) = USDC (6 decimals).
Orca tick_current = -68366, Raydium tick_current = 68365 (sign-flipped due to reversed pair order -- same price).

Links:
- Raydium: https://raydium.io/clmm/create-position/?pool_id=A9RdNEf4T9x1eNPnEHFX1ABHS7J4e9kxBm43S3o5r9Kw
- Orca: https://www.orca.so/pools/7jhhyxPUKpu42hPGSYwgMXbR2dtVJHKhs8DW3sAAgAvX

## Kamino Lending Market

`FsvTiXTUFDc4aLbrov4PrvDTjXCWCniL1dxTUkZ1T2ss`

## Exponent

Underlying token: `5Y8NV33Vv7WbnLfq3zBcKSdYPrk7g2KoiQoe7M2tcxp5` (ONyc, 9 decimals)

---

## Ready-to-Paste Env Vars

### Dexes Service

```env
POOLS=A9RdNEf4T9x1eNPnEHFX1ABHS7J4e9kxBm43S3o5r9Kw:USDG-ONyc:raydium,7jhhyxPUKpu42hPGSYwgMXbR2dtVJHKhs8DW3sAAgAvX:ONyc-USDC:orca
TOKENS=5Y8NV33Vv7WbnLfq3zBcKSdYPrk7g2KoiQoe7M2tcxp5:ONyc:9,2u1tszSeqZ3qBWF3uNGPFc8TzMk2tdiwknnRMWGWjGWH:USDG:6,EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v:USDC:6
```

Note: ONyc is 9 decimals (not 6). With `tick_spacing=1` and current price near $0.93 USDG,
the default tick array spread (4%) should be adequate if ONyc trades in a tight range.
If it moves more broadly, consider:

```env
TICKARRAY_SET=up-to-edge
TICKARRAY_EDGE_DISCOVERY_ATTEMPTS=10.0,25.0,50.0,100.0
```

### Kamino Service

```env
KAMINO_LENDING_MARKET_ADDRESS=FsvTiXTUFDc4aLbrov4PrvDTjXCWCniL1dxTUkZ1T2ss
```

Reserves will be auto-discovered via RPC on first poll, then enriched from DB on subsequent polls.

### Exponent Service

```env
EXPONENT_BASE_TOKENS=5Y8NV33Vv7WbnLfq3zBcKSdYPrk7g2KoiQoe7M2tcxp5:ONyc:9
```

Discovery will find all Exponent markets whose underlying token is ONyc.
If no Exponent markets exist for ONyc yet, the service will start empty and
pick them up automatically when deployed.

Note: the test market depth filter default (`EXPONENT_TEST_MARKET_MIN_DEPTH_RAW=50000000000`)
is calibrated for 6-decimal tokens ($50K). For 9-decimal ONyc, the equivalent threshold
would be `50000000000000` (50T raw = $50K at 9 decimals). Adjust if needed:

```env
EXPONENT_TEST_MARKET_MIN_DEPTH_RAW=50000000000000
```

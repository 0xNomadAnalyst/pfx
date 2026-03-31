# Phase 0: Discovery

## USX and eUSX Markets on Exponent

Four markets identified — two per underlying, one expired (market 1) and one active (market 2).

### PT-USX Markets

| Field | Market 1 (Expired) | Market 2 (Active) |
|-------|-------------------|-------------------|
| vault_address | HJZigEFmMwArysvFpieGsEEZqWczitHFUmzUHTMkXpsW | 4hZugBhgd3xxShK5iHbBAwCnJUjthiStT6LnruRwarjr |
| market_address | 31XQjgfV5PiF2yXEbyctpq7gZ1TALkC9JvygjiR8xJrB | BxbiZpzj32nrVGecFy8VQ1HohaW7ryhas1k9aiETDWdm |
| maturity_date | 2026-02-09 | 2026-06-01 |
| maturity_ts | 1770634699 | 1780318699 |
| maturity_datetime | 2026-02-09 10:58:19 UTC | 2026-06-01 12:58:19 UTC |
| env_sy_symbol | wUSX | wUSX |
| meta_pt_symbol | PT-USX | PT-USX |
| meta_base_symbol | USX | USX |
| mint_sy | 4CEd2syXcV8rAiwFkdCkpmTBsgGVS7NcFnygf86EG2KT | (same) |
| mint_pt | 7vWj1UriSscGmz5wadAC8EkA8ndoU3M7WUifqxTC3Ysf | 3kctCXgt6pP3uZcek8SqNK2KZdQ6cqtj9hc3U46jhgBk |
| mint_yt | HQmMS5W34VcMtR85akhZgvypy7iqVWRXi282vwdf9eTX | Au8g11nXqXrUAmL14GM3gQnrnJnr4dcpgc5DNAnu9F9s |
| mint_lp | 6K6bDA3f2heMYZQzbu3GDzx73zEXCeWZ58msfc1kDA6n | BR2JKV9gPoJfX8A8DkFmo2yNQKCeGipg33oYaZ4EmjbW |
| sy_interface_type | One | One |
| sy_yield_bearing_mint | 6FrrzDk5mQARGc1TDYoyVnSyRdds1t4PbtohCD6p3tgG | (same) |

### PT-eUSX Markets

| Field | Market 1 (Expired) | Market 2 (Active) |
|-------|-------------------|-------------------|
| vault_address | 5G1jVLtmqYctNTU7ok1rr8t2SeSKe8LcFUSh63EX8WWg | 7NviQEEiA5RSY4aL1wpqGE8CYAx2Lx7THHinsW1CWDXu |
| market_address | GhjqLUcaCrfH9s6bM5H9GvbWoDTYGsdXxVubP8J57cUr | rBbzpGk3PTX8mvQg95VWJ24EDgvxyDJYrEo9jtauvjP |
| maturity_date | 2026-03-11 | 2026-06-01 |
| maturity_ts | 1773226699 | 1780318699 |
| maturity_datetime | 2026-03-11 10:58:19 UTC | 2026-06-01 12:58:19 UTC |
| env_sy_symbol | weUSX | weUSX |
| meta_pt_symbol | PT-eUSX | PT-eUSX |
| meta_base_symbol | eUSX | eUSX |
| mint_sy | 7EtXTvy1NBEo51N3Bj3VYafgDFfPcTy5sjpVZvVGiiyR | (same) |
| mint_pt | 6oiDcfve7ybKUC8ysZmncC9iSuxQG2vrRkh3dgV7EKR4 | BNR2FsHo8JrYGWx2V8yxG5GBWiG3uU8voi2eMGBHFwEj |
| mint_yt | DDoYyEUcdkHV5a4NCPXDRL9f93NgPbqK9ZANAGL627wF | GEYwnvNzqFXrLnNq4riXbn2ASnwU3cF8RXW6wXKHM4sw |
| mint_lp | Gz6LTebmfQqjbQD4C5NzqFN6PVWRd9pG3BJ4p4xHeDxF | 4GT6g1iKx2TyYCkwt1tERkReQjSUuVE7uh14M5W8v2nn |
| sy_interface_type | Solstice | Solstice |
| sy_yield_bearing_mint | 3ThdFZQKM6kRyVGLG48kaPg5TRMhYMKY1iCRa9xop1WC | (same) |

## Key Observations

- **SY tokens are shared** across market generations: both USX markets use the same `mint_sy` (wUSX), both eUSX markets use the same `mint_sy` (weUSX). This is structurally important — rollover means merge PT+YT on expired vault to get SY, then strip SY on new vault.
- **USX market 1 matured 2026-02-09** (~7 weeks ago as of 2026-03-31)
- **eUSX market 1 matured 2026-03-11** (~3 weeks ago as of 2026-03-31)
- Both market 2s mature on 2026-06-01
- `is_active` and `is_expired` flags are both False for all markets (aux_key_relations may not refresh these flags post-maturity)

## Maturity Windows for Analysis

| Asset | Maturity | Pre-window (T-7d) | Post-window (T+14d) |
|-------|----------|-------------------|---------------------|
| PT-USX | 2026-02-09 10:58 UTC | 2026-02-02 | 2026-02-23 |
| PT-eUSX | 2026-03-11 10:58 UTC | 2026-03-04 | 2026-03-25 |

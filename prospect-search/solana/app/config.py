"""
Configuration for prospect-search candidate-generation engine.
API endpoints, excluded tokens, scoring weights, and thresholds.
"""

# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

ORCA_POOLS_URL = "https://api.orca.so/v2/solana/pools"
RAYDIUM_POOLS_URL = "https://api-v3.raydium.io/pools/info/list"
METEORA_POOLS_URL = "https://dammv2-api.meteora.ag/pools"
KAMINO_MARKETS_URL = "https://api.kamino.finance/v2/kamino-market"
KAMINO_RESERVES_URL = "https://api.kamino.finance/kamino-market/{pubkey}/reserves/metrics"
EXPONENT_MARKETS_URL = "https://web-api.exponent.finance/api/markets"

# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

MIN_TVL_USD = 10_000  # per-pool minimum to skip dust

# Tokens excluded from the prospect output.
# See docs/exclusion-rationale.md for the reasoning behind each category.
#
# Structure: { mint_address: { "symbol": ..., "category": ..., "note": ... } }
# The symbol and category fields are for documentation / downstream reference.
# The aggregator derives EXCLUDED_TOKEN_MINTS and EXCLUDED_TOKEN_SYMBOLS from
# this dictionary automatically.
EXCLUDED_TOKENS = {
    # -- Stablecoins ----------------------------------------------------------
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": {
        "symbol": "USDC",
        "category": "stablecoin",
        "note": "Circle — major fiat-backed stablecoin, not a project-level prospect",
    },
    "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": {
        "symbol": "USDT",
        "category": "stablecoin",
        "note": "Tether — major fiat-backed stablecoin",
    },
    "2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo": {
        "symbol": "PYUSD",
        "category": "stablecoin",
        "note": "PayPal USD — institutional stablecoin",
    },
    "EjmyN6qEC1Tf1JxiG1ae7UTJhUxSwk1TCWNWqxWV4J6o": {
        "symbol": "DAI",
        "category": "stablecoin",
        "note": "DAI (Wormhole) — MakerDAO, Ethereum-native decentralised stablecoin",
    },

    # potentially relevant
    # "7kbnvuGBxxj8AG9qp8Scn56muWGaRaFqxg1FsRp3PaFT": {
    #     "symbol": "UXD",
    #     "category": "stablecoin",
    #     "note": "UXD Protocol — delta-neutral stablecoin",
    # },

    # potentially relevant
    # "A1KLoBrKBde8Ty9qtNQUtq3C2ortoC3u7twggz7sEto6": {
    #     "symbol": "USDY",
    #     "category": "stablecoin",
    #     "note": "Ondo USDY — tokenised US Treasury yield stablecoin",
    # },

    # -- Base-layer assets ----------------------------------------------------
    "So11111111111111111111111111111111111111112": {
        "symbol": "SOL",
        "category": "base_layer",
        "note": "Native SOL (wrapped) — the chain's base asset",
    },
    "3NZ9JMVBmGAqocybic2c7LQCJScmgsAZ6vQqTDzcqmJh": {
        "symbol": "WBTC",
        "category": "base_layer",
        "note": "Wrapped BTC (Wormhole) — bridge-wrapped Bitcoin",
    },
    "6DNSN2BJsaPFdBAwMgzBLckjpGR3GNtiePyCqAMHre18": {
        "symbol": "tBTC",
        "category": "base_layer",
        "note": "Threshold tBTC — decentralised wrapped Bitcoin",
    },
    "7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs": {
        "symbol": "WETH",
        "category": "base_layer",
        "note": "Wrapped ETH (Wormhole) — bridge-wrapped Ether",
    },

    # -- Liquid staking tokens ------------------------------------------------
    "mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So": {
        "symbol": "mSOL",
        "category": "lst",
        "note": "Marinade staked SOL — largest Solana LST by market share",
    },

    # potentially relevant
    # "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn": {
    #     "symbol": "JitoSOL",
    #     "category": "lst",
    #     "note": "Jito staked SOL — MEV-boosted LST",
    # },

    "7dHbWXmci3dT8UFYWYZweBLXgycu7Y3iL6trKn1Y7ARj": {
        "symbol": "stSOL",
        "category": "lst",
        "note": "Lido staked SOL — Lido on Solana (deprecated)",
    },
    "bSo13r4TkiE4KumL71LsHTPpL2euBYLFx6h9HP3piy1": {
        "symbol": "bSOL",
        "category": "lst",
        "note": "BlazeStake staked SOL",
    },

    # potentially relevant
    # "5oVNBeEEQvYi1cX3ir8Dx5n1P7pdxydbGF2X4TxVusJm": {
    #     "symbol": "INF",
    #     "category": "lst",
    #     "note": "Sanctum Infinity — multi-LST basket token",
    # },

    # -- Source protocol governance tokens ------------------------------------
    "orcaEKTdK7LKz57vaAYr9QeNsVEPfiu6QeMU1kektZE": {
        "symbol": "ORCA",
        "category": "source_protocol",
        "note": "Orca DEX governance — we query Orca as a data source",
    },
    "4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R": {
        "symbol": "RAY",
        "category": "source_protocol",
        "note": "Raydium governance — we query Raydium as a data source",
    },
}

# Derived sets used by the aggregator for fast membership tests.
EXCLUDED_TOKEN_MINTS = set(EXCLUDED_TOKENS.keys())
EXCLUDED_TOKEN_SYMBOLS = {v["symbol"].upper() for v in EXCLUDED_TOKENS.values()}

# ---------------------------------------------------------------------------
# Scoring weights  (must sum to 1.0)
# ---------------------------------------------------------------------------

SCORE_WEIGHT_ECONOMIC = 0.40
SCORE_WEIGHT_BREADTH = 0.30
SCORE_WEIGHT_COMPLEXITY = 0.20
SCORE_WEIGHT_RISK = 0.10

# Cap for pool_count normalisation in complexity score
POOL_COUNT_CAP = 20

# ---------------------------------------------------------------------------
# Network / rate-limit
# ---------------------------------------------------------------------------

REQUEST_DELAY_S = 0.25  # seconds between paginated API calls
REQUEST_TIMEOUT_S = 30

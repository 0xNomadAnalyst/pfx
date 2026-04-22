"""
Configuration for EVM prospect-search candidate-generation engine.
API endpoints, target chains, excluded tokens, scoring weights, and thresholds.
"""

# ---------------------------------------------------------------------------
# Target EVM chains
# ---------------------------------------------------------------------------

TARGET_CHAINS = ["ethereum", "arbitrum", "base", "optimism", "polygon"]

# Mapping used by fetchers that need numeric chain IDs
CHAIN_ID_MAP = {
    "ethereum": 1,
    "arbitrum": 42161,
    "base": 8453,
    "optimism": 10,
    "polygon": 137,
}

CHAIN_ID_TO_NAME = {v: k for k, v in CHAIN_ID_MAP.items()}

# Balancer uses its own enum names
BALANCER_CHAIN_MAP = {
    "ethereum": "MAINNET",
    "arbitrum": "ARBITRUM",
    "base": "BASE",
    "optimism": "OPTIMISM",
    "polygon": "POLYGON",
}

# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

DEFILLAMA_POOLS_URL = "https://yields.llama.fi/pools"
CURVE_POOLS_URL = "https://api.curve.finance/v1/getPools/all/{chain}"
BALANCER_GRAPHQL_URL = "https://api-v3.balancer.fi/"
AAVE_DATA_URL = "https://th3nolo.github.io/aave-v3-data/aave_v3_data.json"
MORPHO_GRAPHQL_URL = "https://blue-api.morpho.org/graphql"
PENDLE_MARKETS_URL = "https://api-v2.pendle.finance/core/v2/markets/all"

# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

MIN_TVL_USD = 10_000

# Tokens excluded from the prospect output.
# EVM tokens have different addresses per chain, so the primary exclusion
# mechanism is symbol-based.  Ethereum mainnet addresses are included for
# documentation and optional address-level filtering.
EXCLUDED_TOKENS = {
    # -- Stablecoins ----------------------------------------------------------
    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48": {
        "symbol": "USDC",
        "category": "stablecoin",
        "note": "Circle USD Coin",
    },
    "0xdAC17F958D2ee523a2206206994597C13D831ec7": {
        "symbol": "USDT",
        "category": "stablecoin",
        "note": "Tether USD",
    },
    "0x6B175474E89094C44Da98b954EedeAC495271d0F": {
        "symbol": "DAI",
        "category": "stablecoin",
        "note": "MakerDAO DAI",
    },
    # "0x853d955aCEf822Db058eb8505911ED77F175b99e": {
    #     "symbol": "FRAX",
    #     "category": "stablecoin",
    #     "note": "Frax stablecoin",
    # },
    "0x5f98805A4E8be255a32880FDeC7F6728C6568bA0": {
        "symbol": "LUSD",
        "category": "stablecoin",
        "note": "Liquity USD",
    },
    # "0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E": {
    #     "symbol": "crvUSD",
    #     "category": "stablecoin",
    #     "note": "Curve USD stablecoin",
    # },
    # "0x4c9EDD5852cd905f086C759E8383e09bff1E68B3": {
    #     "symbol": "USDe",
    #     "category": "stablecoin",
    #     "note": "Ethena USDe",
    # },
    "0x0000000000085d4780B73119b644AE5ecd22b376": {
        "symbol": "TUSD",
        "category": "stablecoin",
        "note": "TrueUSD",
    },
    "0x8457CA5040ad67fdebbCC8EdCE889A335Bc0fbFB": {
        "symbol": "PYUSD",
        "category": "stablecoin",
        "note": "PayPal USD",
    },

    # -- Base-layer assets ----------------------------------------------------
    "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2": {
        "symbol": "WETH",
        "category": "base_layer",
        "note": "Wrapped Ether",
    },
    "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599": {
        "symbol": "WBTC",
        "category": "base_layer",
        "note": "Wrapped Bitcoin",
    },
    "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE": {
        "symbol": "ETH",
        "category": "base_layer",
        "note": "Native Ether placeholder",
    },

    # -- Liquid staking tokens ------------------------------------------------
    "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84": {
        "symbol": "stETH",
        "category": "lst",
        "note": "Lido staked ETH",
    },
    "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0": {
        "symbol": "wstETH",
        "category": "lst",
        "note": "Lido wrapped staked ETH",
    },
    "0xae78736Cd615f374D3085123A210448E74Fc6393": {
        "symbol": "rETH",
        "category": "lst",
        "note": "Rocket Pool staked ETH",
    },
    "0xBe9895146f7AF43049ca1c1AE358B0541Ea49704": {
        "symbol": "cbETH",
        "category": "lst",
        "note": "Coinbase staked ETH",
    },

    # -- Source protocol governance tokens ------------------------------------
    "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984": {
        "symbol": "UNI",
        "category": "source_protocol",
        "note": "Uniswap governance",
    },
    "0xD533a949740bb3306d119CC777fa900bA034cd52": {
        "symbol": "CRV",
        "category": "source_protocol",
        "note": "Curve governance",
    },
    "0xba100000625a3754423978a60c9317c58a424e3D": {
        "symbol": "BAL",
        "category": "source_protocol",
        "note": "Balancer governance",
    },
    "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9": {
        "symbol": "AAVE",
        "category": "source_protocol",
        "note": "Aave governance",
    },
    "0x58D97B57BB95320F9a05dC918Aef65434969c2B2": {
        "symbol": "MORPHO",
        "category": "source_protocol",
        "note": "Morpho governance",
    },
    "GMORPHO_VIRTUAL": {
        "symbol": "GMORPHO",
        "category": "source_protocol",
        "note": "Morpho governance wrapper (multiple addresses per chain)",
    },
}

EXCLUDED_TOKEN_SYMBOLS = {v["symbol"].upper() for v in EXCLUDED_TOKENS.values()}

# ---------------------------------------------------------------------------
# Scoring weights  (must sum to 1.0)
# ---------------------------------------------------------------------------

SCORE_WEIGHT_ECONOMIC = 0.40
SCORE_WEIGHT_BREADTH = 0.30
SCORE_WEIGHT_COMPLEXITY = 0.20
SCORE_WEIGHT_RISK = 0.10

POOL_COUNT_CAP = 30

# ---------------------------------------------------------------------------
# Network / rate-limit
# ---------------------------------------------------------------------------

REQUEST_DELAY_S = 0.25
REQUEST_TIMEOUT_S = 30

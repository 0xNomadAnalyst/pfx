{{
  config(
    materialized='view'
  )
}}

-- Latest query per pool: provides protocol, pair, current tick, and price info
with ranked as (
    select
        query_id,
        pool_address,
        protocol,
        token_pair as pair,
        block_time,
        current_tick,
        sqrt_price_x64,
        mint_decimals_0,
        mint_decimals_1,
        row_number() over (
            partition by pool_address
            order by block_time desc
        ) as rn
    from {{ source('dexes', 'src_acct_tickarray_queries') }}
)

select
    query_id,
    pool_address,
    protocol,
    pair,
    block_time,
    current_tick,
    sqrt_price_x64,
    mint_decimals_0,
    mint_decimals_1,
    round(
        (power(sqrt_price_x64::double precision / power(2::double precision, 64), 2)
            * power(10, mint_decimals_0 - mint_decimals_1))::numeric,
        6
    ) as current_price_t1_per_t0
from ranked
where rn = 1

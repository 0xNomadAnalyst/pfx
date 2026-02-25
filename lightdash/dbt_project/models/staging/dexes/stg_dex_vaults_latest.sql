{{
  config(
    materialized='view'
  )
}}

-- Most recent vault reserve balance per protocol + pair
with ranked as (
    select
        pool_address,
        protocol,
        token_pair as pair,
        block_time,
        token_0_value,
        token_1_value,
        row_number() over (
            partition by protocol, token_pair
            order by block_time desc
        ) as rn
    from {{ source('dexes', 'src_acct_vaults') }}
)

select
    pool_address,
    protocol,
    pair,
    block_time,
    token_0_value,
    token_1_value
from ranked
where rn = 1

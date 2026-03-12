{{
  config(
    materialized='view'
  )
}}

select
    pool_address,
    tick_lower,
    tick_upper,
    query_id,
    round(token0_value::numeric, 0)::double precision as token0_value,
    round(token1_value::numeric, 0)::double precision as token1_value,
    round(token0_cumul::numeric, 0)::double precision as token0_cumul,
    round(token1_cumul::numeric, 0)::double precision as token1_cumul
from {{ source('dexes', 'src_acct_tickarray_tokendist_latest') }}

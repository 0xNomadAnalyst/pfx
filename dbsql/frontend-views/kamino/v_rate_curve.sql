-- Kamino Lend - Borrow Rate Curve View for USX Reserve
-- Extracts and processes the borrow rate curve from the USX borrow reserve
-- Uses rate_curve_all() function with variable granularity interpolation
-- Column names maintained for chart compatibility with existing visualizations

CREATE OR REPLACE VIEW kamino_lend.v_rate_curve_usx AS
WITH usx_curve AS (
    -- Get the interpolated curve for USX (and any reserves sharing the same curve)
    SELECT 
        reserve_assets,
        reserve_addresses,
        utilization_bps,
        utilization_pct,
        borrow_rate_bps,
        borrow_rate_pct
    FROM kamino_lend.rate_curve_all()
    WHERE 'USX' = ANY(reserve_assets)
),
usx_reserve_info AS (
    -- Get the latest metadata for USX reserve
    SELECT DISTINCT ON (reserve_address)
        reserve_address,
        env_symbol,
        time
    FROM kamino_lend.src_reserves
    WHERE reserve_address = 'H2pmnDSjfxeQ8zUeyUohokegYbXZgkjH4kgmoQVybyAX'
    ORDER BY reserve_address, time DESC
)
SELECT 
    uc.borrow_rate_bps,
    uc.utilization_bps AS utilization_rate_bps,
    uc.borrow_rate_pct,
    uc.utilization_pct AS utilization_rate_pct,
    uri.time AS last_updated,
    uri.reserve_address,
    uri.env_symbol
FROM usx_curve uc
CROSS JOIN usx_reserve_info uri
ORDER BY uc.utilization_bps;

-- Add view comment
COMMENT ON VIEW kamino_lend.v_rate_curve_usx IS 
'Borrow rate curve data for the USX reserve with interpolated points from 0-100% utilization.
Uses variable granularity: 5% steps (0-80%), 2% steps (80-90%), 1% steps (90-95%), 0.5% steps (95-100%).
Reserve: H2pmnDSjfxeQ8zUeyUohokegYbXZgkjH4kgmoQVybyAX (USX - borrow asset)
Column names match legacy format for chart compatibility.
Returns 37 interpolated data points for smooth visualization.';
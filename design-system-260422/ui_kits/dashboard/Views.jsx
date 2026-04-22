// Dashboard UI Kit — view compositions (one per sidebar tab)

/* ────────────────── Overview ────────────────── */
function OverviewView() {
  return (
    <React.Fragment>
      <MetricStrip metrics={[
        { label: "Total Monitored TVL", value: "$1.42B",  delta: "1.24%", direction: "up"   },
        { label: "24h Swap Volume",     value: "$86.3M",  delta: "4.37%", direction: "up"   },
        { label: "Stress Coverage",     value: "312%",    delta: "0.6 pt", direction: "down" },
        { label: "Active Reserves",     value: "47",      delta: "2",      direction: "up"   },
        { label: "MM Spread (med)",     value: "12.4 bp", delta: "1.8 bp", direction: "down" },
      ]} />

      <div className="db-grid" style={{ padding: "16px 16px 0" }}>
        <Widget title="TVL — Solstice USX" icon="reserves" sub="last 60d" colSpan={8}
          controls={<FilterSelect label="Granularity" value="daily" options={["daily", "hourly"]} />}>
          <AreaChart series={[
            { name: "TVL", seed: 11, start: 348_000_000, vol: 0.008, drift: 0.001 },
          ]} height={240} yFormat="$~s" />
        </Widget>

        <Widget title="Protocol Exposure" icon="liquidity" colSpan={4}>
          <DonutChart segments={[
            { label: "Kamino",    value: 142 },
            { label: "Orca",      value: 96  },
            { label: "Exponent",  value: 51  },
            { label: "Drift",     value: 32  },
            { label: "Other",     value: 18  },
          ]} height={240} />
        </Widget>

        <Widget title="Swap Distribution" icon="chart" colSpan={6}
          controls={<FilterSelect label="Pool" value="USX/USDC" options={["USX/USDC", "USX/USDT", "USX/SOL"]} />}>
          <BarChart
            categories={["0-1 bp", "1-3 bp", "3-5 bp", "5-10 bp", "10-20 bp", ">20 bp"]}
            values={[128, 212, 186, 94, 48, 21]}
            color="#FF6B00"
            height={220}
          />
        </Widget>

        <Widget title="Market-Maker Performance" icon="incidents" colSpan={6}
          controls={
            <React.Fragment>
              <FilterSelect label="Venue" value="Orca" options={["Orca", "Raydium", "Drift"]} />
              <FilterSelect label="Window" value="7d" options={["7d", "30d", "90d"]} />
            </React.Fragment>
          }>
          <LineChart series={[
            { name: "MM-1 uptime",    seed: 21, start: 98.6, vol: 0.005, drift: -0.0002 },
            { name: "MM-2 uptime",    seed: 22, start: 96.4, vol: 0.008, drift: -0.0003 },
            { name: "Target (99%)",   seed: 33, start: 99,   vol: 0,     drift: 0 },
          ]} height={220} />
        </Widget>
      </div>

      <div style={{ padding: "16px" }}>
        <Widget title="Recent Activity — Top Counterparties" icon="overview">
          <DataTable
            columns={[
              { key: "ts",     label: "Timestamp" },
              { key: "venue",  label: "Venue" },
              { key: "pair",   label: "Pair" },
              { key: "size",   label: "Size (USD)", num: true, render: v => `$${v.toLocaleString()}` },
              { key: "impact", label: "Impact",     num: true, render: v => <Delta value={v} /> },
              { key: "cp",     label: "Counterparty", render: v => <a href="#" className="db-table-link">{v}</a> },
              { key: "status", label: "Status", render: v =>
                <span className={`db-tag ${v === "filled" ? "up" : v === "partial" ? "warn" : "down"}`}>{v}</span>
              },
            ]}
            rows={[
              { ts: "14:02:11", venue: "Orca",     pair: "USX/USDC", size: 428_000, impact: -0.04, cp: "4xQn…r2hP", status: "filled"  },
              { ts: "14:01:46", venue: "Raydium",  pair: "USX/SOL",  size: 112_500, impact: -0.21, cp: "7Kg8…aVbw", status: "filled"  },
              { ts: "14:01:03", venue: "Drift",    pair: "USX-PERP", size: 2_100_000, impact: 0.18, cp: "MM-Lab-1",   status: "partial" },
              { ts: "13:58:22", venue: "Exponent", pair: "USX/USDT", size: 87_400,  impact: 0.02, cp: "9xAa…Mp4t", status: "filled"  },
              { ts: "13:57:01", venue: "Orca",     pair: "USX/USDC", size: 350_000, impact: -0.09, cp: "MM-Lab-2",   status: "filled"  },
              { ts: "13:54:48", venue: "Kamino",   pair: "jitoSOL/SOL", size: 44_200, impact: -0.33, cp: "2vBc…Rz7K", status: "failed"  },
            ]}
          />
        </Widget>
      </div>
    </React.Fragment>
  );
}

/* ────────────────── Liquidity ────────────────── */
function LiquidityView() {
  return (
    <React.Fragment>
      <MetricStrip metrics={[
        { label: "Active DEX Venues",    value: "12" },
        { label: "Cumulative Depth ±2%", value: "$18.4M", delta: "3.1%", direction: "down" },
        { label: "Concentration (HHI)",  value: "0.47",   delta: "0.03", direction: "up" },
        { label: "Top-1 Venue Share",    value: "42%",    delta: "1.6 pt", direction: "up" },
      ]} />
      <div className="db-grid" style={{ padding: "16px 16px 0" }}>
        <Widget title="Depth at ±2% over Time" icon="liquidity" colSpan={8}>
          <StackedAreaChart series={[
            { name: "Orca",     seed: 42, start: 6.2e6, vol: 0.02 },
            { name: "Raydium",  seed: 43, start: 4.8e6, vol: 0.02 },
            { name: "Drift",    seed: 44, start: 3.4e6, vol: 0.02 },
            { name: "Exponent", seed: 45, start: 2.1e6, vol: 0.02 },
            { name: "Other",    seed: 46, start: 1.9e6, vol: 0.02 },
          ]} height={260} />
        </Widget>

        <Widget title="Venue Share" icon="chart" colSpan={4}>
          <DonutChart segments={[
            { label: "Orca",     value: 42 },
            { label: "Raydium",  value: 22 },
            { label: "Drift",    value: 14 },
            { label: "Exponent", value: 11 },
            { label: "Other",    value: 11 },
          ]} height={260} />
        </Widget>

        <Widget title="Price Impact Curve — USX/USDC" icon="chart" colSpan={12}>
          <BarChart
            categories={["$50k", "$100k", "$250k", "$500k", "$1M", "$2.5M", "$5M"]}
            values={[0.02, 0.04, 0.11, 0.24, 0.52, 1.38, 3.12]}
            height={220}
          />
        </Widget>
      </div>
    </React.Fragment>
  );
}

/* ────────────────── Reserves / Yields ────────────────── */
function ReservesView() {
  return (
    <React.Fragment>
      <MetricStrip metrics={[
        { label: "Reserve Assets",      value: "$352.6M", delta: "0.8%", direction: "up" },
        { label: "Utilization (avg)",   value: "68%",     delta: "2.3 pt", direction: "down" },
        { label: "Weighted Health Factor", value: "1.82", delta: "0.04", direction: "up" },
        { label: "Collateral Ratio",    value: "168%" },
      ]} />
      <div className="db-grid" style={{ padding: "16px 16px 0" }}>
        <Widget title="Reserves by Protocol" icon="reserves" colSpan={7}>
          <StackedAreaChart series={[
            { name: "Kamino",    seed: 51, start: 142e6 },
            { name: "Drift",     seed: 52, start: 52e6  },
            { name: "MarginFi",  seed: 53, start: 38e6  },
          ]} height={240} />
        </Widget>

        <Widget title="Supply / Borrow — Kamino" icon="yields" colSpan={5}>
          <DataTable
            columns={[
              { key: "asset",   label: "Asset" },
              { key: "supply",  label: "Supply APY", num: true, render: v => `${v.toFixed(2)}%` },
              { key: "borrow",  label: "Borrow APY", num: true, render: v => `${v.toFixed(2)}%` },
              { key: "util",    label: "Util",       num: true, render: v => `${v}%` },
            ]}
            rows={[
              { asset: "USDC",     supply: 5.42, borrow: 7.18, util: 76 },
              { asset: "USDT",     supply: 4.87, borrow: 6.92, util: 71 },
              { asset: "SOL",      supply: 3.11, borrow: 5.40, util: 58 },
              { asset: "jitoSOL",  supply: 2.86, borrow: 4.72, util: 44 },
              { asset: "mSOL",     supply: 2.92, borrow: 4.84, util: 48 },
              { asset: "USX",      supply: 6.04, borrow: 8.31, util: 82 },
            ]}
          />
        </Widget>

        <Widget title="Exponent Yield Curve (PT)" icon="yields" colSpan={12}>
          <LineChart series={[
            { name: "7d",   seed: 61, start: 4.2, vol: 0.01 },
            { name: "30d",  seed: 62, start: 5.8, vol: 0.008 },
            { name: "90d",  seed: 63, start: 6.9, vol: 0.006 },
          ]} height={240} />
        </Widget>
      </div>
    </React.Fragment>
  );
}

/* ────────────────── Risk ────────────────── */
function RiskView() {
  return (
    <React.Fragment>
      <MetricStrip metrics={[
        { label: "VaR (99%, 1d)",  value: "$4.8M"  },
        { label: "Stress Scenario",value: "−42% SOL" },
        { label: "Reserve Coverage", value: "312%" },
        { label: "Open Alerts",    value: "3",  delta: "1 new", direction: "up" },
      ]} />

      <div className="db-grid" style={{ padding: "16px 16px 0" }}>
        <Widget title="Stress Test — Reserve Coverage" icon="stress" colSpan={7}
          controls={
            <React.Fragment>
              <FilterSelect label="Collateral" value="SOL" options={["SOL", "ETH", "BTC"]} />
              <FilterSelect label="Shock" value="-40%" options={["-20%", "-40%", "-60%"]} />
            </React.Fragment>
          }>
          <LineChart series={[
            { name: "Coverage %",  seed: 71, start: 312, vol: 0.015 },
            { name: "Threshold",   seed: 72, start: 150, vol: 0 },
          ]} height={260} />
        </Widget>

        <Widget title="DEX Downside (Tail)" icon="risk" colSpan={5}>
          <BarChart
            horizontal
            categories={["Orca", "Raydium", "Drift", "Exponent", "Kamino", "Other"]}
            values={[-3.2, -2.7, -4.1, -1.8, -0.9, -0.4]}
            color="#F65F74"
            height={260}
          />
        </Widget>

        <Widget title="Open Risk Events" icon="incidents" colSpan={12}>
          <DataTable
            columns={[
              { key: "id",      label: "Event" },
              { key: "opened",  label: "Opened" },
              { key: "scope",   label: "Scope" },
              { key: "trigger", label: "Trigger" },
              { key: "severity",label: "Severity", render: v =>
                <span className={`db-tag ${v === "high" ? "down" : v === "med" ? "warn" : "up"}`}>{v}</span>
              },
              { key: "owner",   label: "Owner" },
              { key: "state",   label: "State" },
            ]}
            rows={[
              { id: "RE-2042", opened: "12m ago", scope: "Kamino / SOL reserve", trigger: "Util > 92%",         severity: "med",  owner: "R. McKinley",  state: "investigating" },
              { id: "RE-2041", opened: "38m ago", scope: "Orca USX/USDC",        trigger: "Depth −31% (5min)",  severity: "high", owner: "R. McKinley",  state: "triage" },
              { id: "RE-2039", opened: "3h ago",  scope: "Drift USX-PERP",       trigger: "Funding > +65 bp",   severity: "low",  owner: "R. McKinley",  state: "monitoring" },
            ]}
          />
        </Widget>
      </div>
    </React.Fragment>
  );
}

Object.assign(window, { OverviewView, LiquidityView, ReservesView, RiskView });

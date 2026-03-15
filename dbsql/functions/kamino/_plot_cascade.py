"""Cascade chart v11 – bonus-aware per-pool price impact panels."""
import psycopg2
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

conn = psycopg2.connect(
    host="fd3cdmjulb.p56ar8nomm.tsdb.cloud.timescale.com",
    port=33971, dbname="tsdb", user="tsdbadmin",
    password="ner5q1iamtwzkmmd", sslmode="require",
)
cur = conn.cursor()
cur.execute("""
    SELECT initial_shock_pct, equilibrium_shock_pct,
           total_liquidated_usd, induced_coll_decline_pct,
           debt_triggered_liq_usd, cascade_triggered_liq_usd,
           sell_qty_tokens, pool_depth_used_pct, liq_pct_of_deposits,
           pool_address, pool_weight, counter_pair_symbol,
           pool_impact_pct,
           effective_bonus_bps,
           liq_value_pre_bonus_usd,
           liq_value_post_bonus_usd
    FROM kamino_lend.simulate_cascade_amplification(
        NULL, -100, 50, 100, 50, FALSE,
        ARRAY['ONyc'], NULL, 'ONyc', 'weighted', 'blended'
    )
    ORDER BY initial_shock_pct, pool_address
""")
rows = cur.fetchall()
cur.close()
conn.close()

pools = sorted(set(r[9] for r in rows))
pool_labels = {}
pool_weights_map = {}
for r in rows:
    pool_labels[r[9]] = f"ONyc / {r[11]}"
    pool_weights_map[r[9]] = float(r[10])

P = {}
for pa in pools:
    pr = [r for r in rows if r[9] == pa]
    P[pa] = {
        'init':   [float(r[0]) for r in pr],
        'eq':     [float(r[1]) for r in pr],
        'liq':    [float(r[2]) for r in pr],
        'cd':     [float(r[3]) for r in pr],
        'dliq':   [float(r[4]) for r in pr],
        'cliq':   [float(r[5]) for r in pr],
        'qty':    [float(r[6]) for r in pr],
        'pool':   [float(r[7] or 0) for r in pr],
        'dep':    [float(r[8] or 0) for r in pr],
        'pimpact': [float(r[12] or 0) for r in pr],
        'bonus':  [float(r[13] or 0) for r in pr],
        'pre_b':  [float(r[14] or 0) for r in pr],
        'post_b': [float(r[15] or 0) for r in pr],
    }

ref_pool = pools[0]
D = P[ref_pool]
all_x = D['init']
li = [i for i, x in enumerate(all_x) if x <= 0]
ri = [i for i, x in enumerate(all_x) if x > 0]
lx = [all_x[i] for i in li]
rx = [all_x[i] for i in ri]

BG = '#1a1a2e'
CELL = '#16213e'
GRID = '#666688'
SPINE = '#444466'
TXT = '#cccccc'
CASCADE_COL = '#5599dd'
EXOG_COL = '#6677aa'
DECLINE_COL = '#e05555'
POOL_COLORS = ['#ff6b6b', '#ffbb55']

n_pools = len(pools)
n_panels = 1 + n_pools
fig, axes = plt.subplots(n_panels, 1, figsize=(13, 3.5 * n_panels),
    gridspec_kw={'height_ratios': [1] * n_panels}, sharex=True)
fig.patch.set_facecolor(BG)

def style_ax(ax, ylabel, ycolor=TXT):
    ax.set_facecolor(CELL)
    ax.set_ylabel(ylabel, color=ycolor, fontsize=9)
    ax.tick_params(colors='#999999')
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)
    ax.spines['bottom'].set_color(SPINE)
    ax.spines['left'].set_color(SPINE)
    ax.grid(True, alpha=0.12, color=GRID)
    ax.axvline(x=0, color='#555577', linewidth=1, linestyle='--', alpha=0.5)

# ═══════════════════════════════════════════════════════════
#  PANEL 1: Liquidated Value + per-pool depth
# ═══════════════════════════════════════════════════════════
ax1 = axes[0]
style_ax(ax1, 'Liquidated Value ($M)', '#e8a838')
ax1.spines['left'].set_color('#e8a838')
ax1.tick_params(axis='y', colors='#e8a838')

all_liq = [v / 1e6 for v in D['liq']]

base = []
for i in range(len(all_x)):
    if all_x[i] <= 0:
        base.append(all_liq[i])
    else:
        base.append(D['dliq'][i] / 1e6)

casc_top = []
for i in range(len(all_x)):
    if all_x[i] <= 0:
        casc_top.append(all_liq[i])
    else:
        casc_top.append(base[i] + D['cliq'][i] / 1e6)

post_bonus_top = [D['post_b'][i] / 1e6 for i in range(len(all_x))]

ax1.fill_between(all_x, 0, base, alpha=0.25, color='#e8a838',
                 label='Liquidated value (debt-side, $M)')
ax1.fill_between(all_x, base, casc_top, alpha=0.45, color=CASCADE_COL,
                 label='Cascade add\'l ($M)')
ax1.fill_between(all_x, casc_top, post_bonus_top, alpha=0.20, color='#44cc88',
                 label='Bonus gross-up ($M)')
ax1.plot(all_x, casc_top, '-', color='#e8a838', linewidth=1.5, alpha=0.8)
ax1.plot(all_x, post_bonus_top, '-', color='#44cc88', linewidth=1.0, alpha=0.6)

ax1r = ax1.twinx()
for pidx, pa in enumerate(pools):
    col = POOL_COLORS[pidx % len(POOL_COLORS)]
    ax1r.plot(all_x, P[pa]['pool'], '-', color=col, linewidth=1.2, alpha=0.6,
              label=f'Depth: {pool_labels[pa]} ({pool_weights_map[pa]*100:.0f}%)')
ax1r.axhline(y=100, color='white', linewidth=1.2, linestyle=':', alpha=0.35)

ax1r.set_ylabel('Pool Depth Used (%)', color=TXT, fontsize=8)
ax1r.tick_params(axis='y', colors='#999999', labelsize=7)
ax1r.spines['right'].set_color(SPINE)
ax1r.spines['top'].set_visible(False)

ax1.set_title('Liquidation Cascade Analysis  —  ONyc  (weighted multi-pool, bonus: blended)',
              color='white', fontsize=11, fontweight='bold', pad=10)
ax1.text(-25, max(all_liq) * 0.88, r'$\leftarrow$ Collateral Decrease',
         color=EXOG_COL, fontsize=7.5, ha='center', alpha=0.7)
ax1.text(25, max(all_liq) * 0.88, r'Debt Increase $\rightarrow$',
         color='#e05555', fontsize=7.5, ha='center', alpha=0.7)

h1, l1 = ax1.get_legend_handles_labels()
h1r, l1r = ax1r.get_legend_handles_labels()
ax1.legend(h1 + h1r, l1 + l1r, loc='upper left', fontsize=6.5,
           facecolor=BG, edgecolor=SPINE, labelcolor=TXT, ncol=2)

# ═══════════════════════════════════════════════════════════
#  PANELS 2..N: Per-pool Collateral Price Impact
# ═══════════════════════════════════════════════════════════
max_impact_all = 0
for pa in pools:
    pdata = P[pa]
    left_eq = [-pdata['eq'][i] for i in li]
    left_pi = [-pdata['pimpact'][i] for i in li]
    right_pi = [-pdata['pimpact'][i] for i in ri]
    cands = left_eq + left_pi + right_pi
    if cands:
        max_impact_all = max(max_impact_all, max(cands))

ylim = max_impact_all + 5

for pidx, pa in enumerate(pools):
    ax = axes[1 + pidx]
    col = POOL_COLORS[pidx % len(POOL_COLORS)]
    pdata = P[pa]
    lbl = pool_labels[pa]
    wt = pool_weights_map[pa]

    style_ax(ax, f'Price Impact: {lbl} ({wt*100:.0f}%)', col)
    ax.spines['left'].set_color(col)
    ax.tick_params(axis='y', colors=col)

    # Left side: per-pool impact
    left_pi = [-pdata['pimpact'][i] for i in li]
    neg_init = [-all_x[i] for i in li]

    ax.plot(lx, neg_init, ':', color='#888899', linewidth=1.2, alpha=0.6,
            label='No-cascade ref.')
    ax.fill_between(lx, 0, neg_init, alpha=0.10, color=col)
    ax.fill_between(lx, neg_init, [ni + pi for ni, pi in zip(neg_init, left_pi)],
                    alpha=0.40, color=col, label='Cascade addition')
    left_total = [ni + pi for ni, pi in zip(neg_init, left_pi)]
    ax.plot(lx, left_total, '-', color=col, linewidth=2,
            label='Total impact (left)')

    # Right side: per-pool induced impact
    right_pi = [-pdata['pimpact'][i] for i in ri]
    ax.fill_between(rx, 0, right_pi, alpha=0.25, color=col)
    ax.plot(rx, right_pi, '-', color=col, linewidth=2,
            label='Induced impact (right)')

    # Annotations at key points
    for s in [-50, -30]:
        idx = next((i for i, v in enumerate(all_x) if abs(v - s) < 0.6), None)
        if idx is not None and abs(pdata['pimpact'][idx]) > 0.01:
            total_val = -pdata['eq'][idx] if all_x[idx] <= 0 else -pdata['pimpact'][idx]
            pi_val = pdata['pimpact'][idx]
            if all_x[idx] <= 0:
                total_val = neg_init[li.index(idx)] + (-pi_val)
            ax.annotate(f'{pi_val:.2f}%',
                xy=(all_x[idx], -pi_val + neg_init[li.index(idx)] if idx in li else -pi_val),
                xytext=(all_x[idx] + 4, (-pi_val + neg_init[li.index(idx)] if idx in li else -pi_val) + 2),
                fontsize=7, color=col, fontweight='bold',
                arrowprops=dict(arrowstyle='->', color=col, lw=0.7))

    for s in [30, 50]:
        idx = next((i for i, v in enumerate(all_x) if abs(v - s) < 0.6), None)
        if idx is not None and abs(pdata['pimpact'][idx]) > 0.01:
            pi_val = pdata['pimpact'][idx]
            ax.annotate(f'{pi_val:.2f}%',
                xy=(all_x[idx], -pi_val),
                xytext=(all_x[idx] - 5, -pi_val + 1.5),
                fontsize=7, color=col, fontweight='bold',
                arrowprops=dict(arrowstyle='->', color=col, lw=0.7))

    ax.set_ylim(0, ylim)
    ax.legend(loc='upper left', fontsize=6.5,
              facecolor=BG, edgecolor=SPINE, labelcolor=TXT, ncol=4)

    # Pool exhaustion vertical lines on this panel
    pool_d = pdata['pool']
    for i in range(len(all_x) - 1):
        crosses_up = pool_d[i] < 100 and pool_d[i+1] >= 100
        crosses_dn = pool_d[i] >= 100 and pool_d[i+1] < 100
        if crosses_up or crosses_dn:
            denom = pool_d[i+1] - pool_d[i]
            if abs(denom) > 1e-6:
                frac = (100 - pool_d[i]) / denom
                ex = all_x[i] + frac * (all_x[i+1] - all_x[i])
                ax.axvline(x=ex, color=col, linewidth=1.2, linestyle='--', alpha=0.55)
                ax1.axvline(x=ex, color=col, linewidth=1.2, linestyle='--', alpha=0.55)
                ax.text(ex, ylim * 0.95, f'{ex:.0f}%', color=col,
                        fontsize=6.5, ha='center', va='top', fontweight='bold', alpha=0.8)

axes[-1].set_xlabel('Price Change (%)', color=TXT, fontsize=9)

fig.tight_layout(pad=1.5)
out = r'd:\dev\mano\risk_dash\pfx\dbsql\functions\kamino\cascade_amplification_chart.png'
fig.savefig(out, dpi=150, bbox_inches='tight', facecolor=fig.get_facecolor())
print(f'Saved: {out}')
plt.close()

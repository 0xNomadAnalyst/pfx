"""Cascade chart v8 – blue cascade, red price decline, equal panels."""
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
           sell_qty_tokens, pool_depth_used_pct, liq_pct_of_deposits
    FROM kamino_lend.simulate_cascade_amplification(
        NULL, -100, 50, 100, 50, FALSE,
        ARRAY['ONyc'], NULL, 'ONyc'
    )
    ORDER BY initial_shock_pct
""")
rows = cur.fetchall()
cur.close()
conn.close()

D = {
    'init': [float(r[0]) for r in rows],
    'eq':   [float(r[1]) for r in rows],
    'liq':  [float(r[2]) for r in rows],
    'cd':   [float(r[3]) for r in rows],
    'dliq': [float(r[4]) for r in rows],
    'cliq': [float(r[5]) for r in rows],
    'qty':  [float(r[6]) for r in rows],
    'pool': [float(r[7] or 0) for r in rows],
    'dep':  [float(r[8] or 0) for r in rows],
}

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

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(13, 8.5),
    gridspec_kw={'height_ratios': [1, 1]}, sharex=True)
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
#  PANEL 1: Liquidated Value + pool depth
# ═══════════════════════════════════════════════════════════
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

ax1.fill_between(all_x, 0, base, alpha=0.25, color='#e8a838',
                 label='Liquidated value ($M)')
ax1.fill_between(all_x, base, casc_top, alpha=0.45, color=CASCADE_COL,
                 label='Cascade add\'l ($M)')
ax1.plot(all_x, casc_top, '-', color='#e8a838', linewidth=1.5, alpha=0.8)

ax1r = ax1.twinx()
ax1r.plot(all_x, D['pool'], '-', color='#ff6b6b', linewidth=1.2, alpha=0.6,
          label='Pool depth used (%)')
ax1r.axhline(y=100, color='#ff6b6b', linewidth=1.2, linestyle=':', alpha=0.5)
ax1r.set_ylabel('Pool Depth Used (%)', color='#ff6b6b', fontsize=8)
ax1r.tick_params(axis='y', colors='#ff6b6b', labelsize=7)
ax1r.spines['right'].set_color('#ff6b6b')
ax1r.spines['top'].set_visible(False)

ax1.set_title('Liquidation Cascade Analysis  —  ONyc',
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
#  PANEL 2: Collateral Price Decline (%) – red tones
# ═══════════════════════════════════════════════════════════
style_ax(ax2, 'Collateral Price Decline (%)')

neg_init = [-all_x[i] for i in li]

ax2.plot(lx, neg_init, ':', color='#888899', linewidth=1.2, alpha=0.6,
         label='No-cascade reference')

neg_casc = [-D['cd'][i] for i in li]
ax2.fill_between(lx, 0, neg_init, alpha=0.15, color=DECLINE_COL,
                 label='Exogenous shock')
ax2.fill_between(lx, neg_init,
                 [ni + nc for ni, nc in zip(neg_init, neg_casc)],
                 alpha=0.45, color=DECLINE_COL, label='Cascade addition')
ax2.plot(lx, [-D['eq'][i] for i in li], '-', color=DECLINE_COL, linewidth=2,
         label='Total coll. decline (left)')

right_cd = [-D['cd'][i] for i in ri]
ax2.fill_between(rx, 0, right_cd, alpha=0.3, color=DECLINE_COL)
ax2.plot(rx, right_cd, '-', color=DECLINE_COL, linewidth=2,
         label='Induced coll. decline (right)')

for s in [-50, -30, -15]:
    idx = next((i for i, v in enumerate(all_x) if abs(v - s) < 0.6), None)
    if idx and abs(D['eq'][idx]) > 0.5:
        ax2.annotate(f'{D["eq"][idx]:.1f}%',
            xy=(all_x[idx], -D['eq'][idx]),
            xytext=(all_x[idx] + 4, -D['eq'][idx] + 2),
            fontsize=7, color=DECLINE_COL, fontweight='bold',
            arrowprops=dict(arrowstyle='->', color=DECLINE_COL, lw=0.7))

for s in [20, 40]:
    idx = next((i for i, v in enumerate(all_x) if abs(v - s) < 0.6), None)
    if idx and abs(D['cd'][idx]) > 0.01:
        ax2.annotate(f'{D["cd"][idx]:.2f}%',
            xy=(all_x[idx], -D['cd'][idx]),
            xytext=(all_x[idx] - 4, -D['cd'][idx] + 1.5),
            fontsize=7, color=DECLINE_COL, fontweight='bold',
            arrowprops=dict(arrowstyle='->', color=DECLINE_COL, lw=0.7))

ylim = max(-min(D['eq']), max(-v for v in D['cd'])) + 5
ax2.set_ylim(0, ylim)
ax2.set_xlabel('Price Change (%)', color=TXT, fontsize=9)

ax2.legend(loc='upper left', fontsize=6.5,
           facecolor=BG, edgecolor=SPINE, labelcolor=TXT, ncol=3)

# ═══════════════════════════════════════════════════════════
#  Pool exhaustion vertical reference lines (both panels)
# ═══════════════════════════════════════════════════════════
exhaust_xs = []
for i in range(len(all_x) - 1):
    crosses_up = D['pool'][i] < 100 and D['pool'][i+1] >= 100
    crosses_dn = D['pool'][i] >= 100 and D['pool'][i+1] < 100
    if crosses_up or crosses_dn:
        frac = (100 - D['pool'][i]) / (D['pool'][i+1] - D['pool'][i])
        exhaust_xs.append(all_x[i] + frac * (all_x[i+1] - all_x[i]))

for ex in exhaust_xs:
    for ax in [ax1, ax2]:
        ax.axvline(x=ex, color='#ff6b6b', linewidth=1.2, linestyle='--', alpha=0.55)
    ax1.text(ex, max(all_liq) * 0.02, f'{ex:.0f}%', color='#ff6b6b',
             fontsize=7, ha='center', va='bottom', fontweight='bold', alpha=0.8)

fig.tight_layout(pad=1.5)
out = r'd:\dev\mano\risk_dash\pfx\dbsql\functions\kamino\cascade_amplification_chart.png'
fig.savefig(out, dpi=150, bbox_inches='tight', facecolor=fig.get_facecolor())
print(f'Saved: {out}')
plt.close()

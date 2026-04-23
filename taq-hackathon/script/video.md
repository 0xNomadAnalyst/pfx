# Demo Video Script

**Target length:** ~6 minutes. Cap at 7. The app is thin; the thesis does
the heavy lifting.

**Audience:** TAQ voters — accountants, controllers, fractional CFOs,
finance operators moving into Web3. Domain-fluent in finance, partially
fluent in onchain mechanics, largely non-technical. Translate before
showing.

**Tone:** calm, matter-of-fact, slightly understated. The work speaks for
itself; the script shouldn't oversell it.

---

## 1. Intro — what this is (≈ 40s)

> What I'm showing today is a small app that does one thing: it produces
> a short daily brief summarising what materially changed over the last
> 24 hours across a DeFi project's footprint — its liquidity pools, its
> lending markets, its yield markets — and delivers that brief to your
> Slack.
>
> It's aimed at teams whose token or treasury is deployed across several
> onchain protocols at once, where watching each venue individually
> stops being practical.

*[On screen: homepage of the app — the daily brief header, the
"subscribe to Slack" box, and the index of past briefs visible below.]*

---

## 2. Why this exists (≈ 60s)

> The context here is straightforward. Institutional adoption of DeFi
> keeps growing, and with it the number of protocols any given project
> interacts with. A single token can sit in multiple DEX pools, be
> supplied and borrowed across lending markets, and trade on yield
> markets — all at the same time, all moving on different clocks.
>
> You can build an operational dashboard that captures all of that, and
> a lot of teams do. But dashboards have a limit. They're great when you
> already know what you're looking for. They're overwhelming when you
> don't — when the interesting event today isn't the one you pinned to
> the top of the page last quarter.
>
> So the idea here is narrow: surface the small number of things that
> actually shifted today, have an agent write a first-pass
> interpretation of those shifts, and put that interpretation somewhere
> a finance or treasury team already looks — Slack — rather than behind
> yet another login.

---

## 3. Walkthrough (≈ 90s)

*[Land on homepage.]*

> The homepage is a running log. Every day a brief is generated and
> filed here. Clicking into any day opens the detail view for that
> date.

*[Click into today's brief: 2026-04-23.]*

> At the top is the analysis section — this is the LLM's read of the
> day. In this case it's flagging three things: an extreme sell event
> on one of the DEX pools that exceeded the 99th-percentile baseline,
> a meaningful easing on the lending side with utilisation and borrow
> rates both dropping, and a large rotation of token supply between
> venues.
>
> Beneath the analysis are the specific underlying events the agent was
> shown when it wrote that summary — grouped by domain: ecosystem-level
> shifts, DEX events, lending events, yield events. Each item carries
> the raw numbers, so the summary above is auditable against what
> triggered it.

*[Hover over "full dashboard" link on one of the section headers.]*

> If any of these events warrant a deeper look, the section headers
> link through to the full protocol dashboard — the risk platform this
> app sits on top of — where an analyst can drill in properly.

*[Back to top. Click "Subscribe" button.]*

> Subscriptions to the Slack digest are managed here. Pick a channel,
> confirm, done. From that point forward the daily brief posts itself.

---

## 4. Seeing the brief land in Slack (≈ 60s)

> I've already subscribed my own Slack to this, so let me show you what
> that actually looks like in practice. The brief normally goes out
> once a day on a schedule, but for the purposes of this demo I can
> trigger it on demand.

*[Cut to Slack, channel open. No new message.]*

> Here's the channel. Nothing in it yet today.

*[Cut to Railway dashboard, the cronjob service page visible.]*

> The app is hosted on Railway. The daily brief is a scheduled cron
> job — it's what wakes up once a day, pulls the day's events from the
> database, runs them through the LLM, writes the brief, and posts it
> to any subscribed channel. Railway exposes a "run now" on the job,
> which is what I'll use here.

*[Click "Run now" on the cronjob.]*

> That kicks it off.

*[Cut back to Slack. A new message from the bot appears in the
channel.]*

> And there's the message. Same brief that's on the web page, formatted
> for Slack — summary up top, the specific events underneath, a link
> back to the full view on the web if someone wants to dig in.

---

## 5. How it was put together (≈ 90s)

> Now — the part I actually want to spend a minute on.
>
> This app did not take much prompting to build. I used Claude's design
> tool to scrape my existing website and derive a design system from
> it, so the visual language was a given. For the rest, the coding
> agent was pointed at the database — not just the tables, but the
> rich context embedded alongside the schema — and asked to build.
>
> The thing I want to drive home is this: **once a company has a
> well-structured database, and a rich context layer sitting on top of
> it, building custom data apps like this one really does become
> simple.** That's the emerging shift.
>
> But there are two bottlenecks, and they're the part nobody talks
> about enough.
>
> **The first is coming up with a well-structured database in the first
> place.** That's a well-established data engineering concern in any
> industry. Blockchain businesses have a particularly acute version of
> it, because raw onchain data is extremely low-level — Borsh-encoded
> struct bytes, balance deltas you have to reconstruct fees from,
> timestamps in block-time rather than wall-time. A lot of analytics
> engineering has to happen before that data can support the kind of
> higher-level questions a finance team actually asks.
>
> **The second is figuring out how to add context that AI can
> leverage.** A simple version of this is just adding comments to your
> SQL DDL — every table and column annotated with its source, units,
> scaling, and processing rules. More and more, we're also seeing
> databases that let you embed that context directly in the columns
> themselves, so it travels with the data.
>
> Without those two things in place, an app like this one takes months.
> With them, it takes days.

---

## 6. Close (≈ 15s)

> That's the demo. If you're working on something where cross-protocol
> monitoring, onchain accounting, or the data layer underneath either
> of those is a live problem, I'd be glad to talk. Contact details are
> on the landing page. Thanks for watching.

---

## Visual / capture notes

- Record at a resolution where the brief text is legible — the agent's
  analysis block is the centrepiece; viewers need to be able to read
  it.
- Keep the cursor slow. A beat on the analysis section lets the viewer
  see the LLM output is substantive, not a one-liner.
- The click-through to the full protocol dashboard: show the
  destination briefly (2–3 seconds), then cut back. Don't tour it —
  the point is that the depth exists, not that we're exploring it
  here.
- Don't narrate the Slack subscription flow past the first dialog. The
  point is that it's there, not how it works.
- For the Slack demo: have the Slack channel and Railway dashboard
  already open in separate tabs or windows before recording — the cut
  between them should be near-instant. Dead air while something loads
  kills the bit.
- On Railway, zoom / crop so only the cronjob row and the "run now"
  control are visible. The rest of the dashboard is a distraction and
  invites questions the demo isn't trying to answer.
- Budget ~10–15 seconds between hitting "run now" and the Slack
  message appearing. If the job runs slower than that in practice,
  edit the silence out in post rather than narrating through it.
- Do not show the database, SQL, or any code. The thesis lands harder
  if the substrate is alluded to rather than displayed.

## Things to avoid saying

- "Built from scratch in a week." Untrue and off-thesis. The app was,
  the substrate beneath it wasn't.
- "Production-grade" / "enterprise-ready" about the hackathon app
  itself. Claim it for the database it queries, not the app.
- Solana-native jargon as primary voice: "CLMM," "tick array,"
  "obligation health factor." Either translate or skip.
- Specific client names.

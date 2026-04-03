suppose I can pull data from :

exponent api
kamino api
raydium & orca apis

(unsure what yet - but this seems like a start for creating a systematic list, noting their total tvl and volume)

subsequent agent/research could then fill in the picture with web search...

---

Yes — that is a good start, and more importantly it is the right **directional logic**.

What you want is a cold list generated from **market structure evidence**, not just from names you happen to know. Those APIs can help you build exactly that: a first-pass map of which tokens and protocols have enough onchain footprint to plausibly need better monitoring, risk visibility, or market-structure analysis.

The key is not just “collect TVL and volume.” It is to turn that into a **prospect-ranking system**.

A useful way to think about it:

## 1. Use the APIs to build the raw candidate universe

From Exponent, Kamino, Raydium, and Orca, you can start extracting things like:

- token / asset name

- symbol

- protocol presence

- pool / market / vault identifiers

- TVL

- recent volume

- yield metrics where relevant

- number of venues the asset appears in

- type of exposure: spot liquidity, lending collateral, borrow market, yield tokenization, etc.

That gives you a first-pass universe of assets / ecosystems with visible footprint.

This is already much better than building a cold list from Twitter vibes.

## 2. Don’t rank by TVL alone

TVL and volume are useful, but they are not enough by themselves.

The better prospecting question is:  
**which assets / teams have a footprint that is both economically meaningful and operationally complex?**

So beyond raw TVL/volume, I would derive signals like:

- **Cross-venue presence**  
  Appears on multiple DEXes and/or lending/yield venues.

- **Cross-domain complexity**  
  Not just in one pool, but across DEX + lending + yield structure.

- **Liquidity relevance**  
  Enough DEX depth / activity that market structure actually matters.

- **Risk relevance**  
  Presence in lending or structured yield venues where downside pathways become more important.

- **Monitoring relevance**  
  Footprint broad enough that a team might struggle to observe it with standard public tools alone.

That is much closer to your actual value proposition.

## 3. Build the list around “ecosystems,” not just tokens

A token is often the visible anchor, but the real prospect is usually:

- the foundation

- the protocol team

- treasury / ecosystem / BD lead

- issuer

- growth or strategy lead

So your data pipeline can identify **candidate ecosystems**, and then later research maps each ecosystem to:

- operating entity

- decision-makers

- likely use case

- likely budget relevance

- recent context

That two-stage process is strong:

- **Stage 1:** data-driven identification

- **Stage 2:** qualitative qualification

## 4. Define a simple scoring model now

Before you pull too much data, decide how a candidate gets scored.

For example, you might score each ecosystem on:

- DEX TVL

- DEX volume

- number of active venues

- presence in Kamino

- presence in Exponent

- number of exposure types

- concentration / complexity proxy

- whether footprint resembles the kind of cross-protocol problem your demo handles well

Then combine that into something like:

- **Economic significance**

- **Structural complexity**

- **Visibility gap**

- **Commercial plausibility**

Even a rough score is enough.

Because otherwise you will end up with a spreadsheet full of data and no selection logic.

## 5. Think in terms of “fit hypotheses”

Each candidate should end up with a hypothesis like:

- “This team likely needs cross-venue liquidity visibility.”

- “This ecosystem has lending + DEX exposure, so downside/risk monitoring may be relevant.”

- “This token footprint is broad enough that internal reporting may be fragmented.”

- “This looks like a candidate for market structure / MM performance discussion.”

- “This team may be outgrowing public dashboards.”

That is the bridge between data and outreach.

Without that bridge, the list is informative but not commercially useful.

## 6. Your proposed next step is right: let research fill the picture

Once the data gives you a ranked candidate set, agent/web research can enrich it with:

- who the operating team is

- whether they have a foundation / treasury function

- whether they discuss liquidity, treasury, or market structure publicly

- recent launches, integrations, or venue expansion

- known market maker relationships

- whether they look like a serious commercial target vs. just an interesting dataset

That is exactly how I would do it.

Quantitative screening first. Qualitative research second.

## 7. A very practical output format

You probably want two linked tables.

### Table 1: ecosystem screening

Columns like:

- asset / ecosystem

- Raydium presence

- Orca presence

- Kamino presence

- Exponent presence

- DEX TVL

- DEX volume

- number of venues

- exposure types count

- rough complexity score

- rough priority score

### Table 2: commercial qualification

Then for shortlisted names:

- team / entity

- website

- likely decision-maker roles

- why they may care

- likely angle

- recent trigger / context

- fit notes

- status

That keeps the quantitative and qualitative work separate.

## 8. One caution: don’t over-index on what’s easiest to measure

Because you can pull Raydium/Orca/Kamino/Exponent data, you may end up favoring what is easy to observe rather than what is commercially best.

That is fine for a first pass, but remember:

- some good targets will not be the largest by TVL

- some will be more compelling because of complexity, not scale

- some may be better fits for MM accountability than for cross-protocol risk

- some teams with huge footprint may still be poor outreach targets if they are bureaucratic or hard to access

So use the API-driven list as a **candidate generator**, not as the final truth.

## 9. The smart first goal is not completeness

Do not try to map the entire Solana universe perfectly.

A much better first goal is:

- generate top 30–50 ecosystems by your chosen criteria

- shortlist top 15–20 after review

- deeply research top 10–15

- start outreach from there

That is enough to get moving.

## 10. The overall method is sound

In compact form, the pipeline would be:

1. Pull token / ecosystem presence from Exponent, Kamino, Raydium, Orca

2. Aggregate by asset / ecosystem

3. Compute simple signals for size and complexity

4. Rank candidates

5. Use research/web search to identify the entity, context, and likely buyer

6. Convert top-ranked names into outreach targets

That is a solid, systematic way to develop a cold list that actually reflects your offer.

The strongest part of your instinct here is that it grounds business development in **observable system footprint**. That fits your positioning unusually well.

If you want, I can help you design the exact screening columns and scoring logic for a first-pass spreadsheet.

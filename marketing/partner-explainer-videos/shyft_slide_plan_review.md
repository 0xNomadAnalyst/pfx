# Shyft Video Slide Plan (Review Version)

> Notes:
> - `Layout:` should be either `half-page` or `full-page`
> - `Script cue:` gives the opening words of the sentence this slide matches
> - `Review note:` comments intended to be stripped before Gamma generation
> - Use minimal on-slide text; keep wording close to narration

---

## Slide 1
**Layout:** half-page  
**Script cue:** “This video is sponsored by Shyft.”  
**Slide title:** Real-Time Solana Data Ingestion  
**Slide text:**
- Public risk dashboard demo
- Real-time Solana data pipeline
- Infrastructure supported by Shyft

**Review note:** Opening sponsor/title slide. Keep your talking head visible on one side.  
**Visual suggestion:** Use a clean dashboard screenshot on the slide side, with a small Shyft logo lockup if appropriate.

---

## Slide 2
**Layout:** half-page  
**Script cue:** “Let’s start with the basics.”  
**Slide title:** The Goal  
**Slide text:**
- Live dashboard
- Real-time human decision-making
- Collect event data as it occurs

**Review note:** Simple framing slide.  
**Diagram note:** None needed.

---

## Slide 3
**Layout:** half-page  
**Script cue:** “Across much of the internet, the standard way of getting data...”  
**Slide title:** Pull-Based Data Access  
**Slide text:**
- Polling / request-response
- Client asks
- Server sends data back

**Review note:** Keep this very simple.  
**Diagram note:** Simple arrow diagram: `Client -> Request -> Server -> Response -> Client`

---

## Slide 4
**Layout:** half-page  
**Script cue:** “But this approach is not ideal for real-time event ingestion.”  
**Slide title:** Why Polling Breaks Down  
**Slide text:**
- Events can occur between fetches
- More polling = more inefficiency
- Not ideal for live ingestion

**Review note:** Match the rhetorical punch of the narration.  
**Diagram note:** Timeline diagram showing polling intervals with events landing between them.

---

## Slide 5
**Layout:** half-page  
**Script cue:** “What you really want is a push-based streaming model”  
**Slide title:** Push-Based Streaming  
**Slide text:**
- Updates delivered as they occur
- No repeated fetching
- Better fit for live event data

**Review note:** This is the conceptual contrast slide.  
**Diagram note:** Timeline with continuous event stream flowing to client.

---

## Slide 6
**Layout:** half-page  
**Script cue:** “When it comes to Solana data ingestion...”  
**Slide title:** Two Push-Based Options  
**Slide text:**
- WebSocket subscriptions
- gRPC streams

**Review note:** Do not overcrowd. The narration explains the difference.  
**Diagram note:** Two-column comparison card, very lightweight.

---

## Slide 7
**Layout:** half-page  
**Script cue:** “Without getting too deep into the weeds...”  
**Slide title:** Why gRPC Helps  
**Slide text:**
- More structured
- More flexible
- Better fit for rich Solana data

**Review note:** This should feel like a clean conceptual takeaway, not a deep protocol slide.  
**Diagram note:** None needed.

---

## Slide 8
**Layout:** full-page  
**Script cue:** “The standard gRPC interface most people use...”  
**Slide title:** Yellowstone gRPC  
**Slide text:**
- Built around Solana’s Geyser plugin system
- Streams validator data in real time
- Accounts, transactions, blocks, slots

**Review note:** This is one of the few places where a fuller visual earns the space.  
**Diagram note:** Layered diagram: `Validator / Geyser -> Yellowstone gRPC -> External systems`

---

## Slide 9
**Layout:** half-page  
**Script cue:** “What this means in practice is that you can subscribe...”  
**Slide title:** Subscribe to What Matters  
**Slide text:**
- Specific program transactions
- Account updates
- Full block data when needed

**Review note:** Keep the bullet wording close to narration.  
**Diagram note:** None needed.

---

## Slide 10
**Layout:** half-page  
**Script cue:** “Key filtering happens at the source...”  
**Slide title:** Source-Side Filtering  
**Slide text:**
- Filtering before data leaves the node
- Narrow the stream
- Avoid the full Solana firehose

**Review note:** This is a strong claim slide; keep it crisp.  
**Diagram note:** Funnel graphic from large firehose -> narrower stream.

---

## Slide 11
**Layout:** half-page  
**Script cue:** “Definitely valuable... but the irony is...”  
**Slide title:** Filtering Is Not Enough  
**Slide text:**
- Raw Solana data still carries lots of extra material
- You still have to process a lot to reach the signal

**Review note:** This is the first real “twist” in the story.  
**Diagram note:** None needed.

---

## Slide 12
**Layout:** full-page  
**Script cue:** “Because even with a fast and well-filtered stream...”  
**Slide title:** Where the Real Challenge Begins  
**Slide text:**
- Raw Solana transaction data
- Highly structured
- Not analytics-ready

**Review note:** Give this slide some visual drama; it marks the shift from transport to extraction.  
**Diagram note:** Stylized transaction block exploding into nested parts: outer instructions, inner instructions, metadata.

---

## Slide 13
**Layout:** half-page  
**Script cue:** “These transactions are highly structured...”  
**Slide title:** Hidden Inside Inner Instructions  
**Slide text:**
- One user action
- Multiple program interactions
- Relevant pool / reserve interaction may be hidden

**Review note:** This is the core explanatory slide for why downstream parsing still matters.  
**Diagram note:** Nested boxes: `User action -> outer instruction -> inner instructions -> relevant account interaction`

---

## Slide 14
**Layout:** half-page  
**Script cue:** “And hidden is the key word here...”  
**Slide title:** Why Upstream Filtering Only Goes So Far  
**Slide text:**
- Hidden interactions cannot fully tighten filters upstream
- gRPC narrows the stream
- It cannot fully isolate the final signal for you

**Review note:** Important conceptual bridge slide.  
**Diagram note:** None needed.

---

## Slide 15
**Layout:** half-page  
**Script cue:** “After that, you still have to go into the transaction data itself...”  
**Slide title:** Downstream Interpretation  
**Slide text:**
- Unpack the transaction
- Check for the account interaction you care about
- Interpret protocol-specific signal accurately

**Review note:** Avoid sounding like a recipe; keep it high-level.  
**Diagram note:** Three-step flow: `Unpack -> Identify -> Interpret`

---

## Slide 16
**Layout:** half-page  
**Script cue:** “Sometimes it is only at the very end of that chain...”  
**Slide title:** Sometimes You Only Know at the End  
**Slide text:**
- Work through the full chain
- Then find out whether the data is even useful

**Review note:** This slide should land emotionally, almost like a punchline for engineers.  
**Image suggestion:** Optional simple “long pipeline / tiny signal at end” visual.

---

## Slide 17
**Layout:** half-page  
**Script cue:** “So if your goal is not just to observe raw chain activity...”  
**Slide title:** Why Ingestion-Time Processing Matters  
**Slide text:**
- Isolate relevant events
- Normalize into usable form
- Write signal, not noise, into storage

**Review note:** Strong architectural takeaway slide.  
**Diagram note:** `Raw stream -> processing layer -> clean event records -> storage`

---

## Slide 18
**Layout:** half-page  
**Script cue:** “That is the real ingestion challenge...”  
**Slide title:** The Real Challenge  
**Slide text:**
- High-volume blockchain execution data
- Clean, queryable events
- Useful monitoring output

**Review note:** This is a summary beat before moving to Shyft.  
**Diagram note:** None needed.

---

## Slide 19
**Layout:** half-page  
**Script cue:** “So why choose Shyft as my gRPC service provider?”  
**Slide title:** Why Shyft  
**Slide text:**
- Cost
- Documentation
- Broader data stack
- Support

**Review note:** Use this as a category slide before the next few slides.  
**Diagram note:** Four simple icon cards.

---

## Slide 20
**Layout:** half-page  
**Script cue:** “First, pricing.”  
**Slide title:** 1. Pricing  
**Slide text:**
- Most cost-competitive option I found
- Naturally attractive to the client

**Review note:** Keep this factual and restrained.  
**Diagram note:** None needed.

---

## Slide 21
**Layout:** half-page  
**Script cue:** “Second, documentation.”  
**Slide title:** 2. Documentation  
**Slide text:**
- Strong docs
- Practical examples
- Real Solana workflows

**Review note:** You could optionally show a cropped screenshot of the docs here.  
**Image suggestion:** Screenshot of Shyft docs/examples page.

---

## Slide 22
**Layout:** half-page  
**Script cue:** “Third, the broader data stack.”  
**Slide title:** 3. Broader Data Stack  
**Slide text:**
- gRPC for live streaming
- Indexed query layers
- Better account discovery at scale

**Review note:** Keep this high-level; do not drift into implementation specifics.  
**Diagram note:** Three-layer stack: `Streaming / Indexed queries / RPC`

---

## Slide 23
**Layout:** half-page  
**Script cue:** “And finally, support.”  
**Slide title:** 4. Support  
**Slide text:**
- Responsive
- Helpful
- Valuable during implementation

**Review note:** Final sponsor point; keep it brief.  
**Diagram note:** None needed.

---

## Slide 24
**Layout:** half-page  
**Script cue:** “And that gives you a solid introduction...”  
**Slide title:** Ingestion Is Only the First Half  
**Slide text:**
- Real-time Solana pipeline in place
- Still need to turn raw activity into usable metrics
- Database architecture matters next

**Review note:** This is the bridge to the TigerData video.  
**Diagram note:** `Ingestion -> Storage/Transformation` arrow bridge.

---

## Slide 25
**Layout:** half-page  
**Script cue:** “And that's what I will be covering in the next video.”  
**Slide title:** Next: The Database Layer  
**Slide text:**
- Turning raw activity into metrics
- Choosing the right database setup

**Review note:** Final teaser / closing slide.  
**Image suggestion:** Optional preview image of the dashboard plus database-themed graphic.

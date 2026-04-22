// Paste this into the browser console on the Web3 CFO Slack workspace
// (must be running in the browser at app.slack.com)
//
// It will:
//   1. Find the #01-introduce-yourself channel
//   2. Fetch ALL messages from that channel
//   3. Keep the most recent message per member
//   4. Extract URLs (LinkedIn etc.) from the message text
//   5. Download a CSV

(async () => {
  const TOKEN =
    "xoxc-3182982918308-5584279581381-10870380063649-d123482994c0354e03a188f7e38f30b02b62d3351e4be4b02dc6b3dd0ce70da9";

  const CHANNEL_NAME = "01-introduce-yourself";
  const DELAY_MS = 1200;

  const apiCall = async (method, params = {}) => {
    const body = new URLSearchParams({ token: TOKEN, ...params });
    const r = await fetch(`/api/${method}`, {
      method: "POST",
      body,
      credentials: "include",
    });
    if (!r.ok) throw new Error(`${r.status} ${r.statusText} — ${method}`);
    const json = await r.json();
    if (!json.ok) throw new Error(`Slack API error: ${json.error} — ${method}`);
    return json;
  };

  // ── Step 1: Find the channel ID ──────────────────────────────────
  console.log("%c[SLACK] Looking up channel #" + CHANNEL_NAME + "…", "color:#4A154B;font-weight:bold");

  let channelId = null;
  let cursor = "";

  do {
    const params = { types: "public_channel,private_channel", limit: "200", exclude_archived: "true" };
    if (cursor) params.cursor = cursor;
    const data = await apiCall("conversations.list", params);

    const match = (data.channels || []).find(
      (c) => c.name === CHANNEL_NAME || c.name_normalized === CHANNEL_NAME
    );
    if (match) {
      channelId = match.id;
      break;
    }

    cursor = data.response_metadata?.next_cursor || "";
    if (cursor) await new Promise((r) => setTimeout(r, DELAY_MS));
  } while (cursor);

  if (!channelId) {
    console.error(`[SLACK] Could not find channel #${CHANNEL_NAME}. Check the name.`);
    return;
  }

  console.log(`[SLACK] Found channel: ${channelId}`);

  // ── Step 2: Fetch all messages from the channel ──────────────────
  console.log("%c[SLACK] Fetching messages (this may take a few minutes)…", "color:#4A154B;font-weight:bold");

  const allMessages = [];
  cursor = "";
  let pageNum = 0;

  do {
    const params = { channel: channelId, limit: "200" };
    if (cursor) params.cursor = cursor;

    const data = await apiCall("conversations.history", params);
    const msgs = (data.messages || []).filter(
      (m) => m.type === "message" && m.user && !m.subtype
    );

    allMessages.push(...msgs);
    pageNum++;

    cursor = data.response_metadata?.next_cursor || "";
    console.log(
      `[SLACK]   Page ${pageNum}: ${msgs.length} user messages (total: ${allMessages.length})` +
        (data.has_more ? " — more pages…" : " — done")
    );

    if (cursor) await new Promise((r) => setTimeout(r, DELAY_MS));
  } while (cursor);

  console.log(
    `%c[SLACK] ${allMessages.length} total user messages fetched.`,
    "color:#4A154B;font-weight:bold"
  );

  // ── Step 3: Keep most recent message per user ────────────────────
  const byUser = new Map();

  for (const msg of allMessages) {
    if (!byUser.has(msg.user)) {
      byUser.set(msg.user, msg);
    }
  }

  console.log(`[SLACK] ${byUser.size} unique members with intro messages.`);

  // ── Step 4: Extract URLs from message text ───────────────────────
  const URL_RE = /https?:\/\/[^\s>|]+/gi;
  const SLACK_URL_RE = /<(https?:\/\/[^>|]+)(?:\|[^>]*)?>/gi;

  const extractUrls = (text) => {
    const urls = new Set();
    for (const m of text.matchAll(SLACK_URL_RE)) urls.add(m[1]);
    for (const m of text.matchAll(URL_RE)) {
      const u = m[0].replace(/[.)>]+$/, "");
      if (!u.includes("slack.com") && !u.includes("emoji")) urls.add(u);
    }
    return [...urls];
  };

  // ── Step 5: Build results ────────────────────────────────────────
  const results = [];

  for (const [userId, msg] of byUser) {
    const text = msg.text || "";
    const urls = extractUrls(text);
    const linkedin = urls.find((u) => u.includes("linkedin.com")) || "";
    const twitter =
      urls.find((u) => u.includes("twitter.com") || u.includes("x.com")) || "";
    const otherUrls = urls
      .filter((u) => u !== linkedin && u !== twitter)
      .join(" | ");

    const cleanText = text
      .replace(/<https?:\/\/[^>]+>/g, "")
      .replace(/<@[A-Z0-9]+>/g, "")
      .replace(/:[a-z_]+:/g, "")
      .trim();

    results.push({
      user_id: userId,
      intro_text: cleanText,
      linkedin,
      twitter,
      other_urls: otherUrls,
      posted_at: new Date(parseFloat(msg.ts) * 1000).toISOString(),
    });
  }

  // ── Step 6: CSV download ─────────────────────────────────────────
  const esc = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;

  const csvRows = ["user_id,intro_text,linkedin,twitter,other_urls,posted_at"];
  for (const r of results) {
    csvRows.push(
      [
        esc(r.user_id),
        esc(r.intro_text),
        esc(r.linkedin),
        esc(r.twitter),
        esc(r.other_urls),
        esc(r.posted_at),
      ].join(",")
    );
  }

  const csv = csvRows.join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `web3cfo_intros_${new Date().toISOString().slice(0, 10)}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);

  window.__slackIntros = results;

  console.log(
    `%c[SLACK] Done! ${results.length} intro messages exported. Also available as window.__slackIntros`,
    "color:#4A154B;font-weight:bold"
  );
  console.table(results.slice(0, 5));
})();

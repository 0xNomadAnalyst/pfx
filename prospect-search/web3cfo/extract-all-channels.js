// Paste this into the browser console on the Web3 CFO Slack workspace
//
// It will:
//   1. List all channels you're a member of
//   2. Fetch all available messages from each channel (90-day window)
//   3. Aggregate per-member: URLs, LinkedIn, message snippets
//   4. Download a CSV keyed by user_id for merging

(async () => {
  const TOKEN =
    "xoxc-3182982918308-5584279581381-10870380063649-d123482994c0354e03a188f7e38f30b02b62d3351e4be4b02dc6b3dd0ce70da9";

  const API_DELAY_MS = 1200;
  const SKIP_CHANNELS = new Set(["slackbot"]);

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

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ── Step 1: List all joined channels ─────────────────────────────
  console.log("%c[SLACK] Discovering channels…", "color:#4A154B;font-weight:bold");

  const channels = [];
  let cursor = "";
  do {
    const params = {
      types: "public_channel,private_channel",
      exclude_archived: "true",
      limit: "200",
    };
    if (cursor) params.cursor = cursor;
    const data = await apiCall("conversations.list", params);
    for (const ch of data.channels || []) {
      if (ch.is_member && !SKIP_CHANNELS.has(ch.name)) {
        channels.push({ id: ch.id, name: ch.name });
      }
    }
    cursor = data.response_metadata?.next_cursor || "";
    if (cursor) await sleep(API_DELAY_MS);
  } while (cursor);

  console.log(`[SLACK] Found ${channels.length} joined channels: ${channels.map((c) => "#" + c.name).join(", ")}`);

  // ── Step 2: Fetch all messages from each channel ─────────────────
  // Per-user accumulator: { urls: Set, linkedin: string, twitter: string, snippets: [] }
  const userMap = new Map();

  const SLACK_URL_RE = /<(https?:\/\/[^>|]+)(?:\|[^>]*)?>/gi;
  const URL_RE = /https?:\/\/[^\s>|]+/gi;

  const extractUrls = (text) => {
    const urls = new Set();
    for (const m of text.matchAll(SLACK_URL_RE)) urls.add(m[1]);
    for (const m of text.matchAll(URL_RE)) {
      const u = m[0].replace(/[.)>]+$/, "");
      if (!u.includes("slack.com") && !u.includes("emoji") && !u.includes("slack-edge"))
        urls.add(u);
    }
    return [...urls];
  };

  let totalMessages = 0;

  for (let ci = 0; ci < channels.length; ci++) {
    const ch = channels[ci];
    console.log(
      `%c[SLACK] [${ci + 1}/${channels.length}] Fetching #${ch.name}…`,
      "color:#4A154B;font-weight:bold"
    );

    let pageCursor = "";
    let channelMsgCount = 0;

    do {
      const params = { channel: ch.id, limit: "200" };
      if (pageCursor) params.cursor = pageCursor;

      let data;
      try {
        data = await apiCall("conversations.history", params);
      } catch (e) {
        console.warn(`[SLACK]   Error in #${ch.name}: ${e.message}`);
        break;
      }

      const msgs = (data.messages || []).filter(
        (m) => m.type === "message" && m.user && !m.subtype
      );

      for (const msg of msgs) {
        if (!userMap.has(msg.user)) {
          userMap.set(msg.user, {
            urls: new Set(),
            linkedin: "",
            twitter: "",
            channels: new Set(),
            messageCount: 0,
            snippets: [],
          });
        }

        const u = userMap.get(msg.user);
        u.messageCount++;
        u.channels.add(ch.name);

        const urls = extractUrls(msg.text || "");
        for (const url of urls) {
          u.urls.add(url);
          if (!u.linkedin && url.includes("linkedin.com")) u.linkedin = url;
          if (!u.twitter && (url.includes("twitter.com") || url.includes("x.com")))
            u.twitter = url;
        }

        // Keep short snippets that might contain company/role info (first 300 chars of longer messages)
        const text = (msg.text || "").replace(/<[^>]+>/g, "").trim();
        if (text.length > 30 && u.snippets.length < 5) {
          u.snippets.push(text.slice(0, 300));
        }
      }

      channelMsgCount += msgs.length;
      pageCursor = data.response_metadata?.next_cursor || "";

      await sleep(API_DELAY_MS);
    } while (pageCursor);

    totalMessages += channelMsgCount;
    console.log(`[SLACK]   → ${channelMsgCount} messages from #${ch.name}`);
  }

  console.log(
    `%c[SLACK] Total: ${totalMessages} messages from ${channels.length} channels. ${userMap.size} active users found.`,
    "color:#4A154B;font-weight:bold"
  );

  // ── Step 3: Build CSV ────────────────────────────────────────────
  const esc = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;

  const csvRows = [
    "user_id,message_count,active_channels,linkedin,twitter,other_urls,sample_messages",
  ];

  for (const [userId, data] of userMap) {
    const otherUrls = [...data.urls]
      .filter((u) => u !== data.linkedin && u !== data.twitter)
      .join(" | ");

    csvRows.push(
      [
        esc(userId),
        esc(data.messageCount),
        esc([...data.channels].join(", ")),
        esc(data.linkedin),
        esc(data.twitter),
        esc(otherUrls),
        esc(data.snippets.join(" /// ")),
      ].join(",")
    );
  }

  const csv = csvRows.join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `web3cfo_channel_activity_${new Date().toISOString().slice(0, 10)}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);

  window.__slackChannelData = userMap;

  console.log(
    `%c[SLACK] Done! Exported activity for ${userMap.size} users. Also available as window.__slackChannelData`,
    "color:#4A154B;font-weight:bold"
  );
})();

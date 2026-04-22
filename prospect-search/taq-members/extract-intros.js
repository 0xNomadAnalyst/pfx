// Paste this into the browser console on
// https://app.theaccountantquits.com/spaces/17888491/chat
//
// Extracts all messages from the "introduce yourself" chat channel,
// keyed by member, to enrich the member CSV.

(async () => {
  const SPACE_ID = 17888491;
  const NETWORK_SPACE_ID = 17299368;
  const BASE = `https://app.theaccountantquits.com/api/web/v1/spaces/${SPACE_ID}`;
  const PER_PAGE = 25;
  const PAGE_DELAY_MS = 500;

  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const csrfToken = csrfMeta?.content;

  const headers = {
    Accept: "application/json, text/javascript, */*; q=0.01",
    "X-Requested-With": "XMLHttpRequest",
    "X-Context-Space-Id": String(SPACE_ID),
    ...(csrfToken ? { "X-Csrf-Token": csrfToken } : {}),
  };

  const get = async (url) => {
    const r = await fetch(url, { headers, credentials: "include" });
    if (!r.ok) throw new Error(`${r.status} ${r.statusText} — ${url}`);
    return r.json();
  };

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ── Step 1: Fetch first page and detect response shape ──────────────
  console.log("%c[TAQ-INTROS] Fetching first page of chats…", "color:#5E39F3;font-weight:bold");

  const workingEndpoint = `${BASE}/chats`;
  let probeData;
  try {
    probeData = await get(`${workingEndpoint}?per_page=${PER_PAGE}&page=1`);
  } catch (e) {
    console.error(`[TAQ-INTROS] Endpoint failed: ${e.message}`);
    return;
  }

  // Detect which key holds the items
  let itemsKey = null;
  if (Array.isArray(probeData)) {
    itemsKey = null;
  } else {
    for (const key of ["chats", "messages", "data", "records", "posts"]) {
      if (Array.isArray(probeData[key]) && probeData[key].length > 0) {
        itemsKey = key;
        break;
      }
    }
  }

  const probeItems = itemsKey ? probeData[itemsKey] : (Array.isArray(probeData) ? probeData : []);

  if (probeItems.length > 0) {
    console.log(`[TAQ-INTROS] Response key: ${itemsKey || "(root array)"}, sample keys:`, Object.keys(probeItems[0]));
    if (probeItems[0].creator) console.log(`[TAQ-INTROS]   Creator keys:`, Object.keys(probeItems[0].creator));
  } else {
    console.error("[TAQ-INTROS] First page returned 0 items. Check the space ID.");
    return;
  }

  // ── Step 2: Paginate through all messages ──────────────────────────
  console.log("%c[TAQ-INTROS] Fetching all messages…", "color:#5E39F3;font-weight:bold");

  const getItems = (data) => {
    if (Array.isArray(data)) return data;
    return itemsKey ? (data[itemsKey] || []) : [];
  };

  let allItems = [...probeItems];
  console.log(`[TAQ-INTROS]   Page 1: ${allItems.length} items`);

  let page = 2;
  while (allItems.length >= PER_PAGE * (page - 1)) {
    const url = `${workingEndpoint}?per_page=${PER_PAGE}&page=${page}`;
    let data;
    try {
      data = await get(url);
    } catch (e) {
      console.warn(`[TAQ-INTROS]   Page ${page} failed: ${e.message}`);
      break;
    }

    const items = getItems(data);
    if (items.length === 0) break;

    allItems.push(...items);
    console.log(`[TAQ-INTROS]   Page ${page}: ${items.length} items (total: ${allItems.length})`);

    if (items.length < PER_PAGE) break;
    page++;
    await sleep(PAGE_DELAY_MS);
  }

  console.log(
    `%c[TAQ-INTROS] ${allItems.length} total messages fetched. Processing…`,
    "color:#5E39F3;font-weight:bold"
  );

  // ── Step 3: Extract structured data per message ────────────────────
  const URL_RE = /https?:\/\/[^\s"'<>,)}\]\\]+/gi;

  const extractUrls = (text) => {
    if (!text) return [];
    const seen = new Set();
    const urls = [];
    for (const match of text.matchAll(URL_RE)) {
      let u = match[0].replace(/[.)]+$/, "");
      if (seen.has(u)) continue;
      if (u.includes("mightynetworks.imgix.net")) continue;
      if (u.includes("theaccountantquits.com/posts/")) continue;
      seen.add(u);
      urls.push(u);
    }
    return urls;
  };

  const stripHtml = (html) => {
    if (!html) return "";
    const div = document.createElement("div");
    div.innerHTML = html;
    return div.textContent || div.innerText || "";
  };

  const results = [];

  for (const item of allItems) {
    const user = item.user || {};
    const memberId = item.user_id || user.id || "";
    const memberName = user.name || `${user.first_name || ""} ${user.last_name || ""}`.trim() || "";
    const memberBio = user.short_bio || "";

    let body = item.text || item.body || item.content || item.description || item.message || "";
    if (body.includes("<")) body = stripHtml(body);

    const fullText = body.trim();

    const urls = extractUrls(fullText);
    const linkedin = urls.find((u) => u.includes("linkedin.com")) || "";
    const twitter = urls.find((u) => u.includes("twitter.com") || u.includes("x.com")) || "";
    const otherUrls = urls.filter((u) => u !== linkedin && u !== twitter).join(" | ");

    results.push({
      member_id: memberId,
      member_name: memberName,
      member_bio: memberBio,
      posted_at: item.created_at || "",
      message: fullText.replace(/\n+/g, " ").slice(0, 3000),
      linkedin,
      twitter,
      other_urls: otherUrls,
    });
  }

  // Sort by member name then date
  results.sort((a, b) => a.member_name.localeCompare(b.member_name) || a.posted_at.localeCompare(b.posted_at));

  const uniqueMembers = new Set(results.map((r) => r.member_id)).size;

  // ── Step 4: Download CSV ───────────────────────────────────────────
  const esc = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;

  const csvRows = ["member_id,member_name,member_bio,posted_at,message,linkedin,twitter,other_urls"];
  for (const r of results) {
    csvRows.push(
      [
        esc(r.member_id),
        esc(r.member_name),
        esc(r.member_bio),
        esc(r.posted_at),
        esc(r.message),
        esc(r.linkedin),
        esc(r.twitter),
        esc(r.other_urls),
      ].join(",")
    );
  }

  const csv = csvRows.join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `taq_intros_${new Date().toISOString().slice(0, 10)}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);

  window.__taqIntros = results;
  window.__taqIntrosRaw = allItems;

  console.log(
    `%c[TAQ-INTROS] Done! ${results.length} messages from ${uniqueMembers} unique members exported.`,
    "color:#5E39F3;font-weight:bold"
  );
  console.log("[TAQ-INTROS] Raw data: window.__taqIntrosRaw");
  console.table(results.slice(0, 5).map(({ message, ...r }) => r));
})();

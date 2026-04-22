// Paste this entire script into the browser console on
// https://app.theaccountantquits.com/members/all
//
// It will:
//   1. Discover all member IDs via the list API
//   2. Fetch each member's full profile
//   3. Extract company name from short_bio
//   4. Download a cleaned CSV with the results

(async () => {
  const SPACE_ID = 17299368;
  const BASE = `https://app.theaccountantquits.com/api/web/v1/spaces/${SPACE_ID}`;
  const PER_PAGE = 25;
  const DETAIL_DELAY_MS = 250;
  const PAGE_DELAY_MS = 500;

  const SKIP_IDS = new Set([31637953, 33111609, 34533572]);

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

  const extractCompany = (bio) => {
    if (!bio || !bio.trim()) return "";
    const patterns = [
      /\b(?:at|@)\s+(.+?)(?:\s*[|\.\-–—,;(]|$)/i,
      /\b(?:for)\s+(.+?)(?:\s*[|\.\-–—,;(]|$)/i,
    ];
    for (const p of patterns) {
      const m = bio.match(p);
      if (m && m[1]) {
        const company = m[1].trim().replace(/[|.]+$/, "").trim();
        if (company.length > 1 && company.length < 100) return company;
      }
    }
    return "";
  };

  const URL_RE = /https?:\/\/[^\s"'<>,)}\]]+/gi;

  const extractUrls = (source) => {
    const texts = [
      source.short_bio,
      source.website,
      source.website_url,
      source.linkedin,
      source.linkedin_url,
      source.twitter,
      source.twitter_url,
    ];

    // Pull URLs from social_links / links if the API returns them
    if (Array.isArray(source.social_links)) {
      source.social_links.forEach((l) => texts.push(l.url || l.href || l));
    }
    if (Array.isArray(source.links)) {
      source.links.forEach((l) => texts.push(l.url || l.href || l));
    }
    if (source.social_links && !Array.isArray(source.social_links)) {
      Object.values(source.social_links).forEach((v) => texts.push(v));
    }

    // Pull from introduction body text
    const intro = source.introduction;
    if (intro) {
      texts.push(intro.description, intro.body, intro.content);
      if (intro.sharing_meta) texts.push(intro.sharing_meta.url);
    }

    const seen = new Set();
    const urls = [];
    for (const t of texts) {
      if (!t || typeof t !== "string") continue;
      for (const match of t.matchAll(URL_RE)) {
        let u = match[0].replace(/[.)]+$/, "");
        if (seen.has(u)) continue;
        // skip platform-internal asset/image URLs
        if (u.includes("mightynetworks.imgix.net")) continue;
        if (u.includes("theaccountantquits.com/posts/")) continue;
        seen.add(u);
        urls.push(u);
      }
    }
    return urls;
  };

  // ── Step 1: Paginate through member list ──────────────────────────
  console.log("%c[TAQ] Starting member list extraction…", "color:#5E39F3;font-weight:bold");

  let allMembers = [];
  let page = 1;

  while (true) {
    const url = `${BASE}/members?per_page=${PER_PAGE}&page=${page}`;
    console.log(`[TAQ] Fetching page ${page}…`);

    let data;
    try {
      data = await get(url);
    } catch (e) {
      console.warn(`[TAQ] List endpoint failed on page ${page}:`, e.message);
      break;
    }

    const members = Array.isArray(data)
      ? data
      : data.members || data.data || data.results || [];

    if (members.length === 0) break;

    allMembers.push(...members);
    console.log(`[TAQ]   → ${members.length} members (running total: ${allMembers.length})`);

    if (members.length < PER_PAGE) break;
    page++;
    await new Promise((r) => setTimeout(r, PAGE_DELAY_MS));
  }

  if (allMembers.length === 0) {
    console.error("[TAQ] No members returned from list endpoint. Check Network tab for clues.");
    return;
  }

  // Filter out internal/test accounts
  allMembers = allMembers.filter((m) => !SKIP_IDS.has(m.id || m.member_id));

  console.log(`%c[TAQ] Found ${allMembers.length} members. Fetching profiles…`, "color:#5E39F3;font-weight:bold");

  // ── Step 2: Fetch individual profiles to get full data ────────────
  const results = [];

  for (let i = 0; i < allMembers.length; i++) {
    const m = allMembers[i];
    const id = m.id || m.member_id;

    let source = m;
    try {
      source = await get(`${BASE}/members/${id}`);
    } catch (e) {
      console.warn(`[TAQ] Failed to fetch member ${id}, using list data:`, e.message);
    }
    await new Promise((r) => setTimeout(r, DETAIL_DELAY_MS));

    const bio = (source.short_bio || "").trim();
    const urls = extractUrls(source);
    const linkedin = urls.find((u) => u.includes("linkedin.com")) || "";
    const twitter = urls.find((u) => u.includes("twitter.com") || u.includes("x.com")) || "";
    const otherUrls = urls.filter((u) => u !== linkedin && u !== twitter).join(" | ");

    results.push({
      id,
      name: source.name || `${source.first_name || ""} ${source.last_name || ""}`.trim(),
      short_bio: bio,
      company: extractCompany(bio),
      location: source.location || "",
      last_active: source.last_visit_at || source.network_last_visit_at || "",
      member_since: source.created_at || "",
      linkedin,
      twitter,
      other_urls: otherUrls,
    });

    if ((i + 1) % 25 === 0 || i === allMembers.length - 1) {
      console.log(`[TAQ] Profiles: ${i + 1} / ${allMembers.length}`);
    }
  }

  // ── Step 3: Build CSV and download ────────────────────────────────
  const esc = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;

  const csvHeader = "id,name,short_bio,company,location,last_active,member_since,linkedin,twitter,other_urls";
  const csvRows = [csvHeader];
  for (const r of results) {
    csvRows.push(
      [
        esc(r.id),
        esc(r.name),
        esc(r.short_bio),
        esc(r.company),
        esc(r.location),
        esc(r.last_active),
        esc(r.member_since),
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
  a.download = `taq_members_${new Date().toISOString().slice(0, 10)}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);

  window.__taqMembers = results;

  console.log(
    `%c[TAQ] Done! ${results.length} members exported to CSV. Also available as window.__taqMembers`,
    "color:#5E39F3;font-weight:bold"
  );
  console.table(results.slice(0, 10));
})();

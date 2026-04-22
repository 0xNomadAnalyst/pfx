// Paste this into the browser console on
// https://community.web3finance.club/c/introduce-yourself
//
// Fetches ALL intro posts from Circle.so, extracts author + content + URLs

(async () => {
  const BASE = "https://community.web3finance.club";
  const SPACE_ID = 1056791;
  const PER_PAGE = 20;
  const DELAY_MS = 800;

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  const bearerToken =
    "eyJhbGciOiJSUzI1NiJ9.eyJleHAiOjE3NzU2MTM5MjAsInR5cGUiOiJhbmFseXRpY3NfdHJhY2tlciIsImp0aSI6IjFiNmY4YTgwLWE4OWMtNDdhOS1iMjYyLWIyZDEwYThkYmJiYyIsImNvbW11bml0eV9pZCI6MTI5Mjc5LCJhcHBfbmFtZSI6ImNpcmNsZS5wcm9kdWN0aW9uIiwidXNlcl9pZCI6OTk0MDEzNiwiY29tbXVuaXR5X21lbWJlcl9pZCI6MjIxOTA0OTR9.eR5UcPakJrpkgnPLPyTXim4wQ40Aw1Js7fNAHJMgbb1EiFltoUr4vnKcsBDqbspEVTHHmLzJmwCqI1ZAEgBMoV5usBmYpb7A0qD3VrmYkBE5EJx0_SikS90hNYBTfELyg16zKA78tUTf7RRLMBerumlLVAPFDs7aQM3_rZft19Rk4oGsEdDYrE68tE71k01LWcHJQ3g1w43D7EMa0pTcJohh4_x4uxZTJDPcZbfb4b_0q5J_6ldbhaKsDxo60j0hs4DVc7IDj5sdLLNf_KKUA6pLbzgITpWC5nS6L855iGc0v9zOUP8QSKWs4XLoov8LsW7ZHLAovGFmHLN7bF8j3w";

  const headers = {
    Accept: "application/json",
    "Content-Type": "application/json",
    Authorization: `Bearer ${bearerToken}`,
  };

  const fetchJSON = async (url) => {
    const r = await fetch(url, {
      headers,
      credentials: "include",
      cache: "no-store",
    });
    if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
    return r.json();
  };

  // ── Step 1: Probe to get total count ──────────────────────────────
  console.log("%c[CIRCLE] Probing for post count…", "color:#6C3CE1;font-weight:bold");

  const probeUrl = `${BASE}/internal_api/spaces/${SPACE_ID}/posts?per_page=${PER_PAGE}&sort=latest&page=1`;
  const probe = await fetchJSON(probeUrl);

  const totalPosts = probe.count || 0;
  const totalPages = Math.ceil(totalPosts / PER_PAGE);

  console.log(`[CIRCLE] Total posts: ${totalPosts}, pages: ${totalPages}`);

  if (totalPosts === 0) {
    console.error("[CIRCLE] No posts found.");
    return;
  }

  // ── Step 2: Paginate through all posts ────────────────────────────
  console.log("%c[CIRCLE] Fetching all pages…", "color:#6C3CE1;font-weight:bold");

  const allPosts = [...(probe.records || [])];
  console.log(`[CIRCLE]   Page 1/${totalPages}: ${allPosts.length} posts (total: ${allPosts.length})`);

  for (let page = 2; page <= totalPages; page++) {
    const url = `${BASE}/internal_api/spaces/${SPACE_ID}/posts?per_page=${PER_PAGE}&sort=latest&page=${page}`;

    try {
      const data = await fetchJSON(url);
      const records = data.records || [];
      allPosts.push(...records);
      console.log(`[CIRCLE]   Page ${page}/${totalPages}: ${records.length} posts (total: ${allPosts.length})`);
    } catch (e) {
      console.warn(`[CIRCLE]   Page ${page} failed: ${e.message}`);
    }

    await sleep(DELAY_MS);
  }

  console.log(`%c[CIRCLE] ${allPosts.length} posts collected. Extracting data…`, "color:#6C3CE1;font-weight:bold");

  // Log sample structure for debugging
  if (allPosts.length > 0) {
    const s = allPosts[0];
    console.log("[CIRCLE] Sample post keys:", Object.keys(s));
    if (s.community_member) console.log("[CIRCLE] community_member keys:", Object.keys(s.community_member));
    console.log("[CIRCLE] Body fields present:", {
      tiptap_body: typeof s.tiptap_body,
      truncated_content: typeof s.truncated_content,
      body_for_editor: typeof s.body_for_editor,
      name: typeof s.name,
    });
  }

  // ── Step 3: Extract data from each post ───────────────────────────
  const URL_RE = /https?:\/\/[^\s"'<>,)}\]\\]+/gi;

  // Recursively extract plain text from tiptap JSON
  const tiptapToText = (node) => {
    if (!node) return "";
    if (typeof node === "string") return node;
    let text = "";
    if (node.text) text += node.text;
    if (node.content && Array.isArray(node.content)) {
      text += node.content.map(tiptapToText).join("");
    }
    if (node.type === "paragraph" || node.type === "heading") text += "\n";
    return text;
  };

  const results = [];

  for (const post of allPosts) {
    const member = post.community_member || {};

    // Extract post body text
    let textContent = "";
    if (post.tiptap_body) {
      try {
        const parsed = typeof post.tiptap_body === "string"
          ? JSON.parse(post.tiptap_body)
          : post.tiptap_body;
        textContent = tiptapToText(parsed);
      } catch {
        textContent = typeof post.tiptap_body === "string" ? post.tiptap_body : JSON.stringify(post.tiptap_body);
      }
    }
    if (!textContent && post.truncated_content) {
      textContent = post.truncated_content;
    }
    if (!textContent && post.body_for_editor) {
      textContent = typeof post.body_for_editor === "string"
        ? post.body_for_editor.replace(/<[^>]+>/g, " ")
        : JSON.stringify(post.body_for_editor);
    }

    const fullText = ((post.name || "") + " " + textContent).trim();

    const urls = [...new Set((fullText.match(URL_RE) || []).map((u) => u.replace(/[.)]+$/, "")))];
    const linkedin = urls.find((u) => u.includes("linkedin.com")) || "";
    const twitter = urls.find((u) => u.includes("twitter.com") || u.includes("x.com")) || "";
    const otherUrls = urls
      .filter((u) => u !== linkedin && u !== twitter && !u.includes("circle.so") && !u.includes("imgix.net"))
      .join(" | ");

    results.push({
      post_id: post.id || "",
      author_id: post.user_id || member.id || "",
      author_name: member.name || "",
      author_headline: member.headline || member.bio || "",
      author_avatar: member.avatar_url || "",
      post_title: post.name || "",
      post_text: fullText.replace(/\n+/g, " ").slice(0, 2000),
      linkedin,
      twitter,
      other_urls: otherUrls,
      created_at: post.created_at || post.published_at || "",
    });
  }

  // ── Step 4: Download CSV ──────────────────────────────────────────
  const esc = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;

  const csvRows = [
    "post_id,author_id,author_name,author_headline,post_title,post_text,linkedin,twitter,other_urls,created_at",
  ];

  for (const r of results) {
    csvRows.push(
      [
        esc(r.post_id),
        esc(r.author_id),
        esc(r.author_name),
        esc(r.author_headline),
        esc(r.post_title),
        esc(r.post_text),
        esc(r.linkedin),
        esc(r.twitter),
        esc(r.other_urls),
        esc(r.created_at),
      ].join(",")
    );
  }

  const csv = csvRows.join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `web3cfo_circle_intros_${new Date().toISOString().slice(0, 10)}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);

  window.__circleIntros = results;
  window.__circleRawPosts = allPosts;

  console.log(
    `%c[CIRCLE] Done! ${results.length} intro posts exported.`,
    "color:#6C3CE1;font-weight:bold"
  );
  console.log("[CIRCLE] Raw posts: window.__circleRawPosts");
  console.table(results.slice(0, 5).map(({ post_text, ...r }) => r));
})();

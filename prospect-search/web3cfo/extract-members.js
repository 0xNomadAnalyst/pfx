// Paste this into the browser console on the Web3 CFO Slack workspace
// (must be running in the browser at app.slack.com)
//
// It will:
//   1. Discover custom profile fields configured in the workspace
//   2. Fetch all members via users.list with pagination
//   3. Extract name, title, company, LinkedIn, and all custom fields
//   4. Download a CSV

(async () => {
  const TOKEN =
    "xoxc-3182982918308-5584279581381-10870380063649-d123482994c0354e03a188f7e38f30b02b62d3351e4be4b02dc6b3dd0ce70da9";

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

  // ── Step 1: Discover custom profile fields ────────────────────────
  console.log("%c[SLACK] Fetching workspace profile field definitions…", "color:#4A154B;font-weight:bold");

  const fieldMap = {};
  try {
    const tp = await apiCall("team.profile.get");
    if (tp.profile?.fields) {
      for (const f of tp.profile.fields) {
        fieldMap[f.id] = f.label;
        console.log(`[SLACK]   Custom field: ${f.id} → "${f.label}"`);
      }
    }
  } catch (e) {
    console.warn("[SLACK] Could not fetch team profile fields:", e.message);
  }

  // ── Step 2: Paginate through all members ──────────────────────────
  console.log("%c[SLACK] Fetching member list…", "color:#4A154B;font-weight:bold");

  let allMembers = [];
  let cursor = "";

  do {
    const params = { limit: "200", include_locale: "true" };
    if (cursor) params.cursor = cursor;

    const data = await apiCall("users.list", params);
    const members = data.members || [];
    allMembers.push(...members);

    cursor = data.response_metadata?.next_cursor || "";
    console.log(`[SLACK]   Batch: ${members.length} members (total: ${allMembers.length})`);

    if (cursor) await new Promise((r) => setTimeout(r, 1000));
  } while (cursor);

  // Filter out bots, Slackbot, deactivated accounts
  allMembers = allMembers.filter(
    (m) => !m.is_bot && !m.deleted && m.id !== "USLACKBOT"
  );

  console.log(
    `%c[SLACK] ${allMembers.length} real members found. Processing profiles…`,
    "color:#4A154B;font-weight:bold"
  );

  // ── Step 3: Extract profile data ──────────────────────────────────
  const allCustomLabels = new Set();
  const results = [];

  for (const m of allMembers) {
    const p = m.profile || {};

    const customFields = {};
    if (p.fields) {
      for (const [fid, fval] of Object.entries(p.fields)) {
        const label = fieldMap[fid] || fid;
        customFields[label] = fval?.value || "";
        allCustomLabels.add(label);
      }
    }

    const linkedin =
      customFields["LinkedIn"] ||
      customFields["LinkedIn URL"] ||
      customFields["LinkedIn Profile"] ||
      "";
    const company =
      customFields["Company"] ||
      customFields["Organization"] ||
      customFields["Org"] ||
      customFields["Firm"] ||
      "";

    results.push({
      id: m.id,
      name: p.real_name || m.real_name || "",
      display_name: p.display_name || "",
      title: p.title || "",
      email: p.email || "",
      phone: p.phone || "",
      status: p.status_text || "",
      timezone: m.tz || "",
      company,
      linkedin,
      custom_fields: customFields,
    });
  }

  // ── Step 4: Build CSV with all discovered custom field columns ────
  const esc = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;

  const baseColumns = [
    "id",
    "name",
    "display_name",
    "title",
    "email",
    "phone",
    "status",
    "timezone",
    "company",
    "linkedin",
  ];

  const extraLabels = [...allCustomLabels].filter(
    (l) =>
      !["Company", "Organization", "Org", "Firm",
        "LinkedIn", "LinkedIn URL", "LinkedIn Profile"].includes(l)
  );

  const csvHeader = [...baseColumns, ...extraLabels].join(",");
  const csvRows = [csvHeader];

  for (const r of results) {
    const baseCols = baseColumns.map((c) => esc(r[c]));
    const extraCols = extraLabels.map((l) => esc(r.custom_fields[l] || ""));
    csvRows.push([...baseCols, ...extraCols].join(","));
  }

  const csv = csvRows.join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `web3cfo_members_${new Date().toISOString().slice(0, 10)}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);

  window.__slackMembers = results;

  console.log(
    `%c[SLACK] Done! ${results.length} members exported. Also available as window.__slackMembers`,
    "color:#4A154B;font-weight:bold"
  );
  console.log("[SLACK] Custom profile fields found:", [...allCustomLabels]);
  console.table(results.slice(0, 10).map(({ custom_fields, ...r }) => r));
})();

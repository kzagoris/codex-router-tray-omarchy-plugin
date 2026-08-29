// Pure helpers ported from codex-router's apps/desktop/ui/model.mjs, cut down
// to what this plugin renders and stripped of everything a QML JS engine
// cannot be trusted to provide: no Intl (QJSEngine's ECMA-402 support is not
// guaranteed), no i18n (the plugin is English-only per PLAN.md), no imports.
//
// chartGeometry() from the source file was dropped on purpose: the tray draws
// an SVG sparkline from it, while this panel reads TOKENS BY DAY as DayRow
// bars (PLAN.md §4), so nothing here consumes it. todayTokens() and
// sevenDayTokens() were dropped the same way at finalization: the panel gets
// both figures straight off dailySeries()/bucketValue(), so the wrappers had
// no caller left.
//
// Everything is defensive: router payload shapes are verified against
// 0.5.0 but every accessor tolerates absence.

var DAY_MS = 24 * 60 * 60 * 1000;

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// Router health names its own subsystems in the `degraded` array; the
// surface says what they are instead of echoing raw identifiers as if they
// were providers. The set is fixed in codex-router 0.5.0, and anything new
// passes through as-is rather than being swallowed.
var DEGRADED_NAMES = {
  oauth: "Kimi OAuth forwarder",
  grokOauth: "Grok OAuth forwarder",
  api: "API forwarder",
  gateway: "Gateway"
};

var DEGRADED_SENTENCE_MAX = 200;

// The same strip-and-clamp Catalog.js applies to router prose; duplicated
// here because Model.js cannot import the other pure module.
function plainText(value, max) {
  var text = String(value === undefined || value === null ? "" : value);
  text = text.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ");
  text = text.replace(/[<>&]/g, "");
  text = text.replace(/\s+/g, " ").trim();
  var limit = max > 0 ? max : DEGRADED_SENTENCE_MAX;
  return text.length > limit ? text.slice(0, limit - 1) + "…" : text;
}

function degradedSentence(names, max) {
  var list = Array.isArray(names) ? names : [];
  if (list.length === 0) return "";
  var parts = [];
  for (var i = 0; i < list.length; i++) {
    var raw = String(list[i]);
    var name = Object.prototype.hasOwnProperty.call(DEGRADED_NAMES, raw)
      ? DEGRADED_NAMES[raw] : raw;
    parts.push(plainText(name, 80));
  }
  return plainText("Degraded: " + parts.join(", "), max);
}

// The overview snapshot's ChatGPT-session projection: explicit sharing
// consent and session usability are separate facts, and expiresInHours is the
// one perishable number an operator cannot get anywhere else on the desktop.
// One dim Status line, absent payload hidden — an old router must not read as
// "no session found".
function chatgptSessionSummary(session) {
  if (!session || typeof session !== "object") return "";
  var sharing = String(session.sharing || "");
  var state = String(session.session || "");
  var present = session.present === true;
  var hasExpiry = session.expiresInHours !== undefined && session.expiresInHours !== null;
  if (sharing === "" && state === "" && !present && !hasExpiry) return "";

  var parts = [];
  if (sharing === "enabled" || sharing === "disabled") parts.push("Sharing " + sharing);
  if (state === "usable" || state === "expired" || state === "unavailable")
    parts.push("Session " + state);
  else if (present) parts.push("Session present");
  var expiry = boundedExpiry(session.expiresInHours);
  if (expiry !== "") parts.push("expires " + expiry);
  if (parts.length === 0) return "No ChatGPT session found";
  return plainText(parts.join(" · "), 160);
}

// A session's `expiresInHours` is an estimate, so the surface says so and
// caps it: no unbounded figure, no false precision, nothing after 30 days.
function boundedExpiry(hours) {
  var value = Number(hours);
  if (!isFinite(value) || value <= 0) return "";
  if (value < 1) return "under an hour";
  if (value < 48) return "~" + Math.max(1, Math.round(value)) + "h";
  if (value < 720) return "~" + Math.round(value / 24) + "d";
  return "30+ days";
}

// The codex target's router-managed default model. Both facts are informational
// for this plugin: the operator can see what the router pins, not change it.
function routerDefaultCatalogModelSummary(target) {
  var block = target && typeof target === "object" ? target : {};
  var slug = String(block.routerDefaultModel || "");
  var managed = block.routerDefaultManaged === true;
  if (slug === "" && !managed) return "";
  var text = slug !== ""
    ? "Default route: " + slug + (managed ? " (router-managed)" : "")
    : "Router-managed default catalog model";
  return plainText(text, 160);
}

// Percent of an allowance used, clamped to 0..100; null when unusable.
function clampPercent(value) {
  var number = Number(value);
  if (!isFinite(number)) return null;
  return Math.min(100, Math.max(0, number));
}

function groupDigits(number) {
  var digits = String(Math.round(Math.max(0, number)));
  var out = "";
  while (digits.length > 3) {
    out = "," + digits.slice(-3) + out;
    digits = digits.slice(0, -3);
  }
  return digits + out;
}

function trimFixed(value, digits) {
  return value.toFixed(digits).replace(/\.0$/, "");
}

// "842" / "1.2k" / "15.5m" — bar-and-row scale.
function compactTokens(value) {
  var tokens = Math.max(0, Number(value) || 0);
  if (tokens < 1000) return Math.round(tokens).toString();
  if (tokens < 1000000) return trimFixed(tokens / 1000, tokens < 10000 ? 1 : 0) + "k";
  return trimFixed(tokens / 1000000, tokens < 10000000 ? 1 : 0) + "m";
}

// "15,533,403" — tooltips and exact counts.
function exactTokens(value) {
  return groupDigits(Number(value) || 0);
}

// Local calendar day key, "2026-08-21" — matches the router's startDate keys.
function localDateKey(date) {
  return date.getFullYear()
    + "-" + String(date.getMonth() + 1).padStart(2, "0")
    + "-" + String(date.getDate()).padStart(2, "0");
}

// The last `days` local calendar days ending today, each paired with the
// bucket total that shares its key. Missing days are real zeros — a gap in
// the buckets means no traffic, not missing data.
function dailySeries(buckets, days, today) {
  var list = Array.isArray(buckets) ? buckets : [];
  var count = Math.max(1, Number(days) || 7);
  var indexed = {};
  for (var i = 0; i < list.length; i++) {
    var bucket = list[i] || {};
    indexed[String(bucket.startDate)] = Number(bucket.tokens) || 0;
  }
  var anchor = new Date(today.getFullYear(), today.getMonth(), today.getDate(), 12);
  var series = [];
  for (var offset = count - 1; offset >= 0; offset--) {
    var date = new Date(anchor.getTime() - offset * DAY_MS);
    var key = localDateKey(date);
    series.push({
      key: key,
      label: WEEKDAYS[date.getDay()],
      longLabel: WEEKDAYS[date.getDay()] + " " + MONTHS[date.getMonth()] + " " + date.getDate(),
      tokens: indexed[key] || 0
    });
  }
  return series;
}

// The account provider: the one Provider whose Limit windows arrive from the
// slow Account usage read rather than from Provider usage. Both sources name
// it differently ("ChatGPT" and "ChatGPT (native)"); one canonical name keeps
// its pill, its cards and its note reading as one Provider.
var ACCOUNT_PROVIDER_ID = "openai";
var CANONICAL_PROVIDER_NAMES = { openai: "ChatGPT" };

// A Provider id as a string, absent or null included: every row this module
// builds is keyed and matched by one.
function idText(value) {
  return String(value === undefined || value === null ? "" : value);
}

function isAccountProvider(id) {
  return idText(id) === ACCOUNT_PROVIDER_ID;
}

function providerDisplayName(id, raw) {
  var key = idText(id);
  if (Object.prototype.hasOwnProperty.call(CANONICAL_PROVIDER_NAMES, key))
    return CANONICAL_PROVIDER_NAMES[key];
  return plainText(raw || key || "unknown", 64);
}

// Every row this module builds carries the Provider it belongs to, and the
// Usage view shows one Provider at a time (ADR-0002).
function forProvider(rows, providerId) {
  var list = Array.isArray(rows) ? rows : [];
  var id = idText(providerId);
  var out = [];
  for (var i = 0; i < list.length; i++)
    if (list[i] && idText(list[i].providerId) === id) out.push(list[i]);
  return out;
}

// Limit-window metrics arrive with prose labels ("5-hour window", "Weekly limit") or
// canonical durations; normalize both to one of three windows. Titles are
// bare — the pill above already says whose window this is. Anything else
// keeps the router's own label as a generic window instead of being dropped:
// opencode's rolling window carries no duration, and a future window must not
// need a new pattern to reach a card.
function limitWindow(metric) {
  if (!metric || (metric.kind && metric.kind !== "quota")) return null;
  var label = String(metric.label || "").toLowerCase().replace(/[–—]/g, "-");
  var minutes = Number(metric.windowDurationMins);
  if (label.indexOf("5-hour") >= 0 || label.indexOf("5 hour") >= 0
      || label.indexOf("five-hour") >= 0 || minutes === 300)
    return { key: "five-hour", label: "Session" };
  if (label.indexOf("week") >= 0 || minutes === 10080)
    return { key: "weekly", label: "Weekly" };
  if (label.indexOf("month") >= 0 || minutes === 43200)
    return { key: "monthly", label: "Monthly" };
  var sanitized = plainText(metric.label || "", 64);
  var genericLabel = sanitized === "" ? "Usage" : sanitized;
  return {
    key: "generic:" + genericLabel.toLowerCase(),
    kind: "generic",
    label: genericLabel
  };
}

function metricPercent(metric) {
  if (!metric) return null;
  var direct = clampPercent(metric.usedPercent);
  if (direct !== null) return direct;
  var used = Number(metric.used);
  var limit = Number(metric.limit);
  return isFinite(used) && isFinite(limit) && limit > 0
    ? clampPercent((used / limit) * 100)
    : null;
}

// Surfaces answer "how much is left", so prefer an explicit remaining figure
// and derive it only when the metric reports usage instead.
function metricRemainingPercent(metric) {
  if (!metric) return null;
  var direct = clampPercent(metric.remainingPercent);
  if (direct !== null) return direct;
  var used = metricPercent(metric);
  return used === null ? null : 100 - used;
}

// A genuine percentage on a balance metric (OpenRouter's pay-as-you-go
// carries one alongside its value) is kept, but a balance never gets one
// invented for it.
function metricUsedPercent(metric) {
  if (!metric) return null;
  if (metric.kind === "quota") return metricPercent(metric);
  if (metric.usedPercent === undefined || metric.usedPercent === null
      || metric.usedPercent === "") return null;
  return clampPercent(metric.usedPercent);
}

// Balance rows answer "what will fund my next request", which is a value, not
// a percentage. Renders the router's own per-metric fields only; nothing is
// derived or fabricated here.
function buildBalanceRows(sources) {
  var providerUsage = sources && sources.providerUsage;
  var providerSetup = sources && sources.providerSetup;
  var rows = [];
  var seen = {};
  var configured = {};
  var setupProviders = providerSetup && Array.isArray(providerSetup.providers) ? providerSetup.providers : [];
  for (var s = 0; s < setupProviders.length; s++)
    if (setupProviders[s] && setupProviders[s].configured) configured[setupProviders[s].id] = true;

  var entries = providerUsage && Array.isArray(providerUsage.providers) ? providerUsage.providers : [];
  for (var u = 0; u < entries.length; u++) {
    var provider = entries[u];
    if (!provider || !configured[provider.id]) continue;
    var metrics = provider.account && Array.isArray(provider.account.metrics) ? provider.account.metrics : [];
    for (var m = 0; m < metrics.length; m++) {
      var metric = metrics[m];
      if (!metric || (metric.kind && metric.kind !== "balance")) continue;
      if (metric.value === undefined || metric.value === null || metric.value === "") continue;
      var value = Number(metric.value);
      if (!isFinite(value)) continue;
      var key = provider.id + ":" + plainText(String(metric.label || "balance"), 64);
      if (seen[key]) continue;
      seen[key] = true;
      var usedPercent = metricUsedPercent(metric);
      var row = {
        key: key,
        providerId: provider.id,
        providerName: providerDisplayName(provider.id, provider.displayName),
        source: "provider",
        label: plainText(String(metric.label || "Balance"), 64),
        value: value,
        valueText: formatAmount(value, metric.currency),
        currency: typeof metric.currency === "string" && metric.currency !== ""
          ? metric.currency : "",
        detail: plainText(String(metric.detail || ""), 160),
        available: metric.available !== false
      };
      if (usedPercent !== null) row.usedPercent = usedPercent;
      rows.push(row);
    }
  }
  return rows;
}

// Providers whose Limit windows or Balances are usable enough to answer
// "what stops my next prompt": a card with no percent and a Balance the
// router flags unavailable both count for nothing.
function usableAllowanceByProvider(sources) {
  var out = { limits: {}, funding: {} };
  var cards = buildLimitWindows(sources);
  for (var c = 0; c < cards.length; c++)
    if (cards[c].usedPercent !== null) out.limits[cards[c].providerId] = true;
  var rows = buildBalanceRows(sources);
  for (var r = 0; r < rows.length; r++)
    if (rows[r].available !== false) out.funding[rows[r].providerId] = true;
  return out;
}

// Account plan and operator-facing note, surfaced only when this provider's
// payload actually supplies them. The message is router prose, treated as
// plain text: control characters flattened, markup stripped, length clamped.
//
// Notes are informational by default (`urgent: false`). A note earns urgency
// only where the provider reports no usable Limit window and no usable
// Balance — the operator has nothing else telling them this provider will
// not serve. A `local-only` note is dropped outright once its provider's
// limits are on screen: it says the router only sees its own traffic, which
// the numbers above it now say better.
function buildAccountNotes(sources) {
  var providerUsage = sources && sources.providerUsage;
  var providerSetup = sources && sources.providerSetup;
  var allowance = usableAllowanceByProvider(sources);
  var notes = [];
  var configured = {};
  var setupProviders = providerSetup && Array.isArray(providerSetup.providers) ? providerSetup.providers : [];
  for (var s = 0; s < setupProviders.length; s++)
    if (setupProviders[s] && setupProviders[s].configured) configured[setupProviders[s].id] = true;

  var entries = providerUsage && Array.isArray(providerUsage.providers) ? providerUsage.providers : [];
  for (var u = 0; u < entries.length; u++) {
    var provider = entries[u];
    if (!provider || !configured[provider.id] || !provider.account) continue;
    var plan = plainText(String(provider.account.plan || ""), 64);
    var message = plainText(String(provider.account.message || ""), 320);
    if (plan === "" && message === "") continue;
    var hasLimits = allowance.limits[provider.id] === true;
    if (String(provider.account.status || "") === "local-only" && hasLimits) continue;
    notes.push({
      key: provider.id,
      providerId: provider.id,
      providerName: providerDisplayName(provider.id, provider.displayName),
      plan: plan,
      message: message,
      urgent: !hasLimits && allowance.funding[provider.id] !== true
    });
  }
  return notes;
}

// "12.50" / "4" / "1.25" — money and credit values keep up to two decimals;
// plain counters stay whole so "4 VCU" does not read as "4.00 VCU".
function formatAmount(value, currency) {
  var number = Number(value);
  if (!isFinite(number)) return "";
  var text = number.toFixed(2).replace(/\.00$/, "");
  return String(currency || "").toLowerCase() === "usd" ? number.toFixed(2) : text;
}

// Limit windows from every source that has them: the account_usage call when
// it answered, plus any provider_usage entry carrying account metrics.
// Deduped per provider+window so the same window never paints twice.
function buildLimitWindows(sources) {
  var account = sources && sources.account;
  var providerUsage = sources && sources.providerUsage;
  var providerSetup = sources && sources.providerSetup;
  var cards = [];
  var seen = {};

  function add(providerId, providerName, metric, source) {
    var win = limitWindow(metric);
    if (!win) return;
    var key = providerId + ":" + win.key;
    if (seen[key]) return;
    seen[key] = true;
    var resetAt = Number(metric.resetsAt !== undefined ? metric.resetsAt : metric.resetAt);
    cards.push({
      key: key,
      providerId: providerId,
      providerName: providerName,
      source: source,
      window: win.kind || win.key,
      label: win.label,
      usedPercent: metricPercent(metric),
      remainingPercent: metricRemainingPercent(metric),
      resetAt: isFinite(resetAt) && resetAt > 0 ? resetAt : null
    });
  }

  if (account && account.primary)
    add(ACCOUNT_PROVIDER_ID, providerDisplayName(ACCOUNT_PROVIDER_ID, ""), account.primary, "account");
  if (account && account.secondary)
    add(ACCOUNT_PROVIDER_ID, providerDisplayName(ACCOUNT_PROVIDER_ID, ""), account.secondary, "account");

  // Only providers the snapshot confirms as configured may contribute their
  // own quota rows — unconfigured entries carry stale cached numbers.
  var configured = {};
  var setupProviders = providerSetup && Array.isArray(providerSetup.providers) ? providerSetup.providers : [];
  for (var s = 0; s < setupProviders.length; s++)
    if (setupProviders[s] && setupProviders[s].configured) configured[setupProviders[s].id] = true;

  var entries = providerUsage && Array.isArray(providerUsage.providers) ? providerUsage.providers : [];
  for (var u = 0; u < entries.length; u++) {
    var provider = entries[u];
    if (!provider || !configured[provider.id]) continue;
    var metrics = provider.account && Array.isArray(provider.account.metrics) ? provider.account.metrics : [];
    for (var m = 0; m < metrics.length; m++)
      add(provider.id, providerDisplayName(provider.id, provider.displayName), metrics[m], "provider");
  }
  return cards;
}

// The Providers that earn a Usage pill. Carrying traffic is one way in; so is
// reporting a Limit window or a Balance, because an allowance nobody has spent
// yet is exactly the thing an operator opens this view to find (ADR-0002).
// The account provider earns its pill from the Account usage read alone —
// while that read is in flight it holds the slot for the answer.
function usageProviders(sources) {
  var providerUsage = sources && sources.providerUsage;
  var accountLoading = !!(sources && sources.accountLoading);
  var reports = {};
  var cards = buildLimitWindows(sources);
  for (var c = 0; c < cards.length; c++) reports[cards[c].providerId] = true;
  var rows = buildBalanceRows(sources);
  for (var r = 0; r < rows.length; r++) reports[rows[r].providerId] = true;

  var list = providerUsage && Array.isArray(providerUsage.providers) ? providerUsage.providers : [];
  var out = [];
  var seen = {};
  for (var i = 0; i < list.length; i++) {
    var provider = list[i];
    if (!provider) continue;
    var total = Number(provider.totalTokens) || 0;
    var requests = Number(provider.requests) || 0;
    if (total <= 0 && requests <= 0 && reports[provider.id] !== true) continue;
    seen[provider.id] = true;
    out.push({
      id: String(provider.id || ""),
      name: providerDisplayName(provider.id, provider.displayName),
      total: total,
      requests: requests,
      last24h: Number(provider.last24hTokens) || 0,
      last24hRequests: Number(provider.last24hRequests) || 0,
      buckets: Array.isArray(provider.dailyUsageBuckets) ? provider.dailyUsageBuckets : []
    });
  }

  if ((accountLoading || reports[ACCOUNT_PROVIDER_ID] === true)
      && seen[ACCOUNT_PROVIDER_ID] !== true)
    out.push({
      id: ACCOUNT_PROVIDER_ID,
      name: providerDisplayName(ACCOUNT_PROVIDER_ID, ""),
      total: 0,
      requests: 0,
      last24h: 0,
      last24hRequests: 0,
      buckets: []
    });

  out.sort(function(a, b) { return b.total - a.total; });
  return out;
}

// "Resets today at 6:30 PM" style countdown anchor.
function formatReset(unixSeconds, now) {
  var seconds = Number(unixSeconds);
  if (!isFinite(seconds) || seconds <= 0) return "Reset time unavailable";
  var date = new Date(seconds * 1000);
  var time = formatClock(date);
  if (localDateKey(date) === localDateKey(now)) return "Resets today at " + time;
  if (localDateKey(date) === localDateKey(new Date(now.getTime() + DAY_MS)))
    return "Resets tomorrow at " + time;
  return "Resets " + WEEKDAYS[date.getDay()] + ", " + MONTHS[date.getMonth()]
    + " " + date.getDate() + " at " + time;
}

// The tray's allowance surfaces answer the operator's question directly:
// how long until this window turns over. Returns "" when unusable so
// callers can fall back to formatReset's absolute form.
function formatResetIn(unixSeconds, now) {
  var seconds = Number(unixSeconds);
  if (!isFinite(seconds) || seconds <= 0) return "";
  var remainingMs = seconds * 1000 - now.getTime();
  if (!(remainingMs > 0)) return "Resets now";
  var totalMinutes = Math.floor(remainingMs / 60000);
  var days = Math.floor(totalMinutes / (24 * 60));
  var hours = Math.floor((totalMinutes % (24 * 60)) / 60);
  var minutes = totalMinutes % 60;
  if (days > 0) return "Resets in " + days + "d " + hours + "h";
  if (hours > 0) return "Resets in " + hours + "h " + minutes + "m";
  return "Resets in " + Math.max(1, minutes) + "m";
}

// Bucket rows are keyed by their startDate string everywhere; one lookup
// instead of a fresh scan at each call site.
function bucketFor(buckets, dateKey) {
  var list = Array.isArray(buckets) ? buckets : [];
  for (var i = 0; i < list.length; i++)
    if (String(list[i].startDate) === dateKey) return list[i];
  return null;
}

function bucketValue(buckets, dateKey, field) {
  var bucket = bucketFor(buckets, dateKey);
  return bucket ? (Number(bucket[field]) || 0) : 0;
}

function pad2(number) {
  return String(number).padStart(2, "0");
}

function formatClock(date) {
  var hours = date.getHours();
  var suffix = hours < 12 ? "AM" : "PM";
  var twelve = hours % 12;
  if (twelve === 0) twelve = 12;
  return twelve + ":" + pad2(date.getMinutes()) + " " + suffix;
}

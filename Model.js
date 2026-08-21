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
// 0.4.0-beta.4 but every accessor tolerates absence.

var DAY_MS = 24 * 60 * 60 * 1000;

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

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

// ChatGPT quota metrics arrive with prose labels ("5-hour window", "Weekly
// limit") or canonical durations; normalize both to one of three windows.
function quotaWindow(metric) {
  if (!metric || (metric.kind && metric.kind !== "quota")) return null;
  var label = String(metric.label || "").toLowerCase().replace(/[–—]/g, "-");
  var minutes = Number(metric.windowDurationMins);
  if (label.indexOf("5-hour") >= 0 || label.indexOf("5 hour") >= 0
      || label.indexOf("five-hour") >= 0 || minutes === 300)
    return { key: "five-hour", label: "5-hour limit" };
  if (label.indexOf("week") >= 0 || minutes === 10080)
    return { key: "weekly", label: "Weekly limit" };
  if (label.indexOf("month") >= 0 || minutes === 43200)
    return { key: "monthly", label: "Monthly limit" };
  return null;
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

// Quota cards from every source that has them: the account_usage call when it
// answered, plus any provider_usage entry carrying account metrics. Deduped
// per provider+window so the same window never paints twice.
function buildQuotaCards(sources) {
  var account = sources && sources.account;
  var providerUsage = sources && sources.providerUsage;
  var providerSetup = sources && sources.providerSetup;
  var cards = [];
  var seen = {};

  function add(providerId, providerName, metric, source) {
    var win = quotaWindow(metric);
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
      window: win.key,
      label: win.label,
      usedPercent: metricPercent(metric),
      remainingPercent: metricRemainingPercent(metric),
      resetAt: isFinite(resetAt) && resetAt > 0 ? resetAt : null
    });
  }

  if (account && account.primary) add("openai", "ChatGPT", account.primary, "account");
  if (account && account.secondary) add("openai", "ChatGPT", account.secondary, "account");

  // Only providers the snapshot confirms as configured may contribute their
  // own quota rows — unconfigured entries carry stale cached numbers.
  var configured = {};
  var setupProviders = providerSetup && Array.isArray(providerSetup.providers) ? providerSetup.providers : [];
  for (var s = 0; s < setupProviders.length; s++)
    if (setupProviders[s] && setupProviders[s].configured) configured[setupProviders[s].id] = true;

  var usageProviders = providerUsage && Array.isArray(providerUsage.providers) ? providerUsage.providers : [];
  for (var u = 0; u < usageProviders.length; u++) {
    var provider = usageProviders[u];
    if (!provider || !configured[provider.id]) continue;
    var metrics = provider.account && Array.isArray(provider.account.metrics) ? provider.account.metrics : [];
    for (var m = 0; m < metrics.length; m++)
      add(provider.id, provider.displayName || provider.id, metrics[m], "provider");
  }
  return cards;
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

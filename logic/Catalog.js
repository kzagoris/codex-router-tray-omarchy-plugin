// Derivation for the MODELS view: one snapshot in, one view model out.
//
// Every rule the view is easy to get wrong about lives here rather than in
// QML bindings — membership, grouping and sort, secondary text, proof
// badges, the picker/subagent interlock, the optimistic overrides and every
// count the sub-switcher and the group summaries show. ModelsView binds to
// what this returns; it does not branch on snapshot shapes.
//
// Semantics follow the router's own tray (apps/desktop/ui/app.js
// renderModelSettings) so two surfaces editing the same files agree about
// what they are showing:
//   - membership is `model.enabled`, which the router sets from the target's
//     enabled providers;
//   - picker visibility is the hidden list from modelSettings.picker;
//   - a model is subagent-on when it is visible, not explicitly switched
//     off, and either registry-proven (multiAgentVersion "v2") or promoted
//     by the mode the switch wrote: `all`, or `selected` for models on the
//     operator's own enabled list. `proven` promotes nothing of its own, so
//     the enabled list stays on screen only while a mode that reads it is
//     live — the same three-clause rule the router's applyMultiAgentSettings
//     applies.
//
// Presentation metadata rides in row fields only: a synthesized native
// context variant (`nativeClientManaged: false`) is a router-managed picker
// entry, not a separate subagent governance fact, and `isFree` is a price
// tag. Neither takes part in membership, counts, badges or the interlock —
// the badges stay exactly as 003/005 drew them.
//
// Plain script on purpose: QML loads this with `import "logic/Catalog.js"`,
// so no imports and no exports. Everything is defensive; router payloads are
// verified against 0.5.0 but every accessor tolerates absence.

var PICKER = "picker";
var SUBAGENTS = "subagents";

// Badge and tooltip ceilings. A failure reason is the router's own prose and
// can be long; the panel elides it to one line and shows the rest on hover,
// but nothing unbounded is handed to a Text item either way.
var BADGE_MAX = 200;
var TOOLTIP_MAX = 520;

// Everything the router says lands in a Text item, and none of it is markup.
// Same treatment RouterService.plainText applies to health payloads: control
// characters and newlines flattened, markup characters dropped, length
// clamped.
function plainText(value, max) {
  var text = String(value === undefined || value === null ? "" : value);
  text = text.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ");
  text = text.replace(/[<>&]/g, "");
  text = text.replace(/\s+/g, " ").trim();
  var limit = max > 0 ? max : 120;
  return text.length > limit ? text.slice(0, limit - 1) + "…" : text;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function asObject(value) {
  return value && typeof value === "object" ? value : {};
}

function setOf(list) {
  var set = {};
  var values = asArray(list);
  for (var i = 0; i < values.length; i++) set[String(values[i])] = true;
  return set;
}

// Provider display names, with the signed-in session's own fallback: the
// snapshot's provider list describes configurable providers and carries no
// entry for native models.
function providerNames(target) {
  var names = { openai: "OpenAI" };
  var providers = asArray(target.providers);
  for (var i = 0; i < providers.length; i++) {
    var provider = asObject(providers[i]);
    var id = String(provider.id || "");
    if (id === "") continue;
    names[id] = plainText(provider.displayName || id, 48);
  }
  return names;
}

// The catalog models this view is allowed to draw: everything whose provider
// the target has enabled. Models from disabled providers are absent, not
// dimmed — the empty state and the Providers view carry the explanation.
function listedModels(target) {
  var models = asArray(target.models);
  var out = [];
  for (var i = 0; i < models.length; i++) {
    var entry = asObject(models[i]);
    var slug = String(entry.slug || "");
    if (slug === "" || entry.enabled !== true) continue;
    out.push(entry);
  }
  return out;
}

function overrideFor(overrides, setting, slug) {
  var bucket = asObject(asObject(overrides)[setting]);
  return Object.prototype.hasOwnProperty.call(bucket, slug) ? bucket[slug] === true : null;
}

// Picker visibility, pending toggles first. The hidden list is the router's
// own record; `visible` on the model mirrors it and is the fallback for a
// payload that ever stops carrying one of the two.
function isVisible(entry, hidden, overrides) {
  var pending = overrideFor(overrides, PICKER, String(entry.slug));
  if (pending !== null) return pending;
  if (hidden[String(entry.slug)]) return false;
  return entry.visible !== false;
}

function isSubagentOn(entry, visible, subagentState, mode, overrides) {
  if (!visible) return false;
  var pending = overrideFor(overrides, SUBAGENTS, String(entry.slug));
  if (pending !== null) return pending;
  var slug = String(entry.slug);
  if (subagentState.disabled[slug]) return false;
  if (entry.multiAgentVersion === "v2") return true;
  return mode === "all" || (mode === "selected" && subagentState.selected[slug] === true);
}

// The registry's standing verdict, read before anything else: the router's
// `subagents set` guard refuses "v1" outright, and `multiAgentVersion` is
// what the router published after applying local settings — the two
// disagree by design, so only this field predicts the refusal.
function hasV1SubagentCertification(entry) {
  return String(asObject(entry).subagentCertification || "") === "v1";
}

// One concise picker caption for the two 0.5 facts an operator actually
// reads off a row: free routes and the synthesized native context variants
// that are not Codex's own picker entries. Picker-only on purpose — the
// Subagents surface is trying to reason about proof state, and the interlock
// badges must keep that slot.
function pickerCaption(entry) {
  var parts = [];
  if (asObject(entry).isFree === true) parts.push("Free");
  if (asObject(entry).nativeClientManaged === false)
    parts.push("Router-managed context variant");
  return parts.join(" · ");
}

// candidate / verified / checking / failed, plus legacy and interlock badges.
// Statuses follow the 0.5.0 proof lifecycle: a passing probe writes
// `candidate` until the registry certifies the route (its multiAgentVersion
// becomes "v2"). `experimental` and `proven` survive only as legacy records
// written by 0.4 and no longer promote anything. The reason is the router's,
// so a failure can be acted on instead of guessed at.
function proofBadge(entry, visible, proof) {
  if (!visible) return { kind: "hidden", text: "Hidden in picker", tooltip: "", urgent: false };
  if (hasV1SubagentCertification(entry))
    return {
      kind: "v1-certified",
      text: "Certified v1 - cannot be a native v2 subagent",
      tooltip: "",
      urgent: false
    };
  // The registry's own claim outranks any local record: a certifying entry
  // (multiAgentVersion "v2") is proven even while its machine proof waits, and
  // a stale local record cannot take that away.
  if (entry.multiAgentVersion === "v2")
    return { kind: "proven", text: "Proven v2", tooltip: "", urgent: false };
  var status = String(asObject(proof).status || "");
  if (status === "checking")
    return { kind: "checking", text: "Working…", tooltip: "", urgent: false };
  if (status === "failed") {
    var reason = plainText(asObject(proof).reason || "untested", TOOLTIP_MAX);
    return {
      kind: "failed",
      text: plainText("Error: " + reason, BADGE_MAX),
      tooltip: plainText("Error: " + reason, TOOLTIP_MAX),
      urgent: true
    };
  }
  if (status === "candidate")
    return { kind: "candidate", text: "Probe passed — awaiting certification", tooltip: "", urgent: false };
  if (status === "verified")
    return { kind: "verified", text: "Certified on this machine", tooltip: "", urgent: false };
  if (status === "experimental")
    return { kind: "legacy-experimental", text: "Legacy evidence, not a v2 claim", tooltip: "", urgent: false };
  if (status === "proven")
    return { kind: "legacy-proven", text: "Legacy evidence, not a v2 claim", tooltip: "", urgent: false };
  return { kind: "untested", text: "Untested", tooltip: "", urgent: false };
}

// The view model. `options` carries the sub-switcher's setting
// ("picker" | "subagents"), the optimistic overrides keyed
// {picker: {slug: bool}, subagents: {slug: bool}}, and the session-scoped
// collapse state keyed by provider id.
function viewModel(target, options) {
  var settings = asObject(options);
  var setting = settings.setting === SUBAGENTS ? SUBAGENTS : PICKER;
  var overrides = asObject(settings.overrides);
  var collapsed = asObject(settings.collapsed);

  var snapshot = asObject(target);
  var modelSettings = asObject(snapshot.modelSettings);
  var subagentSettings = asObject(modelSettings.subagents);
  var subagentState = {
    disabled: setOf(subagentSettings.disabled),
    selected: setOf(subagentSettings.enabled)
  };
  var subagentMode = String(subagentSettings.mode || "proven");
  var proofs = asObject(subagentSettings.proofs);
  var hidden = setOf(asObject(modelSettings.picker).hidden);
  var names = providerNames(snapshot);

  var totals = { models: 0, pickerVisible: 0, subagentsOn: 0 };
  var anyChecking = false;
  var byProvider = {};
  var order = [];

  var models = listedModels(snapshot);
  for (var i = 0; i < models.length; i++) {
    var entry = models[i];
    var slug = String(entry.slug);
    var providerId = String(entry.provider || "unknown");
    var visible = isVisible(entry, hidden, overrides);
    var subagentOn = isSubagentOn(entry, visible, subagentState, subagentMode, overrides);
    var proof = asObject(proofs[slug]);
    var badge = proofBadge(entry, visible, proof);
    var v1SubagentCertified = hasV1SubagentCertification(entry);

    totals.models++;
    if (visible) totals.pickerVisible++;
    if (subagentOn) totals.subagentsOn++;

    var pickerRow = setting === PICKER;
    var row = {
      slug: slug,
      displayName: plainText(entry.displayName || slug, 64),
      providerId: providerId,
      secondary: pickerRow ? plainText(slug, 96) : badge.text,
      caption: pickerRow ? pickerCaption(entry) : "",
      badgeKind: pickerRow ? "" : badge.kind,
      badgeTooltip: pickerRow ? "" : badge.tooltip,
      badgeUrgent: pickerRow ? false : badge.urgent,
      on: pickerRow ? visible : subagentOn,
      // The interlock is shown, not worked around: a hidden model keeps its
      // row and its explanation, and its subagent toggle is inert rather
      // than silently unhiding the model.
      // Repository v1 is the second interlock. Where both apply, the picker
      // wins, because unhiding is the action that is actually available.
      interlocked: !pickerRow && (!visible || v1SubagentCertified),
      interlockActionable: !pickerRow && !visible,
      interlockTooltip: !pickerRow && !visible
        ? "Hidden in the picker — open Picker to show it again."
        : (!pickerRow && v1SubagentCertified
            ? "Certified v1 — this catalog model cannot be a native v2 subagent."
            : ""),
      toggleEnabled: pickerRow || (visible && !v1SubagentCertified),
      // Only a badge somebody is looking at earns the short-interval
      // re-read: Picker draws no badge, and a collapsed group draws no row.
      checking: !pickerRow && visible && String(proof.status || "") === "checking"
    };

    if (!byProvider[providerId]) {
      byProvider[providerId] = [];
      order.push(providerId);
    }
    byProvider[providerId].push(row);
  }

  order.sort(function(left, right) {
    return left < right ? -1 : (left > right ? 1 : 0);
  });

  var groups = [];
  for (var g = 0; g < order.length; g++) {
    var id = order[g];
    var rows = byProvider[id];
    rows.sort(function(left, right) {
      return left.slug < right.slug ? -1 : (left.slug > right.slug ? 1 : 0);
    });
    var onCount = 0;
    for (var r = 0; r < rows.length; r++) {
      if (rows[r].on) onCount++;
      if (rows[r].checking && collapsed[id] !== true) anyChecking = true;
    }
    groups.push({
      providerId: id,
      providerName: names[id] || id,
      collapsed: collapsed[id] === true,
      total: rows.length,
      onCount: onCount,
      summary: onCount + "/" + rows.length + (setting === PICKER ? " visible" : " on"),
      models: rows
    });
  }

  return {
    setting: setting,
    empty: totals.models === 0,
    mode: subagentMode,
    allCatalogModels: subagentMode === "all",
    hasSelection: asArray(subagentSettings.enabled).length > 0,
    anyChecking: anyChecking,
    totals: totals,
    groups: groups
  };
}

// Sub-switcher labels: the setting that is not being edited stays legible.
function switcherLabel(setting, totals) {
  var counts = asObject(totals);
  var total = Number(counts.models) || 0;
  if (setting === SUBAGENTS) return "Subagents " + (Number(counts.subagentsOn) || 0) + "/" + total;
  return "Picker " + (Number(counts.pickerVisible) || 0) + "/" + total;
}

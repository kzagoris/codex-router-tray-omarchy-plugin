import QtQuick

// Live router state, polled from the bar widget.
//
// Facade over Router I/O. RouterIoAdapter owns loopback HTTP, capability
// authentication, request tracking, size limits, auth replay and the secure
// web-panel handoff. Reads travel through its raw callback contract.
//
// It owns interpretation: payload shaping, polling cadence and derived state.
// Control CLI mutations are composed beside this reader in BarWidget.qml.
Item {
  id: root

  // Poll cadence and target. Port follows the router's own resolution
  // order: explicit setting wins, then MODEL_ROUTER_PORT, then 4202.
  property int healthIntervalSec: 4
  property int dataIntervalSec: 30
  readonly property int healthCadenceMs: Math.max(2, root.healthIntervalSec) * 1000
  readonly property int dataCadenceMs: Math.max(15, root.dataIntervalSec) * 1000
  readonly property int lifecycleRecoveryDelayMs: 3000
  // Composed by BarWidget. The adapter owns timer mechanics and wall-clock
  // access; this reader decides when each cadence is useful.
  required property var clock
  // Production composition supplies RouterIoAdapter; QML tests supply a
  // scripted adapter with the same raw callback contract.
  required property var io
  // Slow ChatGPT quota call; off until the user asks for it.
  property bool accountUsageEnabled: false

  // The capability secret never crosses this boundary. Consumers only learn
  // whether authenticated effects are available.
  readonly property bool hasCallerSecret: !!root.io && root.io.hasCallerSecret

  // Re-read a caller key that was missing at startup. Reader-driven: the
  // panel asks on open and on Refresh, nothing polls (see InvokeClient).
  function recheckCallerSecret() {
    root.io.recheckCallerSecret()
  }

  // A capability can arrive after a View has declared its reader demand. The
  // demand itself, rather than this notification, decides whether that unlocks
  // a read: a hidden View must not be resurrected by a late secret.
  onHasCallerSecretChanged: {
    if (root.hasCallerSecret) root.consumePendingDemand()
  }

  // Last successfully parsed /health payload; null means the router was
  // never reached (or the answer was unusable) — the offline state.
  property var health: null

  // Authenticated reads. Null = never fetched or last fetch failed.
  property var snapshot: null
  property var providerSetup: null
  property var providerUsage: null

  // account_usage rides on its own request and its own loading flag: it is
  // a slow upstream call that times out now and then (PLAN.md §2.2), so its
  // failure must not read as a general data failure nor hold any other
  // section's refresh hostage.
  property var accountUsage: null
  property bool accountUsageFailed: false
  property bool accountUsageLoading: false

  // First error from the shared data commands, message truncated to 500
  // chars like the tray does. Empty = last round had no shared failure;
  // individual payloads still update around it.
  property string dataError: ""
  property bool dataLoading: false
  // Wall-clock of the last round that produced any fresh payload.
  property double lastUpdatedAt: 0
  // Monotonic counter of read rounds, incremented as each one *begins*. A
  // consumer that has just changed something needs to know a payload was
  // read after its change landed, and a round that merely finishes late
  // cannot answer for it. A counter rather than a clock: two rounds can
  // begin in the same millisecond.
  property int dataRound: 0

  // Set by the panel while its popup is up: the authenticated endpoints are
  // only polled for a reader, never behind a closed panel.
  property bool panelOpen: false

  // The expanding caller contract. A caller declares whether it has a reader
  // and which View is visible; later workflow tickets turn that declaration
  // into View-specific demand. `panelOpen` remains for the unchanged callers
  // during this compatibility step.
  property bool readerPresent: false
  property string activeView: "Status"
  property bool _normalizingActiveView: false
  // Later Models migration declares this while a visible Proof is checking.
  // It is here now so staged checking demand has the same cancellation rule as
  // the other visibility work.
  property bool checkingProofVisible: false

  // Intents remain typed while prerequisites or an earlier read block them.
  // Operator reconciliation is keyed by origin so two mutations cannot erase
  // each other; visibility work is keyed by kind and its current View.
  property var _pendingDemands: []
  property string _lifecycleRecoveryOrigin: "Status"
  // Stable diagnostic for lifecycle callers: its value is captured when the
  // service command settles, never sampled when the delayed recovery fires.
  readonly property string lifecycleRecoveryOrigin: root._lifecycleRecoveryOrigin

  onReaderPresentChanged: {
    if (!root.readerPresent) {
      root.cancelInvisibleDemand()
      return
    }
    root.recheckCallerSecret()
    root.pollHealth()
    root.requestViewEntry(root.activeView)
  }
  onActiveViewChanged: {
    if (root._normalizingActiveView) return
    if (!root.isSupportedView(root.activeView)) {
      console.warn("codex-router-tray", "Unsupported Router reader View:", root.activeView)
      root._normalizingActiveView = true
      root.activeView = "Status"
      root._normalizingActiveView = false
      return
    }
    if (!root.readerPresent) return
    root.cancelInvisibleDemand()
    root.pollHealth()
    root.requestViewEntry(root.activeView)
  }
  onPanelOpenChanged: if (!root.panelOpen) root.cancelInvisibleDemand()
  onCheckingProofVisibleChanged: if (!root.checkingProofVisible) root.cancelInvisibleDemand()

  readonly property bool online: !!health && health.ok === true
  readonly property var activity: health && health.activity ? health.activity : {}

  // One of "offline" | "generating" | "error" | "idle" — the four states
  // every consumer (dot, tooltip, hero meta) speaks. Degraded providers
  // surface as their own flag rather than a fifth state: the router keeps
  // serving while degraded, it just wants attention.
  //
  // Renamed away from `state`: shadowing QQuickItem's writable `state`
  // property makes tooling (and readers) trip over which one wins.
  readonly property string routerState: {
    if (!root.online) return "offline"
    if (degraded || String(activity.state || "") === "error") return "error"
    if (String(activity.state || "") === "generating") return "generating"
    return "idle"
  }

  readonly property bool degraded: {
    if (!root.health) return false
    return Array.isArray(root.health.degraded) && root.health.degraded.length > 0
  }
  readonly property var degradedNames: {
    if (!root.health || !Array.isArray(root.health.degraded)) return []
    return root.health.degraded.map(function(name) { return root.plainText(name, 48) })
  }

  readonly property int activeCount: Number(activity.activeCount) || 0
  readonly property var activeRequests: Array.isArray(activity.active) ? activity.active : []

  // Last (or currently) routing provider — what the optional bar label shows.
  // Latched on data arrival (not in a binding): the idle payload carries no
  // provider, so without the latch the label would flap between "Codex
  // Router" and a provider id on every request, resizing the bar slot each
  // time. Cleared only when offline.
  property string lastProviderName: ""
  readonly property string providerName: root.online ? lastProviderName : ""

  readonly property string version: root.health ? root.plainText(health.version, 32) : ""

  // Stable, bar-facing Router projection. Keep this object in place and bind
  // individual facts, so a health event notifies only the facts it changes.
  QtObject {
    id: routerSummaryProjection

    property bool online: false
    readonly property bool capabilityAvailable: root.hasCallerSecret
    property string routerState: "offline"
    property bool degraded: false
    property var degradedNames: []
    property var activeRequests: []
    property int activeCount: 0
    property string providerName: ""
    property string version: ""
  }
  readonly property var routerSummary: routerSummaryProjection

  // The codex target block of the snapshot — everything the mode switches
  // and provider toggles reflect. Empty object until the first read lands;
  // one home for the shaping so no view re-derives it.
  readonly property var codexTarget: {
    var targets = root.snapshot && root.snapshot.targets ? root.snapshot.targets : null
    return targets && targets.codex ? targets.codex : {}
  }

  // Top-level overview facts the Status view reads once, shaped here so the
  // view binds to names rather than snapshot paths. chatgptSession rides in
  // the same overview snapshot as `catalog`; old routers omit both.
  readonly property var chatgptSession: root.snapshot && root.snapshot.chatgptSession
    ? root.snapshot.chatgptSession : ({})
  readonly property var catalog: root.snapshot && root.snapshot.catalog
    ? root.snapshot.catalog : ({})

  // Everything the router says eventually lands in a Text item or in the
  // shell's shared tooltip, and neither should interpret it as markup: Qt's
  // default AutoText sniffs strings for rich text, so a provider name
  // carrying tags could draw into the bar or reference an external <img>
  // source. Text items in this plugin pin textFormat to PlainText; the
  // tooltip belongs to the shell, so router-derived values are stripped
  // here instead -- markup characters dropped, control characters and
  // newlines flattened, and the length clamped so an enormous string cannot
  // stretch a bar slot.
  function plainText(value, max) {
    var text = String(value === undefined || value === null ? "" : value)
    text = text.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
    text = text.replace(/[<>&]/g, "")
    text = text.replace(/\s+/g, " ").trim()
    var limit = max > 0 ? max : 120
    return text.length > limit ? text.slice(0, limit - 1) + "…" : text
  }

  function isSupportedView(view) {
    return ["Status", "Usage", "Providers", "Models"].indexOf(String(view)) !== -1
  }

  function demandPriority(kind) {
    if (kind === "refresh") return 3
    if (kind === "checking-proof") return 2
    if (kind === "reconciliation") return 2
    return 1
  }

  function isVisibilityDemand(demand) {
    return demand && (demand.kind === "view-entry" || demand.kind === "cadence"
      || demand.kind === "checking-proof")
  }

  function demandIsStillVisible(demand) {
    if (!root.isVisibilityDemand(demand)) return true
    if (!(root.readerPresent || root.panelOpen)) return false
    if (demand.view !== root.activeView) return false
    return demand.kind !== "checking-proof" || root.checkingProofVisible
  }

  function cancelInvisibleDemand() {
    root._pendingDemands = root._pendingDemands.filter(function(demand) {
      return !root.isVisibilityDemand(demand) || root.demandIsStillVisible(demand)
    })
  }

  function demandKey(demand) {
    if (demand.kind === "reconciliation") return "reconciliation:" + demand.view
    if (demand.kind === "view-entry") return "view-entry"
    if (demand.kind === "cadence") return "cadence"
    if (demand.kind === "checking-proof") return "checking-proof:" + demand.view
    return demand.kind
  }

  function stageDemand(kind, view) {
    var demand = {
      kind: kind,
      view: view || root.activeView,
      trailing: root.dataLoading
    }
    if (root.isVisibilityDemand(demand) && !root.demandIsStillVisible(demand)) return
    var key = root.demandKey(demand)
    var next = root._pendingDemands.filter(function(existing) {
      return root.demandKey(existing) !== key
    })
    next.push(demand)
    root._pendingDemands = next
    root.consumePendingDemand()
  }

  function consumePendingDemand() {
    root.cancelInvisibleDemand()
    if (root.dataLoading || !root.online || !root.hasCallerSecret) return false
    var selected = -1
    for (var index = 0; index < root._pendingDemands.length; index++) {
      var candidate = root._pendingDemands[index]
      if (selected < 0 || root.demandPriority(candidate.kind)
          > root.demandPriority(root._pendingDemands[selected].kind)) selected = index
    }
    if (selected < 0) return false
    var demand = root._pendingDemands[selected]
    var next = root._pendingDemands.slice()
    next.splice(selected, 1)
    // Every queued demand that arrived while the current shared recipe was
    // active is answered by one trailing shared recipe. Their typed records
    // remain cancellable until this point; after dispatch, that one read is
    // the coherent post-round answer for all of them.
    if (demand.trailing) {
      next = next.filter(function(existing) { return !existing.trailing })
    }
    // Refresh is the operator's complete read intent. Once it actually starts,
    // queued visibility reads are satisfied by that same round; retained
    // reconciliation intents remain independent and therefore survive.
    if (demand.kind === "refresh") {
      next = next.filter(function(existing) { return !root.isVisibilityDemand(existing) })
    }
    root._pendingDemands = next
    root.dispatchDemand(demand)
    return true
  }

  function requestViewEntry(view) {
    if (!(root.readerPresent || root.panelOpen) || !root.isSupportedView(view)) return
    root.stageDemand("view-entry", view)
  }

  // Public semantic intents. The broad effect recipe remains intentionally
  // legacy-shaped until ticket 15 defines Refresh completeness and ticket 16
  // maps real mutation outcomes to reconciliation recipes.
  function requestRefresh() { root.stageDemand("refresh", root.activeView) }
  function requestReconciliation(originatingView) {
    root.stageDemand("reconciliation", originatingView)
  }
  function requestCheckingProof(view) {
    root.stageDemand("checking-proof", view)
  }
  function requestCadence() { root.stageDemand("cadence", root.activeView) }

  function dispatchDemand(demand) {
    root.dispatchDataRecipe(demand)
  }

  function semanticallyEqual(left, right) {
    if (left === right) return true
    if (left === null || right === null || left === undefined || right === undefined)
      return false
    if (typeof left !== typeof right || typeof left !== "object") return false
    if (Array.isArray(left) !== Array.isArray(right)) return false
    if (Array.isArray(left)) {
      if (left.length !== right.length) return false
      for (var i = 0; i < left.length; i++)
        if (!root.semanticallyEqual(left[i], right[i])) return false
      return true
    }
    var leftKeys = Object.keys(left).sort()
    var rightKeys = Object.keys(right).sort()
    if (leftKeys.length !== rightKeys.length) return false
    for (var keyIndex = 0; keyIndex < leftKeys.length; keyIndex++) {
      var key = leftKeys[keyIndex]
      if (key !== rightKeys[keyIndex] || !root.semanticallyEqual(left[key], right[key]))
        return false
    }
    return true
  }

  function updateRouterSummary() {
    if (routerSummaryProjection.online !== root.online)
      routerSummaryProjection.online = root.online
    if (routerSummaryProjection.routerState !== root.routerState)
      routerSummaryProjection.routerState = root.routerState
    if (routerSummaryProjection.degraded !== root.degraded)
      routerSummaryProjection.degraded = root.degraded
    if (routerSummaryProjection.activeCount !== root.activeCount)
      routerSummaryProjection.activeCount = root.activeCount
    if (routerSummaryProjection.providerName !== root.providerName)
      routerSummaryProjection.providerName = root.providerName
    if (routerSummaryProjection.version !== root.version)
      routerSummaryProjection.version = root.version
    var names = root.degradedNames
    if (!root.semanticallyEqual(routerSummaryProjection.degradedNames, names))
      routerSummaryProjection.degradedNames = names
    var requests = root.activeRequests
    if (!root.semanticallyEqual(routerSummaryProjection.activeRequests, requests))
      routerSummaryProjection.activeRequests = requests
  }

  // ------------------------------------------------------------- reading

  function pollHealth() {
    root.io.fetchHealth(applyHealth)
  }

  function applyHealth(status, text) {
    if (status !== 200) {
      // Unreachable or unhappy: drop the last known payload wholesale so
      // "offline" always means "not trusting stale data".
      root.health = null
      root.updateRouterSummary()
      root.consumePendingDemand()
      return
    }
    try {
      var parsed = JSON.parse(String(text))
      root.health = parsed && typeof parsed === "object" ? parsed : null
      if (root.online) {
        var live = root.plainText(root.activity.provider, 48)
        if (live !== "") root.lastProviderName = live
      }
      root.updateRouterSummary()
      root.consumePendingDemand()
    } catch (e) {
      console.warn("codex-router-tray", "Bad /health payload:", e)
      root.health = null
      root.updateRouterSummary()
    }
  }

  // Expand-step compatibility for legacy callers and tests. Production Panel,
  // cadence and mutation paths declare narrower semantic intents above.
  // This alias means explicit operator Refresh; ticket 15 defines its complete
  // all-facts recipe.
  function refreshData() {
    root.requestRefresh()
  }

  function dispatchDataRecipe(demand) {
    if (!root.online || !root.hasCallerSecret) return

    root.dataLoading = true
    root.dataRound++
    var rounds = [{ command: "control_snapshot", prop: "snapshot" },
                  { command: "provider_setup", prop: "providerSetup" },
                  { command: "provider_usage", prop: "providerUsage" }]

    var pending = rounds.length
    var gotFresh = false
    var firstSharedError = ""
    var roundOpen = true

    function receive(round, value, error) {
      if (error === null) {
        gotFresh = true
        root[round.prop] = value
      } else if (firstSharedError === "") {
        firstSharedError = error
      }

      // A retry parked by a mid-round rotation can land after the round
      // closed: its fresh payload still lands above, but it must not touch
      // bookkeeping that belongs to whichever round is now current.
      if (!roundOpen) return
      pending--
      if (pending > 0) return
      roundOpen = false
      root.dataLoading = false
      root.dataError = firstSharedError
      if (gotFresh) root.lastUpdatedAt = root.clock.now()
      root.consumePendingDemand()
    }

    function receiverFor(round) {
      return function(value, error) { receive(round, value, error) }
    }

    for (var i = 0; i < rounds.length; i++)
      root.io.invoke(rounds[i].command, {}, receiverFor(rounds[i]))

    refreshAccountUsage()
  }

  // Fully independent: own flag, no share of dataLoading/pending, so a hung
  // quota call never disables Refresh or freezes the footer (PLAN.md §5).
  function refreshAccountUsage() {
    if (!root.accountUsageEnabled || root.accountUsageLoading) return
    if (!root.online || !root.hasCallerSecret) return

    root.accountUsageLoading = true
    root.io.invoke("account_usage", {}, function(value, error) {
      root.accountUsageLoading = false
      root.accountUsageFailed = error !== null
      if (error === null) root.accountUsage = value
    })
  }

  // A Control CLI service command restarts the Router. The reader owns the
  // recovery policy (including the delay); the clock only owns elapsed time.
  function reconcileAfterServiceCommand(originatingView) {
    root._lifecycleRecoveryOrigin = root.isSupportedView(originatingView)
      ? originatingView : root.activeView
    cadence.scheduleRecovery()
  }

  // ------------------------------------------------------- web panel link

  // The capability URL and browser handoff stay in the I/O adapter. The
  // reader declares only the semantic request and its online fact.
  function openWebPanel() {
    return root.io.openWebPanel(root.online)
  }

  // -------------------------------------------------------- clock adapter

  // The health cadence is always useful for the bar widget. Authenticated
  // data cadence is useful only for an open, reachable Panel.
  RouterCadence {
    id: cadence
    clock: root.clock
    healthIntervalMs: root.healthCadenceMs
    dataIntervalMs: root.dataCadenceMs
    lifecycleDelayMs: root.lifecycleRecoveryDelayMs
    // Router health remains live for the bar widget even when the Panel is
    // closed; this is reader policy, not a clock default.
    healthCadenceActive: true
    dataCadenceActive: (root.panelOpen || root.readerPresent)
      && root.online && root.hasCallerSecret

    onHealthCadenceDue: root.pollHealth()
    onDataCadenceDue: {
      root.requestCadence()
    }
    onRecoveryDelayDue: {
      root.pollHealth()
      root.requestReconciliation(root._lifecycleRecoveryOrigin)
    }
  }
}

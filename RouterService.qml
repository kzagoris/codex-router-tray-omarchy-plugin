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

  // The read lands asynchronously, after the refresh that asked for it has
  // already given up for want of a key. The data cadence has no start trigger,
  // so without this the panel would sit empty for a whole data interval
  // after the key it was waiting for arrived.
  onHasCallerSecretChanged: if (root.hasCallerSecret && root.panelOpen) root.refreshData()

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
  // Set when a refresh was asked for mid-round (a mutation finishing while
  // the interval read is still in flight) and consumed when the round
  // closes, so "mutate, then re-read" can never be silently dropped.
  property bool _refreshPending: false
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

  // ------------------------------------------------------------- reading

  function pollHealth() {
    root.io.fetchHealth(applyHealth)
  }

  function applyHealth(status, text) {
    if (status !== 200) {
      // Unreachable or unhappy: drop the last known payload wholesale so
      // "offline" always means "not trusting stale data".
      root.health = null
      return
    }
    try {
      var parsed = JSON.parse(String(text))
      root.health = parsed && typeof parsed === "object" ? parsed : null
      if (root.online) {
        var live = root.plainText(root.activity.provider, 48)
        if (live !== "") root.lastProviderName = live
      }
    } catch (e) {
      console.warn("codex-router-tray", "Bad /health payload:", e)
      root.health = null
    }
  }

  // Refreshes snapshot/provider_setup/provider_usage (+account_usage when
  // enabled, independently). Called on panel open and on the data interval
  // while open. Production composition also calls it after mutations.
  function refreshData() {
    if (!root.online || !root.hasCallerSecret) return
    if (root.dataLoading) {
      root._refreshPending = true
      return
    }

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
      // A mutation landed while this round was flying: its re-read was
      // parked, and this is where it finally runs.
      if (root._refreshPending) {
        root._refreshPending = false
        refreshData()
      }
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
  function reconcileAfterServiceCommand() {
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
    dataCadenceActive: root.panelOpen && root.online && root.hasCallerSecret

    onHealthCadenceDue: root.pollHealth()
    onDataCadenceDue: {
      root.refreshData()
      root.refreshAccountUsage()
    }
    onRecoveryDelayDue: {
      root.pollHealth()
      root.refreshData()
    }
  }
}

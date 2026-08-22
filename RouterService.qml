import QtQuick
import Quickshell
import Quickshell.Io

// Live router state, polled from the bar widget.
//
// Facade over two transports with different failure models:
//   - InvokeClient owns loopback HTTP — capability authentication, request
//     tracking, size limits, the auth retry. Reads go through the same
//     command bridge the router's browser panel uses.
//   - ControlProcess owns control CLI spawning — resolved interpreter and
//     script path, environment, timeouts and the serialized mutation queue.
//     The only path by which this plugin mutates anything.
//
// This file keeps the property and function names every consumer (bar
// widget, views) already binds to, so the transport split costs no changes
// on the other side of the seam. It owns interpretation: payload shaping,
// polling cadence, derived state and the "mutate, then re-read" policy.
Item {
  id: root

  // Poll cadence and target. Port follows the router's own resolution
  // order: explicit setting wins, then MODEL_ROUTER_PORT, then 4202.
  property int healthIntervalSec: 4
  property int dataIntervalSec: 30

  // Settings overrides; empty string means "use the router's default".
  property string portOverride: ""
  property string stateDirOverride: ""
  property string sourceRootOverride: ""
  // Slow ChatGPT quota call; off until the user asks for it.
  property bool accountUsageEnabled: false

  readonly property string _envPort: Quickshell.env("MODEL_ROUTER_PORT") || ""
  property string port: {
    if (root.portOverride !== "") return root.portOverride
    return /^\d+$/.test(root._envPort) ? root._envPort : "4202"
  }

  // The state dir carries the caller capability. No env fallback exists on
  // the router side for this one — only the documented default path.
  readonly property string stateDir: {
    if (root.stateDirOverride !== "") return root.stateDirOverride
    var home = Quickshell.env("HOME") || ""
    return home !== "" ? home + "/.codex/codex-router" : ""
  }

  // Budget for one /health answer, derived from the poll cadence so a
  // merely-slow response is never dropped as stale (see InvokeClient).
  readonly property int healthTimeoutMs: Math.max(2000, Math.max(2, root.healthIntervalSec) * 1000 - 250)

  InvokeClient {
    id: invokeClient
    port: root.port
    stateDir: root.stateDir
    healthTimeoutMs: root.healthTimeoutMs
  }

  ControlProcess {
    id: controlProcess
    sourceRootOverride: root.sourceRootOverride

    // Mutate, then re-read — the one place that policy lives. Service
    // commands bounce the daemon, so an immediate read would race it; one
    // delayed kick covers start/stop/restart and the regular timers heal
    // anything still settling.
    onJobSucceeded: function(args) {
      if (controlProcess.isServiceCommand(args)) {
        serviceRefreshTimer.restart()
      } else {
        root.pollHealth()
        root.refreshData()
      }
    }
  }

  // Facade surface for what the transports own but consumers read here.
  readonly property alias callerSecret: invokeClient.callerSecret
  readonly property alias hasCallerSecret: invokeClient.hasCallerSecret
  readonly property alias mutationRunning: controlProcess.mutationRunning
  readonly property alias mutationLabel: controlProcess.mutationLabel
  readonly property alias mutationError: controlProcess.mutationError

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
    invokeClient.fetchHealth(applyHealth)
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
  // enabled, independently). Called on panel open, on the data interval
  // while open, and after every mutation (see ControlProcess.onJobSucceeded).
  function refreshData() {
    if (!root.online || !root.hasCallerSecret) return
    if (root.dataLoading) {
      root._refreshPending = true
      return
    }

    root.dataLoading = true
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
      if (gotFresh) root.lastUpdatedAt = Date.now()
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
      invoke(rounds[i].command, {}, receiverFor(rounds[i]))

    refreshAccountUsage()
  }

  // Fully independent: own flag, no share of dataLoading/pending, so a hung
  // quota call never disables Refresh or freezes the footer (PLAN.md §5).
  function refreshAccountUsage() {
    if (!root.accountUsageEnabled || root.accountUsageLoading) return
    if (!root.online || !root.hasCallerSecret) return

    root.accountUsageLoading = true
    invoke("account_usage", {}, function(value, error) {
      root.accountUsageLoading = false
      root.accountUsageFailed = error !== null
      if (error === null) root.accountUsage = value
    })
  }

  function invoke(command, args, onDone) {
    invokeClient.invoke(command, args, onDone)
  }

  // ------------------------------------------------------------ mutations

  function runControl(label, args, onDone) {
    controlProcess.runControl(label, args, onDone)
  }

  // Kept on the facade because consumers key offline behaviour off it; the
  // answer itself belongs to the CLI vocabulary in ControlProcess.
  function isServiceCommand(args) {
    return controlProcess.isServiceCommand(args)
  }

  function commandBudgetMs(args) {
    return controlProcess.commandBudgetMs(args)
  }

  // ------------------------------------------------------- web panel link

  // The plugin's bin/panel: hand the capability URL to xdg-open, gated the
  // same way bin/panel gates itself (no key, no router — no browser). The
  // URL travels through stdin to a fixed command instead of argv: quickshell
  // logs the whole command when a binary fails to start, and that log line
  // must never contain the secret.
  function openWebPanel() {
    if (!root.hasCallerSecret) {
      console.warn("codex-router-tray", "No caller key — cannot open the web panel.")
      return false
    }
    if (!root.online) {
      console.warn("codex-router-tray", "Router offline — not opening the web panel.")
      return false
    }
    if (webPanelOpener.running) return true
    webPanelOpener.running = true
    // Spawn is synchronous, so the pipe exists by this line.
    webPanelOpener.write(invokeClient.callerUrl("panel/") + "\n")
    return true
  }

  Process {
    id: webPanelOpener
    running: false
    command: ["sh", "-c", "read -r url && exec xdg-open \"$url\""]

    stderr: StdioCollector {
      waitForEnd: true
      // Generic on purpose: opener diagnostics name no URLs.
      onStreamFinished: if (text.trim() !== "") console.warn("codex-router-tray", "xdg-open failed")
    }
  }

  // --------------------------------------------------------------- timers

  onHealthIntervalSecChanged: healthTimer.restart()

  // triggeredOnStart covers the first poll; no Component.onCompleted kick.
  Timer {
    id: healthTimer
    interval: Math.max(2, root.healthIntervalSec) * 1000
    running: true
    triggeredOnStart: true
    repeat: true
    onTriggered: root.pollHealth()
  }

  Timer {
    id: dataTimer
    interval: Math.max(15, root.dataIntervalSec) * 1000
    running: root.panelOpen && root.online && root.hasCallerSecret
    repeat: true
    onTriggered: {
      root.refreshData()
      root.refreshAccountUsage()
    }
  }

  // Service commands bounce the daemon; PLAN §4 still wants a refresh after
  // every action. One delayed kick after start/stop/restart — anything that
  // is still settling is healed by the regular poll timers.
  Timer {
    id: serviceRefreshTimer
    interval: 3000
    repeat: false
    onTriggered: {
      root.pollHealth()
      root.refreshData()
    }
  }
}

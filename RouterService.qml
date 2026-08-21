import QtQuick
import Quickshell

// Live router state, polled from the bar widget.
//
// Owns everything that talks to the codex-router HTTP surface. Phase 2
// carries only the unauthenticated /health poll; the authenticated
// panel/invoke bridge and the control CLI runner arrive with phases 3-4
// behind the same instance, so consumers bind to one object.
//
// Health payload shape (verified against codex-router 0.4.0-beta.4):
//   { ok, service, version, degraded: [name...],
//     activity: { state: "generating"|"error"|"idle", activeCount,
//                 active: [{id, provider, model, sessionName, startedAt}],
//                 provider, model, sessionName } }
Item {
  id: root

  // Poll cadence and target. Port follows the router's own resolution
  // order: explicit setting wins, then MODEL_ROUTER_PORT, then 4202.
  property int healthIntervalSec: 4

  readonly property string _envPort: Quickshell.env("MODEL_ROUTER_PORT") || ""
  property string portOverride: ""
  property string port: {
    if (root.portOverride !== "") return root.portOverride
    return /^\d+$/.test(root._envPort) ? root._envPort : "4202"
  }

  // Last successfully parsed /health payload; null means the router was
  // never reached (or the answer was unusable) — the offline state.
  property var health: null

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
  readonly property var degradedNames: root.health && Array.isArray(root.health.degraded) ? root.health.degraded : []

  readonly property int activeCount: Number(activity.activeCount) || 0
  readonly property var activeRequests: Array.isArray(activity.active) ? activity.active : []

  // Last (or currently) routing provider — what the optional bar label shows.
  // Latched on data arrival (not in a binding): the idle payload carries no
  // provider, so without the latch the label would flap between "Codex
  // Router" and a provider id on every request, resizing the bar slot each
  // time. Cleared only when offline.
  property string lastProviderName: ""
  readonly property string providerName: root.online ? lastProviderName : ""

  readonly property string version: root.health ? String(health.version || "") : ""

  // ------------------------------------------------------------- polling

  property var _inFlight: null

  function pollHealth() {
    // Skip, don't abort: a response that is merely slower than the interval
    // is still a healthy answer, and dropping it would report "offline"
    // against a router that is responding. A wedged connection is bounded by
    // the XHR timeout below instead.
    if (_inFlight) return

    var xhr = new XMLHttpRequest()
    _inFlight = xhr
    // Bound the wait inside the poll cadence so a router that accepts but
    // never answers cannot leave the dot green on stale data forever.
    xhr.timeout = Math.max(1500, Math.max(2, root.healthIntervalSec) * 1000 - 250)
    xhr.ontimeout = function() {
      if (_inFlight === xhr) _inFlight = null
      applyHealth(0, "")
    }
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (_inFlight === xhr) _inFlight = null
      applyHealth(xhr.status, xhr.responseText)
    }
    xhr.open("GET", "http://127.0.0.1:" + root.port + "/health")
    xhr.send()
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
        var live = String(root.activity.provider || "")
        if (live !== "") root.lastProviderName = live
      }
    } catch (e) {
      console.warn("codex-router-tray", "Bad /health payload:", e)
      root.health = null
    }
  }

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
}

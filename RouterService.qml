import QtQuick
import Quickshell
import Quickshell.Io

// Live router state, polled from the bar widget.
//
// Owns everything that talks to the codex-router: the unauthenticated
// /health poll (phase 2), the authenticated panel/invoke bridge (phase 3)
// that reads snapshot/provider_setup/provider_usage through the caller
// capability, and the mutating half (phase 4) — serialized control-CLI runs
// plus the web-panel opener.
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
  readonly property string callerSecretPath: root.stateDir === "" ? "" : root.stateDir + "/caller-secret"

  // Caller capability, read once at startup and re-read when the file
  // changes or an invoke comes back auth-denied. Treated like a password:
  // memory only, never logged, never in error strings.
  property string callerSecret: ""
  readonly property bool hasCallerSecret: root.callerSecret !== ""

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

  // ------------------------------------------------------- caller secret

  FileView {
    id: secretFile
    path: root.callerSecretPath
    watchChanges: true
    printErrors: false

    onLoaded: {
      var contents = String(text() || "").trim()
      // A rotated key replaces the old one; an emptied file means the
      // capability is gone and guidance should say so.
      root.callerSecret = contents
      root._authReloading = false
      root._replayAuthRetries()
    }
    onLoadFailed: {
      root.callerSecret = ""
      root._authReloading = false
      root._replayAuthRetries()
    }
  }

  // ------------------------------------------------------------- polling

  property var _inFlight: null

  function pollHealth() {
    // Skip, don't abort: a response that is merely slower than the interval
    // is still a healthy answer, and dropping it would report "offline"
    // against a router that is responding. A wedged connection is bounded by
    // the watchdog below instead of XHR.timeout, which QML's XMLHttpRequest
    // does not honor.
    if (_inFlight) return

    var xhr = new XMLHttpRequest()
    var entry = _track(xhr, Math.max(2000, Math.max(2, root.healthIntervalSec) * 1000 - 250))
    _inFlight = xhr
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (_inFlight === xhr) _inFlight = null
      _untrack(entry)
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

  // ---------------------------------------------------- request watchdog
  //
  // QML's XMLHttpRequest ignores the timeout/ontimeout properties, so a
  // router that accepts but never answers would pin a request open forever.
  // Tracked requests carry an absolute deadline; one repeating Timer scans
  // them once a second and aborts the expired ones.

  // Var-property arrays only notify on reassignment, so every mutation
  // rebuilds the array — the watchdog Timer's running binding reads the
  // length and would otherwise never see pushes.
  property var _tracked: []
  readonly property int _trackedCount: _tracked.length

  function _track(request, budgetMs) {
    var entry = { request: request, deadline: Date.now() + budgetMs, timedOut: false }
    _tracked = _tracked.concat([entry])
    return entry
  }

  function _untrack(entry) {
    var index = _tracked.indexOf(entry)
    if (index < 0) return
    var copy = _tracked.slice()
    copy.splice(index, 1)
    _tracked = copy
  }

  Timer {
    interval: 1000
    running: root._trackedCount > 0
    repeat: true
    triggeredOnStart: false
    onTriggered: root._abortExpired()
  }

  function _abortExpired() {
    var now = Date.now()
    for (var i = _tracked.length - 1; i >= 0; i--) {
      if (_tracked[i].deadline > now) continue
      var entry = _tracked[i]
      var request = entry.request
      entry.timedOut = true
      _untrack(entry)
      try { request.abort() } catch (e) { /* already gone */ }
    }
  }

  // ------------------------------------------------- authenticated invoke
  //
  // POST <base>/_codex-router/<secret>/panel/invoke with {"command", "args"};
  // 200 answers {"value": ...}, failures carry {"error": {"message": ...}}.
  //
  // Callback contract: onDone(value, error) with error === null on success,
  // a human-readable string otherwise.

  function invoke(command, args, onDone) {
    if (!root.hasCallerSecret) {
      if (onDone) onDone(null, "No caller key — run ./bin/doctor --fix to restore it.")
      return
    }
    _postInvoke(command, args || {}, onDone, true)
  }

  function _postInvoke(command, args, onDone, allowAuthRetry) {
    var request = new XMLHttpRequest()
    // account_usage proxies a slow upstream call; everything else answers
    // locally and quickly.
    var entry = _track(request, command === "account_usage" ? 30000 : 15000)
    var settled = false

    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE) return
      if (settled) return
      settled = true
      _untrack(entry)

      if (entry.timedOut) {
        if (onDone) onDone(null, "Router did not answer in time.")
        return
      }

      if (request.status === 200) {
        var value = null
        try {
          var payload = JSON.parse(String(request.responseText))
          value = payload && payload.value !== undefined ? payload.value : null
        } catch (e) {
          if (onDone) onDone(null, "Router sent an unreadable response.")
          return
        }
        if (onDone) onDone(value, null)
        return
      }

      // 401 means the key we sent is stale (a wrong key answers 401; 403
      // is the allowlist-deny shape). Park and replay after re-reading the
      // file once. Concurrent denials park too — the batch of three data
      // commands can all come back denied together — but only the first
      // triggers the reload.
      if (request.status === 401 && allowAuthRetry) {
        root._authRetries.push({ command: command, args: args, onDone: onDone })
        if (!root._authReloading) {
          root._authReloading = true
          secretFile.reload()
        }
        return
      }

      if (onDone) onDone(null, _errorMessage(request.status, request.responseText))
    }
    // Loopback only, capability-authenticated. Never log this URL: it
    // embeds the caller secret.
    request.open("POST", "http://127.0.0.1:" + root.port
                 + "/_codex-router/" + root.callerSecret + "/panel/invoke")
    request.setRequestHeader("Content-Type", "application/json")
    request.send(JSON.stringify({ command: command, args: args }))
  }

  // Commands parked while the secret file is re-read after an auth denial.
  property var _authRetries: []
  property bool _authReloading: false

  function _replayAuthRetries() {
    var queue = _authRetries
    _authRetries = []
    for (var i = 0; i < queue.length; i++) {
      var entry = queue[i]
      // allowAuthRetry=false: one reload per incident. A key that is still
      // wrong surfaces its error instead of looping through the file again.
      if (root.hasCallerSecret) _postInvoke(entry.command, entry.args, entry.onDone, false)
      else if (entry.onDone) entry.onDone(null, "No caller key — run ./bin/doctor --fix to restore it.")
    }
  }

  function _errorMessage(status, responseText) {
    // Prefer the router's own words, truncated to 500 chars like the tray;
    // fall back to a bare status line. Never include request URLs.
    try {
      var parsed = JSON.parse(String(responseText))
      var message = parsed && parsed.error && parsed.error.message
        ? String(parsed.error.message) : ""
      if (message !== "") return _truncate(message, 500)
    } catch (e) { /* not JSON — use the generic line */ }
    return "Router request failed (" + status + ")."
  }

  function _truncate(text, max) {
    text = String(text)
    return text.length > max ? text.slice(0, max - 1) + "…" : text
  }

  // ------------------------------------------------------------ data read

  // Refreshes snapshot/provider_setup/provider_usage (+account_usage when
  // enabled, independently). Called on panel open, on the data interval
  // while open, and — from phase 4 — after every mutation.
  function refreshData() {
    if (!root.online || !root.hasCallerSecret || root.dataLoading) return

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

  // ---------------------------------------------------- control CLI runs
  //
  // Mutations shell out to the router's own control CLI exactly like the
  // Tauri tray does (PLAN.md §2.3): node <root>/src/control.mjs <args> with
  // MODEL_ROUTER_TARGET=codex and cwd at the checkout. One process runs at a
  // time; further requests queue behind it so a slow catalog rebuild can
  // never overlap a toggle clicked in impatience.

  // Same resolution order as the tray: explicit setting, then env, then the
  // standard data locations. No existence probe — a wrong root surfaces as
  // an honest spawn failure instead of silent fallback.
  readonly property string _envSourceRoot: Quickshell.env("MODEL_ROUTER_SOURCE_ROOT") || ""
  readonly property string _envDataHome: Quickshell.env("XDG_DATA_HOME") || ""
  readonly property string sourceRoot: {
    if (root.sourceRootOverride !== "") return root.sourceRootOverride
    if (root._envSourceRoot !== "") return root._envSourceRoot
    if (root._envDataHome !== "") return root._envDataHome + "/codex-router"
    var home = Quickshell.env("HOME") || ""
    return home !== "" ? home + "/.local/share/codex-router" : ""
  }

  // The shell is a GUI session and inherits whatever PATH systemd gave it;
  // the tray widens the same way before spawning node.
  readonly property string controlPath: {
    var parts = []
    var home = Quickshell.env("HOME") || ""
    if (home !== "") parts.push(home + "/.npm-global/bin", home + "/.local/bin")
    parts.push("/usr/local/bin", "/usr/bin")
    var current = Quickshell.env("PATH")
    if (current) parts.push(current)
    return parts.join(":")
  }

  readonly property string nodeCommand: {
    var configured = String(Quickshell.env("MODEL_ROUTER_NODE") || "").trim()
    return configured !== "" ? configured : "node"
  }

  property bool mutationRunning: false
  property string mutationLabel: ""
  property string mutationError: ""

  property var _controlQueue: []
  property bool _controlTimedOut: false
  property string _controlStdout: ""
  property string _controlStderr: ""

  // onDone(error): error === null on success, human-readable otherwise. The
  // CLI's own output is deliberately not handed back — every consumer wants
  // fresh state, and fresh state comes from the standard HTTP re-read, so
  // "mutate, then re-read" lives in exactly one place (see onExited).
  function runControl(label, args, onDone) {
    var clean = []
    for (var i = 0; i < args.length; i++) {
      var arg = String(args[i])
      // Every argument is generated here, but provider ids reach a command
      // line either way — constrain them to the shape the router itself
      // enforces rather than trusting the caller.
      if (!/^-{0,2}[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(arg)) {
        if (onDone) onDone("Internal error: refusing to run the control command.")
        return
      }
      clean.push(arg)
    }
    if (root.sourceRoot === "") {
      if (onDone) onDone("Router checkout not found — set the source directory in the widget settings.")
      return
    }
    _controlQueue.push({ label: String(label || ""), args: clean, onDone: onDone })
    _drainControl()
  }

  function _drainControl() {
    if (root.mutationRunning || root._controlQueue.length === 0) return

    var job = root._controlQueue.shift()
    root.mutationRunning = true
    root.mutationLabel = job.label
    root.mutationError = ""
    root._controlTimedOut = false
    root._controlStdout = ""
    root._controlStderr = ""

    controlProc.job = job
    // Catalog rebuilds (set-apply) get the tray's extended budget; everything
    // else answers well inside two minutes.
    controlWatchdog.interval = job.args[0] === "set-apply" ? 330000 : 120000
    controlProc.command = [root.nodeCommand, root.sourceRoot + "/src/control.mjs"].concat(job.args)
    controlProc.workingDirectory = root.sourceRoot
    controlProc.running = true
    controlWatchdog.restart()
  }

  // Shared tail of every control run: release the lock, record the error,
  // hand the result back, pull the next queued job.
  function _finishControlJob(error, exitCode) {
    controlWatchdog.stop()

    var finishedJob = controlProc.job
    controlProc.job = null
    root.mutationRunning = false

    if (error === null && exitCode !== 0) {
      var detail = String(root._controlStderr || "").trim()
      if (detail === "") detail = String(root._controlStdout || "").trim()
      error = detail !== "" ? root._truncate(detail, 500) : "The router command failed."
    }

    if (error !== null) {
      root.mutationError = error
      if (finishedJob && finishedJob.onDone) finishedJob.onDone(error)
    } else {
      if (finishedJob && finishedJob.onDone) finishedJob.onDone(null)
      // Mutate, then re-read. Service commands are skipped: the daemon is
      // down or bouncing by definition, and both poll timers pick the new
      // instance up on their own cadence.
      if (finishedJob && finishedJob.args[0] !== "service") {
        root.pollHealth()
        root.refreshData()
      }
    }

    root._drainControl()
  }

  Process {
    id: controlProc
    running: false
    environment: ({ MODEL_ROUTER_TARGET: "codex", PATH: root.controlPath })

    property var job: null

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._controlStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._controlStderr = text
    }

    // Quickshell flushes both collectors before emitting exited, so the
    // captured output is complete here.
    onExited: function(exitCode) {
      root._finishControlJob(root._controlTimedOut
        ? "The router command did not finish in time." : null, exitCode)
    }

    // A binary that cannot even be spawned (no Node on PATH) never reaches
    // exited: quickshell drops the process silently. A running→false flip
    // with a job still attached is exactly that case — onExited always
    // detaches the job first in the normal flow.
    onRunningChanged: {
      if (!running && controlProc.job !== null)
        root._finishControlJob(
          "Could not start the control process — is Node.js installed?", -1)
    }
  }

  Timer {
    id: controlWatchdog
    interval: 120000
    repeat: false
    onTriggered: {
      if (!controlProc.running) return
      root._controlTimedOut = true
      controlProc.signal(9)
    }
  }

  // ------------------------------------------------------- web panel link

  // The plugin's bin/panel: build the capability URL and hand it to
  // xdg-open. The URL embeds the caller secret, so it exists only inside
  // this call — never logged, nothing collected from the opener.
  function openWebPanel() {
    if (!root.hasCallerSecret) {
      console.warn("codex-router-tray", "No caller key — cannot open the web panel.")
      return false
    }
    webPanelOpener.command = ["xdg-open",
      "http://127.0.0.1:" + root.port + "/_codex-router/" + root.callerSecret + "/panel/"]
    webPanelOpener.running = true
    return true
  }

  Process {
    id: webPanelOpener
    running: false

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
}

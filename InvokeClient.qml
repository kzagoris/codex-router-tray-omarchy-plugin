import QtQuick
import Quickshell.Io
import "logic/SecretText.js" as SecretText

// Loopback HTTP transport of the codex-router: the one child that owns
// network invocation. Capability authentication (the caller-secret file,
// its watch and the replay after a 401), request tracking with deadlines,
// response size limits, and the /health GET plus the authenticated
// panel/invoke POST live here.
//
// Interpretation of payloads is deliberately NOT here: the answers travel
// to the caller (RouterService) raw or via callbacks, so this file knows
// transports, not router state.
//
// Health payload shape (verified against codex-router 0.4.0-beta.4):
//   { ok, service, version, degraded: [name...],
//     activity: { state: "generating"|"error"|"idle", activeCount,
//                 active: [{id, provider, model, sessionName, startedAt}],
//                 provider, model, sessionName } }
Item {
  id: root

  // Resolved by the facade: settings overrides and env fallbacks are
  // configuration policy, not transport business.
  property string port: "4202"
  property string stateDir: ""
  // Budget for one /health answer; derived from the poll cadence so a
  // merely-slow response is never dropped as stale.
  property int healthTimeoutMs: 3750

  // Caller capability, read once at startup and re-read when the file
  // changes or an invoke comes back auth-denied. Treated like a password:
  // memory only, never logged, never in error strings.
  property string callerSecret: ""
  readonly property bool hasCallerSecret: root.callerSecret !== ""

  // The state dir carries the caller capability. No env fallback exists on
  // the router side for this one — only the documented default path.
  readonly property string callerSecretPath: root.stateDir === "" ? "" : root.stateDir + "/caller-secret"

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

  // watchChanges watches the file, not the directory: a key that did not
  // exist when the shell started (fresh install, or `./bin/doctor --fix`
  // writing it afterwards) is never seen again, and the panel keeps advising
  // a fix that has already run. Nothing polls for it — the reader asks, on
  // panel open and on Refresh (see Panel.refreshNow).
  //
  // Only while the key is missing: a key we already hold is re-read by the
  // watch, or by the reload after a 401, and rereading it here would race
  // that.
  function recheckCallerSecret() {
    if (root.callerSecretPath === "") return
    if (root.hasCallerSecret || root._authReloading) return
    secretFile.reload()
  }

  // ------------------------------------------------------------- health

  property var _inFlight: null
  property var _healthEntry: null

  // Response ceilings. /health is a fixed-shape status blob measured in
  // hundreds of bytes; the authenticated commands carry usage tables and
  // model lists, so they get room to grow without going unbounded.
  readonly property int _healthMaxChars: 256 * 1024
  readonly property int _invokeMaxChars: 4 * 1024 * 1024

  // One unauthenticated GET /health. onDone(status, text): any non-200
  // status (including the oversize abort, reported as status 0) means
  // "do not trust anything" — the caller drops its last known payload.
  //
  // Skip, don't abort: a response that is merely slower than the interval
  // is still a healthy answer, and dropping it would report "offline"
  // against a router that is responding. A wedged connection is bounded by
  // the watchdog below instead of XHR.timeout, which QML's XMLHttpRequest
  // does not honor.
  function fetchHealth(onDone) {
    if (_inFlight) return

    var xhr = new XMLHttpRequest()
    var entry = _track(xhr, Math.max(2000, root.healthTimeoutMs), root._healthMaxChars)
    entry.onDone = onDone
    entry.settled = false
    _inFlight = xhr
    _healthEntry = entry
    xhr.onreadystatechange = function() {
      if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED
          || xhr.readyState === XMLHttpRequest.LOADING) {
        // The abort lands back here as DONE with status 0, which the
        // caller already reads as "not trusting stale data".
        root._overLimit(xhr, entry)
        return
      }
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      root._settleHealth(xhr, entry, entry.oversize ? 0 : xhr.status,
        entry.oversize ? "" : xhr.responseText)
    }
    xhr.open("GET", "http://127.0.0.1:" + root.port + "/health")
    xhr.send()
  }

  // The watchdog must complete the callback itself: some QML XHR backends do
  // not deliver DONE after abort(), and otherwise RouterService's single-flight
  // guard would remain latched forever.
  function _settleHealth(xhr, entry, status, text) {
    if (entry.settled) return
    entry.settled = true
    if (_inFlight === xhr) _inFlight = null
    if (_healthEntry === entry) _healthEntry = null
    _untrack(entry)
    if (entry.onDone) entry.onDone(status, text)
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

  function _track(request, budgetMs, maxChars) {
    var entry = {
      request: request,
      deadline: Date.now() + budgetMs,
      timedOut: false,
      maxChars: maxChars,
      oversize: false
    }
    _tracked = _tracked.concat([entry])
    return entry
  }

  // A loopback service that answers with an endless body would otherwise be
  // buffered whole and handed to JSON.parse, so a compromised router could
  // pin arbitrary memory in a shell that never restarts. Every tracked
  // request carries a size budget checked while the body streams: once the
  // declared or received length passes it the request is aborted, so nothing
  // larger is ever retained, let alone parsed.
  //
  // Measured in UTF-16 code units rather than bytes -- QML exposes no byte
  // count, and the budgets are order-of-magnitude limits, not accounting.
  function _overLimit(request, entry) {
    if (entry.oversize) return true

    var size = -1
    if (request.readyState === XMLHttpRequest.HEADERS_RECEIVED) {
      var declared = parseInt(request.getResponseHeader("Content-Length") || "", 10)
      if (isFinite(declared) && declared >= 0) size = declared
    }
    if (size < 0) size = String(request.responseText || "").length
    if (size <= entry.maxChars) return false

    entry.oversize = true
    _untrack(entry)
    try { request.abort() } catch (e) { /* already gone */ }
    if (request === _inFlight) root._settleHealth(request, entry, 0, "")
    else if (!entry.settled) {
      entry.settled = true
      if (entry.onDone) entry.onDone(null, "Router sent an oversized response.")
    }
    console.warn("codex-router-tray", "Oversized router response aborted at", size, "chars")
    return true
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
      if (request === _inFlight)
        _settleHealth(request, entry, 0, "")
      else if (!entry.settled)
        _settleInvokeTimeout(entry)
    }
  }

  function _settleInvokeTimeout(entry) {
    if (entry.settled) return
    entry.settled = true
    if (entry.onDone) entry.onDone(null, "Router did not answer in time.")
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
    var entry = _track(request,
      command === "account_usage" ? 30000 : 15000,
      root._invokeMaxChars)
    entry.onDone = onDone
    entry.settled = false
    var settled = false

    request.onreadystatechange = function() {
      if (request.readyState === XMLHttpRequest.HEADERS_RECEIVED
          || request.readyState === XMLHttpRequest.LOADING) {
        root._overLimit(request, entry)
        return
      }
      if (request.readyState !== XMLHttpRequest.DONE) return
      if (settled || entry.settled) return
      settled = true
      entry.settled = true
      _untrack(entry)

      if (entry.oversize) {
        if (onDone) onDone(null, "Router sent an oversized response.")
        return
      }

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

      if (onDone) onDone(null, root._errorMessage(request.status, request.responseText))
    }
    // Loopback only, capability-authenticated. Never log this URL: it
    // embeds the caller secret.
    request.open("POST", root.callerUrl("panel/invoke"))
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
      if (message !== "") return root._truncate(root._withoutCallerSecret(message), 500)
    } catch (e) { /* not JSON — use the generic line */ }
    return "Router request failed (" + status + ")."
  }

  function _truncate(text, max) {
    text = String(text)
    return text.length > max ? text.slice(0, max - 1) + "…" : text
  }

  function _withoutCallerSecret(text) {
    return SecretText.withoutSecret(text, root.callerSecret)
  }

  // The one place that assembles capability URLs: every consumer shares the
  // prefix that embeds the caller secret, so it is never rebuilt ad hoc —
  // and never logged.
  function callerUrl(leaf) {
    return "http://127.0.0.1:" + root.port + "/_codex-router/" + root.callerSecret + "/" + leaf
  }
}

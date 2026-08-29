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
    root.updateActiveViewProjection()
  }

  // Last successfully parsed /health payload; null means the router was
  // never reached (or the answer was unusable) — the offline state.
  property var health: null

  // Authenticated reads. Null = never fetched or last fetch failed.
  property var snapshot: null
  // Snapshot is read for a reason, never on cadence. Status, Providers and
  // Models share the one payload: `_snapshotCacheValid` says it may satisfy
  // entry demand without a read, `_snapshotCurrent` says the facts already
  // published from it still describe a live Router.
  property bool _snapshotCacheValid: false
  property bool _snapshotCurrent: false
  // When the cached payload was proved. A View answered from cache is fresh
  // as of that read, not as of the demand that reused it.
  property double _snapshotFreshAt: 0
  // Bumped on every Router reachability transition. A command dispatched in an
  // older epoch cannot answer for the Router that answers now, however
  // reachable the Router happens to be when its result lands.
  property int _routerEpoch: 0
  property var providerSetup: null
  property var providerUsage: null

  // account_usage rides on its own request and its own loading flag: it is
  // a slow upstream call that times out now and then (PLAN.md §2.2), so its
  // failure must not read as a general data failure nor hold any other
  // section's refresh hostage.
  property var accountUsage: null
  property bool accountUsageFailed: false
  property bool accountUsageLoading: false
  property string accountUsageError: ""
  property double accountUsageFreshAt: 0
  onAccountUsageChanged: root.updateActiveViewProjection()
  onAccountUsageLoadingChanged: root.updateActiveViewProjection()
  onAccountUsageErrorChanged: root.updateActiveViewProjection()
  onAccountUsageFreshAtChanged: root.updateActiveViewProjection()
  onAccountUsageEnabledChanged: root.updateActiveViewProjection()

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

  // Legacy reader-presence flag. No production caller writes it any more —
  // the Panel declares `readerPresent` instead — but it still widens every
  // visibility test below, so ticket 18 deletes it together with the rest of
  // the legacy surface rather than piecemeal here.
  property bool panelOpen: false

  // The caller contract: a caller declares whether it has a reader and which
  // View is visible. Open, close and View switches are declarations, not
  // composed reader operations.
  property bool readerPresent: false
  property string activeView: "Status"
  property bool _normalizingActiveView: false
  // Later Models migration declares this while a visible Proof is checking.
  // It is here now so staged checking demand has the same cancellation rule as
  // the other visibility work.
  property bool checkingProofVisible: false
  property var _viewRecords: ({})
  // Active projection commit sequence. This is distinct from a hidden View
  // record's data revision because switching between equally revised records
  // is still a coherent public projection commit.
  property int _activeProjectionCommit: 0
  property string _lastGlobalBlockingReason: ""

  // Intents remain typed while prerequisites or an earlier read block them.
  // Operator reconciliation is keyed by origin so two mutations cannot erase
  // each other; visibility work is keyed by kind and its current View.
  property var _pendingDemands: []
  // Commands are independently versioned. A result is useful only if it is
  // at least as new as the fact already committed; callbacks may arrive in
  // any order from the I/O adapter.
  property var _nextCommandGeneration: ({})
  property var _committedCommandGeneration: ({})
  property var _inFlightCommands: ({})
  property int _activeRecipeCount: 0
  property bool _healthInFlight: false
  property int _nextHealthGeneration: 0
  property int _committedHealthGeneration: 0
  property bool _refreshHealthPending: false
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
    }
    root.updateActiveViewProjection()
    if (!root.readerPresent) return
    root.cancelInvisibleDemand()
    root.pollHealth()
    root.requestViewEntry(root.activeView)
  }
  onOnlineChanged: {
    root._routerEpoch++
    if (!root.online) {
      // Going offline keeps the payload and every complete View projection,
      // but neither counts as current: a Router that dropped may come back
      // with different settings, so retained facts are marked stale.
      root._snapshotCacheValid = false
      root._snapshotCurrent = false
      root.updateActiveViewProjection()
      return
    }
    // Recovery discards cache validity rather than the facts, so the next
    // Snapshot-backed demand reads exactly once. A visible reader asks now;
    // a closed one leaves the obligation for its next entry.
    root._snapshotCacheValid = false
    root.updateActiveViewProjection()
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

  // The public object is never replaced. Hidden View records stay internal
  // and are copied here only when that View is selected.
  QtObject {
    id: activeViewProjectionObject
    property string view: "Status"
    property bool available: false
    property bool refreshing: false
    property string blockingReason: "offline"
    property string readError: ""
    property double freshAt: 0
    // A Snapshot-backed View whose retained facts have not been re-proved
    // since the Router was last reachable.
    property bool stale: false
    property int dataRevision: 0
    property int revision: 0
    property var snapshot: null
    // Snapshot-derived facts, shaped once here so no View re-derives payload
    // paths. Empty objects until this View's own Snapshot commits.
    readonly property var target: {
      var targets = activeViewProjectionObject.snapshot
        && activeViewProjectionObject.snapshot.targets
        ? activeViewProjectionObject.snapshot.targets : null
      return targets && targets.codex ? targets.codex : ({})
    }
    readonly property var chatgptSession: activeViewProjectionObject.snapshot
      && activeViewProjectionObject.snapshot.chatgptSession
      ? activeViewProjectionObject.snapshot.chatgptSession : ({})
    property var providerSetup: null
    property var providerUsage: null
    property var accountUsage: null
    property bool accountUsageLoading: false
    property string accountUsageError: ""
    property double accountUsageFreshAt: 0
  }
  readonly property var activeViewProjection: activeViewProjectionObject

  // The codex target block of the last raw Snapshot — everything the mode
  // switches and provider toggles reflect. Empty object until the first read
  // lands. Status reads the same shape off its own View record instead (see
  // the projection above); this legacy surface serves the Views that have not
  // migrated yet and goes with the rest of them in ticket 18.
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

  // Status, Providers and Models read their facts from the shared Snapshot;
  // Usage does not, so Snapshot policy never describes it.
  function isSnapshotBackedView(view) {
    return root.requiredCommandsForView(view).indexOf("control_snapshot") !== -1
  }

  function requiredCommandsForView(view) {
    if (view === "Usage") return ["provider_setup", "provider_usage"]
    if (view === "Providers") return ["control_snapshot", "provider_setup"]
    return ["control_snapshot"]
  }

  function viewRecord(view) {
    var key = root.isSupportedView(view) ? view : "Status"
    var record = root._viewRecords[key]
    if (record) return record
    record = { view: key, refreshing: 0, readToken: 0, readError: "", freshAt: 0,
      revision: 0, snapshot: null, providerSetup: null, providerUsage: null }
    root._viewRecords[key] = record
    return record
  }

  function globalBlockingReason() {
    if (!root.online) return "offline"
    if (!root.hasCallerSecret) return "capability-missing"
    return ""
  }

  function updateActiveViewProjection() {
    var record = root.viewRecord(root.activeView)
    var projection = activeViewProjectionObject
    var blocking = root.globalBlockingReason()
    // Read errors remain internal while globally blocked. Once the global
    // condition recovers, they no longer describe the newly unblocked reader
    // state, so clear them before any View can project stale failure prose.
    if (root._lastGlobalBlockingReason !== "" && blocking === "") {
      var views = Object.keys(root._viewRecords)
      for (var index = 0; index < views.length; index++)
        root._viewRecords[views[index]].readError = ""
      root.accountUsageError = ""
      root.accountUsageFailed = false
    }
    root._lastGlobalBlockingReason = blocking
    var changed = false
    if (projection.available !== (record.revision > 0)) { projection.available = record.revision > 0; changed = true }
    if (projection.refreshing !== (record.refreshing > 0)) { projection.refreshing = record.refreshing > 0; changed = true }
    if (projection.blockingReason !== blocking) { projection.blockingReason = blocking; changed = true }
    var visibleReadError = blocking === "" ? record.readError : ""
    if (projection.readError !== visibleReadError) { projection.readError = visibleReadError; changed = true }
    if (projection.freshAt !== record.freshAt) { projection.freshAt = record.freshAt; changed = true }
    var stale = root.isSnapshotBackedView(record.view) && record.revision > 0
      && !root._snapshotCurrent
    if (projection.stale !== stale) { projection.stale = stale; changed = true }
    if (projection.dataRevision !== record.revision) { projection.dataRevision = record.revision; changed = true }
    if (projection.snapshot !== record.snapshot) { projection.snapshot = record.snapshot; changed = true }
    if (projection.providerSetup !== record.providerSetup) { projection.providerSetup = record.providerSetup; changed = true }
    if (projection.providerUsage !== record.providerUsage) { projection.providerUsage = record.providerUsage; changed = true }
    var hasAccountUsage = record.view === "Usage" && root.accountUsageEnabled
    var accountValue = hasAccountUsage ? root.accountUsage : null
    var accountLoading = hasAccountUsage && root.accountUsageLoading
    var accountError = hasAccountUsage && blocking === "" ? root.accountUsageError : ""
    var accountFreshAt = hasAccountUsage ? root.accountUsageFreshAt : 0
    if (projection.accountUsage !== accountValue) { projection.accountUsage = accountValue; changed = true }
    if (projection.accountUsageLoading !== accountLoading) { projection.accountUsageLoading = accountLoading; changed = true }
    if (projection.accountUsageError !== accountError) { projection.accountUsageError = accountError; changed = true }
    if (projection.accountUsageFreshAt !== accountFreshAt) { projection.accountUsageFreshAt = accountFreshAt; changed = true }
    // Populate facts before identity changes: an onViewChanged observer never
    // sees a prior View's payload. QML emits each property independently, so
    // imperative consumers use revisionChanged (after viewChanged) as the
    // coherent commit edge; individual factChanged signals stay precise but
    // are not atomic transactions.
    if (projection.view !== record.view) { projection.view = record.view; changed = true }
    if (changed) projection.revision = ++root._activeProjectionCommit
  }

  function beginViewRead(view) {
    var record = root.viewRecord(view)
    record.refreshing++
    record.readToken++
    record.readError = ""
    root.updateActiveViewProjection()
    return { record: record, token: record.readToken }
  }

  function finishViewRead(read, required, staged, failedError, allRequiredFresh, freshAtCeiling) {
    var record = read.record
    record.refreshing = Math.max(0, record.refreshing - 1)
    // A newer logical read owns the record's publication. Older shared
    // receivers still drain their refreshing count, but cannot publish an
    // error or overwrite the newer complete revision.
    if (read.token !== record.readToken) {
      root.updateActiveViewProjection()
      return
    }
    if (failedError !== "") {
      // Store every local outcome; updateActiveViewProjection masks it while
      // global Panel chrome is authoritative and clears it on recovery.
      record.readError = root.plainText(failedError, 500)
      root.updateActiveViewProjection()
      return
    }
    // A stale successful generation is intentionally silent. It cannot form
    // a coherent new revision, and it must not overwrite retained facts or
    // invent an operator-facing error.
    if (!allRequiredFresh) {
      root.updateActiveViewProjection()
      return
    }
    if (required.indexOf("control_snapshot") !== -1) record.snapshot = staged.snapshot
    if (required.indexOf("provider_setup") !== -1) record.providerSetup = staged.providerSetup
    if (required.indexOf("provider_usage") !== -1) record.providerUsage = staged.providerUsage
    // Facts reused from cache cap this View's freshness at the read that
    // proved them: reusing a payload is not re-reading it.
    var now = root.clock.now()
    record.freshAt = freshAtCeiling > 0 ? Math.min(now, freshAtCeiling) : now
    // Revision is assigned last: it marks a fully published fact set.
    record.revision++
    root.updateActiveViewProjection()
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
      // Operator intent, mutation reconciliation and a visible checking Proof
      // want Router truth, not the cache — decided when the intent is formed,
      // so a Snapshot committed while it waits cannot answer for it.
      forcesSnapshot: kind === "refresh" || kind === "reconciliation"
        || kind === "checking-proof",
      trailing: root.dataLoading && (kind === "refresh" || kind === "reconciliation")
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
    if (!root.online || !root.hasCallerSecret) return false
    var selected = -1
    for (var index = 0; index < root._pendingDemands.length; index++) {
      var candidate = root._pendingDemands[index]
      if (selected < 0 || root.demandPriority(candidate.kind)
          > root.demandPriority(root._pendingDemands[selected].kind)) selected = index
    }
    if (selected < 0) return false
    var demand = root._pendingDemands[selected]
    // Ordinary view demand is allowed to join the active physical command
    // batch. Forced Router-truth work retains its causal floor as one trailing
    // batch instead, so it cannot be answered by pre-intent payloads.
    if (root.dataLoading && demand.trailing) return false
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
    root.dispatchDemand(demand, root.dataLoading)
    return true
  }

  function requestViewEntry(view) {
    if (!(root.readerPresent || root.panelOpen) || !root.isSupportedView(view)) return
    root.stageDemand("view-entry", view)
  }

  // Public semantic intents. The broad effect recipe remains intentionally
  // legacy-shaped until ticket 15 defines Refresh completeness and ticket 16
  // maps real mutation outcomes to reconciliation recipes.
  function requestRefresh() {
    // A caller key written after the shell started is invisible until somebody
    // asks for it again, and Refresh is the operator waiting on that answer.
    // Part of the intent, not a step a caller composes around it. A capability
    // already in hand cannot be made more available by re-reading it, so the
    // ordinary Refresh asks for nothing. The adapter short-circuits the same
    // case; deciding whether a read is useful is reader policy, and it should
    // not depend on an adapter internal to stay true.
    if (!root.hasCallerSecret) root.recheckCallerSecret()
    // A known-good health fact is enough to start the authenticated recipe,
    // but Refresh still samples health. Starting both effects here avoids
    // putting useful authenticated work behind an answer we already have.
    if (root._healthInFlight) root._refreshHealthPending = true
    else root.pollHealth()
    root.stageDemand("refresh", root.activeView)
  }
  function requestReconciliation(originatingView) {
    root.stageDemand("reconciliation", originatingView)
  }

  // The hook mutation reconciliation calls when a change may have moved
  // Snapshot settings, so the cached payload stops answering demand until it
  // is re-read. It reads nothing itself; the next demand does. Ticket 16 maps
  // which mutation outcomes are relevant enough to call it.
  function invalidateSnapshotCache() {
    root._snapshotCacheValid = false
  }
  function requestCheckingProof(view) {
    root.stageDemand("checking-proof", view)
  }
  function requestCadence() { root.stageDemand("cadence", root.activeView) }

  function dispatchDemand(demand, joinsActiveRecipe) {
    root.dispatchDataRecipe(demand, joinsActiveRecipe === true)
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
    root.updateActiveViewProjection()
  }

  // ------------------------------------------------------------- reading

  function pollHealth() {
    // Health is one command too: shared callers observe the same live probe
    // instead of building an overlapping HTTP queue.
    if (root._healthInFlight) return false
    root._healthInFlight = true
    var generation = ++root._nextHealthGeneration
    root.io.fetchHealth(function(status, text) {
      root._healthInFlight = false
      root.applyHealth(status, text, generation)
      if (root._refreshHealthPending) {
        root._refreshHealthPending = false
        root.pollHealth()
      }
    })
    return true
  }

  function applyHealth(status, text, generation) {
    if (generation !== undefined && generation < root._committedHealthGeneration) return
    if (status !== 200) {
      // Unreachable or unhappy: drop the last known payload wholesale so
      // "offline" always means "not trusting stale data".
      root.health = null
      root._committedHealthGeneration = generation || root._committedHealthGeneration
      root.updateRouterSummary()
      root.consumePendingDemand()
      return
    }
    try {
      var parsed = JSON.parse(String(text))
      root.health = parsed && typeof parsed === "object" ? parsed : null
      root._committedHealthGeneration = generation || root._committedHealthGeneration
      if (root.online) {
        var live = root.plainText(root.activity.provider, 48)
        if (live !== "") root.lastProviderName = live
      }
      root.updateRouterSummary()
      root.consumePendingDemand()
    } catch (e) {
      console.warn("codex-router-tray", "Bad /health payload:", e)
      root.health = null
      root._committedHealthGeneration = generation || root._committedHealthGeneration
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

  // There is no ordinary Snapshot cadence. Otherwise a demand reads Snapshot
  // when it forces Router truth or when no valid cache can answer it.
  function shouldReadSnapshot(demand) {
    if (demand.kind === "cadence") return false
    return demand.forcesSnapshot === true || !root._snapshotCacheValid
  }

  // Which facts a demand is willing to pay for. Entering a View reads exactly
  // what that View renders — entering Status must not buy Provider facts it
  // never shows. Every other demand keeps the broad recipe until the ticket
  // that owns it says otherwise: 13 for the checking Proof, 15 for Refresh,
  // 16 for reconciliation.
  function commandsForDemand(demand) {
    if (demand.kind === "view-entry") return root.requiredCommandsForView(demand.view)
    return ["control_snapshot", "provider_setup", "provider_usage"]
  }

  // The one place a Router command is paired with the fact it fills.
  readonly property var factProperties: ({
    control_snapshot: "snapshot",
    provider_setup: "providerSetup",
    provider_usage: "providerUsage"
  })
  function factPropertyFor(command) {
    return root.factProperties[command] || ""
  }

  function dispatchDataRecipe(demand, joinsActiveRecipe) {
    if (!root.online || !root.hasCallerSecret) return

    var commands = root.commandsForDemand(demand)
    var readsSnapshot = commands.indexOf("control_snapshot") !== -1
      && root.shouldReadSnapshot(demand)
    // A Snapshot read in flight is already replacing the cache, so demand
    // arriving beside it joins that request rather than committing the
    // payload it supersedes.
    if (readsSnapshot) root._snapshotCacheValid = false
    var rounds = []
    for (var commandIndex = 0; commandIndex < commands.length; commandIndex++) {
      var command = commands[commandIndex]
      if (command === "control_snapshot" && !readsSnapshot) continue
      var prop = root.factPropertyFor(command)
      if (prop !== "") rounds.push({ command: command, prop: prop })
    }
    // Demand a valid cache answers in full reads nothing, so it opens no
    // physical recipe: no loading state, no round, no account-usage ride.
    var readsAnything = rounds.length > 0
    if (readsAnything) {
      root._activeRecipeCount++
      root.dataLoading = true
      if (!joinsActiveRecipe) root.dataRound++
    }

    var pending = rounds.length
    var gotFresh = false
    var firstSharedError = ""
    var roundOpen = true
    var required = root.requiredCommandsForView(demand.view)
    var viewRead = root.beginViewRead(demand.view)
    var staged = { snapshot: null, providerSetup: null, providerUsage: null }
    var requiredError = ""
    var requiredPending = 0
    var allRequiredFresh = true
    var viewReadOpen = true
    var freshAtCeiling = 0

    for (var factIndex = 0; factIndex < required.length; factIndex++) {
      if (required[factIndex] === "control_snapshot" && !readsSnapshot) {
        // A valid cache is this View's Snapshot answer for demand that asked
        // for the View's facts. An ordinary cadence is not such demand: it
        // read nothing here, so it leaves the read incomplete rather than
        // restamping unchanged facts as newly fresh.
        if (root._snapshotCacheValid && demand.kind !== "cadence") {
          staged.snapshot = root.snapshot
          freshAtCeiling = root._snapshotFreshAt
        } else allRequiredFresh = false
      } else {
        requiredPending++
      }
    }
    // Entry demand answered entirely from cache completes without any read.
    if (requiredPending === 0) {
      viewReadOpen = false
      root.finishViewRead(viewRead, required, staged, requiredError, allRequiredFresh,
        freshAtCeiling)
    }

    function receive(round, generation, value, error, epoch) {
      var accepted = false
      if (error === null) {
        gotFresh = true
        var committed = Number(root._committedCommandGeneration[round.command]) || 0
        if (generation >= committed) {
          root[round.prop] = value
          root._committedCommandGeneration[round.command] = generation
          accepted = true
          // Only a Snapshot proved against a reachable Router validates the
          // shared cache; one that lands after the Router dropped is exactly
          // the unverified payload recovery must not inherit.
          if (round.command === "control_snapshot" && root.online
              && epoch === root._routerEpoch) {
            root._snapshotCacheValid = true
            root._snapshotCurrent = true
            root._snapshotFreshAt = root.clock.now()
            root.updateActiveViewProjection()
          }
        }
      } else if (firstSharedError === "") {
        firstSharedError = error
      }
      if (required.indexOf(round.command) !== -1) {
        if (error !== null) {
          if (requiredError === "") requiredError = error
        } else if (accepted) {
          staged[round.prop] = value
        } else {
          allRequiredFresh = false
        }
        requiredPending--
        // A View's logical round is complete as soon as its own facts settle;
        // the broad physical recipe may still be serving unrelated caches.
        if (requiredPending === 0 && viewReadOpen) {
          viewReadOpen = false
          root.finishViewRead(viewRead, required, staged, requiredError, allRequiredFresh,
            freshAtCeiling)
        }
      }

      // A retry parked by a mid-round rotation can land after the round
      // closed: its fresh payload still lands above, but it must not touch
      // bookkeeping that belongs to whichever round is now current.
      if (!roundOpen) return
      pending--
      if (pending > 0) return
      roundOpen = false
      root._activeRecipeCount = Math.max(0, root._activeRecipeCount - 1)
      root.dataLoading = root._activeRecipeCount > 0
      root.dataError = firstSharedError
      if (gotFresh) root.lastUpdatedAt = root.clock.now()
      // Hidden records are intentionally not completed by this broad recipe:
      // ticket 15 defines the all-View explicit Refresh policy. The helper
      // above already accepts an arbitrary record/required-fact set so that
      // policy can fan out without replacing this projection machinery.
      root.consumePendingDemand()
    }

    function receiverFor(round) {
      return function(value, error, generation, epoch) {
        receive(round, generation, value, error, epoch)
      }
    }

    if (!readsAnything) {
      // Nothing was dispatched, so no completion callback will drain the
      // queue: whatever else is waiting gets its chance here instead.
      root.consumePendingDemand()
      return
    }

    for (var i = 0; i < rounds.length; i++) {
      root.invokeShared(rounds[i].command, {}, receiverFor(rounds[i]))
    }

    refreshAccountUsage()
  }

  // The command boundary, rather than a particular View recipe, owns
  // coalescing. This keeps a Status and Providers demand from issuing the
  // same Snapshot read when their recipes overlap.
  function invokeShared(command, args, receiver) {
    var active = root._inFlightCommands[command]
    // A request that left before the Router last changed reachability cannot
    // answer demand raised after it: recovery would otherwise be satisfied by
    // a read the restarted Router never saw.
    if (active && active.epoch === root._routerEpoch) {
      active.receivers.push(receiver)
      return active.generation
    }

    var generation = (Number(root._nextCommandGeneration[command]) || 0) + 1
    root._nextCommandGeneration[command] = generation
    active = { generation: generation, epoch: root._routerEpoch, receivers: [receiver] }
    root._inFlightCommands[command] = active
    root.io.invoke(command, args, function(value, error) {
      if (active.settled) return
      active.settled = true
      // Remove before notifying receivers: a callback can synchronously stage
      // the next round, which must receive a new generation.
      if (root._inFlightCommands[command] === active)
        delete root._inFlightCommands[command]
      for (var index = 0; index < active.receivers.length; index++)
        active.receivers[index](value, error, generation, active.epoch)
    })
    return generation
  }

  // Fully independent: own flag, no share of dataLoading/pending, so a hung
  // quota call never disables Refresh or freezes the footer (PLAN.md §5).
  function refreshAccountUsage() {
    if (!root.accountUsageEnabled || root.accountUsageLoading) return
    if (!root.online || !root.hasCallerSecret) return

    root.accountUsageLoading = true
    root.accountUsageError = ""
    root.io.invoke("account_usage", {}, function(value, error) {
      root.accountUsageLoading = false
      root.accountUsageFailed = error !== null
      if (error === null) {
        root.accountUsage = value
        root.accountUsageFreshAt = root.clock.now()
      } else {
        root.accountUsageError = root.plainText(error, 500)
      }
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

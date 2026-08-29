import QtQuick
import Quickshell
import Quickshell.Io

// Control CLI transport of the codex-router: the one child that spawns
// processes. The resolved interpreter and script path, the widened
// environment, per-command budgets, the serialized mutation queue and the
// watchdog live here.
//
// Mutations shell out to the router's own control CLI exactly like the
// Tauri tray does (PLAN.md §2.3): node <root>/src/control.mjs <args> with
// MODEL_ROUTER_TARGET=codex and cwd at the checkout. One process runs at a
// time; further requests queue behind it so a slow catalog rebuild can
// never overlap a toggle clicked in impatience.
//
// Refresh policy is deliberately NOT here. A caller that runs a mutation
// reports its semantic outcome — the View it originated from and whether the
// Router must come back first — to RouterService, which maps that to the
// right reads. Control CLI vocabulary never reaches the reader.
Item {
  id: root

  // Settings override; empty string means "use the resolution order".
  property string sourceRootOverride: ""

  property bool mutationRunning: false
  property string mutationLabel: ""
  property string mutationError: ""

  // Candidate order as the tray resolves it: explicit setting, then env,
  // then the standard data locations — but like the tray, a candidate only
  // wins if it actually contains the control script.
  readonly property string _envSourceRoot: Quickshell.env("MODEL_ROUTER_SOURCE_ROOT") || ""
  readonly property string _envDataHome: Quickshell.env("XDG_DATA_HOME") || ""
  readonly property string _defaultSourceRoot: {
    var home = Quickshell.env("HOME") || ""
    return home !== "" ? home + "/.local/share/codex-router" : ""
  }

  // Existence probe behind resolveSourceRoot(). waitForJob() parks the
  // caller until the async load settles — a stat on local disk, the same
  // blocking cost the tray pays for its existsSync() checks.
  FileView {
    id: sourceProbe
    printErrors: false
    watchChanges: false

    property bool ok: false
    onLoaded: ok = true
    onLoadFailed: ok = false
  }

  function _hasControlScript(checkout) {
    if (checkout === "") return false
    sourceProbe.ok = false
    sourceProbe.path = checkout + "/src/control.mjs"
    // reload(): re-assigning an unchanged path starts no new job.
    sourceProbe.reload()
    sourceProbe.waitForJob()
    return sourceProbe.ok
  }

  // Resolved fresh per run rather than cached in a binding: settings and env
  // can change under us, and a stale root would fail every mutation until
  // the shell restarted.
  function resolveSourceRoot() {
    var candidates = []
    if (root.sourceRootOverride !== "") candidates.push(root.sourceRootOverride)
    if (root._envSourceRoot !== "") candidates.push(root._envSourceRoot)
    if (root._envDataHome !== "") candidates.push(root._envDataHome + "/codex-router")
    if (root._defaultSourceRoot !== "") candidates.push(root._defaultSourceRoot)

    for (var i = 0; i < candidates.length; i++)
      if (_hasControlScript(candidates[i])) return candidates[i]

    // Nothing verified: hand back the first candidate so the spawn error
    // names the configured path instead of pretending there was none.
    return candidates.length > 0 ? candidates[0] : ""
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

  // The one home for command-class questions, so the CLI vocabulary
  // (budgets, service special cases) never scatters across call sites.
  function commandBudgetMs(args) {
    // Catalog rebuilds (set-apply) get the tray's extended budget; everything
    // else answers well inside two minutes.
    return args[0] === "set-apply" ? 330000 : 120000
  }

  function isServiceCommand(args) {
    return String(args[0] || "") === "service"
  }

  property var _controlQueue: []
  property bool _controlTimedOut: false
  property string _controlStdout: ""
  property string _controlStderr: ""

  // onDone(error): error === null on success, human-readable otherwise. The
  // CLI's own output is deliberately not handed back — every consumer wants
  // fresh state, and fresh state comes from the reader's own reconciling
  // read, so "mutate, then re-read" lives in exactly one place.
  function runControl(label, args, onDone) {
    var clean = []
    for (var i = 0; i < args.length; i++) {
      var arg = String(args[i])
      // Every argument is generated here, but provider ids and catalog
      // model slugs reach a command line either way — constrain them to the
      // shape the router itself enforces rather than trusting the caller.
      // Slugs are provider-qualified (`opencode-go/glm-5.1`), so the slash
      // belongs in the alphabet; nothing is passed through a shell, and the
      // leading character stays alphanumeric so no argument can turn into a
      // path or an option.
      if (!/^-{0,2}[A-Za-z0-9][A-Za-z0-9._:\/-]{0,127}$/.test(arg)) {
        root.mutationError = "Internal error: refusing to run the control command."
        if (onDone) onDone(root.mutationError)
        return
      }
      clean.push(arg)
    }

    var checkout = resolveSourceRoot()
    if (checkout === "") {
      root.mutationError = "Router checkout not found — set the source directory in the widget settings."
      if (onDone) onDone(root.mutationError)
      return
    }

    _controlQueue.push({ label: String(label || ""), args: clean, checkout: checkout, onDone: onDone })
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
    controlWatchdog.interval = root.commandBudgetMs(job.args)
    controlProc.command = [root.nodeCommand, job.checkout + "/src/control.mjs"].concat(job.args)
    controlProc.workingDirectory = job.checkout
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
    } else if (finishedJob && finishedJob.onDone) {
      finishedJob.onDone(null)
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

  function _truncate(text, max) {
    text = String(text)
    return text.length > max ? text.slice(0, max - 1) + "…" : text
  }
}

import QtQuick
import Quickshell
import Quickshell.Io

// Production boundary for every RouterService effect. It resolves the
// machine-specific locations and owns the capability-bearing transport and
// browser handoff; RouterService receives only raw callback results.
Item {
  id: root

  property string portOverride: ""
  property string stateDirOverride: ""
  // RouterService owns the cadence policy. A composition must provide this
  // exact cadence; the deadline below cannot silently fall back to another.
  required property int healthCadenceMs

  readonly property string _envPort: Quickshell.env("MODEL_ROUTER_PORT") || ""
  readonly property string port: root.portOverride !== "" ? root.portOverride
    : (/^\d+$/.test(root._envPort) ? root._envPort : "4202")
  readonly property string stateDir: {
    if (root.stateDirOverride !== "") return root.stateDirOverride
    var home = Quickshell.env("HOME") || ""
    return home !== "" ? home + "/.codex/codex-router" : ""
  }
  readonly property int healthTimeoutMs: Math.max(2000,
    Math.max(2000, root.healthCadenceMs) - 250)
  readonly property bool hasCallerSecret: invokeClient.hasCallerSecret

  function recheckCallerSecret() {
    invokeClient.recheckCallerSecret()
  }

  function fetchHealth(onDone) {
    invokeClient.fetchHealth(onDone)
  }

  function invoke(command, args, onDone) {
    invokeClient.invoke(command, args, onDone)
  }

  // Capability URLs stay entirely within this adapter. They are written to
  // stdin rather than an argv item, so a failed spawn cannot disclose them.
  function openWebPanel(online) {
    if (!root.hasCallerSecret) {
      console.warn("codex-router-tray", "No caller key — cannot open the web panel.")
      return false
    }
    if (!online) {
      console.warn("codex-router-tray", "Router offline — not opening the web panel.")
      return false
    }
    if (webPanelOpener.running) return true
    webPanelOpener.running = true
    webPanelOpener.write(invokeClient.callerUrl("panel/") + "\n")
    return true
  }

  InvokeClient {
    id: invokeClient
    port: root.port
    stateDir: root.stateDir
    healthTimeoutMs: root.healthTimeoutMs
  }

  Process {
    id: webPanelOpener
    running: false
    command: ["sh", "-c", "read -r url && exec xdg-open \"$url\""]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("codex-router-tray", "xdg-open failed")
    }
  }
}

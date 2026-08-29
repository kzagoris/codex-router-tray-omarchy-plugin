import QtQuick
import qs.Commons
import qs.Ui
import "../ui"
import "../Model.js" as Model

// PROVIDERS view: the provider catalog with its enable toggles — a long list
// in a place where it can no longer bury the sections beneath it.
//
// The panel hands over the two reader projections — the Router summary for
// live Router facts, the active-View projection for this View's own Snapshot
// and Provider setup facts — the ControlProcess its mutations run through,
// its own coordinator surface (`panel`: runAction/domainNotice/
// activeControlKey) and the palette.
Item {
  id: providersRoot

  // ------------------------------------------------------------- contract

  // Facts arrive as projections; `service` remains only for the semantic
  // web-panel operation, which is a reader intent rather than a fact.
  property var service: null
  property var summary: null
  property var projection: null
  property var controlProcess: null
  property var panel: null

  // Palette, handed over by the panel.
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(providersRoot.foreground, 1.55)
  property string fontFamily: Style.font.family

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  // ------------------------------------------------------- derived state

  // True while nothing user-facing should accept clicks: the router is
  // unreachable or a mutation is already running.
  readonly property bool actionsLocked: !summary || !summary.online
    || !controlProcess || controlProcess.mutationRunning

  // One guard for every section that needs live, authenticated data: the
  // reader's global blocking condition is exactly that question.
  readonly property bool controlsReachable: !!providersRoot.projection
    && providersRoot.projection.blockingReason === ""

  // The codex target block of this View's own Snapshot — everything the
  // enabled toggle reflects. Empty object until Providers' first read commits.
  readonly property var codexTarget: projection ? projection.target : ({})
  readonly property var enabledProviderIds: Array.isArray(providersRoot.codexTarget.enabledProviders)
    ? providersRoot.codexTarget.enabledProviders : []

  function providerIsEnabled(id) {
    return providersRoot.enabledProviderIds.indexOf(String(id)) >= 0
  }

  // Every catalog provider from provider_setup, configured ones first so the
  // rows that can actually be flipped sit at the top; alphabetical inside
  // each group.
  readonly property var setupProviders: {
    var setup = projection ? projection.providerSetup : null
    var list = setup && Array.isArray(setup.providers) ? setup.providers : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p || String(p.id || "") === "") continue
      out.push({
        id: String(p.id),
        // Router prose, stripped and clamped: these three reach the shell's
        // own tooltip and label items, which do not pin textFormat.
        name: Model.plainText(p.displayName || p.id, 64),
        kind: String(p.kind || "api"),
        configured: p.configured === true,
        action: String(p.action || ""),
        credentialLabel: Model.plainText(p.credentialLabel, 64),
        planNote: Model.plainText(p.planNote, 160)
      })
    }
    out.sort(function(a, b) {
      if (a.configured !== b.configured) return a.configured ? -1 : 1
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
    })
    return out
  }

  function toggleProvider(p) {
    if (!p || !p.configured) return
    if (!panel) return
    var enabling = !providersRoot.providerIsEnabled(p.id)
    panel.runAction("providers", "provider:" + p.id,
      (enabling ? "Enabling " : "Disabling ") + p.name,
      ["set-apply", p.id, enabling ? "on" : "off", "--targets", "codex", "--activate"])
  }

  height: column.implicitHeight

  Column {
    id: column
    // Same guard the old providersSection carried: a bare header over an
    // empty list reads worse than no section, and the status box carries
    // the explanation.
    visible: providersRoot.controlsReachable && providersRoot.setupProviders.length > 0
    width: parent.width
    spacing: Style.spacing.md

    PanelSectionHeader {
      width: parent.width
      text: "PROVIDERS"
      foreground: providersRoot.foreground
      fontFamily: providersRoot.fontFamily
    }

    Repeater {
      model: providersRoot.setupProviders

      ProviderRow {
        required property var modelData
        width: parent.width
        provider: modelData
        enabledState: providersRoot.providerIsEnabled(modelData.id)
        locked: providersRoot.actionsLocked
        busy: !!providersRoot.controlProcess && providersRoot.controlProcess.mutationRunning
        foreground: providersRoot.foreground
        dim: providersRoot.dim
        fontFamily: providersRoot.fontFamily
        onToggleRequested: providersRoot.toggleProvider(modelData)
        onWebPanelRequested: if (providersRoot.service) providersRoot.service.openWebPanel()
      }
    }

    ActionNotice {
      width: parent.width
      notice: providersRoot.panel ? providersRoot.panel.domainNotice("providers") : ""
      running: !!providersRoot.controlProcess && providersRoot.controlProcess.mutationRunning
      dim: providersRoot.dim
      urgent: providersRoot.urgent
      fontFamily: providersRoot.fontFamily
    }
  }
}

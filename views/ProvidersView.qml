import QtQuick
import qs.Commons
import qs.Ui
import "../ui"

// PROVIDERS view: the provider catalog with its enable toggles — a long list
// in a place where it can no longer bury the sections beneath it.
//
// The panel hands over the service, its coordinator surface (`panel`:
// runAction/domainNotice) and the palette.
Item {
  id: providersRoot

  // ------------------------------------------------------------- contract

  property var service: null
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
  readonly property bool actionsLocked: !service || !service.online || service.mutationRunning

  // One guard for every section that needs live, authenticated data.
  readonly property bool controlsReachable: !!service && service.online
    && service.hasCallerSecret

  // Enabled state comes from the snapshot's enabledProviders, not from the
  // setup payload.
  readonly property var codexTarget: service ? service.codexTarget : ({})
  readonly property var enabledProviderIds: Array.isArray(providersRoot.codexTarget.enabledProviders)
    ? providersRoot.codexTarget.enabledProviders : []

  function providerIsEnabled(id) {
    return providersRoot.enabledProviderIds.indexOf(String(id)) >= 0
  }

  // Every catalog provider from provider_setup, configured ones first so the
  // rows that can actually be flipped sit at the top; alphabetical inside
  // each group.
  readonly property var setupProviders: {
    var setup = service ? service.providerSetup : null
    var list = setup && Array.isArray(setup.providers) ? setup.providers : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p || String(p.id || "") === "") continue
      out.push({
        id: String(p.id),
        name: String(p.displayName || p.id),
        kind: String(p.kind || "api"),
        configured: p.configured === true,
        action: String(p.action || ""),
        credentialLabel: String(p.credentialLabel || ""),
        planNote: String(p.planNote || "")
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
        busy: !!providersRoot.service && providersRoot.service.mutationRunning
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
      running: !!providersRoot.service && providersRoot.service.mutationRunning
      dim: providersRoot.dim
      urgent: providersRoot.urgent
      fontFamily: providersRoot.fontFamily
    }
  }
}

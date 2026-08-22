import QtQuick
import qs.Commons
import qs.Ui

// One provider from the setup catalog: configured pill + name, credential
// detail underneath, and on the right either the enable switch (configured)
// or the affordance that hands off to the web panel.
//
// Extracted from Panel.qml. The row is presentation only: enablement state,
// lock and busy come in as properties, and intent leaves through the two
// signals — the enclosing view owns the control-CLI round-trip.
Item {
  id: prow

  property var provider: null

  // Snapshot-derived state, bound by the view:
  // enabledState mirrors enabledProviders, locked is the offline-or-mutating
  // gate, busy is true while any mutation runs.
  property bool enabledState: false
  property bool locked: false
  property bool busy: false

  signal toggleRequested()
  signal webPanelRequested()

  // Palette, handed over by the view that mounts the row.
  property color foreground: Color.foreground
  property color dim: Qt.darker(prow.foreground, 1.55)
  property string fontFamily: Style.font.family

  readonly property bool configured: !!provider && provider.configured === true
  readonly property string cta: provider ? prow.providerCta(provider) : ""
  readonly property string detail: {
    if (!provider) return ""
    var kind = prow.providerKindLabel(provider)
    var note = String(provider.planNote || "")
    return note !== "" ? kind + " · " + note : kind
  }

  implicitHeight: Math.max(provText.implicitHeight, provControl.implicitHeight)

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  function providerKindLabel(p) {
    if (!p) return ""
    if (p.kind === "oauth") return "OAuth sign-in"
    if (p.kind === "anonymous") return "No API key"
    if (p.kind === "per-model") return "Per-model endpoints"
    return p.credentialLabel !== "" ? p.credentialLabel : "API key"
  }

  // Label for the affordance on unconfigured rows. Credentials are
  // deliberately never typed into the plugin — every one of these opens the
  // router's own web panel instead (PLAN.md §4).
  function providerCta(p) {
    if (!p || p.configured || p.kind === "anonymous") return ""
    if (p.kind === "oauth") return "Sign in"
    if (p.action === "install") return "Set up"
    return "Add key"
  }

  Column {
    id: provText
    anchors.left: parent.left
    anchors.right: provControl.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Item {
      width: parent.width
      implicitHeight: Math.max(provPill.height, provName.implicitHeight)

      Rectangle {
        id: provPill
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        radius: height / 2
        width: provPillText.implicitWidth + Style.space(10)
        height: Style.space(16)
        color: prow.configured ? prow.alpha(prow.foreground, 0.14)
          : prow.alpha(prow.foreground, 0.05)

        Text {
          textFormat: Text.PlainText
          id: provPillText
          anchors.centerIn: parent
          text: prow.configured ? "CONFIGURED" : "NOT SET UP"
          color: prow.configured ? prow.foreground : prow.dim
          font.family: prow.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        textFormat: Text.PlainText
        id: provName
        text: prow.provider ? String(prow.provider.name) : ""
        color: prow.foreground
        font.family: prow.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        anchors.left: provPill.right
        anchors.leftMargin: Style.space(8)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: prow.detail
      color: prow.dim
      font.family: prow.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  Item {
    id: provControl
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter

    width: Math.max(provSwitch.implicitWidth, provCta.implicitWidth, provNone.implicitWidth)
    height: Math.max(provSwitch.implicitHeight, provCta.implicitHeight, provNone.implicitHeight)

    ToggleSwitch {
      id: provSwitch
      visible: prow.configured
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: prow.enabledState
      interactive: !prow.locked
      busy: prow.busy
      foreground: prow.foreground
      onToggled: prow.toggleRequested()
    }

    Button {
      id: provCta
      visible: !prow.configured && prow.cta !== ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: prow.cta
      tooltipText: "Opens the router's web panel"
      enabled: !prow.locked
      bordered: true
      foreground: prow.foreground
      fontFamily: prow.fontFamily
      fontSize: Style.font.caption
      onClicked: prow.webPanelRequested()
    }

    Text {
      textFormat: Text.PlainText
      id: provNone
      visible: !prow.configured && prow.cta === ""
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "No key needed"
      color: prow.dim
      font.family: prow.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    id: prowHover
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }

  PanelToolTip {
    visible: prowHover.containsMouse && prow.provider !== null
      && String(prow.provider.planNote || "") !== ""
    text: prow.provider ? String(prow.provider.name) + " · " + String(prow.provider.planNote) : ""
    fontFamily: prow.fontFamily
  }
}

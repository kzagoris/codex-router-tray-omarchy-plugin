import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Codex Router bar widget: a router glyph with an overlaid status dot, plus
// the host for the router panel.
//
// The dot is the whole point of the widget — four states, legible at arm's
// length (PLAN.md §4): green=idle+ok, amber pulsing=generating,
// red=degraded/error, gray=offline. Green and amber have no palette token
// (the theme kit is monochrome plus urgent), so they are local constants on
// the wifiqr `onScrimUrgent` precedent; red and gray come from the theme.
BarWidget {
  id: root
  moduleName: "kzagoris.codex-router-tray"

  // Nerd-font mark (nf-md-router_network). The status dot reads against its
  // lower-right edge; the glyph itself stays tinted plain foreground in
  // every state so the dot carries all the signal.
  readonly property string routerGlyph: "󰒋"

  // ------------------------------------------------------------- service

  RouterService {
    id: router
    healthIntervalSec: root.healthIntervalSec
    portOverride: root.routerPortSetting
  }

  // ------------------------------------------------------------ settings

  readonly property int healthIntervalSec: {
    var n = parseInt(setting("healthIntervalSec", 4), 10)
    return isFinite(n) && n >= 2 ? n : 4
  }
  readonly property string routerPortSetting: {
    var p = parseInt(setting("port", 4202), 10)
    return isFinite(p) && p >= 1024 && p <= 65535 ? String(p) : ""
  }

  // ------------------------------------------------------------ palette

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  // Traffic-light states read at a glance across the desk; themes rarely
  // carry tokens for them. Chosen to sit on any bar background next to the
  // theme's own urgent/muted.
  readonly property color okColor: "#6fae62"
  readonly property color generatingColor: "#c9973f"

  readonly property color dotColor: {
    if (router.state === "generating") return generatingColor
    if (router.state === "error") return urgent
    if (router.state === "idle") return okColor
    return Color.muted
  }

  // While traffic flows the dot breathes; anything static reads "dead"
  // during a long generation.
  readonly property bool pulsing: router.state === "generating"
  onPulsingChanged: if (!pulsing) statusDot.opacity = 1

  // ------------------------------------------------------------- label

  // Manifest enum: "Icon only" | "Provider name". The provider id comes
  // straight off the health payload's activity block; before the first
  // successful poll (and whenever the router is offline) fall back to the
  // module name.
  readonly property bool providerLabelWanted: setting("showProviderText", "Icon only") === "Provider name"
  readonly property string labelText: router.providerName !== "" ? router.providerName : "Codex Router"
  readonly property bool labelVisible: providerLabelWanted && !vertical

  function tooltipSummary() {
    if (router.state === "generating")
      return "Codex Router — generating (" + router.activeCount + " active)"
    if (router.state === "error") {
      var names = router.degradedNames.join(", ")
      return names !== "" ? "Codex Router — degraded: " + names : "Codex Router — error"
    }
    if (router.state === "idle")
      return "Codex Router — idle" + (router.version !== "" ? " · v" + router.version : "")
    return "Codex Router — offline"
  }

  // ---- Panel popup. Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget
  //      root (see clock).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function refresh() {
    router.pollHealth()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // The open-panel indicator sits under the whole painted content when a
  // label shows and under one icon-sized line otherwise — the same geometry
  // every icon widget gets (see clock).
  readonly property real openPanelIndicatorWidth: Math.max(button.labelWidth, contentRow.implicitWidth)
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "kzagoris.codex-router-tray"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.tooltipSummary()
    // An icon-only slot must still be a full icon slot: WidgetButton's own
    // fallback measures its internal (hidden) label, which is empty here,
    // and would squeeze the mark into a sliver that clips the status dot.
    fixedWidth: root.vertical ? -1
      : root.labelVisible ? contentRow.implicitWidth + scaledHorizontalMargin * 2
      : Style.bar.iconSlot
    fixedHeight: root.vertical && !root.labelVisible ? Style.bar.iconSlot : -1

    onPressed: function(b) {
      if (b === Qt.MiddleButton) return // web-panel opener arrives with the controls (phase 4)
      root.togglePanel()
    }

    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Item {
        id: markSlot
        width: glyph.implicitWidth
        height: glyph.implicitHeight

        Text {
          id: glyph
          anchors.centerIn: parent
          text: root.routerGlyph
          color: button.foreground
          font.family: button.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
        }

        // Status dot on the glyph's lower-right edge.
        Rectangle {
          id: statusDot
          width: Style.space(7)
          height: width
          radius: width / 2
          color: root.dotColor
          border.color: root.bar ? root.bar.background : Color.background
          border.width: 1
          anchors.horizontalCenter: glyph.horizontalCenter
          anchors.horizontalCenterOffset: Math.round(glyph.implicitWidth * 0.30)
          anchors.verticalCenter: glyph.verticalCenter
          anchors.verticalCenterOffset: Math.round(glyph.implicitHeight * 0.22)

          SequentialAnimation on opacity {
            running: root.pulsing
            loops: Animation.Infinite

            NumberAnimation { to: 0.3; duration: 650; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1; duration: 650; easing.type: Easing.InOutQuad }
          }
        }
      }

      Text {
        id: trailingLabel
        visible: root.labelVisible
        text: root.labelText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}

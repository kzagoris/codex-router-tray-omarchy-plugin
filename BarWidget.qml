import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Codex Router bar widget: a router glyph with an overlaid status dot, plus
// the host for the router panel.
//
// Phase 1 scaffold — the dot is static and the label is the module name.
// RouterService wiring (live health state, provider text, pulse animation)
// lands in phase 2; the shape contract below already matches what the Bar
// expects from any panel-hosting widget, so summon/hide routing works from
// day one.
BarWidget {
  id: root
  moduleName: "kzagoris.codex-router-tray"

  // Nerd-font mark (nf-md-router_network). The status dot reads against its
  // lower-right edge; the glyph itself stays tinted plain foreground in
  // every state so the dot carries all the signal.
  readonly property string routerGlyph: "󰒋"

  // ------------------------------------------------------------ palette

  readonly property color foreground: bar ? bar.foreground : Color.foreground

  // ------------------------------------------------------------- label

  // Manifest enum: "Icon only" | "Provider name". Until RouterService exists
  // there is no provider name to show, so label mode paints the module name.
  readonly property bool providerLabelWanted: setting("showProviderText", "Icon only") === "Provider name"
  readonly property string labelText: "Codex Router"
  readonly property bool labelVisible: providerLabelWanted && !vertical

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
    tooltipText: root.labelVisible ? "" : "Codex Router"
    // Wide enough for mark + label; plain icon slot otherwise. Vertical bars
    // never show the label, so they keep the natural slot height/width swap.
    fixedWidth: root.vertical || !root.labelVisible ? -1 : contentRow.implicitWidth + scaledHorizontalMargin * 2

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

        // Status dot on the glyph's lower-right edge. Static dim gray until
        // RouterService starts reporting health (phase 2).
        Rectangle {
          id: statusDot
          width: Style.space(7)
          height: width
          radius: width / 2
          color: Qt.darker(root.foreground, 1.8)
          border.color: root.bar ? root.bar.background : Color.background
          border.width: 1
          anchors.horizontalCenter: glyph.horizontalCenter
          anchors.horizontalCenterOffset: Math.round(glyph.implicitWidth * 0.30)
          anchors.verticalCenter: glyph.verticalCenter
          anchors.verticalCenterOffset: Math.round(glyph.implicitHeight * 0.22)
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

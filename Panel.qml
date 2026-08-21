import QtQuick
import qs.Commons
import qs.Ui

// Codex Router popup panel, anchored to the bar button.
//
// Phase 1 stub: palette and panel chrome only. The sections described in
// PLAN.md §4 (hero, status box, mode switches, activity, usage, providers,
// maintenance) are built up in phases 3 and 4 on top of this skeleton.
Panel {
  id: root
  moduleName: "kzagoris.codex-router-tray"
  ipcTarget: "kzagoris.codex-router-tray"
  // The bar widget owns the single IpcHandler for this target (see clock).
  manageIpc: false

  // Injected by BarWidget.injectPanel().
  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel; everything the bar identifies a panel by has to be that
  // widget (see clock).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root  // ------------------------------------------------------------- palette
  //
  // Fills are always alpha steps of foreground so the panel is theme-proof;
  // alarm color only ever comes from `urgent`.

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  function refresh() {
    // RouterService refresh arrives with phase 3.
  }

  // Tab-style walk to the neighboring popout, keyed by the bar widget —
  // PanelKeyCatcher's onTabRequested routes here (see clock).
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(200))

    Column {
      id: column
      width: panel.width
      spacing: Style.space(12)

      PanelHero {
        width: parent.width
        title: "Codex Router"
        meta: ""
        foreground: root.foreground
        fontFamily: root.fontFamily

        iconComponent: Component {
          Item {
            width: Style.font.display
            height: Style.font.display

            Text {
              anchors.centerIn: parent
              text: "󰒋"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }
      }

      Text {
        width: parent.width
        text: "Router status will appear here."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }
}

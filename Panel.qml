import QtQuick
import qs.Commons
import qs.Ui

// Codex Router popup panel, anchored to the bar button.
//
// Phase 2 skeleton: palette, panel chrome, and keyboard wiring. The sections
// described in PLAN.md §4 (status box, mode switches, activity, usage,
// providers, maintenance) are built up in phases 3 and 4 on top of this
// structure — the Flickable/KeyCatcher frame is already the final shape, so
// later phases only add children to `column`.
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

  // ------------------------------------------------------------- palette
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

  // ---- Open/close. Overridden (not inherited) so a hotkey summon suppresses
  //      the bar's center hover reveal: summoning moves no pointer, and the
  //      indicators would stay lit behind the panel otherwise (see clock).
  function open() {
    refresh()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Not root.close(): the override shadows the base method, so that would
    // recurse. The base implementation lives on the controller.
    root.controller.hide()
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Tab-style walk to the neighboring popout, keyed by the bar widget —
  // PanelKeyCatcher's onTabRequested routes here (see clock).
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // The bar identifies this panel by its host slot widget.
  readonly property var barIdentity: hostWidget || root

  function refresh() {
    if (hostWidget && hostWidget.routerService) hostWidget.routerService.pollHealth()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // KeyboardPanel paints a card sized to contentWidth on a full-screen
      // surface; the Flickable is what keeps column measured against the
      // *card*, never the screen.
      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: panelFlick.width
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
  }
}

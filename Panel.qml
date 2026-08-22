import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "views"

// Codex Router popup panel, anchored to the bar button.
//
// Chrome plus a segmented switcher over four mutually exclusive views —
// Status, Usage, Providers, Models (see views/) — so the panel stops being
// one scrolling column and its height stops growing with the feature set.
// Chrome sits outside the switcher: hero, auth/offline status box and
// footer caption render in every view, because the status box is what
// explains an empty view and must never be reachable from only one.
//
// This file owns no section content anymore. It keeps the palette, the
// open/close contract, the anchoring, the Flickable, and the mutation
// coordinator (actionDomain/activeControlKey): busy and error notices must
// follow the control that started them across views.
//
// The selected view is session-scoped state held here — a close/open
// round-trip returns to where you were, a shell restart opens on Status.
// Deliberately not a manifest setting: not something an operator
// configures.
//
// Deviating from the first-party single-column panel idiom is deliberate;
// docs/adr/0001-panel-is-a-view-switcher.md records why — read it before
// "fixing" the deviation against panels/network.
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

  // The RouterService instance lives inside BarWidget; ids are file-scoped,
  // so this alias-by-property is the only route to it.
  readonly property var service: hostWidget ? hostWidget.routerService : null

  // ------------------------------------------------------------- palette

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  // Countdowns and elapsed times read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  // ------------------------------------------------------ view switcher

  readonly property var viewTabs: ["Status", "Usage", "Providers", "Models"]

  // Session-scoped: survives a close/open round-trip, resets when the shell
  // restarts (this object is rebuilt then).
  property int selectedView: 0

  onSelectedViewChanged: if (panelFlick) panelFlick.contentY = 0

  // ---- Open/close. Overridden (not inherited) so a hotkey summon suppresses
  //      the bar's center hover reveal: summoning moves no pointer, and the
  //      indicators would stay lit behind the panel otherwise (see clock).
  function open() {
    refreshNow()
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

  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------------- reading

  function refreshNow() {
    if (!root.service) return
    root.service.pollHealth()
    root.service.refreshData()
  }

  function refresh() {
    refreshNow()
  }

  // The authenticated endpoints are polled only while somebody reads them.
  onOpenedChanged: {
    if (!root.service) return
    root.service.panelOpen = root.opened
    if (opened) {
      nowMs = Date.now()
      if (panelFlick) panelFlick.contentY = 0
      refreshNow()
    }
  }

  // --------------------------------------------------------- chrome state

  // Hero meta line, uppercase small-caps like agents' plan labels.
  function heroMeta() {
    var state = service ? service.routerState : "offline"
    if (state === "offline") return "OFFLINE"
    if (state === "generating") return "GENERATING · " + service.activeCount + " ACTIVE"
    if (state === "error") {
      var names = service.degradedNames.join(", ")
      return (names !== "" ? "DEGRADED: " + names : "ERROR").toUpperCase()
    }
    var version = service.version
    return version !== "" ? "RUNNING · V" + version.toUpperCase() : "RUNNING"
  }

  // One box, worst news first: an unreachable router beats a missing key
  // beats a failed read beats degradation — each earlier line makes the
  // later ones unreadable anyway.
  readonly property string statusMessage: {
    if (!service || service.routerState === "offline")
      return "Router offline — start it with systemctl --user start codex-router."
    if (!service.hasCallerSecret)
      return "Caller key missing or unreadable — run ./bin/doctor --fix to restore it."
    if (service.dataError !== "") return service.dataError
    if (service.degraded)
      return "Degraded providers: " + service.degradedNames.join(", ")
    return ""
  }

  // ------------------------------------------------ mutation coordinator

  // Which section-domain owns the running/last-failed action, so busy and
  // error notices render next to the control that started them rather than
  // in a far corner of whichever view happens to be open. Views hand their
  // clicks here (StatusView, ProvidersView).
  property string actionDomain: ""
  // Which exact control started it, so its own button can swap to a busy
  // label while the rest of the panel merely disables.
  property string activeControlKey: ""

  function runAction(domain, key, label, args) {
    if (!root.service || root.service.mutationRunning) return
    // Offline, only service commands make sense — starting it above all.
    if (!root.service.online && !root.service.isServiceCommand(args)) return
    root.actionDomain = domain
    root.activeControlKey = key
    root.service.runControl(label, args, function(error) {
      if (error === null) root.actionDomain = ""
      root.activeControlKey = ""
    })
  }

  // Busy line while this domain's mutation runs, its error afterwards;
  // empty when the domain is uninvolved.
  function domainNotice(domain) {
    if (!root.service || root.actionDomain !== domain) return ""
    if (root.service.mutationRunning) return root.service.mutationLabel + "…"
    return root.service.mutationError
  }

  // ---------------------------------------------------------------- misc

  function updatedCaption() {
    if (!service || service.lastUpdatedAt <= 0) return ""
    return "Updated " + Model.formatClock(new Date(service.lastUpdatedAt))
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
      onActivateRequested: root.refreshNow()
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      // KeyboardPanel paints a card sized to contentWidth on a full-screen
      // surface; the Flickable is what keeps the column measured against
      // the *card*, never the screen.
      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- View switcher ----------
          // Names the four views; equal-width cells so a click never
          // resizes the popup under the cursor.
          Row {
            width: parent.width
            spacing: Style.spacing.sm

            readonly property real cellWidth: (width - spacing * (root.viewTabs.length - 1))
              / Math.max(1, root.viewTabs.length)

            Repeater {
              model: root.viewTabs

              Button {
                required property var modelData
                required property int index

                width: parent.cellWidth
                text: modelData
                selected: index === root.selectedView
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.selectedView = index
              }
            }
          }

          // ---------- Hero: mark · name · live state ----------
          PanelHero {
            width: parent.width
            title: "Codex Router"
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                width: Style.font.display
                height: Style.font.display

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: "󰒋"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          // ---------- Status / guidance (chrome: every view) ----------
          BorderSurface {
            visible: root.statusMessage !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              textFormat: Text.PlainText
              id: statusText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.statusMessage
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- The active view ----------
          StatusView {
            visible: root.selectedView === 0
            width: parent.width
            service: root.service
            panel: root
            nowMs: root.nowMs
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
          }

          UsageView {
            visible: root.selectedView === 1
            width: parent.width
            service: root.service
            nowMs: root.nowMs
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            track: root.track
            fontFamily: root.fontFamily
            // Same reset the old onTrafficIndexChanged performed on the
            // panel root: reading another provider starts at the top.
            onScrollToTop: if (panelFlick) panelFlick.contentY = 0
          }

          ProvidersView {
            visible: root.selectedView === 2
            width: parent.width
            service: root.service
            panel: root
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
          }

          ModelsView {
            visible: root.selectedView === 3
            // The snapshot is fetched on first entry to this view, not on a
            // timer: the catalog is the largest payload the panel reads.
            active: root.selectedView === 3 && root.opened
            width: parent.width
            service: root.service
            panel: root
            nowMs: root.nowMs
            foreground: root.foreground
            urgent: root.urgent
            dim: root.dim
            fontFamily: root.fontFamily
          }

          // ---------- Footer: manual refresh + freshness stamp (chrome) ----------
          PanelSeparator { foreground: root.foreground }

          Button {
            width: parent.width
            text: root.service && root.service.dataLoading ? "Refreshing…" : "Refresh"
            enabled: !!root.service && !root.service.dataLoading
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.refreshNow()
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: root.updatedCaption()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // Keeps countdowns and elapsed labels honest while the panel is up.
  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: false
    onTriggered: root.nowMs = Date.now()
  }
}

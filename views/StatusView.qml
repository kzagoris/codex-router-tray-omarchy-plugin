import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model
import "../ui"

// STATUS view: what the router is doing and how to fix it. Modes (login-free,
// signed routing), request activity, and maintenance actions — the summary
// view the panel opens on.
//
// The panel hands over the service, its own coordinator surface (`panel`:
// runAction/domainNotice/activeControlKey, so busy and error notices follow
// the control that started them across views), the live clock and the palette.
Item {
  id: statusRoot

  // ------------------------------------------------------------- contract

  property var service: null
  property var panel: null
  property double nowMs: 0

  // Palette, handed over by the panel.
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(statusRoot.foreground, 1.55)
  property string fontFamily: Style.font.family

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  // ------------------------------------------------------- derived state

  // True while nothing user-facing should accept clicks: the router is
  // unreachable or a mutation is already running. Service start is the one
  // action exempt by design (see runAction on the panel).
  readonly property bool actionsLocked: !service || !service.online || service.mutationRunning

  // One guard for every section that needs live, authenticated data.
  readonly property bool controlsReachable: !!service && service.online
    && service.hasCallerSecret

  // The codex target block of the snapshot — everything the mode switches
  // reflect. Empty object until the first read lands.
  readonly property var codexTarget: service ? service.codexTarget : ({})
  readonly property bool loginFree: statusRoot.codexTarget.loginFree === true
  readonly property bool signedRouting: statusRoot.codexTarget.signedRouting === true

  height: column.implicitHeight

  function formatElapsed(ms) {
    var seconds = Math.max(0, Math.floor(ms / 1000))
    if (seconds < 60) return seconds + "s"
    var minutes = Math.floor(seconds / 60)
    seconds %= 60
    if (minutes < 60) return minutes + "m " + Model.pad2(seconds) + "s"
    var hours = Math.floor(minutes / 60)
    minutes %= 60
    return hours + "h " + Model.pad2(minutes) + "m"
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(12)

    // ---------- Mode switches ----------
    Column {
      id: modesSection
      // The toggles mirror snapshot state; without a first read they
      // would show "off" as if it were the truth.
      visible: statusRoot.controlsReachable && !!statusRoot.service.snapshot
      width: parent.width
      spacing: Style.spacing.md

      PanelSectionHeader {
        width: parent.width
        text: "MODES"
        foreground: statusRoot.foreground
        fontFamily: statusRoot.fontFamily
      }

      Toggle {
        width: parent.width
        label: "Login-free mode"
        description: "Route Codex without a ChatGPT sign-in."
        checked: statusRoot.loginFree
        foreground: statusRoot.foreground
        accent: Color.accent
        fontFamily: statusRoot.fontFamily
        opacity: statusRoot.actionsLocked ? 0.55 : 1
        onClicked: if (statusRoot.panel) statusRoot.panel.runAction("modes", "login-free", "Switching login-free mode",
          ["auth-mode", statusRoot.loginFree ? "off" : "on"])
      }

      Toggle {
        width: parent.width
        label: "Signed routing"
        description: "Sign routed requests so upstream responses verify."
        checked: statusRoot.signedRouting
        foreground: statusRoot.foreground
        accent: Color.accent
        fontFamily: statusRoot.fontFamily
        opacity: statusRoot.actionsLocked ? 0.55 : 1
        onClicked: if (statusRoot.panel) statusRoot.panel.runAction("modes", "signed-routing", "Switching signed routing",
          ["signed-routing", statusRoot.signedRouting ? "off" : "on"])
      }

      ActionNotice {
        width: parent.width
        notice: statusRoot.panel ? statusRoot.panel.domainNotice("modes") : ""
        running: !!statusRoot.service && statusRoot.service.mutationRunning
        dim: statusRoot.dim
        urgent: statusRoot.urgent
        fontFamily: statusRoot.fontFamily
      }
    }

    // ---------- Activity ----------
    Column {
      id: activitySection
      visible: !!statusRoot.service && statusRoot.service.online
      width: parent.width
      spacing: Style.spacing.md

      PanelSectionHeader {
        width: parent.width
        text: "ACTIVITY"
        foreground: statusRoot.foreground
        fontFamily: statusRoot.fontFamily
      }

      // Idle collapses to one honest line; traffic lists itself.
      Text {
        textFormat: Text.PlainText
        visible: statusRoot.service && statusRoot.service.activeCount === 0
        width: parent.width
        text: {
          var provider = statusRoot.service ? statusRoot.service.lastProviderName : ""
          return provider !== ""
            ? "Idle — last routed via " + provider
            : "Idle — no routed requests yet."
        }
        color: statusRoot.dim
        font.family: statusRoot.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Repeater {
        model: statusRoot.service ? statusRoot.service.activeRequests : []

        Column {
          id: requestRow
          required property var modelData
          width: parent.width
          spacing: Style.space(2)

          readonly property bool stale: !modelData

          Rectangle {
            width: parent.width
            height: 1
            color: requestRow.stale ? "transparent" : statusRoot.alpha(statusRoot.foreground, 0.06)
          }

          Item {
            width: parent.width
            implicitHeight: requestProvider.implicitHeight

            Text {
              textFormat: Text.PlainText
              id: requestProvider
              text: requestRow.modelData ? String(requestRow.modelData.provider || "request") : ""
              color: statusRoot.foreground
              font.family: statusRoot.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
              anchors.left: parent.left
              anchors.right: requestElapsed.left
              anchors.rightMargin: Style.space(8)
            }

            Text {
              textFormat: Text.PlainText
              id: requestElapsed
              text: {
                var startedAt = requestRow.modelData ? Number(requestRow.modelData.startedAt) : 0
                return startedAt > 0 ? statusRoot.formatElapsed(statusRoot.nowMs - startedAt) : ""
              }
              color: statusRoot.dim
              font.family: statusRoot.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: {
              if (!requestRow.modelData) return ""
              var model = String(requestRow.modelData.model || "")
              var session = String(requestRow.modelData.sessionName || "")
              if (model !== "" && session !== "") return model + " · " + session
              return model !== "" ? model : session
            }
            color: statusRoot.dim
            font.family: statusRoot.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }

    // ---------- Maintenance ----------
    PanelSeparator {
      visible: maintenanceSection.visible
      foreground: statusRoot.foreground
    }

    Column {
      id: maintenanceSection
      visible: !!statusRoot.service
      width: parent.width
      spacing: Style.spacing.md

      PanelSectionHeader {
        width: parent.width
        text: "MAINTENANCE"
        foreground: statusRoot.foreground
        fontFamily: statusRoot.fontFamily
      }

      // Offline, starting the service is the one action that makes
      // sense — everything else needs a router to talk to.
      Button {
        visible: !statusRoot.service || !statusRoot.service.online
        width: parent.width
        readonly property bool mine: !!statusRoot.panel && statusRoot.panel.activeControlKey === "start"
          && !!statusRoot.service && statusRoot.service.mutationRunning
        text: mine ? "Starting…" : "Start service"
        enabled: !!statusRoot.service && !statusRoot.service.mutationRunning
        bordered: true
        foreground: statusRoot.foreground
        fontFamily: statusRoot.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: if (statusRoot.panel) statusRoot.panel.runAction("maintenance", "start", "Starting service",
          ["service", "start"])
      }

      Row {
        visible: !!statusRoot.service && statusRoot.service.online
        width: parent.width
        spacing: Style.spacing.sm

        readonly property real cellWidth: (width - spacing * 2) / 3

        Button {
          width: parent.cellWidth
          readonly property bool mine: !!statusRoot.panel && statusRoot.panel.activeControlKey === "restart"
            && !!statusRoot.service && statusRoot.service.mutationRunning
          text: mine ? "Restarting…" : "Restart"
          tooltipText: "Restart the codex-router service"
          enabled: !statusRoot.actionsLocked
          bordered: true
          foreground: statusRoot.foreground
          fontFamily: statusRoot.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: if (statusRoot.panel) statusRoot.panel.runAction("maintenance", "restart", "Restarting service",
            ["service", "restart"])
        }

        Button {
          width: parent.cellWidth
          readonly property bool mine: !!statusRoot.panel && statusRoot.panel.activeControlKey === "update"
            && !!statusRoot.service && statusRoot.service.mutationRunning
          text: mine ? "Updating…" : "Update"
          tooltipText: "Run the router's maintenance task"
          enabled: !statusRoot.actionsLocked
          bordered: true
          foreground: statusRoot.foreground
          fontFamily: statusRoot.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: if (statusRoot.panel) statusRoot.panel.runAction("maintenance", "update", "Running maintenance",
            ["maintenance"])
        }

        Button {
          width: parent.cellWidth
          readonly property bool mine: !!statusRoot.panel && statusRoot.panel.activeControlKey === "fix"
            && !!statusRoot.service && statusRoot.service.mutationRunning
          text: mine ? "Fixing…" : "Fix"
          tooltipText: "Run doctor --fix to repair the installation"
          enabled: !statusRoot.actionsLocked
          bordered: true
          foreground: statusRoot.foreground
          fontFamily: statusRoot.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: if (statusRoot.panel) statusRoot.panel.runAction("maintenance", "fix", "Running doctor fix",
            ["doctor", "--fix", "--json"])
        }
      }

      Button {
        visible: !!statusRoot.service && statusRoot.service.online
        width: parent.width
        text: "Open web panel"
        tooltipText: "Opens the router's browser panel — sign-ins and API keys live there"
        enabled: !!statusRoot.service && !statusRoot.service.mutationRunning
        bordered: true
        foreground: statusRoot.foreground
        fontFamily: statusRoot.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: if (statusRoot.service) statusRoot.service.openWebPanel()
      }

      ActionNotice {
        width: parent.width
        notice: statusRoot.panel ? statusRoot.panel.domainNotice("maintenance") : ""
        running: !!statusRoot.service && statusRoot.service.mutationRunning
        dim: statusRoot.dim
        urgent: statusRoot.urgent
        fontFamily: statusRoot.fontFamily
      }
    }
  }
}

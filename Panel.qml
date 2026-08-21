import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Codex Router popup panel, anchored to the bar button.
//
// Read-only surface (phase 3): live state hero, guidance/status box,
// request activity, and per-provider token usage drawn through the same
// command bridge the router's browser panel uses. Mutating controls land
// in phase 4 on top of this column.
//
// Visual vocabulary follows omarchy.agents: fills are alpha steps of
// foreground so the panel is theme-proof, alarm color only ever comes from
// `urgent`, and the shared Panel* components carry the chrome.
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

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  // Countdowns and elapsed times read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

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

  // --------------------------------------------------------- derived state

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

  // Providers that have actually carried traffic — the usage switch would
  // be unusable with all thirty-plus catalog entries on it.
  readonly property var trafficProviders: {
    var out = []
    var usage = service ? service.providerUsage : null
    var list = usage && Array.isArray(usage.providers) ? usage.providers : []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p) continue
      var total = Number(p.totalTokens) || 0
      var requests = Number(p.requests) || 0
      if (total <= 0 && requests <= 0) continue
      out.push({
        id: String(p.id || ""),
        name: String(p.displayName || p.id || "unknown"),
        total: total,
        requests: requests,
        last24h: Number(p.last24hTokens) || 0,
        last24hRequests: Number(p.last24hRequests) || 0,
        buckets: Array.isArray(p.dailyUsageBuckets) ? p.dailyUsageBuckets : []
      })
    }
    out.sort(function(a, b) { return b.total - a.total })
    return out
  }

  // Selection follows the provider id, not its slot: a fresh payload that
  // reshuffles the order must not swap what you were reading.
  property string selectedProviderId: ""
  readonly property int trafficIndex: {
    for (var i = 0; i < trafficProviders.length; i++)
      if (trafficProviders[i].id === selectedProviderId) return i
    return 0
  }
  readonly property var selectedProvider: trafficProviders.length > 0
    ? trafficProviders[trafficIndex] : null

  onTrafficIndexChanged: if (panelFlick) panelFlick.contentY = 0

  // The local calendar day, as a string. daySeries and the Today row key
  // off this rather than raw nowMs: a per-second Date would rebuild the
  // series (and with it every DayRow) each tick, dropping hover states and
  // width animations for nothing — the value only moves at midnight.
  readonly property string todayKey: Model.localDateKey(new Date(nowMs))

  readonly property var daySeries: selectedProvider
    ? Model.dailySeries(selectedProvider.buckets, 7, new Date(todayKey + "T12:00:00"))
    : []

  function dayRequests(dateKey) {
    if (!selectedProvider) return 0
    return Model.bucketValue(selectedProvider.buckets, dateKey, "requests")
  }

  readonly property real dayPeak: {
    var peak = 1
    for (var i = 0; i < daySeries.length; i++) peak = Math.max(peak, daySeries[i].tokens)
    return peak
  }

  function dayTooltip(day) {
    if (!day) return ""
    var text = day.longLabel + " · " + Model.exactTokens(day.tokens) + " tokens"
    var requests = dayRequests(day.key)
    if (requests > 0) text += " · " + requests + " requests"
    return text
  }

  // Quota windows come from the slow account call plus whatever the usage
  // payload carries locally; both sources dedupe inside buildQuotaCards.
  readonly property var quotaCards: (service && service.accountUsageEnabled && service.accountUsage)
    ? Model.buildQuotaCards({
        account: service.accountUsage,
        providerUsage: service.providerUsage,
        providerSetup: service.providerSetup
      })
    : []

  readonly property bool quotaUnavailable: !!service && service.accountUsageEnabled
    && !service.accountUsage && service.accountUsageFailed

  // ---------------------------------------------------------------- misc

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
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

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
                  anchors.centerIn: parent
                  text: "󰒋"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          // ---------- Status / guidance ----------
          BorderSurface {
            visible: root.statusMessage !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
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

          // ---------- Activity ----------
          Column {
            id: activitySection
            visible: !!root.service && root.service.online
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "ACTIVITY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Idle collapses to one honest line; traffic lists itself.
            Text {
              visible: root.service && root.service.activeCount === 0
              width: parent.width
              text: {
                var provider = root.service ? root.service.lastProviderName : ""
                return provider !== ""
                  ? "Idle — last routed via " + provider
                  : "Idle — no routed requests yet."
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Repeater {
              model: root.service ? root.service.activeRequests : []

              Column {
                id: requestRow
                required property var modelData
                width: parent.width
                spacing: Style.space(2)

                readonly property bool stale: !modelData

                Rectangle {
                  width: parent.width
                  height: 1
                  color: requestRow.stale ? "transparent" : root.alpha(root.foreground, 0.06)
                }

                Item {
                  width: parent.width
                  implicitHeight: requestProvider.implicitHeight

                  Text {
                    id: requestProvider
                    text: requestRow.modelData ? String(requestRow.modelData.provider || "request") : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                    anchors.left: parent.left
                    anchors.right: requestElapsed.left
                    anchors.rightMargin: Style.space(8)
                  }

                  Text {
                    id: requestElapsed
                    text: {
                      var startedAt = requestRow.modelData ? Number(requestRow.modelData.startedAt) : 0
                      return startedAt > 0 ? root.formatElapsed(root.nowMs - startedAt) : ""
                    }
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.right: parent.right
                  }
                }

                Text {
                  visible: text !== ""
                  width: parent.width
                  text: {
                    if (!requestRow.modelData) return ""
                    var model = String(requestRow.modelData.model || "")
                    var session = String(requestRow.modelData.sessionName || "")
                    if (model !== "" && session !== "") return model + " · " + session
                    return model !== "" ? model : session
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.service && root.service.online && root.service.hasCallerSecret
            width: parent.width
            spacing: Style.spacing.md

            // Waiting for the very first payload of a session reads better
            // than an empty frame that flickers in a moment later.
            Text {
              visible: root.service && root.service.dataLoading && !root.selectedProvider
                && root.quotaCards.length === 0
              width: parent.width
              topPadding: Style.space(6)
              text: "Reading router state…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: root.service && !root.service.dataLoading
                && root.trafficProviders.length === 0 && root.quotaCards.length === 0
              width: parent.width
              topPadding: Style.space(6)
              text: "Router online — no routed traffic yet.\nUsage shows up after the first request."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            // ---------- Provider switch ----------
            Row {
              visible: root.trafficProviders.length > 1
              width: parent.width
              spacing: Style.spacing.sm

              readonly property real cellWidth: (width - spacing * (root.trafficProviders.length - 1))
                / Math.max(1, root.trafficProviders.length)

              Repeater {
                model: root.trafficProviders

                Button {
                  required property var modelData
                  required property int index

                  width: parent.cellWidth
                  text: modelData.name
                  selected: index === root.trafficIndex
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: root.selectedProviderId = modelData.id
                }
              }
            }

            // ---------- Quota (only when the user opted in) ----------
            Column {
              visible: root.quotaCards.length > 0 || root.quotaUnavailable
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                width: parent.width
                text: "LIMITS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.quotaCards

                Column {
                  id: quotaRow
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(6)

                  readonly property bool alarming: modelData.usedPercent !== null
                    && modelData.usedPercent >= 90

                  Item {
                    width: parent.width
                    implicitHeight: quotaLabel.implicitHeight

                    Text {
                      id: quotaLabel
                      text: quotaRow.modelData.label + " · " + quotaRow.modelData.providerName
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      anchors.left: parent.left
                      anchors.right: quotaValue.left
                      anchors.rightMargin: Style.spacing.sm
                    }

                    Text {
                      id: quotaValue
                      text: quotaRow.modelData.usedPercent !== null
                        ? Math.round(quotaRow.modelData.usedPercent) + "% used" : "—"
                      color: quotaRow.alarming ? root.urgent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.right: parent.right
                    }
                  }

                  Meter {
                    width: parent.width
                    value: quotaRow.modelData.usedPercent !== null ? quotaRow.modelData.usedPercent / 100 : -1
                    alarming: quotaRow.alarming
                  }

                  Text {
                    visible: text !== ""
                    width: parent.width
                    // §4 asks for a live countdown; keep the absolute time
                    // as the fallback when no usable reset stamp arrived.
                    text: {
                      if (!quotaRow.modelData.resetAt) return ""
                      var now = new Date(root.nowMs)
                      return Model.formatResetIn(quotaRow.modelData.resetAt, now)
                        || Model.formatReset(quotaRow.modelData.resetAt, now)
                    }
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Text {
                visible: root.quotaUnavailable && root.quotaCards.length === 0
                width: parent.width
                text: "ChatGPT quota unavailable — the upstream call timed out."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // ---------- Tokens by day ----------
            Column {
              visible: root.daySeries.length > 0
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                width: parent.width
                text: "TOKENS BY DAY"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.daySeries

                DayRow {
                  required property var modelData
                  width: usageSection.width
                  day: modelData
                  ratio: modelData.tokens / root.dayPeak
                  // By date, not by position: a payload generated before
                  // midnight must not light yesterday as "Today".
                  today: String(modelData.key) === root.todayKey
                }
              }
            }

            // ---------- Tokens by provider ----------
            Column {
              visible: root.trafficProviders.length > 1
              width: parent.width
              spacing: Style.spacing.md

              PanelSectionHeader {
                width: parent.width
                text: "TOKENS BY PROVIDER"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.trafficProviders.slice(0, 8)

                ModelRow {
                  required property var modelData
                  width: parent.width
                  name: modelData.name
                  tokens: Model.compactTokens(modelData.total)
                  tooltip: modelData.name + " · " + Model.exactTokens(modelData.total)
                    + " tokens · " + modelData.requests + " requests"
                  // Scaled to the heaviest provider, so the top row is always
                  // full — the same scale-to-peak the day chart uses.
                  share: root.trafficProviders.length > 0
                    && root.trafficProviders[0].total > 0
                    ? modelData.total / root.trafficProviders[0].total : 0
                }
              }
            }
          }

          // ---------- Footer: manual refresh + freshness stamp ----------
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

  // Rounded track showing a fraction of an allowance.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      text: dayRow.day ? String(dayRow.day.label) : ""
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      text: dayRow.day ? Model.compactTokens(dayRow.day.tokens) : ""
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day)
      fontFamily: root.fontFamily
    }
  }

  // Roll-up rows read as a table: the share bar fills the row behind the
  // label instead of stacking under it, which keeps the dashboard on one
  // screen (omarchy.agents' ModelRow pattern).
  component ModelRow: Item {
    id: modelRow
    property string name: ""
    property string tokens: ""
    property string tooltip: ""
    property real share: 0

    implicitHeight: nameLabel.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: nameLabel
      text: modelRow.name
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: tokensLabel.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: tokensLabel
      text: modelRow.tokens
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: rowHover.containsMouse
      text: modelRow.tooltip
      fontFamily: root.fontFamily
    }
  }
}

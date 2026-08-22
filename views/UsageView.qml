import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model
import "../ui"

// USAGE view: what the router has spent. Limits (when the operator opted in
// to the ChatGPT account call), tokens by day for the selected provider, and
// the by-provider roll-up — the charts share one screen instead of competing
// with unrelated controls.
//
// The panel hands over the service, the live clock and the palette. The
// provider selection is session-scoped state owned here: it survives a
// close/open round-trip and resets when the shell restarts.
Item {
  id: usageRoot

  // ------------------------------------------------------------- contract

  property var service: null
  property double nowMs: 0

  // Palette, handed over by the panel.
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(usageRoot.foreground, 1.55)
  property color track: Style.selectedFillFor(usageRoot.foreground, Color.accent)
  property string fontFamily: Style.font.family

  // The panel resets its scroll when a view asks to — same contract as the
  // old onTrafficIndexChanged reset on the panel root.
  signal scrollToTop()

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  // ------------------------------------------------------- derived state

  // One guard for every section that needs live, authenticated data.
  readonly property bool controlsReachable: !!service && service.online
    && service.hasCallerSecret

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

  onTrafficIndexChanged: if (visible) usageRoot.scrollToTop()

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

  height: column.implicitHeight

  Column {
    id: column
    // Same guard the old usageSection carried: nothing here means anything
    // without a reachable router, and the status box carries the
    // explanation instead.
    visible: usageRoot.controlsReachable
    width: parent.width
    spacing: Style.spacing.md

    // Waiting for the very first payload of a session reads better
    // than an empty frame that flickers in a moment later.
    Text {
      textFormat: Text.PlainText
      visible: usageRoot.service && usageRoot.service.dataLoading && !usageRoot.selectedProvider
        && usageRoot.quotaCards.length === 0
      width: parent.width
      topPadding: Style.space(6)
      text: "Reading router state…"
      color: usageRoot.dim
      font.family: usageRoot.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      textFormat: Text.PlainText
      visible: !!usageRoot.service && !usageRoot.service.dataLoading
        && usageRoot.trafficProviders.length === 0 && usageRoot.quotaCards.length === 0
      width: parent.width
      topPadding: Style.space(6)
      text: "Router online — no routed traffic yet.\nUsage shows up after the first request."
      color: usageRoot.dim
      font.family: usageRoot.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }

    // ---------- Provider switch ----------
    Row {
      visible: usageRoot.trafficProviders.length > 1
      width: parent.width
      spacing: Style.spacing.sm

      readonly property real cellWidth: (width - spacing * (usageRoot.trafficProviders.length - 1))
        / Math.max(1, usageRoot.trafficProviders.length)

      Repeater {
        model: usageRoot.trafficProviders

        Button {
          required property var modelData
          required property int index

          width: parent.cellWidth
          text: modelData.name
          selected: index === usageRoot.trafficIndex
          bordered: true
          foreground: usageRoot.foreground
          fontFamily: usageRoot.fontFamily
          fontSize: Style.font.bodySmall
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: usageRoot.selectedProviderId = modelData.id
        }
      }
    }

    // ---------- Quota (only when the user opted in) ----------
    Column {
      visible: usageRoot.quotaCards.length > 0 || usageRoot.quotaUnavailable
      width: parent.width
      spacing: Style.space(10)

      PanelSectionHeader {
        width: parent.width
        text: "LIMITS"
        foreground: usageRoot.foreground
        fontFamily: usageRoot.fontFamily
      }

      Repeater {
        model: usageRoot.quotaCards

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
              textFormat: Text.PlainText
              id: quotaLabel
              text: quotaRow.modelData.label + " · " + quotaRow.modelData.providerName
              color: usageRoot.foreground
              font.family: usageRoot.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              anchors.left: parent.left
              anchors.right: quotaValue.left
              anchors.rightMargin: Style.spacing.sm
            }

            Text {
              textFormat: Text.PlainText
              id: quotaValue
              text: quotaRow.modelData.usedPercent !== null
                ? Math.round(quotaRow.modelData.usedPercent) + "% used" : "—"
              color: quotaRow.alarming ? usageRoot.urgent : usageRoot.foreground
              font.family: usageRoot.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
            }
          }

          Meter {
            width: parent.width
            value: quotaRow.modelData.usedPercent !== null ? quotaRow.modelData.usedPercent / 100 : -1
            alarming: quotaRow.alarming
            foreground: usageRoot.foreground
            urgent: usageRoot.urgent
            track: usageRoot.track
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            // §4 asks for a live countdown; keep the absolute time
            // as the fallback when no usable reset stamp arrived.
            text: {
              if (!quotaRow.modelData.resetAt) return ""
              var now = new Date(usageRoot.nowMs)
              return Model.formatResetIn(quotaRow.modelData.resetAt, now)
                || Model.formatReset(quotaRow.modelData.resetAt, now)
            }
            color: usageRoot.dim
            font.family: usageRoot.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: usageRoot.quotaUnavailable && usageRoot.quotaCards.length === 0
        width: parent.width
        text: "ChatGPT quota unavailable — the upstream call timed out."
        color: usageRoot.dim
        font.family: usageRoot.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    // ---------- Tokens by day ----------
    Column {
      visible: usageRoot.daySeries.length > 0
      width: parent.width
      spacing: Style.space(10)

      PanelSectionHeader {
        width: parent.width
        text: "TOKENS BY DAY"
        foreground: usageRoot.foreground
        fontFamily: usageRoot.fontFamily
      }

      Repeater {
        model: usageRoot.daySeries

        DayRow {
          required property var modelData
          width: parent.width
          day: modelData
          ratio: modelData.tokens / usageRoot.dayPeak
          // By date, not by position: a payload generated before
          // midnight must not light yesterday as "Today".
          today: String(modelData.key) === usageRoot.todayKey
          tooltipText: usageRoot.dayTooltip(modelData)
          foreground: usageRoot.foreground
          dim: usageRoot.dim
          track: usageRoot.track
          fontFamily: usageRoot.fontFamily
        }
      }
    }

    // ---------- Tokens by provider ----------
    Column {
      visible: usageRoot.trafficProviders.length > 1
      width: parent.width
      spacing: Style.spacing.md

      PanelSectionHeader {
        width: parent.width
        text: "TOKENS BY PROVIDER"
        foreground: usageRoot.foreground
        fontFamily: usageRoot.fontFamily
      }

      Repeater {
        model: usageRoot.trafficProviders.slice(0, 8)

        ShareRow {
          required property var modelData
          width: parent.width
          name: modelData.name
          tokens: Model.compactTokens(modelData.total)
          tooltip: modelData.name + " · " + Model.exactTokens(modelData.total)
            + " tokens · " + modelData.requests + " requests"
          // Scaled to the heaviest provider, so the top row is always
          // full — the same scale-to-peak the day chart uses.
          share: usageRoot.trafficProviders.length > 0
            && usageRoot.trafficProviders[0].total > 0
            ? modelData.total / usageRoot.trafficProviders[0].total : 0
          foreground: usageRoot.foreground
          dim: usageRoot.dim
          fontFamily: usageRoot.fontFamily
        }
      }
    }
  }
}

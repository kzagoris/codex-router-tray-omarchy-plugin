import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model
import "../ui"

// USAGE view: what the router has spent, and what is left. The pills pick one
// Provider and scope everything down to TOKENS BY DAY — LIMITS, FUNDING and
// ACCOUNTS all belong to that Provider (ADR-0002). TOKENS BY PROVIDER stays
// global: it is a roll-up by definition. Balances answer "what will fund my
// next request" and are value-only unless the metric carries a genuine
// used-percent.
//
// The panel hands over the active-View projection: this View's own Provider
// facts, its loading state, and the account-usage sub-state with its own
// value, loading, error and freshness. Entering the view is a declaration the
// panel makes, so nothing here composes a read; the provider selection is
// session-scoped state owned here — it survives a close/open round-trip and
// resets when the shell restarts.
Item {
  id: usageRoot

  // ------------------------------------------------------------- contract

  property var projection: null
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

  // One guard for every section that needs live, authenticated data: the
  // reader's global blocking condition is exactly that question.
  readonly property bool controlsReachable: !!usageRoot.projection
    && usageRoot.projection.blockingReason === ""

  // Everything the pills, the sections and the roll-up read comes out of one
  // shape, assembled once per payload: the Model builders are pure and the
  // view holds no copy of what they decide.
  readonly property var sources: ({
    account: usageRoot.projection ? usageRoot.projection.accountUsage : null,
    accountLoading: !!usageRoot.projection && usageRoot.projection.accountUsageLoading,
    providerUsage: usageRoot.projection ? usageRoot.projection.providerUsage : null,
    providerSetup: usageRoot.projection ? usageRoot.projection.providerSetup : null
  })

  // Providers that earn a pill: traffic, or an allowance worth reading even
  // before the first request (ADR-0002). The switch would be unusable with
  // all thirty-plus catalog entries on it.
  readonly property var pillProviders: Model.usageProviders(usageRoot.sources)

  // The roll-up counts spend, so it stays on the providers that spent.
  readonly property var trafficProviders: {
    var out = []
    for (var i = 0; i < usageRoot.pillProviders.length; i++) {
      var p = usageRoot.pillProviders[i]
      if (p.total > 0 || p.requests > 0) out.push(p)
    }
    return out
  }

  // Selection follows the provider id, not its slot: a fresh payload that
  // reshuffles the order must not swap what you were reading.
  property string selectedProviderId: ""
  readonly property int selectedIndex: {
    for (var i = 0; i < pillProviders.length; i++)
      if (pillProviders[i].id === selectedProviderId) return i
    return 0
  }
  readonly property var selectedProvider: pillProviders.length > 0
    ? pillProviders[selectedIndex] : null

  onSelectedIndexChanged: if (visible) usageRoot.scrollToTop()

  // The local calendar day, as a string. daySeries and the Today row key
  // off this rather than raw nowMs: a per-second Date would rebuild the
  // series (and with it every DayRow) each tick, dropping hover states and
  // width animations for nothing — the value only moves at midnight.
  readonly property string todayKey: Model.localDateKey(new Date(nowMs))

  // A Provider that earned its pill on an allowance alone has no history to
  // draw: seven empty bars would answer a question nobody asked.
  readonly property var daySeries: selectedProvider
    && (selectedProvider.total > 0 || selectedProvider.requests > 0)
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

  // The id the sections are scoped to. Not `selectedProviderId`, which stays
  // empty until the operator picks a pill.
  readonly property string selectedProviderKey: usageRoot.selectedProvider
    ? usageRoot.selectedProvider.id : ""

  // Limit windows come from the slow account read plus whatever the usage
  // payload carries locally; both sources dedupe inside buildLimitWindows.
  // Provider-sourced windows publish the moment provider_usage commits — the
  // slow read never holds them up.
  readonly property var limitWindows: usageRoot.projection
    ? Model.forProvider(Model.buildLimitWindows(usageRoot.sources), usageRoot.selectedProviderKey)
    : []

  readonly property var balanceRows: usageRoot.projection
    ? Model.forProvider(Model.buildBalanceRows(usageRoot.sources), usageRoot.selectedProviderKey)
    : []

  readonly property var accountNotes: usageRoot.projection
    ? Model.forProvider(Model.buildAccountNotes(usageRoot.sources), usageRoot.selectedProviderKey)
    : []

  // The account read is the only source of the ChatGPT windows, and it is the
  // only slow one. Under its pill the slot says what it is doing instead of
  // vanishing and reappearing.
  readonly property bool accountSlot: Model.isAccountProvider(usageRoot.selectedProviderKey)

  readonly property bool accountLoadingSlot: usageRoot.accountSlot
    && !!usageRoot.projection && usageRoot.projection.accountUsageLoading
    && usageRoot.limitWindows.length === 0

  // A failed account read keeps whatever it had: an hour-old percentage
  // beats nothing, and the line joins the cards rather than replacing them.
  // It also stands alone when there was nothing to keep — a read that was
  // attempted and failed is something to report, which is what separates
  // this slot from the empty section a silent Provider gets.
  // Keyed on the sub-state's own error, so a retry clears it while the
  // replacement attempt runs and core Provider facts never decide this line.
  readonly property bool accountErrorSlot: usageRoot.accountSlot
    && !!usageRoot.projection && !usageRoot.projection.accountUsageLoading
    && usageRoot.projection.accountUsageError !== ""

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
      visible: usageRoot.projection && usageRoot.projection.refreshing
        && !usageRoot.selectedProvider
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
      visible: !!usageRoot.projection && !usageRoot.projection.refreshing
        && usageRoot.pillProviders.length === 0
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
    // One Provider is still worth a pill: it names whose limits these are.
    Row {
      visible: usageRoot.pillProviders.length > 0
      width: parent.width
      spacing: Style.spacing.sm

      readonly property real cellWidth: (width - spacing * (usageRoot.pillProviders.length - 1))
        / Math.max(1, usageRoot.pillProviders.length)

      Repeater {
        model: usageRoot.pillProviders

        Button {
          required property var modelData
          required property int index

          width: parent.cellWidth
          text: modelData.name
          selected: index === usageRoot.selectedIndex
          bordered: true
          foreground: usageRoot.foreground
          fontFamily: usageRoot.fontFamily
          fontSize: Style.font.bodySmall
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: usageRoot.selectedProviderId = modelData.id
        }
      }
    }

    // ---------- Limits, for the selected provider ----------
    // A provider with nothing to report has no section at all — no header,
    // no placeholder. The ChatGPT slot is the one exception: it says it is
    // reading rather than showing an empty frame that fills a second later.
    Column {
      visible: usageRoot.limitWindows.length > 0 || usageRoot.accountLoadingSlot
        || usageRoot.accountErrorSlot
      width: parent.width
      spacing: Style.space(10)

      PanelSectionHeader {
        width: parent.width
        text: "LIMITS"
        foreground: usageRoot.foreground
        fontFamily: usageRoot.fontFamily
      }

      Repeater {
        model: usageRoot.limitWindows

        Column {
          id: limitRow
          required property var modelData
          width: parent.width
          spacing: Style.space(6)

          readonly property bool alarming: modelData.usedPercent !== null
            && modelData.usedPercent >= 90

          Item {
            width: parent.width
            implicitHeight: limitLabel.implicitHeight

            Text {
              textFormat: Text.PlainText
              id: limitLabel
              // Bare title: the pill above already says whose window this is.
              text: limitRow.modelData.label
              color: usageRoot.foreground
              font.family: usageRoot.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              anchors.left: parent.left
              anchors.right: limitValue.left
              anchors.rightMargin: Style.spacing.sm
            }

            Text {
              textFormat: Text.PlainText
              id: limitValue
              text: limitRow.modelData.usedPercent !== null
                ? Math.round(limitRow.modelData.usedPercent) + "%" : "—"
              color: limitRow.alarming ? usageRoot.urgent : usageRoot.foreground
              font.family: usageRoot.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
            }
          }

          Meter {
            width: parent.width
            value: limitRow.modelData.usedPercent !== null ? limitRow.modelData.usedPercent / 100 : -1
            alarming: limitRow.alarming
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
              if (!limitRow.modelData.resetAt) return ""
              var now = new Date(usageRoot.nowMs)
              return Model.formatResetIn(limitRow.modelData.resetAt, now)
                || Model.formatReset(limitRow.modelData.resetAt, now)
            }
            color: usageRoot.dim
            font.family: usageRoot.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // The slow read holds its own slot: neither line names a cause it
      // cannot know, and neither blanks the cards already on screen.
      Text {
        textFormat: Text.PlainText
        visible: usageRoot.accountLoadingSlot
        width: parent.width
        text: "Reading ChatGPT limits…"
        color: usageRoot.dim
        font.family: usageRoot.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        visible: usageRoot.accountErrorSlot
        width: parent.width
        text: "ChatGPT limits unavailable"
        color: usageRoot.dim
        font.family: usageRoot.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    // ---------- Funding (provider-reported balances) ----------
    Column {
      visible: usageRoot.balanceRows.length > 0
      width: parent.width
      spacing: Style.space(8)

      PanelSectionHeader {
        width: parent.width
        text: "FUNDING"
        foreground: usageRoot.foreground
        fontFamily: usageRoot.fontFamily
      }

      Repeater {
        model: usageRoot.balanceRows

        Column {
          id: balanceRow
          required property var modelData
          width: parent.width
          spacing: Style.space(2)

          Item {
            width: parent.width
            implicitHeight: balanceLabel.implicitHeight

            Text {
              textFormat: Text.PlainText
              id: balanceLabel
              // Bare, for the same reason a limit row is: the pill says who.
              text: balanceRow.modelData.label
              color: usageRoot.foreground
              font.family: usageRoot.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              anchors.left: parent.left
              anchors.right: balanceValue.left
              anchors.rightMargin: Style.spacing.sm
            }

            Text {
              textFormat: Text.PlainText
              id: balanceValue
              text: balanceRow.modelData.valueText
                + (balanceRow.modelData.currency !== ""
                   ? " " + balanceRow.modelData.currency : "")
              color: balanceRow.modelData.available === false
                ? usageRoot.dim : usageRoot.foreground
              font.family: usageRoot.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              anchors.right: parent.right
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: balanceRow.modelData.available === false
            width: parent.width
            text: "Unavailable"
            color: usageRoot.urgent
            font.family: usageRoot.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            visible: balanceRow.modelData.detail !== ""
            width: parent.width
            text: balanceRow.modelData.detail
            color: usageRoot.dim
            font.family: usageRoot.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Meter {
            width: parent.width
            visible: balanceRow.modelData.usedPercent !== undefined
              && balanceRow.modelData.usedPercent !== null
            value: balanceRow.modelData.usedPercent !== undefined
              && balanceRow.modelData.usedPercent !== null
              ? balanceRow.modelData.usedPercent / 100 : -1
            alarming: balanceRow.modelData.usedPercent !== undefined
              && balanceRow.modelData.usedPercent !== null
              && balanceRow.modelData.usedPercent >= 90
            foreground: usageRoot.foreground
            urgent: usageRoot.urgent
            track: usageRoot.track
          }
        }
      }
    }

    // ---------- Account notes (plan / operator message) ----------
    Column {
      visible: usageRoot.accountNotes.length > 0
      width: parent.width
      spacing: Style.space(8)

      PanelSectionHeader {
        width: parent.width
        text: "ACCOUNTS"
        foreground: usageRoot.foreground
        fontFamily: usageRoot.fontFamily
      }

      Repeater {
        model: usageRoot.accountNotes

        Column {
          id: noteRow
          required property var modelData
          width: parent.width
          spacing: Style.space(2)

          // The plan alone: this section belongs to the selected Provider,
          // so a row that only repeated its name would say nothing.
          Text {
            textFormat: Text.PlainText
            visible: noteRow.modelData.plan !== ""
            text: noteRow.modelData.plan
            color: usageRoot.foreground
            font.family: usageRoot.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            visible: noteRow.modelData.message !== ""
            width: parent.width
            text: noteRow.modelData.message
            // Router prose is a statement of fact until the provider has no
            // usable allowance left to report — only then is it a caution.
            color: noteRow.modelData.urgent ? usageRoot.urgent : usageRoot.dim
            font.family: usageRoot.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
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

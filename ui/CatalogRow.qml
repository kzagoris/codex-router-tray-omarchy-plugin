import QtQuick
import qs.Commons
import qs.Ui

// One catalog model in the MODELS view: display name in bold, a secondary
// line, and a switch on the right.
//
// One component serves both settings, because the sub-switcher — not the row
// — decides which setting is being edited: under Picker the secondary line is
// the model's slug and the switch is visibility; under Subagents it is the
// proof badge and the switch is eligibility. The row is presentation only:
// every string, the toggled state and the enabled/disabled pair are computed
// by logic/Catalog.js and bound in by the view, and intent leaves through
// `toggleRequested` and `interlockRequested`.
Item {
  id: crow

  // The row's view model (see logic/Catalog.js): slug, displayName,
  // secondary, badgeKind/badgeTooltip/badgeUrgent, on, toggleEnabled,
  // interlocked.
  property var row: null

  // Offline-or-mutating gate, owned by the view.
  property bool locked: false

  signal toggleRequested()
  // A row whose subagent toggle is inert because the model is hidden from
  // the picker: clicking it goes where the cause can be fixed rather than
  // unhiding the model behind the operator's back.
  signal interlockRequested()

  // Palette, handed over by the view that mounts the row.
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color dim: Qt.darker(crow.foreground, 1.55)
  property string fontFamily: Style.font.family

  readonly property bool interlocked: !!crow.row && crow.row.interlocked === true
  readonly property bool switchEnabled: !!crow.row && crow.row.toggleEnabled === true
    && !crow.locked

  implicitHeight: Math.max(rowText.implicitHeight, rowSwitch.implicitHeight)

  Column {
    id: rowText
    anchors.left: parent.left
    anchors.right: rowSwitch.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: crow.row ? String(crow.row.displayName) : ""
      color: crow.foreground
      font.family: crow.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }

    // Slug under Picker, proof badge under Subagents. A failure is the
    // router's own words in the panel's urgent colour, elided to one line
    // with the whole reason on hover.
    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: crow.row ? String(crow.row.secondary) : ""
      color: crow.row && crow.row.badgeUrgent === true ? crow.urgent : crow.dim
      font.family: crow.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  ToggleSwitch {
    id: rowSwitch
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    checked: !!crow.row && crow.row.on === true
    interactive: crow.switchEnabled
    opacity: crow.switchEnabled ? 1 : 0.45
    foreground: crow.foreground
    onToggled: crow.toggleRequested()
  }

  MouseArea {
    id: rowHover
    anchors.fill: parent
    hoverEnabled: true
    // Only the interlocked row answers a click, and it answers by navigating,
    // never by changing a setting.
    acceptedButtons: crow.interlocked ? Qt.LeftButton : Qt.NoButton
    cursorShape: crow.interlocked ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: if (crow.interlocked) crow.interlockRequested()
  }

  PanelToolTip {
    visible: rowHover.containsMouse
      && (crow.interlocked
          || (!!crow.row && String(crow.row.badgeTooltip) !== ""))
    text: crow.interlocked
      ? "Hidden in the picker — open Picker to show it again."
      : (crow.row ? String(crow.row.badgeTooltip) : "")
    fontFamily: crow.fontFamily
  }
}

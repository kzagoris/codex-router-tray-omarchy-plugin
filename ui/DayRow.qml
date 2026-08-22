import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// One row per day: label, bar, tokens. Today is picked out in full
// foreground so the week reads as a run-up to right now.
//
// Extracted from Panel.qml; the palette and the prebuilt tooltip text are
// handed in by the enclosing view (see views/UsageView.qml).
Item {
  id: dayRow

  property var day: null
  property real ratio: 0
  property bool today: false
  // Prebuilt by the view (dayTooltip lives where the series does); rows
  // stay dumb about series shape.
  property string tooltipText: ""

  // Palette, handed over by the view that mounts the row.
  property color foreground: Color.foreground
  property color dim: Qt.darker(dayRow.foreground, 1.55)
  property color track: Style.selectedFillFor(dayRow.foreground, Color.accent)
  property string fontFamily: Style.font.family

  implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  Text {
    textFormat: Text.PlainText
    id: dayLabel
    text: dayRow.day ? String(dayRow.day.label) : ""
    color: dayRow.today ? dayRow.foreground : dayRow.dim
    font.family: dayRow.fontFamily
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
    color: dayRow.track

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      radius: parent.radius
      width: parent.width * dayRow.clamp(dayRow.ratio, 0, 1)
      color: dayRow.today ? dayRow.foreground : dayRow.alpha(dayRow.foreground, 0.55)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    id: dayValue
    text: dayRow.day ? Model.compactTokens(dayRow.day.tokens) : ""
    color: dayRow.today ? dayRow.foreground : dayRow.dim
    font.family: dayRow.fontFamily
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
    text: dayRow.tooltipText
    fontFamily: dayRow.fontFamily
  }
}

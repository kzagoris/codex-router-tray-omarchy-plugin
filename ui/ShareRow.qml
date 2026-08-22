import QtQuick
import qs.Commons
import qs.Ui

// Roll-up rows read as a table: the share bar fills the row behind the
// label instead of stacking under it, which keeps the dashboard on one
// screen.
//
// Named ShareRow on purpose: it renders provider share bars and never
// showed a catalog model, so it must not keep a name that collides with
// the catalog-model row issue 002 adds (see CONTEXT.md — "model" is
// reserved for the Omarchy sense).
//
// Extracted from Panel.qml; palette is handed in by the enclosing view.
Item {
  id: shareRow

  property string name: ""
  property string tokens: ""
  property string tooltip: ""
  property real share: 0

  // Palette, handed over by the view that mounts the row.
  property color foreground: Color.foreground
  property color dim: Qt.darker(shareRow.foreground, 1.55)
  property string fontFamily: Style.font.family

  implicitHeight: nameLabel.implicitHeight + Style.spacing.lg

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: shareRow.alpha(shareRow.foreground, 0.05)
  }

  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: parent.width * shareRow.clamp(shareRow.share, 0, 1)
    radius: Style.cornerRadius
    color: shareRow.alpha(shareRow.foreground, 0.14)

    Behavior on width {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }
  }

  Text {
    textFormat: Text.PlainText
    id: nameLabel
    text: shareRow.name
    color: shareRow.foreground
    font.family: shareRow.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.right: tokensLabel.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
  }

  Text {
    textFormat: Text.PlainText
    id: tokensLabel
    text: shareRow.tokens
    color: shareRow.dim
    font.family: shareRow.fontFamily
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
    text: shareRow.tooltip
    fontFamily: shareRow.fontFamily
  }
}

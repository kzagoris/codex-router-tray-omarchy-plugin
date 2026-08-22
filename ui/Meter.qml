import QtQuick
import qs.Commons
import qs.Ui

// Rounded track showing a fraction of an allowance.
//
// Extracted from Panel.qml so a new view can reuse it without copying it;
// the palette is handed in by the enclosing view (see views/*.qml).
Item {
  id: meterRoot

  // Fraction 0..1; negative means "no usable figure" and paints empty.
  property real value: -1
  property bool alarming: false

  // Palette, handed over by the view that mounts the meter.
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color track: Style.selectedFillFor(meterRoot.foreground, Color.accent)

  property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

  implicitHeight: thickness

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  Rectangle {
    id: meterTrack
    anchors.fill: parent
    radius: height / 2
    color: meterRoot.track
  }

  Rectangle {
    anchors.left: meterTrack.left
    anchors.verticalCenter: meterTrack.verticalCenter
    height: meterTrack.height
    radius: meterTrack.radius
    width: meterTrack.width * meterRoot.clamp(meterRoot.value, 0, 1)
    color: meterRoot.alarming ? meterRoot.urgent : meterRoot.foreground

    Behavior on width {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }
  }
}

import QtQuick
import qs.Commons
import qs.Ui

// MODELS view: placeholder. Issue 002 fills it with the catalog-model
// controls (picker visibility, subagent eligibility) over one
// provider-grouped list; until then the view says so instead of pretending.
//
// The panel hands over the service, the live clock and the palette — the
// same contract the real view will bind to.
Item {
  id: modelsRoot

  // ------------------------------------------------------------- contract

  property var service: null
  property double nowMs: 0

  // Palette, handed over by the panel.
  property color foreground: Color.foreground
  property color dim: Qt.darker(modelsRoot.foreground, 1.55)
  property string fontFamily: Style.font.family

  height: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.spacing.md

    PanelSectionHeader {
      width: parent.width
      text: "MODELS"
      foreground: modelsRoot.foreground
      fontFamily: modelsRoot.fontFamily
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: "Catalog model controls are on their way.\nPicker and subagent switches will live here."
      color: modelsRoot.dim
      font.family: modelsRoot.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }
  }
}

import QtQuick
import qs.Commons
import qs.Ui

// Busy/error line for one controls section. Dim while the mutation runs,
// urgent once it has failed; hidden otherwise.
//
// Extracted from Panel.qml and kept dumb: the enclosing view binds `notice`
// from the panel's per-domain notice (see Panel.domainNotice) and mirrors
// the mutation state in `running`.
Text {
  id: actionNoticeRoot

  // Prebuilt by the view: the busy label while this domain's mutation
  // runs, its error afterwards, empty when the domain is uninvolved.
  property string notice: ""
  property bool running: false

  // Palette, handed over by the view that mounts the notice.
  property color dim: Color.muted
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  visible: notice !== ""
  text: actionNoticeRoot.notice
  // The notice can carry raw stderr from control.mjs — a string this plugin
  // does not control. Plain text keeps it from being parsed as rich text.
  textFormat: Text.PlainText
  color: actionNoticeRoot.running ? actionNoticeRoot.dim : actionNoticeRoot.urgent
  font.family: actionNoticeRoot.fontFamily
  font.pixelSize: Style.font.caption
  wrapMode: Text.WordWrap
}

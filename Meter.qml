import QtQuick
import qs.Commons

// Label, value, and a filled track — the panel's unit of measurement.
//
// Levels come from Model.level(): "normal" leaves the fill in the theme's
// own accent, "warn" and "critical" shift it towards the urgent color. The
// track never turns red on its own, so red always means something.
Item {
  id: root

  property string label: ""
  property string value: ""
  property real percent: 0
  property string level: "normal"
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.bodySmall
  property real trackHeight: Style.space(6)
  property real labelWidth: Style.space(96)
  property real valueWidth: Style.space(92)
  property bool showTrack: true

  readonly property color urgentColor: Color.urgent
  readonly property color fillColor: {
    var base = Style.selectedStateColor(foreground, Color.accent)
    if (level === "critical") return urgentColor
    if (level === "warn") return Qt.tint(base, Qt.rgba(urgentColor.r, urgentColor.g, urgentColor.b, 0.45))
    return base
  }

  implicitHeight: Math.max(labelText.implicitHeight, Style.space(14))
  implicitWidth: Style.space(280)

  Text {
    id: labelText
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: root.labelWidth
    elide: Text.ElideRight
    text: root.label
    color: Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }

  Text {
    id: valueText
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: root.valueWidth
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    text: root.value
    color: root.level === "critical" ? root.urgentColor : root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }

  Rectangle {
    visible: root.showTrack
    anchors.left: labelText.right
    anchors.right: valueText.left
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    height: root.trackHeight
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

    Rectangle {
      width: Math.round(parent.width * Math.max(0, Math.min(100, root.percent)) / 100)
      height: parent.height
      radius: parent.radius
      color: root.fillColor

      Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }
  }
}

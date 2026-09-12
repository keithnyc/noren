import QtQuick
import qs.Commons
import qs.Ui

// The other way to part the curtain: a ring of actions around whatever page is
// in front of you.
//
// A chrome-less window has no toolbar, so back/forward/reload/copy have nowhere
// to live. A list would work and be duller; a ring puts every action the same
// distance from the pointer, which is the one thing a radial menu is actually
// better at.
//
// Every label is a word. Glyphs are decoration only -- a missing one in the
// theme's font leaves a tofu box, and an action you cannot name is an action you
// cannot use.
Item {
  id: root

  // Each entry: { key, icon, label, hint, run }
  property var actions: []
  property bool active: false
  property string contextLabel: ""
  property int hovered: -1

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color accent: Color.menu.selectedText
  property color selectedBackground: Color.menu.selectedBackground
  property string fontFamily: Style.font.menuFamily

  signal chose(int index)
  signal dismissed()

  readonly property real ringRadius: Style.space(148)
  readonly property real itemSize: Style.space(96)

  // Drives the whole entrance: items fly out from the centre and the ring
  // scales up behind them. One property so nothing can animate out of step.
  property real spread: 0

  Behavior on spread {
    NumberAnimation {
      duration: 260
      easing.type: Easing.OutBack
      easing.overshoot: 1.1
    }
  }

  onActiveChanged: {
    root.hovered = -1
    root.spread = active ? 1 : 0
  }

  function indexForKey(text) {
    if (!text || text.length !== 1) return -1
    var want = text.toUpperCase()
    for (var i = 0; i < root.actions.length; i++) {
      if (String(root.actions[i].key || "").toUpperCase() === want) return i
    }
    return -1
  }

  function step(delta) {
    var n = root.actions.length
    if (n === 0) return
    root.hovered = root.hovered < 0
      ? (delta > 0 ? 0 : n - 1)
      : (root.hovered + delta + n) % n
  }

  function activate() {
    if (root.hovered >= 0 && root.hovered < root.actions.length) {
      root.chose(root.hovered)
    } else {
      root.dismissed()
    }
  }

  focus: root.active
  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Escape) {
      root.dismissed()
    } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down
               || event.key === Qt.Key_Tab) {
      root.step(1)
    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up
               || event.key === Qt.Key_Backtab) {
      root.step(-1)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
               || event.key === Qt.Key_Space) {
      root.activate()
    } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
      var idx = event.key - Qt.Key_1
      if (idx < root.actions.length) root.chose(idx)
    } else {
      // A mnemonic letter fires its action straight away -- the ring is meant
      // to be summoned and dismissed in one gesture, and reaching for arrows
      // first would undo that. Falls through to ignored if the key is not one
      // of ours, so the compositor still sees it.
      var typed = root.indexForKey(event.text)
      if (typed < 0) return
      root.chose(typed)
    }
    event.accepted = true
  }

  // ----------------------------------------------------------------- the ring

  Item {
    id: hub
    anchors.centerIn: parent
    width: root.ringRadius * 2 + root.itemSize
    height: width

    // A faint guide so the items read as one ring rather than eight buttons.
    Rectangle {
      anchors.centerIn: parent
      width: root.ringRadius * 2 * root.spread
      height: width
      radius: width / 2
      color: "transparent"
      border.width: Math.max(1, Style.space(1))
      border.color: root.borderColor
      opacity: 0.35 * root.spread
    }

    // Centre: what the ring is acting on, or what the highlighted action does.
    Rectangle {
      id: core
      anchors.centerIn: parent
      width: Style.space(132)
      height: Style.space(132)
      radius: width / 2
      color: root.background
      border.width: Math.max(1, Style.space(1))
      border.color: root.hovered >= 0 ? root.accent : root.borderColor
      scale: root.spread
      opacity: root.spread

      Behavior on border.color { ColorAnimation { duration: 120 } }

      Column {
        anchors.centerIn: parent
        width: parent.width - Style.space(20)
        spacing: Style.space(4)

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.hovered >= 0
            ? (root.actions[root.hovered].label || "")
            : "Noren"
          color: root.hovered >= 0 ? root.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.hovered >= 0
            ? (root.actions[root.hovered].hint || "")
            : (root.contextLabel + "  ·  press a letter")
          color: root.foreground
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          maximumLineCount: 2
          wrapMode: Text.WordWrap
        }
      }
    }

    Repeater {
      model: root.actions

      delegate: Item {
        id: spoke
        readonly property int idx: index
        readonly property bool isHovered: root.hovered === index
        // Start at twelve o'clock and go clockwise, so the first action is
        // where the eye already is.
        readonly property real angle:
          (-90 + index * (360 / Math.max(1, root.actions.length))) * Math.PI / 180

        width: root.itemSize
        height: root.itemSize
        x: hub.width / 2 + Math.cos(angle) * root.ringRadius * root.spread - width / 2
        y: hub.height / 2 + Math.sin(angle) * root.ringRadius * root.spread - height / 2
        opacity: root.spread
        scale: spoke.isHovered ? 1.14 : 1.0

        Behavior on scale {
          NumberAnimation { duration: 140; easing.type: Easing.OutBack }
        }

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: spoke.isHovered ? root.selectedBackground : root.background
          border.width: Math.max(1, Style.space(spoke.isHovered ? 2 : 1))
          border.color: spoke.isHovered ? root.accent : root.borderColor

          Behavior on color { ColorAnimation { duration: 120 } }
          Behavior on border.color { ColorAnimation { duration: 120 } }

          Column {
            anchors.centerIn: parent
            width: parent.width - Style.space(12)
            spacing: Style.space(2)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: modelData.icon || ""
              color: spoke.isHovered ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              visible: text.length > 0
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: modelData.label || ""
              color: spoke.isHovered ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        // The key that fires this item. Shown rather than learned: a shortcut
        // nobody can see is a shortcut nobody uses.
        Rectangle {
          width: Style.space(36)
          height: width
          radius: width / 2
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.topMargin: Style.space(1)
          anchors.rightMargin: Style.space(1)
          visible: String(modelData.key || "").length > 0
          // Opacity on the badge dims the letter inside it too -- that is what
          // made these unreadable. Contrast comes from the theme's own
          // background/accent pair instead, which is a real contrast pair in
          // every theme, and the badge stays fully opaque in both states.
          color: spoke.isHovered ? root.accent : root.background
          border.width: Math.max(1, Style.space(1))
          border.color: root.accent

          Behavior on color { ColorAnimation { duration: 120 } }

          Text {
            anchors.centerIn: parent
            text: String(modelData.key || "")
            color: spoke.isHovered ? root.background : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onEntered: root.hovered = spoke.idx
          onExited: if (root.hovered === spoke.idx) root.hovered = -1
          onClicked: root.chose(spoke.idx)
        }
      }
    }
  }
}

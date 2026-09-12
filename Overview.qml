import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Every page in the group, laid out in depth.
//
// A Hyprland group shows one member and hides the rest behind a bar of titles,
// which is fine for two pages and useless for eight. This is the other view of
// the same thing: all of them at once, as live captures, pick one and it becomes
// the active member.
//
// Live capture of a *hidden* group member works -- measured 2026-09-12, an
// inactive member reports hasContent with full dimensions. That was the one
// thing this feature depended on and the reason it needs no frame caching.
//
// `HyprlandToplevel` is what makes it possible without shelling out: it carries
// `address` (to match Hyprland's own group list), `lastIpcObject` (the client
// map, including `grouped`), and `wayland` -- the Toplevel a ScreencopyView can
// capture.
Item {
  id: root

  property bool active: false

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color accent: Color.menu.selectedText
  property string fontFamily: Style.font.menuFamily

  // Two different outcomes, and they were one signal to begin with: picking a
  // page emitted `dismissed`, which the overlay reads as "go back to the ring",
  // so Enter activated the window and then bounced to the radial.
  signal chosen()
  signal dismissed()

  property int selected: 0
  property real spread: 0

  readonly property var members: root.active ? root.groupMembers() : []
  readonly property int count: members.length

  // Cards are sized to the screen rather than fixed, so this works on any
  // monitor without a magic number.
  readonly property real cardW: Math.min(Style.space(720), root.width * 0.46)
  readonly property real cardH: cardW * 0.62
  // Named cardStep, not step: there is a step() function below, and qmllint
  // flags the collision -- a property and a method of the same name is a bug
  // waiting to happen.
  readonly property real cardStep: cardW * 0.56

  Behavior on spread {
    NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
  }

  onActiveChanged: {
    root.spread = active ? 1 : 0
    if (active) {
      Hyprland.refreshToplevels()
      root.selected = root.indexOfActive()
    }
  }

  // Hyprland reports addresses as 0x-prefixed strings in `grouped`; normalise
  // before comparing, since the two sources have differed on that before.
  function sameAddress(a, b) {
    return String(a || "").replace(/^0x/, "").toLowerCase()
      === String(b || "").replace(/^0x/, "").toLowerCase()
  }

  function groupMembers() {
    var act = Hyprland.activeToplevel
    if (!act) return []
    var ipc = act.lastIpcObject || {}
    var addresses = ipc.grouped || []
    if (!addresses || addresses.length < 2) return []

    var all = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var out = []
    // Walk the group's own order, not Hyprland's client list order, so the
    // cards match the order of the group bar.
    for (var i = 0; i < addresses.length; i++) {
      for (var j = 0; j < all.length; j++) {
        if (root.sameAddress(all[j].address, addresses[i])) {
          out.push(all[j])
          break
        }
      }
    }
    return out
  }

  function indexOfActive() {
    for (var i = 0; i < root.members.length; i++) {
      if (root.members[i] && root.members[i].activated) return i
    }
    return 0
  }

  function step(delta) {
    if (root.count === 0) return
    root.selected = (root.selected + delta + root.count) % root.count
  }

  function choose(index) {
    var member = root.members[index]
    if (member && member.wayland) member.wayland.activate()
    root.chosen()
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
      if (root.count > 0) root.choose(root.selected)
      else root.dismissed()
    } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
      var idx = event.key - Qt.Key_1
      if (idx < root.count) root.choose(idx)
    } else {
      return
    }
    event.accepted = true
  }

  // Nothing to show: say so rather than presenting an empty stage.
  Column {
    anchors.centerIn: parent
    spacing: Style.space(6)
    visible: root.active && root.count === 0
    opacity: root.spread

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "No group here"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Gather some windows first — G in the radial, or `noren gather`"
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Repeater {
    model: root.members

    delegate: Item {
      id: card

      readonly property int idx: index
      readonly property int offset: index - root.selected
      readonly property real away: Math.abs(offset)
      readonly property bool isSelected: offset === 0

      width: root.cardW
      height: root.cardH
      // Cards stack outward from the middle; the selected one sits square to
      // the viewer and everything else leans away.
      x: root.width / 2 - width / 2 + offset * root.cardStep * root.spread
      y: root.height / 2 - height / 2
      z: 100 - away
      opacity: root.spread * Math.max(0.22, 1 - away * 0.24)
      scale: Math.max(0.55, 1 - away * 0.12) * (0.86 + 0.14 * root.spread)

      // Rotation about the vertical axis is what sells the depth: the flat
      // scale alone reads as a carousel, the foreshortening reads as space.
      transform: Rotation {
        origin.x: card.width / 2
        origin.y: card.height / 2
        axis { x: 0; y: 1; z: 0 }
        angle: Math.max(-54, Math.min(54, -card.offset * 27))
      }

      // Tightened from 280ms. The move is short and mostly horizontal, so a
      // long ease reads as lag rather than weight.
      Behavior on x { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 140 } }

      Rectangle {
        anchors.fill: parent
        color: root.background
        radius: Style.cornerRadius
        border.width: Math.max(1, Style.space(card.isSelected ? 2 : 1))
        border.color: card.isSelected ? root.accent : root.borderColor

        Behavior on border.color { ColorAnimation { duration: 140 } }

        // The page itself. Only the selected card captures continuously: N live
        // screencopies, each composited through a rotation and a scale, is what
        // made moving between cards feel heavy. The rest hold their last frame,
        // which is all an overview needs -- and if a still capture turns out to
        // yield nothing, the selected card still works, so this degrades rather
        // than breaks.
        ScreencopyView {
          id: capture
          anchors.fill: parent
          anchors.margins: Math.max(1, Style.space(2))
          captureSource: modelData && modelData.wayland ? modelData.wayland : null
          live: root.active && card.isSelected
          visible: hasContent
        }

        // Until the first frame arrives, or if capture is refused.
        Text {
          anchors.centerIn: parent
          visible: !capture.hasContent
          text: "no preview"
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Index badge, so a page can be picked by number without counting.
        Rectangle {
          width: Style.space(34)
          height: width
          radius: width / 2
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.margins: Style.space(8)
          visible: card.idx < 9
          color: card.isSelected ? root.accent : root.background
          border.width: Math.max(1, Style.space(1))
          border.color: root.accent

          Text {
            anchors.centerIn: parent
            text: String(card.idx + 1)
            color: card.isSelected ? root.background : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onEntered: root.selected = card.idx
        onClicked: root.choose(card.idx)
      }
    }
  }

  // One title, for the selected card only. A label under every card at these
  // angles is unreadable and competes with the pages themselves.
  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.height / 2 + root.cardH / 2 + Style.space(28)
    width: root.width * 0.6
    horizontalAlignment: Text.AlignHCenter
    visible: root.count > 0
    opacity: root.spread
    text: {
      var m = root.members[root.selected]
      return m ? (m.title || "") : ""
    }
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    y: root.height / 2 + root.cardH / 2 + Style.space(56)
    visible: root.count > 0
    opacity: root.spread * 0.55
    text: "← →  choose  ·  1–9 jump  ·  Enter open  ·  Esc back"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}

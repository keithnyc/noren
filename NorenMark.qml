import QtQuick
import qs.Commons

// Noren itself, drawn: a rod with panels hanging from it. The plugin is named
// after the split curtain over a shop door, so this is the face it wears when
// it is doing something -- not a mascot, just the mark, in the theme's colours.
//
//   mood "idle"     a slow sway, like cloth in a doorway
//   mood "working"  a quicker ripple, left to right
//   mood "done"     the panels part once, the way you walk through them
Item {
  id: root

  property string mood: "idle"
  property color accent: Color.menu.selectedText
  property color rod: Color.menu.border

  readonly property int panels: 4
  implicitWidth: Style.space(58)
  implicitHeight: Style.space(42)

  // One driver for every panel, so they cannot drift out of step. Phase is
  // taken per panel from its index, which is what makes it read as a ripple
  // rather than four things wobbling.
  property real phase: 0
  NumberAnimation on phase {
    from: 0
    to: 2 * Math.PI
    duration: root.mood === "working" ? 1100 : 4200
    loops: Animation.Infinite
    running: true
  }

  // A single parting, when an answer lands. Driven rather than done with a
  // Behavior: a Behavior leaves the property at the value that was assigned to
  // it, so `parted` stayed at 1 after the panels had visibly swung back, and
  // the second answer parted nothing at all.
  property real parted: 0
  SequentialAnimation {
    id: parting
    NumberAnimation {
      target: root; property: "parted"; from: 0; to: 1
      duration: 260; easing.type: Easing.OutCubic
    }
    PauseAnimation { duration: 420 }
    NumberAnimation {
      target: root; property: "parted"; to: 0
      duration: 520; easing.type: Easing.InOutQuad
    }
  }
  onMoodChanged: if (mood === "done") parting.restart()

  Rectangle {
    id: bar
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: Math.max(2, Style.space(3))
    radius: height / 2
    color: root.rod
  }

  Row {
    anchors { top: bar.bottom; topMargin: Style.space(1) }
    spacing: Style.space(3)

    Repeater {
      model: root.panels

      delegate: Rectangle {
        id: panel
        required property int index
        readonly property real fromMiddle: (index + 0.5) / root.panels - 0.5
        readonly property real swing: root.mood === "working" ? 7 : 2.2

        width: (root.width - (root.panels - 1) * Style.space(3)) / root.panels
        height: root.height - bar.height - Style.space(1)
        radius: Style.space(2)
        color: root.accent
        opacity: 0.55 + 0.35 * (0.5 + 0.5 * Math.sin(root.phase + index * 0.7))

        // Hung from the rod: a panel pivots where it is attached.
        transformOrigin: Item.Top
        rotation: Math.sin(root.phase + index * 0.7) * swing
          + root.parted * fromMiddle * 26
        // Stepping aside is a transform, never an `x`: a Row sets its
        // children's x itself, so binding x here overwrote the layout the
        // moment `parted` changed and stacked all four panels on top of each
        // other -- the mark collapsed to a single panel exactly when an answer
        // arrived.
        transform: Translate { x: root.parted * panel.fromMiddle * Style.space(10) }
      }
    }
  }
}

import QtQuick
import QtQuick.Effects
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
  // Two moments, not one. The window is raised as the card starts flying, so the
  // compositor has already switched by the time the card lands on it; the
  // overlay closes only when the animation is done.
  signal raiseRequested(string address)
  signal chosen()
  signal dismissed()

  property int selected: 0
  property real spread: 0

  // The card being launched, and where it is flying to. Selecting a page should
  // read as that card *becoming* the window, so it animates to the window's real
  // geometry rather than just fading out.
  property int launchIndex: -1
  readonly property bool launching: launchIndex >= 0
  property rect launchRect: Qt.rect(0, 0, 0, 0)

  // Whether the pointer, rather than the keyboard, is driving the selection.
  //
  // Cards move when the selection changes, so a stationary cursor has cards
  // slide *underneath* it -- and a plain `onEntered` then fires and drags the
  // selection to whichever card arrived. Arrowing left would advance a card or
  // two and snap back to whatever sat under the pointer, and opening the
  // overview with the cursor on the right would select the rightmost card
  // immediately. Hover only counts while the pointer is genuinely moving.
  property bool pointerDriving: false
  // Last physical pointer position, in *root* coordinates. Item-local
  // coordinates are useless for this: when a card slides under a cursor that
  // never moved, its local mouse position changes and positionChanged fires,
  // which is indistinguishable from a real movement. Mapped back to root space
  // a stationary pointer stays put no matter what the cards do.
  property point lastPointer: Qt.point(-1, -1)

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
      root.launchIndex = -1
      root.pointerDriving = false
      // Deferred: `members` is a binding on `active`, so at this instant it can
      // still be the old (empty) list and indexOfActive would answer 0.
      Qt.callLater(function () { root.selected = root.indexOfActive() })
    }
  }

  // Hyprland reports addresses as 0x-prefixed strings in `grouped`; normalise
  // before comparing, since the two sources have differed on that before.
  function sameAddress(a, b) {
    return String(a || "").replace(/^0x/, "").toLowerCase()
      === String(b || "").replace(/^0x/, "").toLowerCase()
  }

  function groupMembers() {
    var all = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var act = Hyprland.activeToplevel
    var ipc = act ? (act.lastIpcObject || {}) : {}
    var addresses = ipc.grouped || []

    if (addresses && addresses.length > 1) {
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

    // Not a group. This used to stop here and say "no group", which made the
    // overview useless in the state most pages are actually in -- scattered
    // across a workspace. Every chrome-less page on this workspace instead, so
    // it is a page switcher first and a group view second.
    var wsId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    var loose = []
    for (var k = 0; k < all.length; k++) {
      var top = all[k]
      var tipc = top.lastIpcObject || {}
      if (String(tipc["class"] || "").indexOf("chrome-") !== 0) continue
      var tws = top.workspace ? top.workspace.id : -1
      if (wsId >= 0 && tws !== wsId) continue
      loose.push(top)
    }
    return loose
  }

  // Where a member's window actually sits, in this overlay's coordinates.
  //
  // `at`/`size` from Hyprland are global *logical* coordinates, and monitors
  // here have non-zero origins and different scales (DP-2 at -960, eDP-1 at
  // -2560), so the monitor origin has to come off. The overlay ignores
  // exclusion zones, so its 0,0 is the monitor's origin.
  function rectFor(member) {
    var fallback = Qt.rect(root.width / 2 - root.cardW / 2,
                           root.height / 2 - root.cardH / 2,
                           root.cardW, root.cardH)
    if (!member) return fallback
    var ipc = member.lastIpcObject || {}
    var at = ipc.at
    var size = ipc.size
    if (!at || !size || at.length < 2 || size.length < 2) return fallback

    var mon = member.monitor || Hyprland.focusedMonitor
    var ox = mon ? mon.x : 0
    var oy = mon ? mon.y : 0
    return Qt.rect(at[0] - ox, at[1] - oy, size[0], size[1])
  }

  function indexOfActive() {
    for (var i = 0; i < root.members.length; i++) {
      if (root.members[i] && root.members[i].activated) return i
    }
    return 0
  }

  function step(delta) {
    if (root.count === 0) return
    root.pointerDriving = false
    root.selected = (root.selected + delta + root.count) % root.count
  }

  // Closing from here is the natural companion to seeing everything at once, and
  // Shift+Delete is the gesture the url bar already uses to drop a set. Goes
  // through the Wayland toplevel rather than a Hyprland dispatch -- close is a
  // protocol request, not a compositor command, and the page gets to run its
  // own teardown.
  function closeSelected() {
    var member = root.members[root.selected]
    if (!member || !member.wayland) return false
    root.shatter(cards.itemAt(root.selected), member)
    member.wayland.close()
    // Keep the selection in range as the row disappears.
    if (root.selected >= root.count - 1) root.selected = Math.max(0, root.count - 2)
    Hyprland.refreshToplevels()
    return true
  }

  function choose(index) {
    if (root.launching) return
    var member = root.members[index]
    if (!member) {
      root.chosen()
      return
    }
    // Hand the address up rather than dispatching here. Hyprland.dispatch from
    // Quickshell worked once and then silently did nothing twice -- Enter
    // appeared dead while the key handler was provably fine. The `noren` CLI
    // does the same focus and verifies it took, and it is the path every other
    // radial action already uses, so there is one dispatch route instead of two.
    root.launchRect = root.rectFor(member)
    root.selected = index
    root.launchIndex = index
    // Raise immediately: the switch happens behind the flying card, so the card
    // lands on a window that is already active.
    root.raiseRequested(String(member.address || ""))
    launchTimer.restart()
  }

  Timer {
    id: launchTimer
    interval: 300
    repeat: false
    onTriggered: root.chosen()
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
    } else if (event.key === Qt.Key_Delete
               && (event.modifiers & Qt.ShiftModifier)) {
      if (!root.closeSelected()) return
    } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
      var idx = event.key - Qt.Key_1
      if (idx < root.count) root.choose(idx)
    } else {
      return
    }
    event.accepted = true
  }

  // Wheel steps through the cards. A WheelHandler rather than a MouseArea so it
  // does not sit on top of the cards and swallow their clicks.
  WheelHandler {
    enabled: root.active
    onWheel: function (event) {
      root.step(event.angleDelta.y > 0 ? -1 : 1)
    }
  }

  // Nothing to show: say so rather than presenting an empty stage.
  Column {
    anchors.centerIn: parent
    spacing: Style.space(6)
    visible: root.active && root.count === 0
    opacity: root.spread

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Nothing open here"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Open a page, or gather some windows — G in the radial"
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ------------------------------------------------------------------ shatter
  //
  // The same burst the rest of Noren uses, so closing a page looks the same
  // whether it goes from here or from `noren close`. The card is grabbed the
  // instant before the window is asked to close: a moment later there is
  // nothing left to photograph.
  property string shatterStyle: "curtain"
  property bool shatterEnabled: true

  Shatter { id: burstLayer }

  function shatter(item, member) {
    if (!item || !root.shatterEnabled) return
    // Card coordinates are overlay-local; the burst draws in Hyprland's own,
    // so put the monitor's origin back.
    var mon = (member && member.monitor) || Hyprland.focusedMonitor
    var ox = mon ? mon.x : 0
    var oy = mon ? mon.y : 0
    var x = item.x + ox
    var y = item.y + oy
    var w = item.width
    var h = item.height
    item.grabToImage(function (result) {
      burstLayer.burst(x, y, w, h, result.url, root.shatterStyle)
    }, Qt.size(w, h))
  }

  Repeater {
    id: cards
    model: root.members

    delegate: Item {
      id: card

      readonly property int idx: index
      readonly property int offset: index - root.selected
      readonly property real away: Math.abs(offset)
      readonly property bool isSelected: offset === 0
      readonly property bool isLaunching: root.launchIndex === index

      // Cards stack outward from the middle; the selected one sits square to
      // the viewer and everything else leans away. The launching card leaves
      // the ring entirely and takes the window's own geometry.
      width: card.isLaunching ? root.launchRect.width : root.cardW
      height: card.isLaunching ? root.launchRect.height : root.cardH
      x: card.isLaunching
        ? root.launchRect.x
        : root.width / 2 - root.cardW / 2 + offset * root.cardStep * root.spread
      y: card.isLaunching
        ? root.launchRect.y
        : root.height / 2 - root.cardH / 2
      z: card.isLaunching ? 999 : 100 - away
      opacity: root.launching
        ? (card.isLaunching ? 1 : 0)
        : root.spread * Math.max(0.22, 1 - away * 0.24)
      scale: card.isLaunching
        ? 1
        : Math.max(0.55, 1 - away * 0.12) * (0.86 + 0.14 * root.spread)

      // Rotation about the vertical axis is what sells the depth: the flat
      // scale alone reads as a carousel, the foreshortening reads as space.
      transform: Rotation {
        origin.x: card.width / 2
        origin.y: card.height / 2
        axis { x: 0; y: 1; z: 0 }
        // Square to the viewer as it flies: the card stops being a card.
        angle: card.isLaunching ? 0 : Math.max(-54, Math.min(54, -card.offset * 27))
        Behavior on angle {
          NumberAnimation { duration: root.launching ? 280 : 170; easing.type: Easing.OutCubic }
        }
      }

      // Stepping between cards is a short horizontal nudge and wants 170ms;
      // the launch crosses the screen and changes size, where the same 170ms
      // reads as a snap. One duration, chosen by which is happening.
      Behavior on x {
        NumberAnimation { duration: root.launching ? 280 : 170; easing.type: Easing.OutCubic }
      }
      Behavior on y {
        NumberAnimation { duration: root.launching ? 280 : 170; easing.type: Easing.OutCubic }
      }
      Behavior on width {
        NumberAnimation { duration: root.launching ? 280 : 170; easing.type: Easing.OutCubic }
      }
      Behavior on height {
        NumberAnimation { duration: root.launching ? 280 : 170; easing.type: Easing.OutCubic }
      }
      Behavior on scale {
        NumberAnimation { duration: root.launching ? 280 : 170; easing.type: Easing.OutCubic }
      }
      Behavior on opacity { NumberAnimation { duration: root.launching ? 200 : 140 } }

      // A ring of accent just outside the selected card. Cheaper than a real
      // drop shadow and it does not read as a fake one: the depth comes from
      // the blur on everything else.
      Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.space(5)
        radius: Style.cornerRadius + Style.space(5)
        color: "transparent"
        border.width: Style.space(5)
        border.color: root.accent
        opacity: (card.isSelected && !root.launching) ? 0.22 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
      }

      Rectangle {
        anchors.fill: parent
        color: root.background
        radius: Style.cornerRadius
        border.width: Math.max(1, Style.space(card.isSelected ? 2 : 1))
        border.color: card.isSelected ? root.accent : root.borderColor
        // A window has no accent frame, so the card loses its one on the way in.
        opacity: card.isLaunching ? 0.5 : 1

        Behavior on border.color { ColorAnimation { duration: 140 } }
        Behavior on opacity { NumberAnimation { duration: 260 } }

        // Depth of field: the selected page is sharp, the rest fall back out of
        // focus. Only the unselected cards are layered -- they hold a still
        // frame, so the effect is a one-off render. The selected card captures
        // continuously and layering *that* would be an extra pass every frame.
        layer.enabled: !card.isSelected && !card.isLaunching && capture.hasContent
        layer.effect: MultiEffect {
          blurEnabled: true
          blur: 0.42
          blurMax: 24
          brightness: -0.14
          saturation: -0.22
        }

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
          visible: card.idx < 9 && !root.launching
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
        // Only a pointer that actually moved in root space takes control. The
        // 3px slack absorbs float noise from the card's rotation and scale.
        onPositionChanged: function (mouse) {
          var here = mapToItem(root, mouse.x, mouse.y)
          if (Math.abs(here.x - root.lastPointer.x) < 3
              && Math.abs(here.y - root.lastPointer.y) < 3) return
          root.lastPointer = here
          root.pointerDriving = true
          root.selected = card.idx
        }
        // Being arrived at is not movement -- that also happens when the
        // keyboard slides this card under a cursor that never moved.
        onEntered: if (root.pointerDriving) root.selected = card.idx
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
    visible: root.count > 0 && !root.launching
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
    visible: root.count > 0 && !root.launching
    opacity: root.spread * 0.55
    text: "← →  choose  ·  1–9 jump  ·  Enter open  ·  Shift+Del close  ·  Esc back"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// A stashed page flying into the topbar count.
//
// `noren stash` photographs the window, calls in here, and only then closes
// it, so the card goes up over a window that is still on screen and the
// compositor's own close plays underneath it. The card lifts, shrinks as it
// arcs over to the count, and the count ticks up when it lands -- the page is
// visibly *put* somewhere, which is the whole promise of a stash as opposed
// to a close.
//
// Where it lands is the bar widget's business: each one registers with the
// service and says where its badge is. With no widget on this monitor there is
// nowhere to land, so the card rises to the top of the screen and fades.
Item {
  id: root

  property color surface: Commons.Color.menu.background
  property color edge: Commons.Color.menu.border
  property color accent: Commons.Color.menu.selectedText

  // Fired on contact, not when the animation ends: the count has to move the
  // instant the card reaches it, or the bump reads as an afterthought.
  signal landed(int count)

  property rect area: Qt.rect(0, 0, 0, 0)   // the window, screen-local
  property point land: Qt.point(0, 0)        // the badge centre, screen-local
  property real landSize: 18
  property bool hasTarget: false
  property url picture: ""
  property int count: 0
  property bool pendingLanding: false
  property bool active: false
  property var onScreen: null

  property real t: 0      // the flight, 0 → 1 at contact
  property real k: 0      // the impact afterwards, 0 → 1

  // Shatter.qml's monitor lookup. Hyprland reports a monitor's width and
  // height in physical pixels but windows and origins in logical ones, so the
  // size is divided by the scale here; Shatter compares them raw, which only
  // matters for a point near the far edge of a scaled monitor.
  function screenFor(x, y, w, h) {
    var monitors = Hyprland.monitors ? Hyprland.monitors.values : []
    var cx = x + w / 2
    var cy = y + h / 2
    for (var i = 0; i < monitors.length; i++) {
      var ipc = monitors[i].lastIpcObject || {}
      var s = ipc.scale || 1
      if (cx >= ipc.x && cx < ipc.x + ipc.width / s && cy >= ipc.y && cy < ipc.y + ipc.height / s) {
        return { name: monitors[i].name, x: ipc.x, y: ipc.y }
      }
    }
    var focused = Hyprland.focusedMonitor
    var fipc = focused ? (focused.lastIpcObject || {}) : {}
    return { name: focused ? focused.name : "", x: fipc.x || 0, y: fipc.y || 0 }
  }

  // `landings` is every registered badge, as { screen, x, y, size } in its own
  // screen's local space. Only one on the window's monitor is any use: a layer
  // surface is per-monitor, and a card crossing screens would vanish at the edge.
  function launch(x, y, w, h, image, count, landings) {
    // A second stash while the first is still in the air: land the first now,
    // so its count is not lost, then start again from the new window.
    if (root.pendingLanding) root.touchDown()
    // Stopped before anything is set: stopping runs onStopped, which clears
    // the surface, and it must not clear the flight about to start.
    flight.stop()

    var mon = root.screenFor(x, y, w, h)
    var screens = Quickshell.screens
    root.onScreen = null
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === mon.name) root.onScreen = screens[i]
    }
    root.count = count
    root.pendingLanding = true
    if (!root.onScreen || w <= 0 || h <= 0) {
      // Nothing to draw, but the count must still move.
      root.touchDown()
      return
    }

    var target = null
    for (var j = 0; landings && j < landings.length; j++) {
      if (landings[j] && landings[j].screen === mon.name) target = landings[j]
    }
    root.hasTarget = target !== null
    if (target) {
      root.land = Qt.point(target.x, target.y)
      root.landSize = Math.max(12, target.size || 18)
    } else {
      root.land = Qt.point(root.onScreen.width / 2, 0)
      root.landSize = 24
    }

    root.picture = image || ""
    root.area = Qt.rect(x - mon.x, y - mon.y, w, h)
    root.t = 0
    root.k = 0
    root.active = true
    flight.start()
  }

  function touchDown() {
    if (!root.pendingLanding) return
    root.pendingLanding = false
    root.landed(root.count)
  }

  // --------------------------------------------------------------- the path
  //
  // Everything below is a pure function of the flight's progress, so the card
  // and its trail are the same curve sampled at different moments.

  // The first stretch is a wind-up: the card gives a little, the way something
  // does when it is picked up. The rest is the journey.
  readonly property real windUp: 0.14

  function travel(u) {
    return Math.max(0, Math.min(1, (u - root.windUp) / (1 - root.windUp)))
  }

  function easeInOutCubic(p) {
    return p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2
  }

  // A quadratic curve whose bend sits beside the landing point at the card's
  // own height: it sets off sideways and comes into the count from below,
  // like something dropped into a slot rather than slid along the bar.
  function pointAt(u) {
    var p = root.easeInOutCubic(root.travel(u))
    var sx = root.area.x + root.area.width / 2
    var sy = root.area.y + root.area.height / 2
    var ex = root.land.x
    var ey = root.land.y
    var cx = ex
    var cy = sy
    var a = (1 - p) * (1 - p)
    var b = 2 * (1 - p) * p
    var c = p * p
    return Qt.point(a * sx + b * cx + c * ex, a * sy + b * cy + c * ey)
  }

  function scaleAt(u) {
    var full = Math.max(root.area.width, root.area.height, 1)
    var small = root.landSize * 1.2 / full
    if (u < root.windUp) {
      // Down to 94% and back a touch, so the launch has somewhere to push from.
      var w = Math.sin(Math.PI * u / root.windUp)
      return 1 - 0.06 * w
    }
    // Shrinks fast and early: most of the journey is made small, which is
    // what makes it read as flying rather than as a window sliding about.
    var p = root.travel(u)
    var e = 1 - Math.pow(1 - p, 3)
    return 0.97 + (small - 0.97) * e
  }

  // A lean into the turn, gone again by the time it lands.
  function tiltAt(u) {
    var dir = root.land.x >= root.area.x + root.area.width / 2 ? 1 : -1
    return dir * 9 * Math.sin(Math.PI * root.travel(u))
  }

  SequentialAnimation {
    id: flight
    NumberAnimation {
      target: root
      property: "t"
      from: 0
      to: 1
      duration: 640
      easing.type: Easing.Linear
    }
    ScriptAction { script: root.touchDown() }
    NumberAnimation {
      target: root
      property: "k"
      from: 0
      to: 1
      duration: 420
      easing.type: Easing.OutCubic
    }
    onStopped: {
      root.active = false
      root.picture = ""
    }
  }

  PanelWindow {
    visible: root.active
    screen: root.onScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "noren-stash"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Purely decoration: the click after a stash belongs to whatever is under it.
    mask: Region {}

    // The trail. Plain accent shapes rather than copies of the picture -- a
    // comet's tail, not three pages -- sampled a beat behind the card.
    Repeater {
      model: root.active ? 3 : 0

      delegate: Rectangle {
        required property int index
        readonly property real u: Math.max(0, root.t - 0.045 * (index + 1))
        readonly property point at: root.pointAt(u)
        readonly property real s: root.scaleAt(u)

        visible: root.t > root.windUp && root.t < 1
        width: root.area.width
        height: root.area.height
        x: at.x - width / 2
        y: at.y - height / 2
        scale: s
        rotation: root.tiltAt(u)
        radius: Math.min(width, height) / 2 * Math.min(1, root.travel(u) * 1.4)
        color: root.accent
        opacity: (0.22 - 0.06 * index) * Math.sin(Math.PI * root.travel(root.t))
      }
    }

    Item {
      id: card
      readonly property point at: root.pointAt(root.t)
      readonly property real p: root.travel(root.t)

      visible: root.active && root.t < 1
      width: root.area.width
      height: root.area.height
      x: at.x - width / 2
      y: at.y - height / 2
      scale: root.scaleAt(root.t)
      rotation: root.tiltAt(root.t)
      // Into the count it goes in one piece; to the top of a screen with no
      // count on it, it fades on the way, since there is nothing to hit.
      opacity: root.hasTarget
        ? (p < 0.9 ? 1 : 1 - (p - 0.9) / 0.1 * 0.6)
        : Math.max(0, 1 - Math.max(0, p - 0.45) / 0.55)

      // Corners round up as it shrinks, so what arrives is a token rather than
      // a tiny window. The radius is in the card's own units, before scaling.
      readonly property real round: Style.cornerRadius
        + (Math.min(width, height) / 2 - Style.cornerRadius) * p * p

      Rectangle {
        id: plate
        anchors.fill: parent
        radius: card.round
        color: root.surface
        border.color: root.edge
        border.width: Math.max(1, 2 / Math.max(0.05, card.scale))
        clip: true

        Image {
          anchors.fill: parent
          visible: root.picture != ""
          source: root.picture
          fillMode: Image.PreserveAspectCrop
          smooth: true
          // Every stash writes the same file, so a cached decode would fly the
          // previous page. And unlike the shatter the file is gone in seconds.
          cache: false
        }

        // No picture -- grim failed or was never there. The theme's own
        // surface, lit from the top so it still reads as a page and not a hole.
        Rectangle {
          visible: root.picture == ""
          anchors.fill: parent
          radius: card.round
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.lighter(root.surface, 1.3) }
            GradientStop { position: 1.0; color: root.surface }
          }
        }
      }

      // A wash of accent coming up as it nears the count, so the thing that
      // lands is the same colour as the ring it sets off.
      Rectangle {
        anchors.fill: parent
        radius: card.round
        color: root.accent
        opacity: 0.55 * Math.max(0, card.p - 0.55) / 0.45
      }
    }

    // The impact: a ring thrown out from the count and a handful of sparks.
    // Only where there is a count to hit.
    Rectangle {
      readonly property real d: root.landSize * (1 + 2.2 * root.k)
      visible: root.active && root.hasTarget && root.t >= 1 && root.k < 1
      width: d
      height: d
      radius: d / 2
      x: root.land.x - d / 2
      y: root.land.y - d / 2
      color: "transparent"
      border.color: root.accent
      border.width: Math.max(1, 3 * (1 - root.k))
      opacity: 0.9 * (1 - root.k)
    }

    Repeater {
      model: root.active && root.hasTarget ? 8 : 0

      delegate: Rectangle {
        required property int index
        // Fanned away from the screen edge the bar sits on: past it they
        // would simply be cut off.
        readonly property real angle: Math.PI * (index / 7)
        readonly property real away:
          root.onScreen && root.land.y > root.onScreen.height / 2 ? -1 : 1
        readonly property real reach: root.landSize * (0.6 + 1.4 * root.k)
        visible: root.t >= 1 && root.k < 1
        width: 4
        height: 4
        radius: 2
        x: root.land.x + Math.cos(angle) * reach - 2
        y: root.land.y + away * Math.sin(angle) * reach - 2
        color: root.accent
        opacity: 1 - root.k
      }
    }
  }
}

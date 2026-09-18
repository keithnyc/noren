import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// A page window coming apart as it closes.
//
// The overview shatters its own card, which it can: it has the picture and the
// card on screen. Everywhere else the window is simply gone by the time anyone
// hears about it, so the picture has to be taken first -- `noren close` grabs
// the region with grim and hands the file over here before closing the window.
//
// Closes Noren did not make (SUPER+W, a page closing itself) still get a burst,
// drawn from the window's last known geometry in the theme's own colours. Less
// of a picture, same shape and the same weight.
Item {
  id: root

  property color surface: Color.menu.background
  property color edge: Color.menu.border

  // How the window leaves. A noren is a split curtain in a doorway: the page
  // parts into hanging panels, sways aside and drops. Glass is the other one --
  // small pieces, thrown out and down.
  property string style: "curtain"
  readonly property bool curtain: style !== "glass"
  readonly property int cols: curtain ? 5 : 10
  readonly property int rows: curtain ? 1 : 7

  property rect area: Qt.rect(0, 0, 0, 0)   // where to draw, screen-local
  property url picture: ""                   // the grabbed page, if there is one
  property var seeds: []
  property bool active: false
  property real t: 0
  property var onScreen: null

  // Which screen the window was on. Coordinates from Hyprland are global; a
  // layer surface is per-monitor, so the burst has to be placed in the right
  // one and shifted into its local space.
  function screenFor(x, y, w, h) {
    var monitors = Hyprland.monitors ? Hyprland.monitors.values : []
    var cx = x + w / 2
    var cy = y + h / 2
    for (var i = 0; i < monitors.length; i++) {
      var ipc = monitors[i].lastIpcObject || {}
      if (cx >= ipc.x && cx < ipc.x + ipc.width && cy >= ipc.y && cy < ipc.y + ipc.height) {
        return { name: monitors[i].name, x: ipc.x, y: ipc.y }
      }
    }
    var focused = Hyprland.focusedMonitor
    var fipc = focused ? (focused.lastIpcObject || {}) : {}
    return { name: focused ? focused.name : "", x: fipc.x || 0, y: fipc.y || 0 }
  }

  function burst(x, y, w, h, image, how) {
    if (w <= 0 || h <= 0) return
    root.style = how === "glass" ? "glass" : "curtain"
    var mon = root.screenFor(x, y, w, h)
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === mon.name) root.onScreen = screens[i]
    }

    var made = []
    for (var n = 0; n < root.cols * root.rows; n++) {
      var col = n % root.cols
      var row = Math.floor(n / root.cols)
      // Outward from the middle, so it reads as one impact rather than every
      // piece deciding for itself.
      var fromX = (col + 0.5) / root.cols - 0.5
      var fromY = (row + 0.5) / root.rows - 0.5
      if (root.curtain) {
        // Panels swing out from the middle, the way a curtain opens when
        // someone passes through it, and the outer ones follow the inner.
        made.push({
          vx: fromX * (70 + Math.random() * 30),
          vy: 0,
          spin: fromX * (10 + Math.random() * 8),
          delay: Math.abs(fromX) * 0.12 + Math.random() * 0.03
        })
      } else {
        made.push({
          vx: fromX * (120 + Math.random() * 90),
          vy: fromY * (75 + Math.random() * 60) - (24 + Math.random() * 34),
          spin: (Math.random() - 0.5) * 90,
          delay: Math.random() * 0.07
        })
      }
    }
    root.seeds = made
    root.picture = image || ""
    root.area = Qt.rect(x - mon.x, y - mon.y, w, h)
    root.active = true
    fly.restart()
  }

  NumberAnimation {
    id: fly
    target: root
    property: "t"
    from: 0
    to: 1
    // Cloth takes longer to fall than glass does to scatter.
    duration: root.curtain ? 520 : 380
    easing.type: root.curtain ? Easing.InOutQuad : Easing.OutQuad
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
    WlrLayershell.namespace: "noren-shatter"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Nothing here is clickable, and a window closing must not swallow the
    // click that comes after it.
    mask: Region {}

    Repeater {
      model: root.active ? root.cols * root.rows : 0

      delegate: Item {
        id: shard
        required property int index
        readonly property int col: index % root.cols
        readonly property int row: Math.floor(index / root.cols)
        readonly property real pieceW: root.area.width / root.cols
        readonly property real pieceH: root.area.height / root.rows
        readonly property var seed: root.seeds[index] || ({ vx: 0, vy: 0, spin: 0, delay: 0 })
        // A fraction late each, so the window comes apart rather than leaving
        // in one piece.
        readonly property real t:
          Math.max(0, Math.min(1, (root.t - seed.delay) / (1 - seed.delay)))

        width: pieceW
        height: pieceH
        clip: true

        // A panel hangs from its top edge and swings there; a shard tumbles
        // about its middle.
        transformOrigin: root.curtain ? Item.Top : Item.Center

        x: root.area.x + col * pieceW + seed.vx * t
        // Cloth is let go, then falls; glass is thrown out and pulled down.
        y: root.area.y + row * pieceH + seed.vy * t
          + (root.curtain ? (40 * t + 430 * t * t) : 340 * t * t)
        opacity: Math.max(0, 1 - t * t * (root.curtain ? 1.25 : 1.7))
        scale: 1 - (root.curtain ? 0.06 : 0.2) * t
        rotation: seed.spin * t

        // A window onto the whole grabbed page, shifted so this piece shows its
        // own part of it. Clipping a scaled copy rather than slicing source
        // pixels keeps it right whatever size the grab came back at.
        Image {
          visible: root.picture != ""
          source: root.picture
          width: root.area.width
          height: root.area.height
          x: -shard.col * shard.pieceW
          y: -shard.row * shard.pieceH
          smooth: true
          // Shared between every shard: the same url drawn seventy times should
          // be decoded once. Each burst writes a new file, so nothing stale is
          // held onto.
          cache: true
        }

        // No picture -- a close Noren did not make, so there was nothing left to
        // photograph by the time we heard. Cloth rather than a slab: shaded
        // down its length, with the light catching the cut edges.
        Rectangle {
          visible: root.picture == ""
          anchors.fill: parent
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.lighter(root.surface, 1.35) }
            GradientStop { position: 0.55; color: root.surface }
            GradientStop { position: 1.0; color: Qt.darker(root.surface, 1.25) }
          }

          // The slit edges, lit the way a parted curtain catches light.
          Rectangle {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 1
            color: Qt.lighter(root.edge, 1.6)
            opacity: 0.8
          }
          Rectangle {
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
            width: 1
            color: Qt.darker(root.edge, 1.2)
            opacity: 0.8
          }
        }
      }
    }
  }
}

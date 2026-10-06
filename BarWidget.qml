import QtQuick
import Quickshell
import qs.Ui

// Shows what the focused browser window is on, and opens the url bar on click.
// Every value comes off the shared service — nothing is derived per-view.
BarWidget {
  id: root
  moduleName: "io.github.keithnyc.noren"

  // The bar lays widgets out by their implicit size, and the base BarWidget
  // has none. Without these the widget was in the layout at zero width: loaded,
  // error-free, and invisible.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var noren: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName)
    : null

  readonly property bool connected: noren ? noren.connected : false
  readonly property bool loading: noren ? noren.loading : false
  readonly property string label: noren ? noren.label : ""
  readonly property int stashed: noren ? noren.stashCountShown : 0

  // No "disconnected" glyph: the bridge drops for a moment on every shell
  // restart and extension reload, and an X-in-a-box there read as a broken
  // font rather than news. `noren doctor` is where the connection is diagnosed.
  readonly property string icon: connected && loading ? "󰑓" : "󰖟"

  function summary() {
    if (!root.connected) return "Noren — browser not running"
    var line = root.label || "Noren"
    if (root.stashed > 0) line += "  \u00B7  " + root.stashed + " stashed"
    return line
  }

  // Where the stash flight should land: the badge's centre in this screen's
  // own coordinates. The bar surface is anchored to one edge, so its 0,0 is the
  // screen's except on the bottom and right, where the bar's own offset has to
  // be added -- the same correction the bar makes for its tooltips.
  function stashLanding() {
    var win = root.QsWindow.window
    if (!win || !win.screen || !win.contentItem) return null
    var p = win.contentItem.mapFromItem(badge, badge.width / 2, badge.height / 2)
    var x = p.x
    var y = p.y
    var edge = root.bar ? root.bar.position : "top"
    if (edge === "bottom") y += Math.max(0, win.screen.height - win.height)
    else if (edge === "right") x += Math.max(0, win.screen.width - win.width)
    return { screen: String(win.screen.name || ""), x: x, y: y, size: badge.height }
  }

  // One registration per bar, so a stash on any monitor lands on its own.
  onNorenChanged: if (root.noren) root.noren.registerStashTarget(root)
  Component.onCompleted: if (root.noren) root.noren.registerStashTarget(root)
  Component.onDestruction: if (root.noren) root.noren.unregisterStashTarget(root)

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.loading
    // The bar's own tooltip, placed and themed like every other widget's.
    tooltipText: root.summary()

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.noren) root.noren.reload()
        return
      }
      // Left click parts the curtain.
      Quickshell.execDetached(["omarchy-shell", "-q", "shell", "toggle", root.moduleName, "{}"])
    }
  }

  // The stash count. Its geometry is kept up even at zero -- only its
  // visibility follows the count -- so the very first stash still has
  // somewhere to fly to.
  Rectangle {
    id: badge
    readonly property real size: Math.max(10, Math.round(root.barSize * 0.4))
    visible: root.stashed > 0
    width: Math.max(size, countText.implicitWidth + size * 0.5)
    height: size
    radius: size / 2
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: Math.round(size * 0.05)
    anchors.topMargin: Math.round(size * 0.1)
    // The bar's own pair, reversed: whatever the theme, those two already
    // read against each other.
    color: root.bar ? root.bar.foreground : "white"
    border.color: root.bar ? root.bar.background : "black"
    border.width: 1
    transformOrigin: Item.Center

    Text {
      id: countText
      anchors.centerIn: parent
      text: root.stashed > 99 ? "99+" : String(root.stashed)
      color: root.bar ? root.bar.background : "black"
      font.family: root.bar ? root.bar.fontFamily : ""
      font.pixelSize: Math.max(7, Math.round(badge.size * 0.68))
      font.bold: true
    }
  }

  // A landing is felt as well as counted: the badge swells past its size and
  // settles, and the icon under it gives a little, as if caught.
  SequentialAnimation {
    id: bump
    ParallelAnimation {
      NumberAnimation { target: badge; property: "scale"; from: 1; to: 1.55; duration: 110; easing.type: Easing.OutQuad }
      NumberAnimation { target: button; property: "scale"; from: 1; to: 0.86; duration: 110; easing.type: Easing.OutQuad }
    }
    ParallelAnimation {
      NumberAnimation { target: badge; property: "scale"; to: 1; duration: 380; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
      NumberAnimation { target: button; property: "scale"; to: 1; duration: 320; easing.type: Easing.OutBack }
    }
  }

  Connections {
    target: root.noren
    function onStashLanded() { bump.restart() }
  }

  // Party mode's lights on this bar. Its own surface, on this bar's screen.
  PartyGlow {
    service: root.noren
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    edge: root.bar ? String(root.bar.position || "top") : "top"
    barSize: root.barSize
    barWindow: root.QsWindow.window
  }

  // The badge is its own button: straight to the stash in the url bar.
  // Generous around the dot, since the dot itself is a few pixels across --
  // but clamped to the widget, because the part of a child outside its parent
  // draws and never sees a click.
  MouseArea {
    x: Math.max(0, badge.x - 4)
    y: Math.max(0, badge.y - 4)
    width: Math.min(root.width, badge.x + badge.width + 4) - x
    height: Math.min(root.height, badge.y + badge.height + 4) - y
    enabled: badge.visible
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    onClicked: Quickshell.execDetached(["omarchy-shell", "-q", "shell", "toggle", root.moduleName,
                                        JSON.stringify({ mode: "url", text: "~" })])
  }
}

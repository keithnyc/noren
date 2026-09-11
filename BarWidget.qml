import QtQuick
import Quickshell
import qs.Ui

// Shows what the focused browser window is on, and opens the url bar on click.
// Every value comes off the shared service — nothing is derived per-view.
BarWidget {
  id: root
  moduleName: "io.github.keithnyc.noren"

  readonly property var noren: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName)
    : null

  readonly property bool connected: noren ? noren.connected : false
  readonly property bool loading: noren ? noren.loading : false
  readonly property string label: noren ? noren.label : ""

  readonly property string icon: !connected ? "󰅘" : (loading ? "󰑓" : "󰖟")

  function summary() {
    if (!root.connected) return "Noren — browser not running"
    if (!root.label) return "Noren"
    return root.label
  }

  BarIconButton {
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.loading

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.noren) root.noren.reload()
        return
      }
      // Left click parts the curtain.
      Quickshell.execDetached(["omarchy-shell", "-q", "shell", "toggle", root.moduleName, "{}"])
    }
  }

  PanelToolTip {
    bar: root.bar
    text: root.summary()
  }
}

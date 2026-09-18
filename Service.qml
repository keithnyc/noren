import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

// Holds whatever the browser last told us, and exposes the bridge to the rest
// of the shell. State arrives push-style from noren-host, which calls
//
//   omarchy-shell -q io.github.keithnyc.noren setState '<json>'
//
// on every tab, title, load and focus change. Nothing here polls.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string binPath: String(Qt.resolvedUrl("bin/noren")).replace("file://", "")

  // Last known state of the focused browser window.
  property string pageTitle: ""
  property string pageUrl: ""
  property bool loading: false
  property bool connected: false

  // Derived once here rather than in each consumer — a bar widget and an
  // overlay reading the same thing must not each recompute it.
  readonly property string host: extractHost(pageUrl)
  readonly property string label: pageTitle.length > 0 ? pageTitle : host

  function extractHost(url) {
    if (!url) return ""
    var m = String(url).match(/^[a-z][a-z0-9+.-]*:\/\/([^\/?#]+)/i)
    if (!m) return ""
    return m[1].replace(/^www\./, "")
  }

  function applyState(state) {
    if (!state || typeof state !== "object") {
      root.connected = false
      root.pageTitle = ""
      root.pageUrl = ""
      root.loading = false
      return
    }
    root.connected = true
    root.pageTitle = state.title || ""
    root.pageUrl = state.url || ""
    root.loading = Boolean(state.loading)
  }

  // Fire-and-forget CLI call. Commands that need a reply go through the
  // socket directly from whoever asked; the bar must never block on the browser.
  function run(args) {
    runner.command = [root.binPath].concat(args)
    runner.running = true
  }

  function go(url) { if (url && url.length > 0) root.run(["go", url]) }
  function open(url) { if (url && url.length > 0) root.run(["open", url]) }
  function back() { root.run(["back"]) }
  function forward() { root.run(["forward"]) }
  function reload() { root.run(["reload"]) }
  function peel() { root.run(["peel"]) }

  Process {
    id: runner
    running: false
  }

  // ------------------------------------------------------------------ shatter
  //
  // Page windows come apart when they close. `noren close` takes the picture
  // first and calls in through IPC; anything else that closes a page window --
  // SUPER+W, a page closing itself -- is caught here from Hyprland's own event
  // and bursts without one.
  Shatter {
    id: burstLayer
  }

  // The same settings file the CLI writes. Read directly rather than asked for
  // over the bridge: a window closing must not wait on the browser, and this
  // has to hold when the browser is not running at all.
  property bool shatterEnabled: true
  property string shatterStyle: "curtain"

  FileView {
    id: configFile
    path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
      + "/noren/config.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.readConfig()
    onFileChanged: reload()
  }

  function readConfig() {
    try {
      var config = JSON.parse(configFile.text() || "{}")
      var how = config.shatter
      if (how === undefined || how === true) how = "curtain"
      root.shatterEnabled = how !== false && how !== "off"
      root.shatterStyle = how === "glass" ? "glass" : "curtain"
    } catch (e) {
      root.shatterEnabled = true
      root.shatterStyle = "curtain"
    }
  }

  IpcHandler {
    target: "io.github.keithnyc.noren"

    // Called by noren-host whenever the browser changes.
    function setState(payloadJson: string): string {
      try {
        root.applyState(JSON.parse(payloadJson))
      } catch (e) {
        root.connected = false
      }
      return "ok"
    }

    function go(url: string): string { root.go(url); return "ok" }
    function open(url: string): string { root.open(url); return "ok" }
    function back(): string { root.back(); return "ok" }
    function forward(): string { root.forward(); return "ok" }
    function reload(): string { root.reload(); return "ok" }
    function peel(): string { root.peel(); return "ok" }

    function state(): string {
      return JSON.stringify({
        connected: root.connected,
        title: root.pageTitle,
        url: root.pageUrl,
        loading: root.loading
      })
    }

    function ping(): string { return "ok" }

    // The host calls this when a page window closes, whoever closed it: it
    // keeps a recent snapshot of each page window, so there is a picture to
    // tear up even though the window itself is already gone.
    function shatter(payloadJson: string): string {
      try {
        var it = JSON.parse(payloadJson)
        burstLayer.burst(Number(it.x), Number(it.y), Number(it.w), Number(it.h),
                         it.image ? "file://" + it.image : "",
                         it.style || root.shatterStyle)
      } catch (e) {
        return "bad payload"
      }
      return "ok"
    }
  }

  // The host only pushes on change, so a restart of the shell leaves us blank
  // until the next browser event. Ask once on load to fill the gap.
  Component.onCompleted: refreshTimer.start()

  Timer {
    id: refreshTimer
    interval: 400
    repeat: false
    onTriggered: statusProbe.running = true
  }

  Process {
    id: statusProbe
    command: [root.binPath, "status"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var res = JSON.parse(this.text)
          if (res && res.ok) root.applyState(res.state)
        } catch (e) {
          root.connected = false
        }
      }
    }
  }
}

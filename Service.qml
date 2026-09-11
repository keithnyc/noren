import QtQuick
import Quickshell
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

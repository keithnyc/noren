import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The curtain. Type a url to navigate the focused window, or type anything to
// filter open tabs and jump to one.
//
// Summoned with:  omarchy-shell shell toggle io.github.keithnyc.noren
Item {
  id: root

  property var shell: null
  property bool opened: false
  // Which face the overlay is wearing. The plugin schema allows one overlay
  // entry point, and `open()` already receives a payload, so the radial is a
  // mode rather than a second plugin:
  //   omarchy-shell shell toggle io.github.keithnyc.noren '{"mode":"radial"}'
  property string mode: "url"
  // Filled from `noren status` when the radial opens: the ring needs the live
  // url to copy, and the theme mode to cycle from where it actually is.
  property string pageUrl: ""
  property string pageTitle: ""
  property string themeMode: "tint"
  // Whether new pages join the group in front, from `noren status`.
  property bool tabbedMode: false
  // The window the overview asked for, kept across the close so it can be
  // raised again afterwards -- see onChosen.
  property string pendingRaise: ""
  // Set while handing the screen over to a window the overview picked. The
  // overlay drops its exclusive keyboard focus first -- see the PanelWindow.
  property bool handingOff: false
  property string filterText: ""
  property int selectedIndex: 0
  property var tabs: []
  // Completions from the browser's bookmarks and history, fetched per keystroke.
  // The shell cannot see either, so they come across the bridge.
  property var suggestions: []
  // Named sets of pages, from `noren set list --json`.
  property var sets: []
  // What `set save` would capture right now, so the save row can show what it
  // is about to save instead of a bare count.
  property var pending: ({ urls: [], grouped: false })
  // Whether the user has actually moved off the first row. Enter treats a typed
  // url as literal until they do -- see activate().
  property bool selectionMoved: false
  // The chrome-less window on this workspace, if any — the one Ctrl+Enter
  // would replace. Queried straight from Hyprland so it works with the
  // browser closed.
  property var target: null
  readonly property bool canReplace: target && target.chromeless === true

  readonly property string binPath: String(Qt.resolvedUrl("bin/noren")).replace("file://", "")

  // Share the [menu] surface tokens, so a theme that styles the menu styles
  // this too without knowing Noren exists.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property string fontFamily: Style.font.menuFamily

  readonly property var matches: buildMatches()
  readonly property int maxRows: 12

  // A leading sigil scopes the search. Blended ranking is right by default and
  // imprecise when you already know what you are looking for, so:
  //   *term  bookmarks      %term  history      #term  open tabs
  // `*` alone lists your bookmarks, which is as close to a bookmark manager as
  // a chrome-less browser gets.
  readonly property string scope: {
    var t = root.filterText
    if (t.length === 0) return ""
    var c = t.charAt(0)
    if (c === "*") return "bookmark"
    if (c === "%") return "history"
    if (c === "#") return "tab"
    if (c === "@") return "set"
    return ""
  }

  // Everything downstream matches on this, never on filterText: `*foo.com`
  // would otherwise read as a url and Enter would try to open the sigil.
  readonly property string query:
    root.scope.length > 0 ? root.filterText.slice(1) : root.filterText

  readonly property string scopeLabel:
    root.scope === "bookmark" ? "bookmarks"
      : root.scope === "history" ? "history"
      : root.scope === "tab" ? "open tabs"
      : root.scope === "set" ? "your sets" : ""

  // Several destinations typed at once: `social.example, search.example, video.example`.
  // The comma only counts as a separator when *every* part is itself a
  // destination -- `bread, butter recipe` is a search. The same rule lives in
  // `noren open`, which does the actual splitting; this copy only decides what
  // the footer promises and what Ctrl+Enter means.
  readonly property var destinations: splitDestinations(query)
  readonly property bool multiUrl: destinations.length > 1

  function isDestination(text) {
    var raw = String(text || "").trim()
    if (raw.length === 0 || raw.indexOf(" ") >= 0) return false
    return /^[a-z][a-z0-9+.-]*:\/\//i.test(raw) || raw.indexOf(".") >= 0
  }

  function splitDestinations(text) {
    var raw = String(text || "").trim()
    if (raw.indexOf(",") < 0) return raw.length > 0 ? [raw] : []
    var parts = []
    var pieces = raw.split(",")
    for (var i = 0; i < pieces.length; i++) {
      var piece = pieces[i].trim()
      if (piece.length > 0) parts.push(piece)
    }
    if (parts.length > 1) {
      for (var j = 0; j < parts.length; j++) {
        if (!root.isDestination(parts[j])) return [raw]
      }
      return parts
    }
    return [raw]
  }

  // A typed string that looks like a destination rather than a search.
  readonly property bool looksLikeUrl: /^[a-z][a-z0-9+.-]*:\/\//i.test(query)
    || (query.length > 0 && /\./.test(query) && !/\s/.test(query))

  function dedupeKey(url) {
    return String(url || "").replace(/^https?:\/\//, "").replace(/\/+$/, "").toLowerCase()
  }

  // Open tabs first, then bookmarks and history. A page that is already open
  // should be jumped to rather than opened a second time, so anything the
  // browser suggests that is already a tab is dropped.
  function setRows(needle) {
    var rows = []
    for (var i = 0; i < root.sets.length; i++) {
      var entry = root.sets[i]
      if (needle.length > 0 && entry.name.toLowerCase().indexOf(needle) < 0) continue
      var hosts = []
      for (var j = 0; j < entry.urls.length && j < 5; j++) hosts.push(root.hostOf(entry.urls[j]))
      if (entry.urls.length > 5) hosts.push("+" + (entry.urls.length - 5))
      rows.push({
        kind: "set",
        id: -1,
        name: entry.name,
        title: entry.name + "  \u00B7  " + entry.urls.length + " pages"
          + (entry.grouped ? ", as a group" : ", tiled"),
        url: hosts.join("  ")
      })
    }
    return rows
  }

  function hostOf(url) {
    var m = String(url || "").match(/^[a-z][a-z0-9+.-]*:\/\/([^\/?#]+)/i)
    return m ? m[1].replace(/^www\./, "") : String(url || "")
  }

  function buildMatches() {
    var needle = root.query.toLowerCase().trim()
    var out = []
    var seen = {}

    // Nothing typed yet: the guide, not a search. The bookmarks bar in its own
    // order, then the sites visited most -- the same places the start page
    // leads with -- then your sets, then whatever else is open. A place that is
    // already open becomes its tab, so Enter jumps rather than opening a twin.
    if (root.scope === "" && needle.length === 0) {
      // The start page first, always, so SUPER+B then Enter is always "home"
      // -- from a terminal, from an empty workspace, from anywhere.
      out.push({
        kind: "home",
        id: -1,
        title: "Start page",
        url: "pinned sites, most visited and sets"
      })
      var openByHost = {}
      for (var t = 0; t < root.tabs.length; t++) {
        var tabHost = root.hostOf(root.tabs[t].url).toLowerCase()
        if (!openByHost[tabHost]) openByHost[tabHost] = root.tabs[t]
      }
      var used = {}
      for (var p = 0; p < root.suggestions.length; p++) {
        var place = root.suggestions[p]
        var already = openByHost[root.hostOf(place.url).toLowerCase()]
        if (already && !used[already.id]) {
          used[already.id] = true
          out.push({ kind: "tab", id: already.id, title: already.title, url: already.url })
        } else if (!already) {
          out.push({ kind: place.kind || "history", id: -1, title: place.title, url: place.url })
        }
      }
      out = out.concat(root.setRows(""))
      for (var r = 0; r < root.tabs.length; r++) {
        if (used[root.tabs[r].id]) continue
        out.push({ kind: "tab", id: root.tabs[r].id, title: root.tabs[r].title, url: root.tabs[r].url })
      }
      return out.slice(0, root.maxRows)
    }

    // Sets first, and also when no sigil was typed: a set named `news` should
    // turn up for someone who typed `news` and has never heard of `@`.
    if (root.scope === "set" || root.scope === "") {
      out = out.concat(root.setRows(needle))
    }
    if (root.scope === "set") {
      // Saving lives here rather than in the radial: a name is the only input a
      // save needs, and this is already where names get typed. Type `@news`
      // with no such set and the first row becomes the save.
      var typed = root.query.trim()
      var pages = (root.pending && root.pending.urls) ? root.pending.urls.length : 0
      if (typed.length > 0 && pages > 0) {
        var exists = false
        for (var k = 0; k < root.sets.length; k++) {
          if (root.sets[k].name.toLowerCase() === typed.toLowerCase()) exists = true
        }
        var hosts = []
        for (var h = 0; h < root.pending.urls.length && h < 5; h++) {
          hosts.push(root.hostOf(root.pending.urls[h]))
        }
        if (root.pending.urls.length > 5) hosts.push("+" + (root.pending.urls.length - 5))
        var row = {
          kind: "save",
          id: -1,
          name: typed,
          title: (exists ? "Replace \u201C" + typed + "\u201D with " : "Save as \u201C" + typed + "\u201D  \u00B7  ")
            + pages + " open page" + (pages === 1 ? "" : "s")
            + (root.pending.grouped ? ", as a group" : ", tiled"),
          url: hosts.join("  ")
        }
        // A matching set stays first, so Enter opens rather than overwrites;
        // replacing is a deliberate arrow-down.
        if (exists) out.push(row)
        else out = [row].concat(out)
      }

      // A bare `@` with nothing saved used to show an empty list: no sets, no
      // save row (there is no name yet), and no clue that either exists. A dead
      // end where the answer was one sentence.
      if (out.length === 0) {
        out.push({
          kind: "hint",
          id: -1,
          name: "",
          title: pages > 0
            ? "No sets yet \u00B7 type a name to save the " + pages
              + " open page" + (pages === 1 ? "" : "s")
            : "No sets yet",
          url: pages > 0
            ? "e.g. \u201Cnews\u201D \u2014 then Enter"
            : "Open some pages first, then come back and name them"
        })
      }
      return out.slice(0, root.maxRows)
    }

    var live = (root.scope === "" || root.scope === "tab") ? root.tabs : []
    if (needle.length > 0) {
      live = live.filter(function (t) {
        return (t.title || "").toLowerCase().indexOf(needle) >= 0
          || (t.url || "").toLowerCase().indexOf(needle) >= 0
      })
    }
    for (var i = 0; i < live.length; i++) {
      seen[root.dedupeKey(live[i].url)] = true
      out.push({ kind: "tab", id: live[i].id, title: live[i].title, url: live[i].url })
    }

    for (var j = 0; root.scope !== "tab" && j < root.suggestions.length; j++) {
      var sug = root.suggestions[j]
      var key = root.dedupeKey(sug.url)
      if (seen[key]) continue
      seen[key] = true
      out.push({ kind: sug.kind || "history", id: -1, title: sug.title, url: sug.url })
    }

    return out.slice(0, root.maxRows)
  }

  readonly property var radialActions: [
    { icon: "\uf053", key: "B", label: "Back", hint: "Previous page",
      run: function () { root.runNoren(["back"]) } },
    { icon: "\uf054", key: "F", label: "Forward", hint: "Next page",
      run: function () { root.runNoren(["forward"]) } },
    { icon: "\udb81\udc53", key: "R", label: "Reload", hint: "Fetch this page again",
      run: function () { root.runNoren(["reload"]) } },
    { icon: "\udb80\udd8f", key: "C", label: "Copy", hint: root.pageUrl,
      run: function () { root.copyUrl() } },
    // U+F00C4: a bookmark with a plus in it. Rendered and looked at -- the
    // neighbours are the same bookmark filled and outlined, with no plus.
    { icon: "\udb80\udcc4", key: "D", label: "Save", hint: "Bookmark this page",
      run: function () { root.runNoren(["save"]) } },
    { icon: "\udb80\udd9f", key: "U", label: "Url bar", hint: "Type a url, search tabs and history",
      run: function () { root.showUrlBar() } },
    // U+F02DC: a house. Rendered and looked at; its neighbour U+F07D1 is a
    // house with a wifi signal in it.
    { icon: "\udb80\udedc", key: "H", label: "Home", hint: "This page goes to your start page",
      run: function () { root.runNoren(["start"]) } },
    { icon: "\udb81\udd6f", key: "P", label: "Peel", hint: "This tab into its own window",
      run: function () { root.runNoren(["peel"]) } },
    // U+F1400: a window with content panels. U+F00C5 was the first pick and is
    // a bookmark-plus -- all but identical to Save, two items along.
    { icon: "\udb85\udc00", key: "V", label: "Overview", hint: "See every page in the group",
      run: function () { root.showOverview() } },
    { icon: "\udb81\udd70", key: "G", label: "Gather", hint: "Fold windows into one group",
      run: function () { root.runNoren(["gather"]) } },
    // U+F1401: a window with a bar across its top. Rendered and looked at --
    // its neighbour U+F1400 is the panelled window Overview uses.
    { icon: "\udb85\udc01", key: "J", label: "Tabs",
      state: root.tabbedMode ? "on" : "off",
      hint: root.tabbedMode
        ? "New pages join this group \u2014 on"
        : "New pages open as their own window \u2014 off",
      run: function () { root.setTabbed(!root.tabbedMode) } },
    // U+F0207: an arrow leaving a box. Rendered and looked at, not guessed --
    // its neighbour U+F0342 is the same arrow pointing *into* the box.
    { icon: "\udb80\ude07", key: "O", label: "Pop out", hint: "Lift this window out of the group",
      run: function () { root.runNoren(["pop"]) } },
    // U+F0616: arrows pointing apart. Rendered and checked rather than guessed
    // from the codepoint -- the neighbours are an up-arrow, a superscript 2 and
    // a filled square.
    { icon: "\udb81\ude16", key: "S", label: "Scatter", hint: "Break the group into tiled windows",
      run: function () { root.runNoren(["scatter"]) } },
    { icon: "\udb80\udd0e", key: "T", label: "Theme", state: root.themeMode,
      hint: "Page theming: " + root.themeMode,
      run: function () { root.cycleTheme() } }
  ]

  function copyUrl() {
    if (root.pageUrl.length > 0) Quickshell.execDetached(["wl-copy", "--", root.pageUrl])
  }

  // Both settings on the ring are set to a value, never "toggled", and the ring
  // shows the new value at once rather than waiting to be told. Asking for the
  // state back after writing it means a round trip through a CLI process, a
  // socket and the host -- and if any part of that is late or does not re-run,
  // the ring silently keeps showing the old value, which reads as a toggle that
  // does nothing. `noren status` still reconciles on the next summon, so a
  // setting changed elsewhere is not missed.
  function setTabbed(on) {
    root.tabbedMode = on
    root.runNoren(["tabbed", on ? "on" : "off"])
  }

  function cycleTheme() {
    var order = ["respect", "tint", "immerse"]
    var at = order.indexOf(root.themeMode)
    var next = order[(at + 1) % order.length]
    root.themeMode = next
    root.runNoren(["theme", next])
  }

  // Like the url bar, the overview swaps face rather than closing -- the ring
  // is how you get to it, not something to dismiss first.
  function showOverview() {
    root.mode = "overview"
    Qt.callLater(function () { overview.forceActiveFocus() })
  }

  // The ring's own way back to the url bar: swap face instead of closing, so
  // it is one gesture rather than dismiss-and-summon.
  function showUrlBar() {
    root.mode = "url"
    root.filterText = ""
    root.selectedIndex = 0
    root.selectionMoved = false
    tabLoader.running = true
    root.requestSuggestions()
    Qt.callLater(function () { input.forceActiveFocus() })
  }

  function open(payloadJson) {
    var wanted = "url"
    try {
      var payload = payloadJson ? JSON.parse(payloadJson) : null
      if (payload && payload.mode === "radial") wanted = "radial"
      if (payload && payload.mode === "overview") wanted = "overview"
    } catch (e) {
      // A malformed payload is a url bar, not an error worth surfacing.
    }
    root.mode = wanted
    root.opened = true
    // Reset here rather than on close: flipping the surface back to exclusive
    // as it disappears would take the keyboard back for a frame, which is the
    // very thing the hand-off avoids.
    root.handingOff = false
    root.filterText = ""
    root.selectedIndex = 0
    root.selectionMoved = false
    root.suggestions = []
    targetLoader.running = true
    statusLoader.running = true
    setLoader.running = true
    pendingLoader.running = true
    if (root.mode === "url") {
      tabLoader.running = true
      root.requestSuggestions()
      Qt.callLater(function () { input.forceActiveFocus() })
    } else if (root.mode === "overview") {
      Qt.callLater(function () { overview.forceActiveFocus() })
    } else {
      Qt.callLater(function () { radial.forceActiveFocus() })
    }
  }

  function close() {
    root.opened = false
    root.mode = "url"
    root.filterText = ""
    root.tabs = []
    root.suggestions = []
    root.selectionMoved = false
    root.target = null
  }

  function moveSelection(delta) {
    var n = root.matches.length
    if (n === 0) return
    root.selectedIndex = (root.selectedIndex + delta + n) % n
    root.selectionMoved = true
  }

  // The highlighted row, or null. Several handlers need it.
  function currentRow() {
    var picks = root.matches
    if (picks.length === 0 || root.selectedIndex >= picks.length) return null
    return picks[root.selectedIndex]
  }

  // Shift+Delete on a set removes it -- the same gesture Chromium's omnibox uses
  // to drop a suggestion, so it is already in the fingers. Deliberately two
  // keys and deliberately not a confirmation dialog: a set costs seconds to
  // rebuild (gather, `@name`, Enter) and a modal inside an overlay is worse than
  // the mistake it prevents.
  function deleteHighlightedSet() {
    var row = root.currentRow()
    if (!row || row.kind !== "set") return false
    runNoren(["set", "rm", row.name])
    // Stay open and reload, so the row visibly goes away.
    root.selectedIndex = 0
    setRefresh.restart()
    return true
  }

  // Debounced: a process per keystroke would spawn faster than it can answer.
  function requestSuggestions() {
    suggestDebounce.restart()
  }

  // Enter: jump to the highlighted tab, or open what was typed as a new tiled
  // window. Always the same thing — the overlay is a launcher, and a launcher
  // that sometimes mutates the window behind it is a launcher you cannot trust.
  function activate() {
    var picks = root.matches
    var pick = (picks.length > 0 && root.selectedIndex < picks.length)
      ? picks[root.selectedIndex] : null

    // A typed url is taken literally until the user actually arrows onto a
    // suggestion. Otherwise typing `example.com/invoices` and pressing Enter
    // could land on `example.com/inbox` because history ranked it first --
    // a launcher that sometimes goes somewhere else is a launcher you cannot
    // trust, which is the same rule Enter already follows for windows.
    // A set the user explicitly arrowed onto, or asked for with @, wins over
    // the literal-url rule: `@news` is not a hostname.
    if (root.scope === "set" && picks.length > 0
        && root.selectedIndex < picks.length) {
      var chosen = picks[root.selectedIndex]
      if (chosen.kind === "hint") return   // nothing to act on; keep typing
      if (chosen.kind === "save") runNoren(["set", "save", chosen.name])
      else runNoren(["set", "open", chosen.name])
      root.close()
      return
    }

    // Several destinations beat any suggestion: nobody types three hosts and
    // means "jump to a tab".
    if (root.multiUrl) {
      runNoren(["open", root.query.trim()])
      root.close()
      return
    }

    var honourPick = pick && (root.selectionMoved || !root.looksLikeUrl)

    if (honourPick && pick.kind === "home") {
      // Raise an open start page or open one; never replace the page behind.
      runNoren(["start", "--keep"])
      root.close()
      return
    }

    if (honourPick && pick.kind === "save") {
      runNoren(["set", "save", pick.name])
      root.close()
      return
    }

    if (honourPick && pick.kind === "set") {
      runNoren(["set", "open", pick.name])
      root.close()
      return
    }

    if (honourPick && pick.kind === "tab") {
      runNoren(["focus", String(pick.id)])
    } else if (honourPick) {
      runNoren(["open", pick.url])
    } else if (root.query.trim().length > 0) {
      runNoren(["open", root.query.trim()])
    }
    root.close()
  }

  // Ctrl+Enter: point the chrome-less window on this workspace somewhere else.
  // A chrome-less window has no address bar, so this overlay is the only way to
  // redirect one — it has to be reachable, not buried.
  function replaceCurrent() {
    var text = root.query.trim()
    // "Replace this window" has no meaning for three urls, so Ctrl+Enter takes
    // the other reading there: open them all as one group. The single-url
    // invariant is untouched -- Enter opens, Ctrl+Enter replaces.
    if (root.multiUrl) {
      runNoren(["open", "--group", text])
      root.close()
      return
    }
    // Honour the highlighted row exactly as Enter does. This used to read only
    // the typed text, so picking a site with the arrows -- or from the list an
    // empty url bar now shows -- and pressing Ctrl+Enter closed the bar and did
    // nothing at all, since nothing had been typed.
    var pick = root.currentRow()
    var honourPick = pick && (root.selectionMoved || !root.looksLikeUrl)
    if (honourPick && pick.kind === "home") {
      // The page in front goes home -- or, with none, the start page opens.
      runNoren(["start"])
      root.close()
      return
    }
    if (honourPick && pick.kind === "set") {
      // Ctrl+Enter's meaning, for a set: in place of the page in front, which
      // becomes the set's first page (and its group). Enter opens alongside.
      runNoren(["set", "open", pick.name, "--replace"])
      root.close()
      return
    }
    if (honourPick && (pick.kind === "save" || pick.kind === "hint")) {
      root.activate()
      return
    }
    if (honourPick && pick.kind === "tab") {
      // Already open somewhere: go to it rather than loading it twice.
      runNoren(["focus", String(pick.id)])
      root.close()
      return
    }
    if (honourPick && pick.url) text = pick.url
    if (text.length > 0 && root.canReplace) runNoren(["go", text])
    else if (text.length > 0) runNoren(["open", text])
    root.close()
  }

  function runNoren(args) {
    Quickshell.execDetached([root.binPath].concat(args))
  }

  Timer {
    id: handOff
    interval: 16
    repeat: false
    onTriggered: {
      if (root.pendingRaise.length > 0) root.runNoren(["raise", root.pendingRaise])
    }
  }

  Timer {
    id: reRaise
    interval: 90
    repeat: false
    onTriggered: {
      if (root.pendingRaise.length > 0) root.runNoren(["raise", root.pendingRaise])
      root.pendingRaise = ""
    }
  }

  Timer {
    id: setRefresh
    interval: 260
    repeat: false
    onTriggered: {
      if (!root.opened) return
      setLoader.running = false
      setLoader.running = true
    }
  }

  Process {
    id: pendingLoader
    command: [root.binPath, "set", "preview", "--json"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var raw = JSON.parse(this.text)
          root.pending = {
            urls: raw.urls || [],
            grouped: Boolean(raw.grouped)
          }
        } catch (e) {
          root.pending = { urls: [], grouped: false }
        }
      }
    }
  }

  Process {
    id: setLoader
    command: [root.binPath, "set", "list", "--json"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var out = []
        try {
          var raw = JSON.parse(this.text)
          for (var name in raw) {
            var entry = raw[name] || {}
            out.push({
              name: name,
              urls: entry.urls || [],
              grouped: Boolean(entry.grouped)
            })
          }
          out.sort(function (a, b) { return a.name.localeCompare(b.name) })
        } catch (e) {
          out = []
        }
        root.sets = out
      }
    }
  }

  // A setting toggled from the ring is written by the CLI or the extension, so
  // the new value is only readable a moment later.
  Timer {
    id: statusRefresh
    interval: 220
    repeat: false
    // false first: a Process that has already run ignores `running = true`,
    // so the ring kept showing the state it opened with and a toggle looked
    // like it had done nothing.
    onTriggered: {
      statusLoader.running = false
      statusLoader.running = true
    }
  }

  Process {
    id: statusLoader
    command: [root.binPath, "status"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var res = JSON.parse(this.text)
          var st = (res && res.state) ? res.state : {}
          root.pageUrl = st.url || ""
          root.pageTitle = st.title || ""
          if (res && res.themeMode) root.themeMode = res.themeMode
          root.tabbedMode = Boolean(res && res.tabbed)
        } catch (e) {
          root.pageUrl = ""
          root.pageTitle = ""
        }
      }
    }
  }

  Process {
    id: targetLoader
    command: [root.binPath, "target"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var t = JSON.parse(this.text)
          root.target = (t && t.app_id) ? t : null
        } catch (e) {
          root.target = null
        }
      }
    }
  }

  Timer {
    id: suggestDebounce
    interval: 140
    repeat: false
    onTriggered: {
      if (!root.opened) return
      if (root.scope === "tab") { root.suggestions = []; return }
      var args = [root.binPath, "suggest"]
      var q = root.query.trim()
      if (root.scope.length > 0) args = args.concat(["--kind", root.scope])
      else if (q.length === 0) args = args.concat(["--kind", "start"])
      if (q.length > 0) args.push(q)
      suggestLoader.running = false
      suggestLoader.command = args
      suggestLoader.running = true
    }
  }

  Process {
    id: suggestLoader
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var res = JSON.parse(this.text)
          root.suggestions = (res && res.ok && res.suggestions) ? res.suggestions : []
        } catch (e) {
          root.suggestions = []
        }
      }
    }
  }

  Process {
    id: tabLoader
    command: [root.binPath, "tabs"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var res = JSON.parse(this.text)
          root.tabs = (res && res.ok && res.tabs) ? res.tabs : []
        } catch (e) {
          root.tabs = []
        }
        root.selectedIndex = 0
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "noren-urlbar"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive while the overlay is being used, None while it is handing the
    // screen to a window. Hyprland restores focus to whatever held it before an
    // exclusive surface appeared, so closing *undid* the raise: the old page
    // came back for a frame or two before the second raise pulled the new one
    // in again. Letting the focus go before raising means there is nothing left
    // to restore, and the switch happens once, behind the flying card.
    WlrLayershell.keyboardFocus: root.handingOff
      ? WlrKeyboardFocus.None
      : WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      // Fades while the overview launches a page, so the card lands on the real
      // window rather than on a dimmed copy of the desktop.
      opacity: (root.mode === "overview" && overview.launching) ? 0 : 1
      Behavior on opacity { NumberAnimation { duration: 240 } }
      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    RadialMenu {
      id: radial
      anchors.fill: parent
      visible: root.mode === "radial"
      active: root.opened && root.mode === "radial"
      actions: root.radialActions
      contextLabel: root.pageTitle.length > 0
        ? root.pageTitle
        : (root.pageUrl.length > 0 ? root.pageUrl : "No page in front of you")

      background: root.background
      foreground: root.foreground
      borderColor: root.borderColor
      accent: root.selectedText
      selectedBackground: root.selectedBackground
      fontFamily: root.fontFamily

      onChose: function (index) {
        var chosen = root.radialActions[index]
        // Url bar and Overview swap face rather than dismissing. A setting --
        // anything carrying a `state` -- also stays, so the ring can show what
        // it just became; flipping a toggle and being thrown out to check it is
        // how you end up toggling it twice.
        var staysOpen = chosen
          && (chosen.label === "Url bar" || chosen.label === "Overview"
              || chosen.state !== undefined)
        if (chosen && chosen.run) chosen.run()
        if (staysOpen && chosen.state !== undefined) statusRefresh.restart()
        if (!staysOpen) root.close()
      }
      onDismissed: root.close()
    }

    Overview {
      id: overview
      anchors.fill: parent
      visible: root.mode === "overview"
      active: root.opened && root.mode === "overview"

      background: root.background
      foreground: root.foreground
      borderColor: root.borderColor
      accent: root.selectedText
      fontFamily: root.fontFamily

      // The switch happens as the card starts flying, so the card lands on a
      // window that is already live. Before raising, the overlay gives up its
      // exclusive keyboard focus, or closing would hand focus back to the page
      // that had it and the raise would be undone.
      //
      // The second raise after the close stays as a safety net: `noren raise`
      // verifies the focus landed, and raising a window that already has it is
      // a no-op, so it costs nothing when the first one holds.
      onRaiseRequested: function (address) {
        if (!address || address.length === 0) return
        root.pendingRaise = address
        root.handingOff = true
        // One frame for the compositor to see the surface let go of the
        // keyboard before the window is raised.
        handOff.restart()
      }
      onChosen: {
        root.close()
        if (root.pendingRaise.length > 0) reRaise.restart()
      }

      // Escape, by contrast, returns to the ring rather than closing outright,
      // so a wrong turn costs one key instead of a re-summon.
      onDismissed: {
        root.mode = "radial"
        Qt.callLater(function () { radial.forceActiveFocus() })
      }
    }

    Rectangle {
      id: card
      visible: root.mode === "url"
      width: Math.min(Style.space(760), panel.width - Style.gapsOut * 2)
      height: Math.min(contentColumn.implicitHeight + Style.spacing.panelPadding * 2,
                       panel.height - Style.gapsOut * 2)
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.round(panel.height * 0.22)
      color: root.background
      radius: Style.cornerRadius
      border.color: root.borderColor
      border.width: Math.max(1, Style.space(1))

      Column {
        id: contentColumn
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.md

        TextField {
          id: input
          width: parent.width
          placeholderText: root.scope.length > 0
            ? "Searching " + root.scopeLabel
            : (root.tabs.length > 0
               ? "Go to a url, or search " + root.tabs.length + " tabs, bookmarks and history   (@ sets, * bookmarks, % history, # tabs)"
               : "Go to a url, or search bookmarks and history   (@ sets, * bookmarks, % history, # tabs)")
          text: root.filterText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          background: Rectangle { color: "transparent" }

          onTextChanged: {
            root.filterText = text
            root.selectedIndex = 0
            // Typing re-arms the literal-url rule: a pick only wins once the
            // user has arrowed onto it for *this* text.
            root.selectionMoved = false
            root.requestSuggestions()
          }

          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
              root.close()
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              root.moveSelection(1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              root.moveSelection(-1)
              event.accepted = true
            } else if (event.key === Qt.Key_Delete
                       && (event.modifiers & Qt.ShiftModifier)) {
              // Only consumed when it actually removed something, so
              // Shift+Delete still edits text everywhere else.
              event.accepted = root.deleteHighlightedSet()
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (event.modifiers & Qt.ControlModifier) root.replaceCurrent()
              else root.activate()
              event.accepted = true
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(1))
          color: root.borderColor
          visible: root.matches.length > 0
        }

        ListView {
          width: parent.width
          height: Math.min(root.matches.length * Style.space(44), Style.space(360))
          model: root.matches
          clip: true
          interactive: true
          currentIndex: root.selectedIndex
          visible: root.matches.length > 0

          delegate: Rectangle {
            width: ListView.view.width
            height: Style.space(44)
            color: index === root.selectedIndex ? root.selectedBackground : "transparent"
            radius: Style.cornerRadius

            // Where the row came from. An open tab is jumped to; a bookmark or
            // a history entry is opened fresh, and those behave differently
            // enough to be worth naming.
            Text {
              id: kindBadge
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.rowPaddingX
              text: modelData.kind === "hint" ? ""
                : modelData.kind === "tab" ? "tab"
                : modelData.kind === "save" ? "save"
                : modelData.kind === "set" ? "set"
                : modelData.kind === "home" ? "home"
                : modelData.kind === "bookmark" ? "saved" : "visited"
              color: index === root.selectedIndex ? root.selectedText : root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: kindBadge.left
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.spacing.rowPaddingX
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: modelData.title || modelData.url || ""
                color: index === root.selectedIndex ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: modelData.url || ""
                color: index === root.selectedIndex ? root.selectedText : root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
            }

            MouseArea {
              anchors.fill: parent
              // A hint is text, not a button.
              enabled: modelData.kind !== "hint"
              onClicked: {
                root.selectedIndex = index
                root.activate()
              }
            }
          }
        }

        // Always visible, so the two outcomes are read rather than guessed.
        // Ctrl+Enter names the window it would redirect; when there is no
        // chrome-less window here it says so instead of silently doing nothing.
        Row {
          width: parent.width
          spacing: Style.spacing.md

          Text {
            text: {
              var row = root.currentRow()
              if (row && row.kind === "hint") return "type a name to save a set"
              if (row && row.kind === "set") return "\u21B5 open set  \u00B7  Shift+Del delete"
              if (row && row.kind === "home") return root.canReplace
                ? "\u21B5 start page  \u00B7  Ctrl+\u21B5 this page goes home"
                : "\u21B5 start page"
              if (row && row.kind === "save") return "\u21B5 save set"
              if (root.multiUrl) return "\u21B5 open " + root.destinations.length + " windows"
              return (root.matches.length > 0 && !root.looksLikeUrl)
                ? "\u21B5 go to tab" : "\u21B5 new window"
            }
            color: root.foreground
            opacity: 0.75
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            text: "\u00B7"
            color: root.foreground
            opacity: 0.35
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: Math.max(0, parent.width - Style.space(220))
            text: root.multiUrl
              ? "^\u21B5 open " + root.destinations.length + " as one group"
              : (root.canReplace
                 ? "^\u21B5 replace \u201C" + root.target.title + "\u201D"
                 : "^\u21B5 replace \u2014 no page on this workspace")
            color: root.foreground
            opacity: (root.multiUrl || root.canReplace) ? 0.75 : 0.35
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}

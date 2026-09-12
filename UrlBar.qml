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
  property string filterText: ""
  property int selectedIndex: 0
  property var tabs: []
  // Completions from the browser's bookmarks and history, fetched per keystroke.
  // The shell cannot see either, so they come across the bridge.
  property var suggestions: []
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

  // A typed string that looks like a destination rather than a search.
  readonly property bool looksLikeUrl: /^[a-z][a-z0-9+.-]*:\/\//i.test(filterText)
    || (/\./.test(filterText) && !/\s/.test(filterText))

  function dedupeKey(url) {
    return String(url || "").replace(/^https?:\/\//, "").replace(/\/+$/, "").toLowerCase()
  }

  // Open tabs first, then bookmarks and history. A page that is already open
  // should be jumped to rather than opened a second time, so anything the
  // browser suggests that is already a tab is dropped.
  function buildMatches() {
    var needle = root.filterText.toLowerCase().trim()
    var out = []
    var seen = {}

    var live = root.tabs
    if (needle.length > 0) {
      live = root.tabs.filter(function (t) {
        return (t.title || "").toLowerCase().indexOf(needle) >= 0
          || (t.url || "").toLowerCase().indexOf(needle) >= 0
      })
    }
    for (var i = 0; i < live.length; i++) {
      seen[root.dedupeKey(live[i].url)] = true
      out.push({ kind: "tab", id: live[i].id, title: live[i].title, url: live[i].url })
    }

    for (var j = 0; j < root.suggestions.length; j++) {
      var sug = root.suggestions[j]
      var key = root.dedupeKey(sug.url)
      if (seen[key]) continue
      seen[key] = true
      out.push({ kind: sug.kind || "history", id: -1, title: sug.title, url: sug.url })
    }

    return out.slice(0, root.maxRows)
  }

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.selectionMoved = false
    root.suggestions = []
    tabLoader.running = true
    targetLoader.running = true
    root.requestSuggestions()
    Qt.callLater(function () { input.forceActiveFocus() })
  }

  function close() {
    root.opened = false
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
    var honourPick = pick && (root.selectionMoved || !root.looksLikeUrl)

    if (honourPick && pick.kind === "tab") {
      runNoren(["focus", String(pick.id)])
    } else if (honourPick) {
      runNoren(["open", pick.url])
    } else if (root.filterText.trim().length > 0) {
      runNoren(["open", root.filterText.trim()])
    }
    root.close()
  }

  // Ctrl+Enter: point the chrome-less window on this workspace somewhere else.
  // A chrome-less window has no address bar, so this overlay is the only way to
  // redirect one — it has to be reachable, not buried.
  function replaceCurrent() {
    var text = root.filterText.trim()
    if (text.length > 0 && root.canReplace) runNoren(["go", text])
    root.close()
  }

  function runNoren(args) {
    Quickshell.execDetached([root.binPath].concat(args))
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
      suggestLoader.running = false
      suggestLoader.command = [root.binPath, "suggest", root.filterText.trim()]
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
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    Rectangle {
      id: card
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
          placeholderText: root.tabs.length > 0
            ? "Go to a url, or search " + root.tabs.length + " tabs, bookmarks and history"
            : "Go to a url, or search bookmarks and history"
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
              text: modelData.kind === "tab" ? "tab"
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
            text: root.matches.length > 0 && !root.looksLikeUrl
              ? "\u21B5 go to tab"
              : "\u21B5 new window"
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
            text: root.canReplace
              ? "^\u21B5 replace \u201C" + root.target.title + "\u201D"
              : "^\u21B5 replace \u2014 no page on this workspace"
            color: root.foreground
            opacity: root.canReplace ? 0.75 : 0.35
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Ask your own agent about the page in front of you.
//
// This is a composer, not a chat client. Omarchy already knows which agent the
// user picked, and that agent has its own terminal where its approvals and tool
// output belong -- wrapping every agent CLI's stream in a window of ours would
// fight the interface they chose, and lose. So: you type what you want, Noren
// adds what you cannot type (the rendered page you are logged into, its
// structure, the window it lives in), the agent works in its own terminal, and
// what comes back here is a line of narration and, at the end, its answer.
//
// The composer takes the middle of the screen only while it is being typed
// into. The moment an ask is out it stands aside into a corner card, the
// surface gives up the keyboard, and the desktop comes back -- because for a
// site script the interesting thing is the *page* changing behind it, and for
// a question it is whatever else you were doing. The change of place is never
// seen: a curtain drops over the card that is leaving and lifts off the one
// arriving, which is the gesture this plugin is named after.
Item {
  id: root

  property bool active: false
  property string binPath: ""
  property string agentName: ""
  property string pageTitle: ""
  property string pageHost: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color accent: Color.menu.selectedText
  property color surface: Color.menu.selectedBackground
  property string fontFamily: Style.font.menuFamily

  // "ask" answers a question about the page; "site" writes a site script for it.
  property string mode: "ask"
  // idle | working | done | trouble
  property string phase: "idle"
  property string answerPath: ""
  property string statusPath: ""
  property string answerText: ""
  property string statusText: ""
  property string trouble: ""

  signal dismissed()       // back to the ring: only reachable while typing
  signal closeRequested()  // put the whole overlay away

  readonly property bool ready: root.agentName.length > 0
  // Anything but "waiting to be typed into" belongs in the corner.
  readonly property bool compact: root.phase !== "idle"
  // What still takes clicks once the overlay has gone click-through.
  readonly property Item hotItem: littleCard

  function reset() {
    root.phase = "idle"
    root.answerPath = ""
    root.statusPath = ""
    root.answerText = ""
    root.statusText = ""
    root.trouble = ""
    input.text = ""
  }

  function send() {
    var wanted = input.text.trim()
    if (wanted.length === 0 || !root.ready) return
    root.answerText = ""
    root.trouble = ""
    root.statusText = "waking your agent"
    root.phase = "working"
    var args = [root.binPath, "ask"]
    if (root.mode === "site") args.push("--site")
    args.push(wanted)
    asker.running = false
    asker.command = args
    asker.running = true
  }

  function watchAgent() {
    raiser.running = false
    raiser.running = true
  }

  // An answer arrives as a file, wrapped at whatever width the agent felt like.
  // The card has its own width, so single newlines are joined and only blank
  // lines -- real paragraph breaks -- are kept.
  function reflow(text) {
    return String(text || "")
      .replace(/\r/g, "")
      .replace(/([^\n])\n(?!\n)/g, "$1 ")
      .trim()
  }

  function blend(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t,
                   a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, 1)
  }

  focus: root.active && !root.compact
  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Escape) {
      root.dismissed()
      event.accepted = true
    }
  }

  onActiveChanged: {
    if (root.active) {
      agentProbe.running = true
      // The panel outlives nothing: the agent works in its own terminal and
      // writes files. So opening it picks up whatever was already asked --
      // after a stray click, after the ring, after a shell restart -- rather
      // than pretending nothing was.
      if (root.phase === "idle" && root.answerText.length === 0) {
        lastProbe.running = false
        lastProbe.running = true
      }
      if (!root.compact) Qt.callLater(function () { input.forceActiveFocus() })
    }
  }

  // -------------------------------------------------------------- the curtain
  //
  // Panels hung from the top of a card, dropped over it and lifted off again.
  // The middle ones lead, so it gathers the way a doorway curtain does, and the
  // cloth is shaded down its length with the cut edges catching light -- the
  // same recipe as a closing window, so the two read as one idea.
  component Curtain: Item {
    id: veil
    property real cover: 0
    property color cloth: "#000000"
    property color edge: "#ffffff"
    readonly property int panels: 5

    visible: veil.cover > 0.002
    clip: true

    Row {
      anchors.fill: parent
      spacing: 0

      Repeater {
        model: veil.panels

        delegate: Item {
          id: strip
          required property int index
          // How much of a head start this panel gets. Nearer the middle,
          // further along -- so the curtain gathers instead of falling as one
          // slab.
          readonly property real lead:
            (0.5 - Math.abs((index + 0.5) / veil.panels - 0.5)) * 0.45
          readonly property real t:
            Math.max(0, Math.min(1, (veil.cover - lead) / Math.max(0.05, 1 - lead)))

          width: veil.width / veil.panels
          height: veil.height

          Rectangle {
            width: parent.width
            height: parent.height
            y: -parent.height * (1 - strip.t)
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.lighter(veil.cloth, 1.3) }
              GradientStop { position: 0.6; color: veil.cloth }
              GradientStop { position: 1.0; color: Qt.darker(veil.cloth, 1.2) }
            }

            Rectangle {
              anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
              width: 1
              color: Qt.lighter(veil.edge, 1.6)
              opacity: 0.75
            }
            Rectangle {
              anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
              width: 1
              color: Qt.darker(veil.edge, 1.2)
              opacity: 0.75
            }
          }
        }
      }
    }
  }

  // The hand-off. Two sequences rather than one reversible animation: which
  // card pulls its curtain down first is the whole difference between them.
  property real littleLift: 0

  onCompactChanged: {
    toLittle.stop()
    toBig.stop()
    if (root.compact) toLittle.restart()
    else toBig.restart()
  }

  SequentialAnimation {
    id: toLittle
    PropertyAction { target: littleCard; property: "visible"; value: true }
    PropertyAction { target: littleVeil; property: "cover"; value: 1 }
    NumberAnimation {
      target: bigVeil; property: "cover"; from: 0; to: 1
      duration: 200; easing.type: Easing.OutQuad
    }
    PropertyAction { target: bigCard; property: "visible"; value: false }
    PauseAnimation { duration: 80 }
    ParallelAnimation {
      NumberAnimation {
        target: littleVeil; property: "cover"; to: 0
        duration: 360; easing.type: Easing.InOutQuad
      }
      NumberAnimation {
        target: root; property: "littleLift"; from: 16; to: 0
        duration: 360; easing.type: Easing.OutCubic
      }
    }
  }

  SequentialAnimation {
    id: toBig
    PropertyAction { target: bigCard; property: "visible"; value: true }
    PropertyAction { target: bigVeil; property: "cover"; value: 1 }
    NumberAnimation {
      target: littleVeil; property: "cover"; from: 0; to: 1
      duration: 200; easing.type: Easing.OutQuad
    }
    PropertyAction { target: littleCard; property: "visible"; value: false }
    PauseAnimation { duration: 80 }
    NumberAnimation {
      target: bigVeil; property: "cover"; to: 0
      duration: 360; easing.type: Easing.InOutQuad
    }
    ScriptAction { script: if (root.active) input.forceActiveFocus() }
  }

  // -------------------------------------------------------- the composer card

  Rectangle {
    id: bigCard
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(80), Style.space(620))
    height: column.implicitHeight + Style.space(44)
    radius: Style.space(14)
    color: root.background
    border.width: Math.max(1, Style.space(1))
    border.color: root.borderColor

    Column {
      id: column
      anchors { fill: parent; margins: Style.space(22) }
      spacing: Style.space(14)

      // --- who is answering, and what about
      Row {
        width: parent.width
        spacing: Style.space(14)

        NorenMark {
          id: mark
          anchors.verticalCenter: parent.verticalCenter
          accent: root.accent
          rod: root.borderColor
          mood: "idle"
        }

        Column {
          width: parent.width - mark.width - Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(3)

          Text {
            text: "Noren"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            text: !root.ready
              ? "No agent set — run: omarchy default agent"
              : (root.pageHost.length > 0
                 ? "via " + root.agentName + "  ·  about " + root.pageHost
                 : "via " + root.agentName + "  ·  no page in front of you")
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // --- what it should do
      Row {
        spacing: Style.space(6)

        Repeater {
          model: [
            { key: "ask", label: "Ask about this page" },
            { key: "site", label: "Write a site script" }
          ]

          delegate: Rectangle {
            required property var modelData
            readonly property bool on: root.mode === modelData.key
            height: Style.space(30)
            width: label.implicitWidth + Style.space(22)
            radius: Style.space(8)
            color: on ? root.surface : "transparent"
            border.width: Math.max(1, Style.space(1))
            border.color: on ? root.accent : root.borderColor

            Text {
              id: label
              anchors.centerIn: parent
              text: modelData.label
              color: on ? root.accent : root.foreground
              opacity: on ? 1 : 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.mode = modelData.key
                input.forceActiveFocus()
              }
            }
          }
        }
      }

      // --- the composer
      Rectangle {
        width: parent.width
        height: Style.space(46)
        radius: Style.space(10)
        color: root.surface
        border.width: Math.max(1, Style.space(1))
        border.color: input.activeFocus ? root.accent : root.borderColor

        TextInput {
          id: input
          anchors { fill: parent; leftMargin: Style.space(14); rightMargin: Style.space(14) }
          verticalAlignment: TextInput.AlignVCenter
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          selectByMouse: true
          enabled: root.ready && !root.compact
          onAccepted: root.send()

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.length === 0
            text: root.mode === "site"
              ? "What should this site do differently?"
              : "What do you want to know about this page?"
            color: root.foreground
            opacity: 0.4
            font: input.font
          }
        }
      }

      Text {
        width: parent.width
        text: "↵ send  ·  Esc close"
        color: root.foreground
        opacity: 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Curtain {
      id: bigVeil
      anchors.fill: parent
      cloth: root.surface
      edge: root.accent
    }
  }

  // ----------------------------------------------------------- the corner card

  Rectangle {
    id: littleCard
    visible: false
    anchors {
      right: parent.right
      bottom: parent.bottom
      rightMargin: Style.space(28)
      bottomMargin: Style.space(28)
    }
    width: Math.min(parent.width - Style.space(60),
                    root.phase === "working" ? Style.space(400) : Style.space(470))
    height: little.implicitHeight + Style.space(32)
    radius: Style.space(14)
    color: root.background
    border.width: Math.max(1, Style.space(1))
    // A slow breath along the border while the agent is out, so the card is
    // alive without anything spinning.
    border.color: root.blend(root.borderColor, root.accent, 0.8 * root.glow)

    transform: Translate { y: root.littleLift }

    // Growing into the answer, rather than a second card appearing with it.
    Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
    Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

    Column {
      id: little
      anchors { fill: parent; margins: Style.space(16) }
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(12)

        NorenMark {
          id: littleMark
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(40)
          height: Style.space(30)
          accent: root.accent
          rod: root.borderColor
          mood: root.phase === "working" ? "working"
            : (root.phase === "done" ? "done" : "idle")
        }

        Column {
          width: parent.width - littleMark.width - shut.width - Style.space(24)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: root.phase === "working" ? "Asking " + root.agentName
              : root.phase === "done" ? "Answered"
              : "That did not work"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // The agent's own narration. Each new line rises into place, which is
          // the difference between progress and a label that changes.
          Text {
            id: statusLine
            width: parent.width
            text: root.phase === "working"
              ? (root.statusText.length > 0 ? root.statusText : "working…")
              : (root.pageHost.length > 0 ? "about " + root.pageHost : "")
            color: root.accent
            opacity: 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            transform: Translate { id: rise; y: 0 }
            onTextChanged: if (root.phase === "working") riseIn.restart()
          }

          ParallelAnimation {
            id: riseIn
            NumberAnimation {
              target: rise; property: "y"; from: 8; to: 0
              duration: 260; easing.type: Easing.OutCubic
            }
            NumberAnimation {
              target: statusLine; property: "opacity"; from: 0; to: 0.85
              duration: 260
            }
          }
        }

        // The only way out while the overlay is click-through: there is no
        // keyboard here to press Escape with.
        Text {
          id: shut
          anchors.verticalCenter: parent.verticalCenter
          text: "✕"
          color: root.foreground
          opacity: shutArea.containsMouse ? 0.9 : 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            id: shutArea
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.closeRequested()
          }
        }
      }

      // --- what came back
      Rectangle {
        width: parent.width
        visible: root.answerText.length > 0 || root.trouble.length > 0
        height: visible ? Math.min(Style.space(220), answer.implicitHeight + Style.space(22)) : 0
        radius: Style.space(10)
        color: "transparent"
        border.width: Math.max(1, Style.space(1))
        border.color: root.borderColor

        Flickable {
          anchors { fill: parent; margins: Style.space(11) }
          contentHeight: answer.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Text {
            id: answer
            width: parent.width
            text: root.trouble.length > 0 ? root.trouble : root.answerText
            color: root.trouble.length > 0 ? root.accent : root.foreground
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // --- the two ways on from here
      Row {
        width: parent.width
        spacing: Style.space(14)

        Text {
          id: watch
          text: "watch it work →"
          color: root.accent
          opacity: watchArea.containsMouse ? 1 : 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            id: watchArea
            anchors.fill: parent
            anchors.margins: -Style.space(5)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.watchAgent()
          }
        }

        // An agent can be denied, shut down, or simply told no, and none of
        // that reaches the file this card is waiting on. Waiting must never be
        // a dead end.
        Text {
          id: over
          text: "start over"
          color: root.foreground
          opacity: overArea.containsMouse ? 0.9 : 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            id: overArea
            anchors.fill: parent
            anchors.margins: -Style.space(5)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              answerWatch.stop()
              root.reset()
            }
          }
        }
      }
    }

    Curtain {
      id: littleVeil
      anchors.fill: parent
      cover: 1
      cloth: root.surface
      edge: root.accent
    }
  }

  // ------------------------------------------------------------------ plumbing

  // The border's breath while an ask is out.
  property real glow: 0
  SequentialAnimation on glow {
    running: root.phase === "working"
    loops: Animation.Infinite
    NumberAnimation { from: 0; to: 1; duration: 1500; easing.type: Easing.InOutSine }
    NumberAnimation { from: 1; to: 0; duration: 1500; easing.type: Easing.InOutSine }
  }

  // Which agent Omarchy is set to. Asked each time the panel opens rather than
  // cached: it is one process, and a stale answer here means offering to use an
  // agent the user has since changed.
  Process {
    id: agentProbe
    command: [root.binPath, "agent"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.agentName = JSON.parse(this.text).agent || ""
        } catch (e) {
          root.agentName = ""
        }
      }
    }
  }

  // `watch it work →`: the agent's own terminal, in front. It waits a moment
  // for one to appear, since the click usually comes seconds after the ask.
  Process {
    id: raiser
    command: [root.binPath, "agent", "raise"]
    running: false
  }

  Process {
    id: asker
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var res = JSON.parse(this.text)
          root.answerPath = res.answer || ""
          root.statusPath = res.status || ""
          if (root.answerPath.length > 0) answerWatch.start()
          else root.phase = "trouble"
        } catch (e) {
          root.phase = "trouble"
          root.trouble = "Noren could not start the agent."
        }
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var said = String(this.text || "").trim()
        if (said.length > 0) {
          root.phase = "trouble"
          root.trouble = said
        }
      }
    }
  }

  // Two files: one the agent overwrites as it goes, one it writes at the end.
  // Polled rather than watched, because neither exists yet and there is nothing
  // to put a watch on until it does.
  Timer {
    id: answerWatch
    interval: 700
    repeat: true
    running: false
    onTriggered: {
      if (root.statusPath.length > 0) {
        statusFile.path = root.statusPath
        statusFile.reload()
      }
      if (root.answerPath.length === 0) {
        stop()
        return
      }
      answerFile.path = root.answerPath
      answerFile.reload()
    }
  }

  FileView {
    id: statusFile
    printErrors: false
    onLoaded: {
      // The last line rather than the file: the prompt says overwrite, but an
      // agent that appends instead should still read as progress, not a log.
      var lines = String(statusFile.text() || "").split("\n")
      for (var i = lines.length - 1; i >= 0; i--) {
        var line = lines[i].trim()
        if (line.length > 0) {
          root.statusText = line.substring(0, 120)
          return
        }
      }
    }
  }

  FileView {
    id: answerFile
    printErrors: false
    onLoaded: {
      var said = String(answerFile.text() || "").trim()
      if (said.length === 0) return
      answerWatch.stop()
      root.answerText = root.reflow(said)
      root.phase = "done"
      // Card put away, agent finished: without this the answer sits somewhere
      // nobody knows to look. Omarchy's own OSD, so it arrives the way
      // everything else on this desktop does.
      if (!root.active) {
        var about = root.pageHost.length > 0 ? root.pageHost : "your page"
        notify.running = false
        notify.command = [
          "omarchy-shell", "-q", "osd", "show",
          JSON.stringify({
            icon: "󰧑",
            message: "Noren answered about " + about,
            duration: 4000
          })
        ]
        notify.running = true
      }
    }
  }

  // The last ask, and its answer if it has landed. One process, on open.
  Process {
    id: lastProbe
    command: [root.binPath, "ask", "--last"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var res = null
        try {
          res = JSON.parse(this.text)
        } catch (e) {
          return
        }
        if (!res || res.empty) return
        // An ask that is still out is worth picking up for as long as an agent
        // might plausibly still be on it. An ask that already came back is
        // worth re-showing only for a few minutes -- after that, opening the
        // composer should give you a composer, not this morning's answer.
        var age = res.started ? (Date.now() / 1000 - res.started) : 1e9
        if (age > (res.done ? 900 : 3600)) return
        root.mode = res.mode === "site" ? "site" : "ask"
        if (res.question) input.text = res.question
        root.statusPath = res.status || ""
        root.statusText = res.statusText || ""
        if (res.done && res.answerText) {
          root.answerText = root.reflow(res.answerText)
          root.phase = "done"
        } else if (res.answer) {
          // Still out there. Watch the same files the agent was told to write.
          root.answerPath = res.answer
          root.phase = "working"
          answerWatch.start()
        }
      }
    }
  }

  Process {
    id: notify
    running: false
  }
}

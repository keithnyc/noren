import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons

// Steal this theme: the colours of the page in front of you, as an Omarchy
// theme you can adjust before you keep it.
//
// All the colour thinking stays in Python (host/noren_steal.py) -- contrast
// solving, clustering, the hue slots. This card only holds your choices and
// asks `noren steal --cached --json` again whenever one changes. The page is
// read once, when the card opens; after that nothing here touches the browser.
//
// The preview is drawn here, so it follows every change at once. Applying the
// real theme is slow on slow machines, so that only happens on "Try it".
// Put back undoes a try and stays open; Cancel puts back the theme you had when
// the card opened and closes; Keep leaves the new one in place.
Item {
  id: root

  property bool active: false
  property string binPath: ""

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color accent: Color.menu.selectedText
  property color surface: Color.menu.selectedBackground
  property string fontFamily: Style.font.menuFamily

  signal closeRequested()

  // reading | ready | applying | putting | trouble
  property string phase: "reading"
  property string trouble: ""
  property var result: null
  readonly property var theme: root.result ? root.result.theme : null

  // Your choices. Everything shown is rebuilt from these.
  property string mode: ""          // "" = whatever the page is
  property real vividness: 1.0
  property var overrides: ({})
  property string role: "accent"
  property string startTheme: ""
  // What was last applied for real, so Keep need not apply it twice and Cancel
  // knows whether there is anything to put back.
  property string triedKey: ""
  property bool closeAfterApply: false
  // Held down (the Peek button, or Space): the card steps aside and the chosen
  // wallpaper fills the screen at full size -- no Try it needed to judge it.
  property bool peeking: false
  // Wallpapers on offer: yours and the page's (files, found after the colours),
  // then three made from the theme. `wall` is what --wallpaper gets.
  property var walls: []
  property bool findingWalls: false
  property string wall: "current"
  readonly property var wallChoices: root.walls.concat([
    { kind: "glow" }, { kind: "dusk" }, { kind: "solid" }
  ])
  readonly property var currentWall: {
    for (var i = 0; i < root.wallChoices.length; i++) {
      var w = root.wallChoices[i]
      if ((w.path || w.kind) === root.wall) return w
    }
    return { kind: "solid" }
  }

  function t(key, fallback) {
    return root.theme && root.theme[key] ? root.theme[key] : (fallback || "#808080")
  }

  function options() {
    var out = []
    if (root.mode.length > 0) out.push("--mode", root.mode)
    if (Math.abs(root.vividness - 1) > 0.01) out.push("--vivid", root.vividness.toFixed(2))
    for (var k in root.overrides) out.push("--set", k + "=" + root.overrides[k])
    var name = nameInput.text.trim()
    if (name.length > 0) out.push("--name", name)
    out.push("--wallpaper", root.wall)
    return out
  }

  function reset() {
    root.phase = "reading"
    root.trouble = ""
    root.result = null
    root.mode = ""
    root.vividness = 1.0
    root.overrides = ({})
    root.role = "accent"
    root.startTheme = ""
    root.triedKey = ""
    root.closeAfterApply = false
    root.walls = []
    root.wall = "current"
    root.findingWalls = false
    root.peeking = false
    nameInput.text = ""
    enter.restart()
    reader.running = false
    reader.running = true
  }

  function rebuild() { rebuildTimer.restart() }

  function setRole(hex) {
    var next = Object.assign({}, root.overrides)
    next[root.role] = String(hex)
    root.overrides = next
    root.rebuild()
  }

  function clearRole() {
    var next = Object.assign({}, root.overrides)
    delete next[root.role]
    root.overrides = next
    root.rebuild()
  }

  // Qt's lighter/darker work in HSV, which is rough, but the host makes the
  // result readable again anyway; this only has to move in the right direction.
  function nudge(lighter) {
    var now = Qt.color(root.t(root.role))
    var moved = lighter ? Qt.lighter(now, 1.12) : Qt.darker(now, 1.12)
    root.setRole(moved.toString().slice(0, 7))
  }

  function apply(thenClose) {
    if (!root.theme || root.phase === "applying" || root.phase === "putting") return
    var key = JSON.stringify(root.options())
    if (key === root.triedKey) {
      if (thenClose) root.closeRequested()
      return
    }
    root.closeAfterApply = thenClose
    root.phase = "applying"
    applier.command = [root.binPath, "steal", "--cached"].concat(root.options())
    applier.running = false
    applier.running = true
  }

  // Undo a try without leaving: back to the theme the card opened on.
  function putBack() {
    if (root.triedKey.length === 0 || root.startTheme.length === 0 || root.phase === "applying") return
    root.phase = "putting"
    putter.command = ["omarchy-theme-set", root.startTheme]
    putter.running = false
    putter.running = true
  }

  function fade(c, alpha) {
    c = Qt.color(c)
    return Qt.rgba(c.r, c.g, c.b, alpha)
  }

  function blend(a, b, t) {
    a = Qt.color(a); b = Qt.color(b)
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }

  function cancel() {
    // Only if something was tried: otherwise the theme never changed.
    if (root.triedKey.length > 0 && root.startTheme.length > 0) {
      Quickshell.execDetached(["omarchy-theme-set", root.startTheme])
    }
    root.closeRequested()
  }

  focus: root.active
  Keys.onPressed: function (event) {
    if (event.key === Qt.Key_Escape) {
      root.cancel()
      event.accepted = true
    } else if (event.key === Qt.Key_Space && root.theme) {
      if (!event.isAutoRepeat) root.peeking = true
      event.accepted = true
    }
  }
  Keys.onReleased: function (event) {
    if (event.key === Qt.Key_Space && !event.isAutoRepeat) {
      root.peeking = false
      event.accepted = true
    }
  }

  onActiveChanged: if (root.active) root.reset()

  Timer {
    id: rebuildTimer
    interval: 60
    repeat: false
    onTriggered: {
      builder.command = [root.binPath, "steal", "--cached", "--json"].concat(root.options())
      builder.running = false
      builder.running = true
    }
  }

  Process {
    id: reader
    command: [root.binPath, "steal", "--json"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.result = JSON.parse(this.text)
          root.startTheme = root.result.current || ""
          nameInput.text = root.result.name || ""
          root.phase = "ready"
          root.findingWalls = true
          wallFinder.running = false
          wallFinder.running = true
        } catch (e) {
          root.phase = "trouble"
          root.trouble = "Couldn't read the page in front of you."
        }
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var said = this.text.trim().replace(/^noren steal: /, "")
        if (said.length > 0) root.trouble = said.charAt(0).toUpperCase() + said.slice(1)
      }
    }
  }

  Process {
    id: wallFinder
    command: [root.binPath, "steal", "--cached", "--wallpapers"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.walls = JSON.parse(this.text)
          var mine = root.walls.filter(function (w) { return w.kind === "current" })
          if (mine.length > 0) root.wall = mine[0].path
        } catch (e) {
          root.walls = []
        }
        root.findingWalls = false
      }
    }
  }

  Process {
    id: putter
    running: false
    onExited: function (code) {
      root.triedKey = ""
      root.phase = "ready"
    }
  }

  Process {
    id: builder
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var next = JSON.parse(this.text)
          root.result = next
        } catch (e) {
          // Keep showing the last good theme; the next change will try again.
        }
      }
    }
  }

  Process {
    id: applier
    running: false
    onExited: function (code) {
      if (code === 0) {
        root.triedKey = JSON.stringify(root.options())
        root.phase = "ready"
        landed.restart()
        if (root.closeAfterApply) root.closeRequested()
      } else {
        root.phase = "trouble"
        if (root.trouble.length === 0) root.trouble = "Omarchy couldn't switch to it."
      }
      root.closeAfterApply = false
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var said = this.text.trim().replace(/^noren steal: /, "")
        if (said.length > 0) root.trouble = said
      }
    }
  }

  // ------------------------------------------------------------------ pieces

  component Chip: Rectangle {
    id: chip
    property string label: ""
    property bool on: false
    signal pressed()
    signal held(bool down)
    height: Style.space(28)
    width: chipLabel.implicitWidth + Style.space(20)
    radius: Style.space(8)
    color: chip.on ? root.surface
      : chipMouse.containsMouse ? root.fade(root.surface, 0.6) : "transparent"
    border.width: Math.max(1, Style.space(1))
    border.color: chip.on || chipMouse.containsMouse ? root.accent : root.borderColor
    scale: chipMouse.pressed ? 0.93 : (chipMouse.containsMouse ? 1.04 : 1)
    Behavior on scale { SpringAnimation { spring: 5; damping: 0.28 } }
    Behavior on color { ColorAnimation { duration: 140 } }
    Behavior on border.color { ColorAnimation { duration: 140 } }

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label
      color: chip.on ? root.accent : root.foreground
      opacity: chip.on ? 1 : 0.75
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.pressed()
      onPressedChanged: chip.held(pressed)
    }
  }

  // A wallpaper, drawn: a file as a picture, a gradient the way
  // noren_steal.wallpaper() paints it. Used for the thumbnails and the preview.
  component WallArt: Item {
    id: art
    property var choice: ({ kind: "solid" })
    // Decode width for pictures; 0 is full size, for the peek.
    property int detail: 640
    clip: true

    Rectangle {
      anchors.fill: parent
      visible: !art.choice.path
      color: root.t("background")
      gradient: art.choice.kind === "dusk" ? duskGradient : null
      Gradient {
        id: duskGradient
        GradientStop { position: 0; color: root.t("darker_background") }
        GradientStop { position: 1; color: root.blend(root.t("background"), root.t("accent"), 0.3) }
      }
    }

    Shape {
      anchors.fill: parent
      visible: art.choice.kind === "glow"
      ShapePath {
        strokeWidth: -1
        fillGradient: RadialGradient {
          centerX: art.width * 0.28; centerY: art.height * 0.78
          focalX: centerX; focalY: centerY
          centerRadius: art.width * 0.85
          // 0.42 * exp(-(d / 0.45)^2), sampled.
          GradientStop { position: 0.0; color: root.fade(root.t("accent"), 0.42) }
          GradientStop { position: 0.2; color: root.fade(root.t("accent"), 0.345) }
          GradientStop { position: 0.4; color: root.fade(root.t("accent"), 0.19) }
          GradientStop { position: 0.6; color: root.fade(root.t("accent"), 0.07) }
          GradientStop { position: 0.8; color: root.fade(root.t("accent"), 0.018) }
          GradientStop { position: 1.0; color: root.fade(root.t("accent"), 0) }
        }
        PathLine { x: art.width; y: 0 }
        PathLine { x: art.width; y: art.height }
        PathLine { x: 0; y: art.height }
        PathLine { x: 0; y: 0 }
      }
    }

    Image {
      anchors.fill: parent
      visible: !!art.choice.path && !art.choice.video
      source: art.choice.path && !art.choice.video ? "file://" + art.choice.path : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: art.detail
    }

    Text {
      anchors.centerIn: parent
      visible: !!art.choice.video
      text: "video"
      color: root.t("foreground")
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component Caption: Text {
    color: root.foreground
    opacity: 0.55
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // A line of terminal text in the stolen colours: [[text, role], ...].
  component Line: Row {
    property var parts: []
    Repeater {
      model: parent.parts
      delegate: Text {
        required property var modelData
        text: modelData[0]
        color: root.t(modelData[1])
        Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
        font.family: "monospace"
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ------------------------------------------------------------------- peek
  //
  // The wallpaper you have chosen, at full size, in the theme's colours. It
  // blooms in -- a little large, settling -- while the card drops away, and the
  // card springs back when you let go.

  WallArt {
    id: peekArt
    anchors.fill: parent
    detail: 0
    choice: root.currentWall
    opacity: root.peeking ? 1 : 0
    scale: root.peeking ? 1 : 1.08
    visible: opacity > 0.001
    Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 620; easing.type: Easing.OutQuint } }
  }

  Rectangle {
    id: peekHint
    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: Style.space(48) }
    width: peekText.implicitWidth + Style.space(28)
    height: Style.space(34)
    radius: height / 2
    color: root.fade(root.background, 0.85)
    border.width: Math.max(1, Style.space(1))
    border.color: root.fade(root.accent, 0.6)
    opacity: root.peeking ? 1 : 0
    visible: opacity > 0.001
    transform: Translate { y: root.peeking ? 0 : Style.space(18); Behavior on y { NumberAnimation { duration: 360; easing.type: Easing.OutBack } } }
    Behavior on opacity { NumberAnimation { duration: 220 } }
    Text {
      id: peekText
      anchors.centerIn: parent
      text: "Peeking at " + (root.currentWall.kind === "current" ? "your wallpaper"
        : root.currentWall.kind === "page" ? "the page's picture" : root.currentWall.kind)
        + "  ·  let go to come back"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ------------------------------------------------------------------- card

  // In: a small rise and settle. Also replayed by reset(), so each opening
  // feels like one.
  ParallelAnimation {
    id: enter
    NumberAnimation { target: card; property: "enterScale"; from: 0.94; to: 1; duration: 420; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
    NumberAnimation { target: card; property: "enterOpacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
    NumberAnimation { target: card; property: "enterLift"; from: Style.space(24); to: 0; duration: 420; easing.type: Easing.OutCubic }
  }

  // A tried theme landing: the preview gives a little nod.
  SequentialAnimation {
    id: landed
    NumberAnimation { target: preview; property: "scale"; to: 1.025; duration: 120; easing.type: Easing.OutCubic }
    NumberAnimation { target: preview; property: "scale"; to: 1; duration: 520; easing.type: Easing.OutElastic; easing.amplitude: 1.2; easing.period: 0.45 }
  }

  Rectangle {
    id: card
    property real enterScale: 1
    property real enterOpacity: 1
    property real enterLift: 0
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(60), Style.space(640))
    height: column.implicitHeight + Style.space(44)
    radius: Style.space(14)
    color: root.background
    border.width: Math.max(1, Style.space(1))
    border.color: root.borderColor
    Behavior on color { ColorAnimation { duration: 400 } }
    Behavior on border.color { ColorAnimation { duration: 400 } }

    // Peeking: shrink, sink and fade; coming back springs.
    property real peekScale: root.peeking ? 0.9 : 1
    property real peekOpacity: root.peeking ? 0 : 1
    property real peekDrop: root.peeking ? Style.space(60) : 0
    Behavior on peekScale { SpringAnimation { spring: root.peeking ? 6 : 3.2; damping: root.peeking ? 0.6 : 0.24 } }
    Behavior on peekOpacity { NumberAnimation { duration: root.peeking ? 180 : 260; easing.type: Easing.OutCubic } }
    Behavior on peekDrop { SpringAnimation { spring: root.peeking ? 6 : 3.2; damping: root.peeking ? 0.6 : 0.3 } }

    scale: card.enterScale * card.peekScale
    opacity: card.enterOpacity * card.peekOpacity
    transform: Translate { y: card.enterLift + card.peekDrop }

    // Clicks on the card are the card's, not the scrim's -- and they take the
    // keyboard back from the name box, so Space peeks again.
    MouseArea { anchors.fill: parent; onPressed: root.forceActiveFocus() }

    Column {
      id: column
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(22) }
      spacing: Style.space(14)

      Column {
        width: parent.width
        spacing: Style.space(3)
        Text {
          text: "Steal this theme"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Caption {
          width: parent.width
          elide: Text.ElideRight
          text: root.phase === "reading" ? "Reading the page…"
            : root.phase === "trouble" ? root.trouble
            : root.phase === "applying" ? "Switching Omarchy to it…"
            : root.phase === "putting" ? "Putting back " + root.startTheme + "…"
            : "From " + (root.result ? root.result.host : "") + "  ·  EXPERIMENTAL"
        }
      }

      // --- the preview: a window with a bar and a terminal in it
      //
      // `clip` alone clips to the square box, so the wallpaper and the bar
      // used to poke out past the rounded corners and over the border. The
      // mask rounds them; clip stays for the wallpaper's bloom, which starts
      // zoomed in; and the border is drawn last, over everything.
      Rectangle {
        id: previewMask
        visible: false
        width: preview.width
        height: preview.height
        radius: preview.radius
        layer.enabled: true
      }

      Rectangle {
        id: preview
        visible: root.theme !== null
        width: parent.width
        height: Style.space(230)
        radius: Style.space(10)
        color: root.t("background")
        clip: true
        layer.enabled: true
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: previewMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1.0
        }
        Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }

        WallArt {
          id: previewArt
          anchors { fill: parent; margins: Math.max(1, Style.space(1)) }
          choice: root.currentWall
          // A new wallpaper blooms in rather than snapping.
          onChoiceChanged: bloom.restart()
          ParallelAnimation {
            id: bloom
            NumberAnimation { target: previewArt; property: "opacity"; from: 0.2; to: 1; duration: 380; easing.type: Easing.OutCubic }
            NumberAnimation { target: previewArt; property: "scale"; from: 1.12; to: 1; duration: 560; easing.type: Easing.OutQuint }
          }
        }

        Rectangle {
          id: bar
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: Math.max(1, Style.space(1)) }
          height: Style.space(24)
          color: root.t("background")
          Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }

          Row {
            anchors { left: parent.left; leftMargin: Style.space(10); verticalCenter: parent.verticalCenter }
            spacing: Style.space(10)
            Repeater {
              model: ["1", "2", "3", "4"]
              delegate: Text {
                required property var modelData
                required property int index
                text: modelData
                color: index === 1 ? root.t("accent") : root.t("dark_foreground")
                Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
          Text {
            anchors.centerIn: parent
            text: "Fri 21:07"
            color: root.t("foreground")
            Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Row {
            anchors { right: parent.right; rightMargin: Style.space(10); verticalCenter: parent.verticalCenter }
            spacing: Style.space(6)
            Repeater {
              model: ["red", "yellow", "green", "cyan", "blue", "magenta"]
              delegate: Rectangle {
                required property var modelData
                width: Style.space(9); height: width; radius: width / 2
                color: root.t(modelData)
                Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
              }
            }
          }
        }

        Rectangle {
          id: term
          anchors { left: parent.left; right: parent.right; top: bar.bottom; bottom: parent.bottom
                    leftMargin: Style.space(18); rightMargin: Style.space(90)
                    topMargin: Style.space(12); bottomMargin: Style.space(14) }
          radius: Style.space(6)
          color: root.t("background")
          border.width: Math.max(2, Style.space(2))
          border.color: root.t("accent")
          Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
          Behavior on border.color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
        }

        Column {
          anchors { left: term.left; right: term.right; top: term.top; margins: Style.space(10) }
          spacing: Style.space(3)
          Line { parts: [["~/code ", "blue"], ["❯ ", "accent"], ["git status", "foreground"]] }
          Line { parts: [["  On branch ", "foreground"], ["main", "cyan"]] }
          Line { parts: [["  new file:  ", "green"], ["steal.py", "green"]] }
          Line { parts: [["  modified:  ", "red"], ["bar.js", "red"]] }
          Line { parts: [["~/code ", "blue"], ["❯ ", "accent"], ["ls", "foreground"]] }
          Line { parts: [["bin/  host/  ", "blue"], ["run.sh  ", "green"], ["notes.md  ", "foreground"], ["build.log", "dark_foreground"]] }
          Row {
            spacing: 0
            Text {
              text: "# a comment, and "
              color: root.t("dark_foreground")
              Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
              font.family: "monospace"
              font.pixelSize: Style.font.caption
            }
            Rectangle {
              width: selected.implicitWidth + Style.space(4)
              height: selected.implicitHeight
              color: root.t("selection")
              Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
              Text {
                id: selected
                anchors.centerIn: parent
                text: "a selection"
                color: root.t("foreground")
                Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
                font.family: "monospace"
                font.pixelSize: Style.font.caption
              }
            }
          }
          Line { parts: [["warning: ", "yellow"], ["disk 91%  ", "foreground"], ["error: ", "red"], ["timeout  ", "foreground"], ["→ ", "magenta"], ["retry", "orange"]] }
        }

        Rectangle {
          anchors.fill: parent
          z: 10
          radius: preview.radius
          color: "transparent"
          border.width: Math.max(1, Style.space(1))
          border.color: root.borderColor
        }

        // While Omarchy switches: a band of light runs across, over and over.
        Rectangle {
          id: sweep
          readonly property bool busy: root.phase === "applying" || root.phase === "putting"
          y: 0
          width: parent.width * 0.35
          height: parent.height
          visible: sweep.busy
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: root.fade(root.t("accent"), 0) }
            GradientStop { position: 0.5; color: root.fade(root.t("accent"), 0.28) }
            GradientStop { position: 1; color: root.fade(root.t("accent"), 0) }
          }
          NumberAnimation on x {
            running: sweep.busy
            loops: Animation.Infinite
            from: -sweep.width; to: preview.width
            duration: 900
            easing.type: Easing.InOutSine
          }
        }
      }

      // --- which colour you are changing
      Column {
        visible: root.theme !== null
        width: parent.width
        spacing: Style.space(8)
        Caption { text: "Click a colour to change it, then pick from the page or nudge it" }
        Flow {
          width: parent.width
          spacing: Style.space(8)
          Repeater {
            model: root.result ? root.result.editable : []
            delegate: Column {
              required property var modelData
              spacing: Style.space(3)
              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(28); height: width; radius: width / 2
                color: root.t(modelData)
                border.width: root.role === modelData ? Math.max(2, Style.space(3)) : Math.max(1, Style.space(1))
                border.color: root.role === modelData ? root.foreground : root.borderColor
                scale: root.role === modelData ? 1.18 : (swatchMouse.containsMouse ? 1.08 : 1)
                Behavior on scale { SpringAnimation { spring: 4.5; damping: 0.22 } }
                Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
                Text {
                  anchors.centerIn: parent
                  visible: root.overrides[modelData] !== undefined
                  text: "•"
                  color: root.t("background")
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  id: swatchMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.role = modelData
                }
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData === "background" ? "bg" : modelData === "foreground" ? "text" : modelData
                color: root.foreground
                opacity: root.role === modelData ? 1 : 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption - 1
              }
            }
          }
        }

        Row {
          spacing: Style.space(6)
          Caption { anchors.verticalCenter: parent.verticalCenter; text: "From the page" }
          Repeater {
            model: root.result ? root.result.pageColours : []
            delegate: Rectangle {
              required property var modelData
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(20); height: width; radius: Style.space(5)
              color: modelData
              border.width: Math.max(1, Style.space(1))
              border.color: pageMouse.containsMouse ? root.foreground : root.borderColor
              scale: pageMouse.pressed ? 0.85 : (pageMouse.containsMouse ? 1.28 : 1)
              z: pageMouse.containsMouse ? 1 : 0
              Behavior on scale { SpringAnimation { spring: 5; damping: 0.25 } }
              MouseArea {
                id: pageMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setRole(modelData)
              }
            }
          }
        }

        Row {
          spacing: Style.space(6)
          Chip { label: "Darker"; onPressed: root.nudge(false) }
          Chip { label: "Lighter"; onPressed: root.nudge(true) }
          Chip {
            label: "Reset " + (root.role === "background" ? "bg" : root.role === "foreground" ? "text" : root.role)
            visible: root.overrides[root.role] !== undefined
            onPressed: root.clearRole()
          }
        }
      }

      // --- wallpaper
      Column {
        visible: root.theme !== null
        width: parent.width
        spacing: Style.space(6)
        Row {
          spacing: Style.space(10)
          Caption {
            anchors.verticalCenter: parent.verticalCenter
            text: root.findingWalls ? "Wallpaper  ·  looking for pictures on the page…" : "Wallpaper"
          }
          Chip {
            anchors.verticalCenter: parent.verticalCenter
            label: "Hold to peek  (or Space)"
            on: root.peeking
            onHeld: function (down) { root.peeking = down }
          }
        }
        Flow {
          width: parent.width
          spacing: Style.space(8)
          Repeater {
            model: root.wallChoices
            delegate: Column {
              required property var modelData
              readonly property string value: modelData.path || modelData.kind
              spacing: Style.space(3)
              Rectangle {
                width: Style.space(76); height: Style.space(44)
                radius: Style.space(6)
                color: "transparent"
                border.width: root.wall === value ? Math.max(2, Style.space(3)) : Math.max(1, Style.space(1))
                border.color: root.wall === value ? root.foreground : (thumbMouse.containsMouse ? root.accent : root.borderColor)
                scale: thumbMouse.pressed ? 0.92 : (root.wall === value ? 1.08 : (thumbMouse.containsMouse ? 1.05 : 1))
                z: root.wall === value || thumbMouse.containsMouse ? 1 : 0
                Behavior on scale { SpringAnimation { spring: 4.5; damping: 0.24 } }
                Behavior on border.color { ColorAnimation { duration: 140 } }
                WallArt {
                  anchors { fill: parent; margins: Math.max(2, Style.space(3)) }
                  choice: modelData
                }
                MouseArea {
                  id: thumbMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.wall = value
                }
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: modelData.kind === "current" ? "yours" : modelData.kind === "page" ? "from page" : modelData.kind
                color: root.foreground
                opacity: root.wall === value ? 1 : 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption - 1
              }
            }
          }
        }
      }

      // --- mode and vividness
      Row {
        visible: root.theme !== null
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: [{ key: "", label: "As the page" }, { key: "dark", label: "Dark" }, { key: "light", label: "Light" }]
          delegate: Chip {
            required property var modelData
            label: modelData.label
            on: root.mode === modelData.key
            onPressed: { root.mode = modelData.key; root.rebuild() }
          }
        }

        Item { width: Style.space(10); height: 1 }

        Caption { anchors.verticalCenter: parent.verticalCenter; text: "Vividness" }

        Item {
          id: slider
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(150)
          height: Style.space(28)
          readonly property real frac: root.vividness / 2

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width; height: Style.space(4); radius: height / 2
            color: root.borderColor
          }
          Rectangle {
            width: slider.frac * slider.width
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(4); radius: height / 2
            color: root.fade(root.accent, 0.55)
          }
          Rectangle {
            x: slider.frac * (slider.width - width)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(14); height: width; radius: width / 2
            color: root.accent
            scale: sliderMouse.pressed ? 1.45 : (sliderMouse.containsMouse ? 1.15 : 1)
            Behavior on scale { SpringAnimation { spring: 5; damping: 0.25 } }
            Behavior on x { enabled: !sliderMouse.pressed; NumberAnimation { duration: 380; easing.type: Easing.OutBack } }
          }
          MouseArea {
            id: sliderMouse
            hoverEnabled: true
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            function set(mx) {
              root.vividness = Math.max(0, Math.min(2, 2 * mx / slider.width))
              root.rebuild()
            }
            onPressed: function (m) { set(m.x) }
            onPositionChanged: function (m) { if (pressed) set(m.x) }
            onDoubleClicked: { root.vividness = 1; root.rebuild() }
          }
        }
      }

      // --- name, and what to do with it
      Row {
        width: parent.width
        spacing: Style.space(8)

        Rectangle {
          width: parent.width - buttons.width - Style.space(8)
          height: Style.space(34)
          radius: Style.space(8)
          color: root.surface
          border.width: Math.max(1, Style.space(1))
          border.color: nameInput.activeFocus ? root.accent : root.borderColor

          TextInput {
            id: nameInput
            anchors { fill: parent; leftMargin: Style.space(10); rightMargin: Style.space(10) }
            verticalAlignment: TextInput.AlignVCenter
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            selectByMouse: true
            onAccepted: root.apply(false)
            Keys.onEscapePressed: root.cancel()
          }
        }

        Row {
          id: buttons
          spacing: Style.space(6)
          Chip {
            label: "Put back"
            visible: root.triedKey.length > 0 && root.startTheme.length > 0
            onPressed: root.putBack()
          }
          Chip { label: "Cancel"; onPressed: root.cancel() }
          Chip { label: "Try it"; onPressed: root.apply(false) }
          Chip { label: "Keep"; on: true; onPressed: root.apply(true) }
        }
      }

      Caption {
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Try it switches Omarchy for real · Put back undoes that and stays · Cancel or Esc puts back " +
          (root.startTheme.length > 0 ? root.startTheme : "your theme") + " and closes"
      }
    }
  }
}

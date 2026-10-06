import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland

// Party mode's bar: while a video plays in a Noren window, the bar is lit by it.
//
// Inside the bar, three stage lights -- soft pools of the video's colour and
// two neighbouring hues -- drift along it, faster and brighter as the music
// gets louder. On every beat a flare shoots from the middle of the bar out to
// both ends. Along the bar's inner edge runs a lit line, and below it an
// underglow falls onto the windows, the way light from a screen spills onto a
// wall; it pumps on the kick drum. Without sound (a silent video, or one the
// page cannot hear) the lights follow the picture instead, and hard cuts in the
// video stand in for beats.
//
// The pools are capped well short of opaque: they pass over the bar's clock and
// workspace list, which still have to be read.
//
// It is its own surface, on the overlay layer, one per bar: the bar's own
// window is only as tall as the bar and cannot draw below itself. It takes no
// input and reserves no space -- the pointer and the layout never know it is
// there. Horizontal bars only; a glow down the side of a vertical bar would be
// a different design, not this one turned.
PanelWindow {
  id: win

  property var service: null
  property string edge: "top"
  property int barSize: 0
  // The bar's own window. The shake moves the bar's contents (see below).
  property var barWindow: null

  readonly property bool horizontal: edge === "top" || edge === "bottom"
  readonly property bool fromTop: edge !== "bottom"
  readonly property bool lit: !!service && service.partyLit && horizontal && barSize > 0
  readonly property bool hearing: !!service && service.partyHearing
  readonly property int depth: 26   // the underglow's reach at full drive

  // One clock drives everything here, thirty steps a second: the fade in and
  // out, the drive, the beat's pulse and flare, the lights' drift. Separate
  // animations each redraw at the display's own rate, and with a beat every
  // half second something was always animating -- both monitors' overlays
  // repainting at full rate for as long as the music played.

  // How hard the lights are driven, 0-1: the music when it can be heard, the
  // picture's brightness when not.
  readonly property real target: !service ? 0
    : (hearing ? service.partyEnergy : 0.35 + 0.4 * service.partyLevel)

  property real on: 0       // the lights up (1) or down (0)
  property real drive: 0    // `target`, eased over a couple of ticks
  property real pulse: 0    // 1 on a beat (or, without sound, a cut), fading after
  property real sweep: 1    // the flare's journey from the middle to the ends, 0 -> 1
  property real t: 0        // the lights' drift, faster with the music
  property real clock: 0
  property real hitAt: -1

  // The video's colour. The service keeps the last one after the lights go
  // out, so the fade-out fades that rather than black. Not animated here: the
  // page already eases it, and every colour change rebuilds the gradients --
  // so the service also rounds it, and it only moves when it really moves.
  readonly property color tone: service ? service.partyColor : "transparent"

  function hue(dh) {
    var h = win.tone.hslHue < 0 ? 0 : win.tone.hslHue
    return Qt.hsla((h + dh + 1) % 1, win.tone.hslSaturation, win.tone.hslLightness, 1)
  }

  function hit() { win.hitAt = win.clock }

  Connections {
    target: win.service
    function onPartyBeat() { win.hit() }
    function onPartyCut() { if (!win.hearing) win.hit() }
  }

  Timer {
    interval: 33
    repeat: true
    running: win.lit || win.on > 0
    onTriggered: {
      var dt = interval / 1000
      win.clock += dt
      var want = win.lit ? 1 : 0
      var on = win.on + (want - win.on) * 0.18     // ~450 ms to settle
      win.on = Math.abs(on - want) < 0.004 ? want : on
      win.drive += (win.target - win.drive) * 0.6
      var since = win.hitAt < 0 ? 99 : win.clock - win.hitAt
      var pulse = Math.exp(-since * 7)
      win.pulse = pulse < 0.01 ? 0 : pulse
      win.sweep = since >= 0.46 ? 1 : 1 - Math.pow(1 - since / 0.46, 3)
      win.t += dt * (0.15 + 0.6 * win.drive)
      win.shake()
    }
  }

  // The shake: the bar's modules thump on the beat and rumble with the music.
  // A render transform on the row the bar lays its modules in -- drawing only,
  // so nothing re-lays out and the bar's reserved space never changes (moving
  // the bar window itself would re-tile every window thirty times a second).
  // That row is Omarchy's, not a plugin interface: found by shape, left alone
  // if it is not there, and always handed back untransformed.
  Scale { id: thump }
  Translate { id: rumble }
  property var shaken: null

  function shakeTarget() {
    var w = win.barWindow
    var kids = w && w.contentItem ? w.contentItem.children : []
    for (var i = 0; i < kids.length; i++)
      if (kids[i] && kids[i].sourceComponent !== undefined && kids[i].item) return kids[i].item
    return null
  }

  function unshake() {
    if (win.shaken) {
      try { win.shaken.transform = [] } catch (e) {}
    }
    win.shaken = null
  }

  function shake() {
    var amount = win.lit && win.service.partyShake ? win.on : 0
    if (amount <= 0.001) { win.unshake(); return }
    var item = win.shakeTarget()
    if (item !== win.shaken) {
      win.unshake()
      if (!item) return
      item.transform = [thump, rumble]
      win.shaken = item
    }
    // Scaled from the middle, a percentage of a 4K-wide bar throws the end
    // modules ~70 px, off the screen. So the thump is a few pixels wide
    // whatever the bar's width, and the height takes the punch.
    var k = amount * (0.25 * win.drive + win.pulse)
    thump.origin.x = item.width / 2
    thump.origin.y = item.height / 2
    thump.xScale = 1 + k * 10 / Math.max(1, item.width)
    thump.yScale = 1 + k * 0.07
    // The bar's surface clips what leaves it, so the rumble stays small.
    var r = amount * (0.5 * win.drive + 1.6 * win.pulse)
    rumble.x = (Math.random() * 2 - 1) * r * 1.5
    rumble.y = (Math.random() * 2 - 1) * r
  }

  onLitChanged: if (!lit) shake()
  Component.onDestruction: unshake()

  visible: on > 0.001
  color: "transparent"
  anchors {
    top: win.fromTop
    bottom: !win.fromTop
    left: true
    right: true
  }
  // Room for the underglow at full pump as well as the bar.
  implicitHeight: Math.max(1, barSize + depth * 2)
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "noren-party"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  mask: Region {}

  // A pool of light: a radial gradient, squashed into the bar's height. How
  // bright it is goes through opacity, which costs nothing; only the tint is
  // in the gradient, because a gradient is rebuilt whenever its stops change.
  component Light: Shape {
    id: light
    property color tint: "white"
    property real glow: 0
    opacity: glow
    property real size: 400
    property real centre: 0
    x: centre - size / 2
    y: win.barSize / 2 - size / 2
    width: size
    height: size
    transform: Scale {
      origin.x: light.size / 2
      origin.y: light.size / 2
      yScale: Math.min(1, win.barSize * 2.4 / Math.max(1, light.size))
    }
    ShapePath {
      strokeWidth: -1
      strokeColor: "transparent"
      fillGradient: RadialGradient {
        centerX: light.size / 2
        centerY: light.size / 2
        centerRadius: light.size / 2
        focalX: light.size / 2
        focalY: light.size / 2
        GradientStop { position: 0; color: Qt.rgba(light.tint.r, light.tint.g, light.tint.b, 0.42) }
        GradientStop { position: 0.4; color: Qt.rgba(light.tint.r, light.tint.g, light.tint.b, 0.18) }
        GradientStop { position: 1; color: Qt.rgba(light.tint.r, light.tint.g, light.tint.b, 0) }
      }
      startX: 0; startY: 0
      PathLine { x: light.size; y: 0 }
      PathLine { x: light.size; y: light.size }
      PathLine { x: 0; y: light.size }
      PathLine { x: 0; y: 0 }
    }
  }

  // Inside the bar: a faint wash, the stage lights, and the beat's flares.
  Item {
    width: parent.width
    height: win.barSize
    y: win.fromTop ? 0 : parent.height - win.barSize
    clip: true
    opacity: win.on

    Rectangle {
      anchors.fill: parent
      color: win.tone
      opacity: 0.05 + 0.05 * win.drive + 0.08 * win.pulse
    }

    Repeater {
      // Three lights, each on its own slow path, so they cross and part
      // rather than march in step.
      model: [
        { hue: 0, speed: 1.0, phase: 0 },
        { hue: 0.07, speed: 0.73, phase: 2.1 },
        { hue: -0.07, speed: 1.31, phase: 4.2 }
      ]
      delegate: Light {
        required property var modelData
        size: win.width * 0.24
        centre: win.width * (0.5 + 0.42 * Math.sin(win.t * modelData.speed + modelData.phase))
        tint: win.hue(modelData.hue)
        glow: Math.min(1, (0.3 + 0.7 * win.drive) * (1 + 0.5 * win.pulse))
      }
    }

    // The beat, from the middle of the bar out to both ends.
    Repeater {
      model: [-1, 1]
      delegate: Rectangle {
        required property var modelData
        width: win.width * 0.12
        height: parent.height
        x: win.width / 2 + modelData * win.sweep * win.width / 2 - width / 2
        opacity: (1 - win.sweep) * 0.6
        visible: win.sweep < 1
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: "transparent" }
          GradientStop { position: 0.5; color: Qt.lighter(win.tone, 1.4) }
          GradientStop { position: 1; color: "transparent" }
        }
      }
    }
  }

  // The lit edge.
  Rectangle {
    width: parent.width
    height: 2
    y: win.fromTop ? win.barSize - height : parent.height - win.barSize
    color: Qt.lighter(win.tone, 1.3)
    opacity: win.on * (0.45 + 0.4 * win.drive + 0.3 * win.pulse)
  }

  // The underglow.
  Rectangle {
    id: under
    readonly property real strength: Math.min(1, 0.25 + 0.5 * win.drive + 0.45 * win.pulse)
    width: parent.width
    height: win.depth * (0.45 + 0.45 * win.drive + 0.9 * win.pulse)
    y: win.fromTop ? win.barSize : parent.height - win.barSize - height
    // Strength through opacity, for the same reason as the lights.
    opacity: win.on * under.strength
    gradient: Gradient {
      GradientStop {
        position: 0
        color: Qt.rgba(win.tone.r, win.tone.g, win.tone.b, win.fromTop ? 0.5 : 0)
      }
      GradientStop {
        position: 1
        color: Qt.rgba(win.tone.r, win.tone.g, win.tone.b, win.fromTop ? 0 : 0.5)
      }
    }
  }
}

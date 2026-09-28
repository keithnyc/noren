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

  readonly property bool horizontal: edge === "top" || edge === "bottom"
  readonly property bool fromTop: edge !== "bottom"
  readonly property bool lit: !!service && service.partyLit && horizontal && barSize > 0
  readonly property bool hearing: !!service && service.partyHearing
  readonly property int depth: 26   // the underglow's reach at full drive

  // Everything fades in and out on this, so the lights come up and go down
  // rather than switching.
  property real on: lit ? 1 : 0
  Behavior on on { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }

  // How hard the lights are driven, 0-1: the music when it can be heard, the
  // picture's brightness when not. Eased over a couple of frames so thirty
  // steps a second read as one movement.
  property real drive: !service ? 0
    : (hearing ? service.partyEnergy : 0.35 + 0.4 * service.partyLevel)
  Behavior on drive { NumberAnimation { duration: 70 } }

  // The video's colour. The service keeps the last one after the lights go
  // out, so the fade-out fades that rather than black.
  property color tone: service ? service.partyColor : "transparent"
  Behavior on tone { ColorAnimation { duration: 180 } }

  function hue(dh) {
    var h = win.tone.hslHue < 0 ? 0 : win.tone.hslHue
    return Qt.hsla((h + dh + 1) % 1, win.tone.hslSaturation, win.tone.hslLightness, 1)
  }

  // 1 on a beat (or, without sound, a cut), back to 0 quickly after.
  property real pulse: 0
  SequentialAnimation {
    id: pulseAnim
    NumberAnimation { target: win; property: "pulse"; to: 1; duration: 30; easing.type: Easing.OutQuad }
    NumberAnimation { target: win; property: "pulse"; to: 0; duration: 380; easing.type: Easing.OutCubic }
  }

  // The flare's journey from the middle to the ends, 0 -> 1.
  property real sweep: 1
  NumberAnimation {
    id: sweepAnim
    target: win; property: "sweep"; from: 0; to: 1; duration: 460; easing.type: Easing.OutCubic
  }

  function hit() {
    pulseAnim.restart()
    sweepAnim.restart()
  }

  Connections {
    target: win.service
    function onPartyBeat() { win.hit() }
    function onPartyCut() { if (!win.hearing) win.hit() }
  }

  // The lights' clock, running faster with the music.
  property real t: 0
  FrameAnimation {
    running: win.visible
    onTriggered: win.t += frameTime * (0.15 + 0.6 * win.drive)
  }

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

  // A pool of light: a radial gradient, squashed into the bar's height.
  component Light: Shape {
    id: light
    property color tint: "white"
    property real glow: 0
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
        GradientStop { position: 0; color: Qt.rgba(light.tint.r, light.tint.g, light.tint.b, 0.42 * light.glow) }
        GradientStop { position: 0.4; color: Qt.rgba(light.tint.r, light.tint.g, light.tint.b, 0.18 * light.glow) }
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
    opacity: win.on
    gradient: Gradient {
      GradientStop {
        position: 0
        color: Qt.rgba(win.tone.r, win.tone.g, win.tone.b, win.fromTop ? 0.5 * under.strength : 0)
      }
      GradientStop {
        position: 1
        color: Qt.rgba(win.tone.r, win.tone.g, win.tone.b, win.fromTop ? 0 : 0.5 * under.strength)
      }
    }
  }
}

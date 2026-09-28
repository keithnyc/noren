// Noren glow -- party mode's eyes and ears: a playing video lights the window it
// plays in, and the bar, in time with its sound.
//
// A dozen times a second the picture is shrunk to a handful of pixels and made
// into one colour; the host puts that colour on the window's border and on the
// shadow around it, so the light spills onto the desktop, and the shell lights
// the bar with it. Thirty times a second the sound is measured -- how loud, and
// whether a beat just landed -- so the lights move with the music rather than
// only with the picture. Only while a video is actually playing, big enough to
// be the thing being watched, in a window that has focus -- otherwise this
// sends one "off" and goes quiet.
//
// The colour is chosen, not averaged. A plain mean of a frame is a brownish
// grey: black letterbox bars count, and the vivid parts are outvoted by
// everything around them. So near-black pixels are left out, saturated ones
// weigh more, and the result is pushed towards vivid and kept bright enough to
// read as light. How bright the scene is sets how strong the glow is, so a fade
// to black fades the glow with it.
//
// It never runs unless the worker says glow is on and this is one of Noren's
// own windows, and it sends only numbers.

(() => {
  if (window.top !== window) return;
  // Replaced rather than refused, for the same reason as bar.js: a copy
  // injected before `noren reload-extension` has a dead extension context.
  if (window.__norenGlow && typeof window.__norenGlow.destroy === 'function') {
    try {
      window.__norenGlow.destroy();
    } catch (e) {
      // Replaced either way.
    }
  }
  const stop = new AbortController();
  const signal = stop.signal;

  // Thirty ticks a second, for the sound: a light that trails the kick drum by
  // a twelfth of a second reads as late. The picture needs far less and costs
  // more, so it is looked at every third tick.
  const TICK_MS = 33;
  const PICTURE_EVERY = 3;
  const EASE = 0.35; // share of the way to the new colour per sample: ~0.5s to settle
  const W = 32; // the frame is sampled at this size
  const H = 18;
  const MIN_SHARE = 0.2; // a video must fill this much of the viewport to count
  const IDLE_TICKS = 8; // ticks with nothing to show before the loop stops
  // A still shot does not change colour, but the host puts the glow out when it
  // stops hearing from the page -- that is how a closed or crashed page goes
  // dark -- so an unchanged colour is still sent this often.
  const KEEPALIVE_MS = 500;
  // A hard cut: the picture's colour or brightness jumps between two samples.
  // The bar flashes on one, so it is rationed -- a strobing music video would
  // otherwise flash on every other frame.
  const CUT_DISTANCE = 110; // summed rgb difference of the raw samples
  const CUT_BRIGHTNESS = 0.22;
  const CUT_GAP_MS = 350;

  let enabled = false;
  let timer = null;
  let lit = false;
  let idle = 0;
  let cur = null; // {rgb: [r, g, b], level}, as eased
  let sent = null; // what the host was last given
  let sentAt = 0;
  let last = null; // the previous raw sample, for spotting cuts
  let cutAt = 0;
  let ticks = 0;
  const tainted = new WeakSet(); // cross-origin videos the canvas may not read

  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });

  function post(msg) {
    try {
      chrome.runtime.sendMessage(msg).catch(() => {});
    } catch (e) {
      // The extension was reloaded under this copy; the new one takes over.
    }
  }

  // The one being watched: playing, in view, and the biggest such.
  function pickVideo() {
    const viewport = window.innerWidth * window.innerHeight;
    let best = null;
    let bestArea = 0;
    for (const v of document.querySelectorAll('video')) {
      if (v.paused || v.ended || v.readyState < 2 || tainted.has(v)) continue;
      const r = v.getBoundingClientRect();
      const w = Math.min(r.right, window.innerWidth) - Math.max(r.left, 0);
      const h = Math.min(r.bottom, window.innerHeight) - Math.max(r.top, 0);
      const area = Math.max(0, w) * Math.max(0, h);
      if (area > bestArea) {
        best = v;
        bestArea = area;
      }
    }
    // A hover preview or a muted autoplay in a sidebar is not the show.
    return best && bestArea >= viewport * MIN_SHARE ? best : null;
  }

  function vivid(r, g, b) {
    // To HSL, saturation up, lightness into the range that reads as light.
    r /= 255;
    g /= 255;
    b /= 255;
    const mx = Math.max(r, g, b);
    const mn = Math.min(r, g, b);
    let h = 0;
    let s = 0;
    let l = (mx + mn) / 2;
    const d = mx - mn;
    if (d > 0) {
      s = d / (1 - Math.abs(2 * l - 1));
      if (mx === r) h = ((g - b) / d) % 6;
      else if (mx === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h *= 60;
      if (h < 0) h += 360;
    }
    s = Math.min(1, s * 1.6 + 0.1);
    l = Math.min(0.62, Math.max(0.42, l));
    const c = (1 - Math.abs(2 * l - 1)) * s;
    const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
    const m = l - c / 2;
    const [r1, g1, b1] =
      h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
        : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
    return [(r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255];
  }

  // One colour and a brightness for the frame, or null if it cannot be read.
  function sample(video) {
    let data;
    try {
      ctx.drawImage(video, 0, 0, W, H);
      data = ctx.getImageData(0, 0, W, H).data;
    } catch (e) {
      // A cross-origin video without CORS taints the canvas. Not this one again.
      tainted.add(video);
      return null;
    }
    let wr = 0;
    let wg = 0;
    let wb = 0;
    let wt = 0;
    let bright = 0;
    const n = data.length / 4;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i];
      const g = data[i + 1];
      const b = data[i + 2];
      const mx = Math.max(r, g, b);
      bright += mx;
      if (mx < 20) continue; // letterbox and true black carry no colour
      const sat = (mx - Math.min(r, g, b)) / mx;
      const w = (0.25 + 2 * sat) * (mx / 255);
      wr += r * w;
      wg += g * w;
      wb += b * w;
      wt += w;
    }
    const level = Math.min(1, (bright / n / 255) * 1.6);
    // All black -- a fade, or DRM, which draws black -- keeps the last colour
    // and lets the level take the glow down.
    if (wt === 0) return { rgb: cur ? cur.rgb : [0, 0, 0], level: 0 };
    return { rgb: vivid(wr / wt, wg / wt, wb / wt), level };
  }

  // ------------------------------------------------------------------ sound
  //
  // The sound is tapped, never rerouted. captureStream() hands over a copy of
  // what the video is playing and the video's own output is untouched. The
  // other way in, createMediaElementSource, moves the video's audio into this
  // script's AudioContext -- and then a suspended context (autoplay rules) or
  // a dead one (`noren reload-extension`) is a video that has gone silent.
  // With a copy the worst case is hearing nothing and lighting by the picture
  // alone. Cross-origin media without CORS, and DRM, refuse the copy: same.
  const ears = new Map(); // video -> {stream, track, ctx, analyser, ...}
  const deaf = new WeakSet(); // videos that refused

  function unhear(e) {
    try {
      if (e.ctx) e.ctx.close();
    } catch (err) {
      // Closed already.
    }
  }

  function unhearAll() {
    for (const e of ears.values()) unhear(e);
    ears.clear();
  }

  // {energy, beat} for this tick, or null if the video cannot be heard.
  function listen(video) {
    if (deaf.has(video)) return null;
    let e = ears.get(video);
    let track;
    try {
      if (!e) {
        e = { stream: video.captureStream(), track: null };
        ears.set(video, e);
      }
      track = e.stream.getAudioTracks().find((t) => t.readyState === 'live');
    } catch (err) {
      deaf.add(video);
      ears.delete(video);
      return null;
    }
    if (!track) return null; // not yet, or a silent video
    // A playlist moving on swaps the track under the same element.
    if (e.track !== track) {
      unhear(e);
      e.track = track;
      e.ctx = new AudioContext();
      e.analyser = e.ctx.createAnalyser();
      e.analyser.fftSize = 2048;
      e.analyser.smoothingTimeConstant = 0.3;
      e.ctx.createMediaStreamSource(new MediaStream([track])).connect(e.analyser);
      e.wave = new Float32Array(e.analyser.fftSize);
      e.bins = new Float32Array(e.analyser.frequencyBinCount);
      e.peak = 0.05;
      e.bassAvg = 0;
      e.bassPrev = 0;
      e.beatAt = 0;
    }
    if (e.ctx.state !== 'running') {
      e.ctx.resume().catch(() => {});
      return null;
    }

    // Loudness: the waveform's RMS, against a peak that falls away slowly, so
    // a quiet song and a loud one both use the whole range.
    e.analyser.getFloatTimeDomainData(e.wave);
    let sum = 0;
    for (let i = 0; i < e.wave.length; i++) sum += e.wave[i] * e.wave[i];
    const rms = Math.sqrt(sum / e.wave.length);
    e.peak = Math.max(rms, e.peak * 0.996, 0.02);
    const energy = rms < 0.004 ? 0 : Math.min(1, Math.pow(rms / e.peak, 1.4));

    // A beat: the bass (40-150 Hz, where the kick drum lives) jumping well
    // above its own recent average, on the way up, and not twice within
    // 180ms -- which is a ceiling of 330 BPM, well past anything danced to.
    e.analyser.getFloatFrequencyData(e.bins);
    const hz = e.ctx.sampleRate / e.analyser.fftSize;
    const lo = Math.max(1, Math.round(40 / hz));
    const hi = Math.max(lo, Math.round(150 / hz));
    let bass = 0;
    for (let i = lo; i <= hi; i++) bass += Math.pow(10, e.bins[i] / 20); // dB to amplitude
    bass /= hi - lo + 1;
    const now = performance.now();
    const beat = e.bassAvg > 0 && bass > e.bassAvg * 1.45 && bass > e.bassPrev
      && bass > 0.01 && now - e.beatAt > 180;
    if (beat) e.beatAt = now;
    e.bassAvg = e.bassAvg === 0 ? bass : e.bassAvg * 0.94 + bass * 0.06;
    e.bassPrev = bass;
    return { energy: Math.round(energy * 100) / 100, beat };
  }

  function off() {
    cur = null;
    sent = null;
    last = null;
    if (lit) {
      lit = false;
      post({ norenGlow: 'off' });
    }
  }

  function halt() {
    clearInterval(timer);
    timer = null;
    idle = 0;
    ticks = 0;
    unhearAll();
    off();
  }

  function tick() {
    const video = enabled && !document.hidden && document.hasFocus() ? pickVideo() : null;
    if (!video) {
      // Off at once, so a pause is felt; the loop itself lingers a moment in
      // case this was a buffering blip.
      off();
      if (++idle >= IDLE_TICKS) halt();
      return;
    }
    const now = performance.now();
    let cut = false;
    if (!cur || ticks % PICTURE_EVERY === 0) {
      const frame = sample(video);
      if (!frame) {
        off();
        if (++idle >= IDLE_TICKS) halt();
        return;
      }
      cut = Boolean(last) && now - cutAt > CUT_GAP_MS
        && (frame.rgb.reduce((s, c, i) => s + Math.abs(c - last.rgb[i]), 0) > CUT_DISTANCE
          || Math.abs(frame.level - last.level) > CUT_BRIGHTNESS);
      last = frame;
      if (cut) cutAt = now;
      if (!cur) {
        cur = { rgb: frame.rgb.slice(), level: frame.level };
      } else {
        cur.rgb = cur.rgb.map((c, i) => c + (frame.rgb[i] - c) * EASE);
        cur.level += (frame.level - cur.level) * EASE;
      }
    }
    ticks++;
    idle = 0;
    const sound = listen(video);
    const moved = !sent
      || cur.rgb.some((c, i) => Math.abs(c - sent.rgb[i]) >= 3)
      || Math.abs(cur.level - sent.level) >= 0.03;
    // With sound every tick goes: the music is always moving. Without it,
    // only a change, a cut, or the keepalive.
    if (!sound && !moved && !cut && now - sentAt < KEEPALIVE_MS) return;
    sentAt = now;
    sent = { rgb: cur.rgb.map(Math.round), level: Math.round(cur.level * 100) / 100 };
    lit = true;
    post({
      norenGlow: 'frame', rgb: sent.rgb, level: sent.level, cut,
      energy: sound ? sound.energy : null, beat: Boolean(sound && sound.beat),
    });
  }

  function wake() {
    if (!enabled || timer) return;
    timer = setInterval(tick, TICK_MS);
    tick();
  }

  // Media events do not bubble, but they do pass through the document on the
  // way down, so a capturing listener hears every video on the page.
  document.addEventListener('playing', wake, { capture: true, signal });
  window.addEventListener('focus', wake, { signal });
  document.addEventListener('visibilitychange', () => (document.hidden ? tick() : wake()), { signal });
  window.addEventListener('blur', () => timer && tick(), { signal });

  function hello() {
    try {
      chrome.runtime
        .sendMessage({ norenGlow: 'hello' })
        .then((reply) => {
          enabled = Boolean(reply && reply.enabled);
          if (enabled) wake();
          else halt();
        })
        .catch(() => {});
    } catch (e) {
      // No extension context; nothing to do.
    }
  }

  const onMessage = (msg) => {
    if (msg && msg.norenGlow === 'config') {
      if (msg.enabled) hello();
      else {
        enabled = false;
        halt();
      }
    }
  };
  chrome.runtime.onMessage.addListener(onMessage);

  window.__norenGlow = {
    destroy() {
      halt();
      stop.abort();
      try {
        chrome.runtime.onMessage.removeListener(onMessage);
      } catch (e) {
        // Dead context.
      }
    },
  };

  hello();
})();

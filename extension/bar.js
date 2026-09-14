// Noren reveal bar -- a browser toolbar for a window that has none.
//
// A chrome-less window has no back button, no address and no reload. The radial
// menu has all three, but only from the keyboard. This puts them on the window
// itself: rest the pointer on the window's top edge and a thin bar slides down
// over the page; move away and it goes.
//
// Built to stay out of the page's way:
//   - it floats over the page (position: fixed), so it never shifts a layout
//     or fights a sticky header;
//   - it lives in a closed shadow root, so the page's CSS cannot restyle it and
//     its CSS cannot leak into the page;
//   - it asks the worker first and only runs in Noren's chrome-less windows,
//     never in an ordinary tabbed window, which has a toolbar of its own;
//   - it needs a deliberate pause at the very top edge, so reaching for a
//     site's own menu does not keep summoning it;
//   - it stays hidden while anything is fullscreen.
//
// It is a content script, so it gets nothing it could misuse: it can only ask
// the worker to act on its own tab.

(() => {
  if (window.top !== window || window.__norenBar) return;
  window.__norenBar = true;

  const EDGE_PX = 6; // how close to the top edge counts as "at the edge"
  const DWELL_MS = 180; // how long the pointer must rest there
  const HIDE_MS = 450; // grace after the pointer leaves, so a wobble is forgiven

  let root = null; // shadow root
  let bar = null;
  let shown = false;
  // Pinned: stays down until unpinned. Per window, remembered by the worker,
  // so it survives this window navigating to another site.
  let pinned = false;
  let dwellTimer = null;
  let hideTimer = null;

  // ------------------------------------------------------------------- icons
  // Inline SVG rather than a glyph font: a page cannot be relied on to have a
  // Nerd Font, and an icon font that fails to load draws nothing at all.
  const ICONS = {
    back: '<path d="M15 5l-7 7 7 7"/>',
    forward: '<path d="M9 5l7 7-7 7"/>',
    reload: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
    home: '<path d="M4 11l8-7 8 7"/><path d="M6 10v10h12V10"/>',
    pin: '<path d="M9 4h6l-1 6 3 3H7l3-3z"/><path d="M12 13v7"/>',
  };

  function svg(name) {
    return (
      '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" ' +
      'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      ICONS[name] +
      '</svg>'
    );
  }

  const CSS = `
    :host { all: initial; }
    .bar {
      position: fixed;
      top: 0; left: 0; right: 0;
      z-index: 2147483647;
      height: 36px;
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 0 10px;
      box-sizing: border-box;
      background: color-mix(in srgb, var(--bg) 88%, transparent);
      backdrop-filter: blur(12px) saturate(1.2);
      border-bottom: 1px solid var(--border);
      box-shadow: 0 6px 18px rgba(0, 0, 0, 0.22);
      color: var(--fg);
      font: 13px/1 ui-monospace, "JetBrainsMono Nerd Font", "MesloLGL Nerd Font", monospace;
      transform: translateY(-110%);
      transition: transform 140ms ease;
      pointer-events: none;
    }
    .bar.shown { transform: translateY(0); pointer-events: auto; }
    button {
      all: unset;
      display: grid;
      place-items: center;
      width: 28px; height: 28px;
      border-radius: 7px;
      color: var(--muted);
      cursor: pointer;
    }
    button:hover { background: var(--surface); color: var(--fg); }
    button.on { color: var(--accent); }
    button.on svg { fill: currentColor; }
    button:active { transform: scale(0.94); }
    .address {
      all: unset;
      flex: 1;
      min-width: 0;
      display: flex;
      align-items: center;
      gap: 8px;
      height: 26px;
      margin: 0 6px;
      padding: 0 10px;
      border-radius: 7px;
      background: var(--surface);
      cursor: text;
    }
    .address:hover { outline: 1px solid var(--accent); }
    .address img { width: 16px; height: 16px; flex: none; }
    .url {
      overflow: hidden;
      white-space: nowrap;
      text-overflow: ellipsis;
    }
    .host { color: var(--fg); }
    .path { color: var(--muted); }
  `;

  // Dark defaults until the Omarchy palette arrives from storage.
  const FALLBACK = {
    bg: '#1a1b26', fg: '#c0caf5', surface: '#2a2c3d',
    border: '#3b3d52', muted: '#9aa0c0', accent: '#7aa2f7',
  };

  function applyRoles(roles) {
    if (!bar) return;
    const r = { ...FALLBACK, ...(roles || {}) };
    for (const key of ['bg', 'fg', 'surface', 'border', 'muted', 'accent']) {
      bar.style.setProperty('--' + key, r[key]);
    }
  }

  function favicon(url) {
    const u = new URL(chrome.runtime.getURL('/_favicon/'));
    u.searchParams.set('pageUrl', url);
    u.searchParams.set('size', '32');
    return u.toString();
  }

  function build() {
    const host = document.createElement('noren-bar');
    root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>${CSS}</style>
      <div class="bar" part="bar">
        <button data-act="back" title="Back">${svg('back')}</button>
        <button data-act="forward" title="Forward">${svg('forward')}</button>
        <button data-act="reload" title="Reload">${svg('reload')}</button>
        <button class="address" data-act="urlbar" title="Change address (opens the url bar)">
          <img alt="">
          <span class="url"><span class="host"></span><span class="path"></span></span>
        </button>
        <button data-act="home" title="Start page">${svg('home')}</button>
        <button data-act="pin" title="Keep this bar visible">${svg('pin')}</button>
      </div>`;
    bar = root.querySelector('.bar');

    bar.addEventListener('click', (event) => {
      const button = event.target.closest('button');
      if (!button) return;
      act(button.dataset.act);
    });
    bar.addEventListener('mouseenter', () => clearTimeout(hideTimer));
    bar.addEventListener('mouseleave', scheduleHide);

    // On <html>, not <body>: frameworks replace body wholesale, and the bar
    // should survive that without being re-added.
    document.documentElement.appendChild(host);
    chrome.storage.local.get({ themeRoles: null }).then((got) => applyRoles(got.themeRoles));
  }

  // The address as it is right now. Single-page apps change it without a load,
  // so it is read at the moment the bar appears, not once at startup.
  function refresh() {
    const img = root.querySelector('img');
    img.src = favicon(location.href);
    root.querySelector('.host').textContent = location.host.replace(/^www\./, '');
    const rest = (location.pathname === '/' ? '' : location.pathname) + location.search;
    root.querySelector('.path').textContent = rest;
  }

  // While the bar is down, follow the address. Single-page apps change it with
  // no load and no event a content script can rely on, and a pinned bar would
  // otherwise name the page you started on for as long as it stays open.
  let lastHref = '';
  let follow = null;

  function show() {
    if (shown || document.fullscreenElement) return;
    if (!bar) build();
    refresh();
    lastHref = location.href;
    shown = true;
    bar.classList.add('shown');
    clearInterval(follow);
    follow = setInterval(() => {
      if (!shown) {
        clearInterval(follow);
        return;
      }
      if (location.href !== lastHref) {
        lastHref = location.href;
        refresh();
      }
    }, 500);
  }

  function setPinned(on, remember) {
    pinned = on;
    if (bar) {
      const button = root.querySelector('[data-act="pin"]');
      button.classList.toggle('on', on);
      button.title = on ? 'Unpin -- hide this bar again' : 'Keep this bar visible';
    }
    if (on) show();
    if (remember) chrome.runtime.sendMessage({ norenBar: 'pin', value: on }).catch(() => {});
  }

  function hide() {
    if (!shown || pinned) return;
    shown = false;
    bar.classList.remove('shown');
  }

  function scheduleHide() {
    if (pinned) return;
    clearTimeout(hideTimer);
    hideTimer = setTimeout(hide, HIDE_MS);
  }

  function act(action) {
    if (action === 'back') history.back();
    else if (action === 'forward') history.forward();
    else if (action === 'reload') location.reload();
    else if (action === 'pin') setPinned(!pinned, true);
    else if (action === 'home' || action === 'urlbar') {
      chrome.runtime.sendMessage({ norenBar: action }).catch(() => {});
      hide();
    }
  }

  function onMove(event) {
    if (event.clientY <= EDGE_PX) {
      clearTimeout(hideTimer);
      if (!shown && !dwellTimer) {
        dwellTimer = setTimeout(() => {
          dwellTimer = null;
          show();
        }, DWELL_MS);
      }
      return;
    }
    clearTimeout(dwellTimer);
    dwellTimer = null;
    // Below the bar and not over it: start the grace period.
    if (shown && event.clientY > 44) scheduleHide();
  }

  function start() {
    document.addEventListener('mousemove', onMove, { passive: true, capture: true });
    document.addEventListener('fullscreenchange', () => {
      if (document.fullscreenElement) {
        // Fullscreen wins even over a pin; the pin comes back afterwards.
        shown = false;
        if (bar) bar.classList.remove('shown');
      } else if (pinned) {
        show();
      }
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && shown) hide();
    }, true);
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === 'local' && changes.themeRoles) applyRoles(changes.themeRoles.newValue);
    });
    // `noren bar` toggles it from the keyboard or a Hyprland bind.
    chrome.runtime.onMessage.addListener((msg) => {
      if (msg && msg.norenBar === 'toggle') {
        // From the keyboard, "hide" means hide -- a pin included.
        if (shown && pinned) setPinned(false, true);
        (shown ? hide : show)();
      }
      if (msg && msg.norenBar === 'pin') setPinned(!pinned, true);
    });
  }

  // Ask before doing anything: only Noren's own chrome-less windows get a bar.
  chrome.runtime
    .sendMessage({ norenBar: 'hello' })
    .then((reply) => {
      if (!reply || !reply.enabled) return;
      start();
      if (reply.pinned) {
        build();
        setPinned(true, false);
      }
    })
    .catch(() => {});
})();

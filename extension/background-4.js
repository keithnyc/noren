// Noren — Chromium side of the bridge.
//
// Keep this filename versioned. Chromium caches service workers for extensions
// loaded via --load-extension, so a new URL forces registration of new code.
// Bump to background-2.js when you change this file, and update manifest.json.

const HOST = 'com.noren.bridge';

let port = null;

// ---------------------------------------------------------------- connection

function connect() {
  if (port) return port;

  port = chrome.runtime.connectNative(HOST);

  port.onMessage.addListener((msg) => {
    handleCommand(msg).catch((err) => {
      send({ type: 'error', id: msg && msg.id, message: String(err) });
    });
  });

  // The host exits when Chromium does, and vice versa. If it dies first --
  // crashed, or cycled during development -- reconnect on a backoff instead of
  // waiting for whatever browser event happens to come next, which may be
  // minutes away or never.
  port.onDisconnect.addListener(() => {
    // Surface the reason. A rejected connectNative (wrong extension id in the
    // host manifest, missing manifest, host not executable) looks exactly like
    // a clean shutdown unless this is read.
    const err = chrome.runtime.lastError;
    if (err && err.message) console.warn('noren: native port closed —', err.message);
    port = null;
    scheduleReconnect();
  });

  retryDelay = 1000;
  return port;
}

let retryDelay = 1000;
let retryTimer = null;

function scheduleReconnect() {
  if (retryTimer) return;
  retryTimer = setTimeout(() => {
    retryTimer = null;
    try {
      connect();
      pushState();
    } catch (e) {
      // connect() already cleared the port; back off and try again.
    }
    retryDelay = Math.min(retryDelay * 2, 30000);
  }, retryDelay);
}

function send(payload) {
  try {
    connect().postMessage(payload);
  } catch (err) {
    port = null;
  }
}

// ------------------------------------------------------------------ commands

// Chromium's "last focused window" is not what the user is looking at: a
// command issued from a terminal or a Hyprland bind arrives while the browser
// isn't focused at all, so Chromium answers with whatever window it saw last —
// frequently on another workspace. The host passes the title of the browser
// window on the *active* workspace; prefer that, and fall back only if the
// hint is missing or matches nothing.
async function focusedTab(matchTitle) {
  if (matchTitle) {
    const wins = await chrome.windows.getAll({ populate: true });
    const wanted = String(matchTitle).trim();
    for (const win of wins) {
      const active = (win.tabs || []).find((t) => t.active);
      if (!active) continue;
      const title = (active.title || '').trim();
      // Hyprland truncates nothing, but the browser suffix is already stripped
      // host-side; allow either direction of prefix match for safety.
      if (title === wanted || title.startsWith(wanted) || wanted.startsWith(title)) {
        return active;
      }
    }
  }

  const win = await chrome.windows.getLastFocused({ populate: true });
  if (!win || !win.tabs) return null;
  return win.tabs.find((t) => t.active) || win.tabs[0] || null;
}

function describe(tab) {
  if (!tab) return null;
  return {
    id: tab.id,
    windowId: tab.windowId,
    url: tab.url || '',
    title: tab.title || '',
    loading: tab.status === 'loading',
  };
}

async function handleCommand(msg) {
  if (!msg || !msg.cmd) return;
  const reply = (data) => send({ type: 'reply', id: msg.id, data });

  switch (msg.cmd) {
    case 'ping':
      return reply({ ok: true });

    case 'navigate': {
      const tab = await focusedTab(msg.matchTitle);
      if (!tab) return reply({ ok: false, error: 'no focused window' });
      await chrome.tabs.update(tab.id, { url: normalize(msg.url) });
      return reply({ ok: true, id: tab.id });
    }

    case 'back':
      return withTab(reply, msg, (id) => chrome.tabs.goBack(id));

    case 'forward':
      return withTab(reply, msg, (id) => chrome.tabs.goForward(id));

    case 'reload':
      return withTab(reply, msg, (id) => chrome.tabs.reload(id));

    case 'tabs': {
      const tabs = await chrome.tabs.query({});
      return reply({ ok: true, tabs: tabs.map(describe) });
    }

    case 'focus': {
      const tab = await chrome.tabs.get(Number(msg.tabId));
      await chrome.windows.update(tab.windowId, { focused: true });
      await chrome.tabs.update(tab.id, { active: true });
      return reply({ ok: true });
    }

    case 'peel': {
      // Move the focused tab into its own chrome-less window.
      const tab = await focusedTab(msg.matchTitle);
      if (!tab) return reply({ ok: false, error: 'no focused window' });
      send({ type: 'spawn', url: tab.url });
      await chrome.tabs.remove(tab.id);
      return reply({ ok: true });
    }

    case 'state':
      return reply({ ok: true, state: describe(await focusedTab()) });

    case 'setAutoPeel':
      autoPeel = Boolean(msg.value);
      return reply({ ok: true, autoPeel });

    default:
      return reply({ ok: false, error: `unknown command: ${msg.cmd}` });
  }
}

async function withTab(reply, msg, fn) {
  const tab = await focusedTab(msg && msg.matchTitle);
  if (!tab) return reply({ ok: false, error: 'no focused window' });
  await fn(tab.id);
  return reply({ ok: true });
}

function normalize(url) {
  const raw = String(url || '').trim();
  if (!raw) return 'about:blank';
  if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) return raw;
  // A bare token with no dot is a search, not a hostname.
  if (!raw.includes('.') || raw.includes(' ')) {
    return 'https://duckduckgo.com/?q=' + encodeURIComponent(raw);
  }
  return 'https://' + raw;
}

// ----------------------------------------------------------------- auto-peel
//
// The tabs-as-windows experiment. Off by default: turn it on with
// `noren peel on` once you want every new tab to become its own window.

let autoPeel = false;

chrome.tabs.onCreated.addListener(async (tab) => {
  if (!autoPeel) return;
  // A tab with no URL yet is mid-navigation; wait for onUpdated to carry one.
  const url = tab.pendingUrl || tab.url;
  if (!url || url === 'about:blank' || url === 'chrome://newtab/') return;

  // Only peel tabs born in an ordinary tabbed window. A chrome-less --app
  // window contains exactly one tab, and that tab IS the result of peeling:
  // peel it again and we spawn a replacement, close this one, and the
  // replacement's tab fires onCreated in turn. `noren open` then appears to do
  // nothing at all, because every window it makes is destroyed on arrival.
  try {
    const win = await chrome.windows.get(tab.windowId);
    if (!win || win.type !== 'normal') return;
  } catch (e) {
    return;
  }

  send({ type: 'spawn', url });
  chrome.tabs.remove(tab.id, () => void chrome.runtime.lastError);
});

// ------------------------------------------------------------- state updates

function pushState() {
  focusedTab().then((tab) => send({ type: 'state', state: describe(tab) }));
}

chrome.tabs.onUpdated.addListener((_id, info) => {
  if (info.status || info.title || info.url) pushState();
});
chrome.tabs.onActivated.addListener(pushState);
chrome.tabs.onRemoved.addListener(pushState);
chrome.windows.onFocusChanged.addListener(pushState);

// Establish the port as soon as the worker spins up.
connect();
pushState();

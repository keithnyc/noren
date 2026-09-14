// Noren — Chromium side of the bridge.
//
// Keep this filename versioned. Chromium caches service workers for extensions
// loaded via --load-extension, so a new URL forces registration of new code.
// Bump the number when you change this file, and update manifest.json.

const HOST = 'com.noren.bridge';

let port = null;

// ---------------------------------------------------------------- connection

function connect() {
  if (port) return port;

  port = chrome.runtime.connectNative(HOST);

  port.onMessage.addListener((msg) => {
    if (msg && msg.type === 'theme') {
      applyTheme(msg.theme);
      return;
    }
    if (msg && (msg.type === 'sets' || msg.type === 'setOpResult')) {
      const settle = pendingHost.get(msg.id);
      pendingHost.delete(msg.id);
      if (settle) settle(msg);
      return;
    }
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

    case 'saveBookmark': {
      // A chrome-less window has no Ctrl+D and cannot host chrome://bookmarks,
      // so without this a bookmark can only be *read*, never made. Silent by
      // design: one keystroke, default folder. Organising is what a tabbed
      // window is still for.
      const tab = await focusedTab(msg.matchTitle);
      const url = tab && tab.url;
      if (!url || !/^https?:/i.test(url)) {
        return reply({ ok: false, error: 'nothing bookmarkable in front of you' });
      }
      // Pressing it twice should not pile up duplicates.
      const found = await chrome.bookmarks.search({ url }).catch(() => []);
      if (found && found.length) {
        return reply({ ok: true, already: true, title: found[0].title, url });
      }
      const node = await chrome.bookmarks.create({ title: tab.title || url, url });
      return reply({ ok: true, already: false, title: node.title, url: node.url });
    }

    case 'suggest': {
      // What the url bar completes against. Bookmarks and history are the two
      // things the browser knows and the shell does not, so they have to come
      // back across the bridge; open tabs are already in the overlay.
      const query = String(msg.query || '').trim();
      const limit = Math.min(Number(msg.limit) || 8, 25);
      // `kind` narrows the sources rather than filtering afterwards, so a
      // bookmarks-only search returns a full page of bookmarks instead of
      // whatever survived a mixed ranking.
      const kind = msg.kind === 'bookmark' || msg.kind === 'history' ? msg.kind : null;
      if (msg.kind === 'start') {
        return reply({ ok: true, suggestions: await startSuggestions(limit) });
      }
      return reply({ ok: true, suggestions: await suggest(query, limit, kind) });
    }

    case 'windows': {
      // What Chromium thinks each window *is*. Auto-peel keys off window type,
      // and the types are not obvious: a chrome-less `--app` window does not
      // necessarily report 'app'. Guessing here is what created the loop that
      // destroyed every window Noren made, so this exists to be looked at.
      const wins = await chrome.windows.getAll({ populate: true });
      return reply({
        ok: true,
        windows: wins.map((w) => ({
          id: w.id,
          type: w.type,
          focused: w.focused,
          state: w.state,
          tabs: (w.tabs || []).map((t) => ({
            id: t.id,
            active: t.active,
            url: (t.url || t.pendingUrl || '').slice(0, 80),
            title: (t.title || '').slice(0, 40),
          })),
        })),
      });
    }

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

    case 'home': {
      // Send the page in front of you back to the start page, the way a
      // browser's Home button does. Strict about the target: focusedTab falls
      // back to Chromium's last-focused window when the title hint matches
      // nothing, and "go home" landing on some other window is exactly the
      // silent retargeting this bridge exists to avoid. No hint, no match, no
      // navigation -- the CLI then opens a start page instead.
      if (!msg.matchTitle) return reply({ ok: false, error: 'no page in front of you' });
      const tab = await focusedTab(msg.matchTitle);
      const title = ((tab && tab.title) || '').trim();
      const wanted = String(msg.matchTitle).trim();
      if (!tab || !(title === wanted || title.startsWith(wanted) || wanted.startsWith(title))) {
        return reply({ ok: false, error: 'page in front of you not found' });
      }
      if ((tab.url || '').startsWith(START_URL)) return reply({ ok: true, already: true });
      await chrome.tabs.update(tab.id, { url: START_URL });
      return reply({ ok: true });
    }

    case 'state':
      return reply({ ok: true, state: describe(await focusedTab()) });

    case 'setThemeMode': {
      const mode = String(msg.mode || '');
      if (!MODES.includes(mode)) {
        return reply({ ok: false, error: `unknown mode: ${mode}` });
      }
      await themeReady;
      themeMode = mode;
      await chrome.storage.local.set({ themeMode });
      await restyleAllTabs();
      return reply({ ok: true, mode: themeMode });
    }

    case 'themeStatus':
      await themeReady;
      return reply({ ok: true, mode: themeMode, loaded: Boolean(themeCss) });

    case 'setAutoPeel':
      await autoPeelReady;
      autoPeel = Boolean(msg.value);
      await chrome.storage.local.set({ autoPeel });
      pushState();
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

// ---------------------------------------------------------------- suggestions

function normalizeUrl(url) {
  // Dedupe key only -- never shown, never navigated to. http/https and a
  // trailing slash are the same destination as far as a url bar is concerned.
  return String(url || '')
    .replace(/^https?:\/\//, '')
    .replace(/\/+$/, '')
    .toLowerCase();
}

function scoreEntry(entry, needle) {
  const url = normalizeUrl(entry.url);
  const title = (entry.title || '').toLowerCase();
  let score = entry.kind === 'bookmark' ? 120 : 0;

  if (needle) {
    // A host that starts with what was typed is almost always the intent --
    // "git" should reach github.com before a page whose title mentions git.
    if (url.startsWith(needle)) score += 200;
    else if (url.indexOf('/' + needle) >= 0) score += 60;
    else if (url.indexOf(needle) >= 0) score += 40;
    if (title.startsWith(needle)) score += 80;
    else if (title.indexOf(needle) >= 0) score += 30;
  }

  // Frequency, flattened: the tenth visit should not outrank a good match.
  score += Math.min(60, Math.log2(1 + (entry.visitCount || 0)) * 12);

  if (entry.lastVisitTime) {
    const days = (Date.now() - entry.lastVisitTime) / 86400000;
    score += Math.max(0, 40 - days * 2);
  }
  return score;
}

async function suggest(query, limit, kind) {
  const needle = query.toLowerCase();
  const wantMarks = kind !== 'history';
  const wantHist = kind !== 'bookmark';

  const [marks, hist] = await Promise.all([
    wantMarks
      ? (query
          ? chrome.bookmarks.search({ query })
          : chrome.bookmarks.getRecent(Math.max(limit * 2, 40))
        ).catch(() => [])
      : Promise.resolve([]),
    wantHist
      ? chrome.history
          .search({ text: query, maxResults: 60, startTime: 0 })
          .catch(() => [])
      : Promise.resolve([]),
  ]);

  const byUrl = new Map();
  const add = (entry, kind) => {
    if (!entry || !entry.url || !/^https?:/i.test(entry.url)) return;
    const key = normalizeUrl(entry.url);
    const existing = byUrl.get(key);
    // A bookmarked page that is also in history keeps the bookmark's standing
    // and borrows history's visit counts.
    if (existing) {
      if (kind === 'bookmark') existing.kind = 'bookmark';
      existing.visitCount = Math.max(existing.visitCount || 0, entry.visitCount || 0);
      existing.lastVisitTime = Math.max(existing.lastVisitTime || 0, entry.lastVisitTime || 0);
      if (!existing.title && entry.title) existing.title = entry.title;
      return;
    }
    byUrl.set(key, {
      url: entry.url,
      title: entry.title || '',
      kind,
      visitCount: entry.visitCount || 0,
      lastVisitTime: entry.lastVisitTime || 0,
    });
  };

  for (const m of marks) add(m, 'bookmark');
  for (const h of hist) add(h, 'history');

  return Array.from(byUrl.values())
    .map((e) => ({ entry: e, score: scoreEntry(e, needle) }))
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map(({ entry }) => ({
      url: entry.url,
      title: entry.title,
      kind: entry.kind,
      visits: entry.visitCount,
    }));
}

// What the url bar and the start page show before anything is typed: the
// bookmarks bar in its own order -- someone arranged it -- then the sites
// actually visited most. One source, so the two can never disagree.
//
// Most visited is ranked from history, not `chrome.topSites`. topSites is a
// cache Chromium refreshes on its own schedule and seeds with defaults: on a
// profile used daily it answered the Web Store, a benchmark and a localhost
// login page, none of which were the sites actually visited most.
const PLACES_WINDOW_DAYS = 30;

function placeHost(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '').toLowerCase();
  } catch (e) {
    return '';
  }
}

// Link shorteners and redirectors: every click on a social feed site goes through t.co, so it
// ranks as a site you visit when it is only a hop on the way to one.
const PASS_THROUGH = new Set(['t.co', 'bit.ly', 'lnkd.in', 'l.facebook.com', 'out.reddit.com']);

// Somewhere you went, not something that happened to you: a local dev server's
// login callback visits itself a dozen times without anyone choosing it.
function destination(url) {
  if (!/^https?:/i.test(url || '')) return false;
  const host = placeHost(url);
  return Boolean(host) && host !== 'localhost' && !/^127\.|^\[?::1\]?$/.test(host)
    && !PASS_THROUGH.has(host);
}

async function mostVisited(limit) {
  let items = [];
  try {
    items = await chrome.history.search({
      text: '',
      startTime: Date.now() - PLACES_WINDOW_DAYS * 86400000,
      maxResults: 5000,
    });
  } catch (e) {
    return [];
  }

  // One entry per site: social.example and social.example/home are the same stop. The site's
  // count is the sum of its pages; its link is the page visited most.
  const sites = new Map();
  for (const item of items) {
    if (!destination(item.url)) continue;
    const host = placeHost(item.url);
    const visits = item.visitCount || 0;
    const site = sites.get(host);
    if (!site) {
      sites.set(host, { url: item.url, title: item.title || '', best: visits, visits });
      continue;
    }
    site.visits += visits;
    if (visits > site.best) {
      site.best = visits;
      site.url = item.url;
      site.title = item.title || site.title;
    }
  }
  return Array.from(sites.values())
    .sort((x, y) => y.visits - x.visits)
    .slice(0, limit)
    .map((site) => ({ url: site.url, title: site.title }));
}

// Sites hidden from most visited on the start page, by host. History cannot
// forget a site without deleting what you did there, so hiding is a filter.
// Mirrored to the host, which writes it where `noren suggest --kind start` can
// read it with the browser closed.
async function hiddenSites() {
  try {
    const got = await chrome.storage.local.get({ hiddenSites: [] });
    return Array.isArray(got.hiddenSites) ? got.hiddenSites : [];
  } catch (e) {
    return [];
  }
}

async function setHiddenSites(hosts) {
  const unique = Array.from(new Set(hosts.map((h) => String(h).toLowerCase()).filter(Boolean)));
  await chrome.storage.local.set({ hiddenSites: unique });
  send({ type: 'saveStart', hidden: unique });
}

async function places(limit) {
  const bar = [];
  try {
    const [root] = await chrome.bookmarks.getSubTree('1');
    for (const node of root.children || []) {
      if (/^https?:/i.test(node.url || '')) {
        bar.push({ id: node.id, url: node.url, title: node.title || '' });
      }
    }
  } catch (e) {
    // No bar is fine; most visited still answers.
  }
  const hidden = await hiddenSites();
  // A site already on the bar is on screen; do not spend a second slot on it.
  const skip = new Set(bar.map((e) => placeHost(e.url)).concat(hidden));
  const top = (await mostVisited(limit + skip.size)).filter((e) => !skip.has(placeHost(e.url)));
  return { bar, top: top.slice(0, limit), hidden: hidden.length };
}

async function startSuggestions(limit) {
  const { bar, top } = await places(limit);
  return bar
    .map((e) => ({ url: e.url, title: e.title, kind: 'bookmark' }))
    .concat(top.map((e) => ({ url: e.url, title: e.title, kind: 'top' })))
    .slice(0, limit);
}

// ---------------------------------------------------------------- start page
//
// The start page is an extension page, so it can read bookmarks and top sites
// itself. What it cannot do is open a chrome-less window or see the sets file:
// both belong to the host, which only this worker can talk to.

const START_URL = chrome.runtime.getURL('start.html');

// id -> resolve, for requests the host answers asynchronously.
const pendingHost = new Map();
let hostSeq = 0;

// Resolves with the host's reply message, or `fallback` if none arrives: a
// host that never answers must not leave the page waiting forever.
function askHost(payload, fallback, timeoutMs) {
  return new Promise((resolve) => {
    const id = 'host-' + ++hostSeq;
    pendingHost.set(id, resolve);
    send({ ...payload, id });
    setTimeout(() => {
      if (pendingHost.delete(id)) resolve(fallback);
    }, timeoutMs);
  });
}

async function askSets() {
  const reply = await askHost({ type: 'getSets' }, null, 3000);
  return reply && Array.isArray(reply.sets) ? reply.sets : [];
}

const SET_OPS = ['put', 'rm', 'save'];

// A start page opened from a cold start loses a race it cannot see: Chromium
// creates the `--app` window before it has loaded this extension, refuses the
// chrome-extension:// url as ERR_BLOCKED_BY_CLIENT, and nothing ever retries.
// The window just sits on an error page.
//
// So when the worker comes up, reload any start-page tab that is not actually
// running. `getContexts` lists the extension pages that are alive; a blocked
// tab has the url but no context. Checked twice, because at a cold start the
// page may still be loading on the first look -- and reloading a healthy page is
// never done, since a live one always has a context.
async function reviveStartPages() {
  if (!chrome.runtime.getContexts) return;
  try {
    const tabs = await chrome.tabs.query({});
    const candidates = tabs.filter(
      (t) => (t.url || t.pendingUrl || '').startsWith(START_URL) && t.status === 'complete',
    );
    if (candidates.length === 0) return;
    const live = await chrome.runtime.getContexts({ contextTypes: ['TAB'] });
    const running = new Set(live.map((c) => c.tabId));
    for (const tab of candidates) {
      if (!running.has(tab.id)) chrome.tabs.reload(tab.id).catch(() => {});
    }
  } catch (e) {
    // Nothing to revive, or the browser is shutting down.
  }
}

reviveStartPages();
setTimeout(reviveStartPages, 1500);

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // Only our own start page may ask. Content scripts are not ours to trust
  // with spawning windows, and there are none today -- keep it that way.
  if (!msg || !msg.noren || sender.id !== chrome.runtime.id) return false;
  if (!sender.url || !sender.url.startsWith(START_URL)) return false;

  switch (msg.noren) {
    case 'open':
      if (/^https?:/i.test(msg.url || '')) send({ type: 'spawn', url: msg.url });
      sendResponse({ ok: true });
      return false;
    case 'openSet':
      send({ type: 'openSet', name: String(msg.name || '') });
      sendResponse({ ok: true });
      return false;
    case 'sets':
      askSets().then((sets) => sendResponse({ ok: true, sets }));
      return true;
    case 'setOp': {
      // The CLI validates everything; this only refuses what is not an edit.
      if (!SET_OPS.includes(msg.op)) {
        sendResponse({ ok: false, error: 'unknown set operation' });
        return false;
      }
      // `save` asks the browser for its open windows before writing, so it
      // gets longer than a plain file edit.
      askHost({ type: 'setOp', op: msg.op, data: msg.data || {} },
        { ok: false, error: 'Noren did not answer' }, msg.op === 'save' ? 20000 : 15000)
        .then((reply) => sendResponse({ ok: Boolean(reply.ok), error: reply.error || '' }));
      return true;
    }
    case 'places':
      places(12).then((got) => sendResponse({ ok: true, ...got }));
      return true;
    case 'hide':
      hiddenSites()
        .then((hosts) => setHiddenSites(hosts.concat(placeHost('https://' + String(msg.host || '')))))
        .then(() => sendResponse({ ok: true }));
      return true;
    case 'unhideAll':
      setHiddenSites([]).then(() => sendResponse({ ok: true }));
      return true;
    default:
      return false;
  }
});

// ----------------------------------------------------------------- auto-peel
//
// The tabs-as-windows experiment. Off by default: turn it on with
// `noren peel on` once you want every new tab to become its own window.
//
// The setting lives in chrome.storage.local, not just this variable. A service
// worker is torn down whenever the browser decides it is idle and always when
// the last window closes, so an in-memory flag silently reverts to off -- which
// is indistinguishable from the feature not working, and fatal to a week-long
// trial of tabs-as-windows.

let autoPeel = false;

// Every read of autoPeel must await this first. The worker starts answering
// events immediately, and a tab created in that window would otherwise be
// judged against the default rather than the stored value.
const autoPeelReady = chrome.storage.local
  .get({ autoPeel: false })
  .then((got) => {
    autoPeel = Boolean(got.autoPeel);
  })
  .catch((err) => {
    console.warn('noren: could not read stored auto-peel —', err);
  });

// Tabs that fired onCreated before they had a URL, waiting for onUpdated to
// bring one. Chromium creates a middle-clicked tab first and navigates it a
// moment later, so for those the URL is simply not there yet. onCreated always
// said to wait for onUpdated and nothing ever did -- so those tabs were dropped
// silently, and middle-click peeled only when the URL happened to arrive in
// time. Verified against `noren windows`: a chrome-less window reports type
// 'app', so 'normal' still excludes our own windows either way.
// tabId -> windowId. A Map rather than a Set because the window was already
// validated when the tab was created, and webNavigation does not report one:
// carrying it here keeps the fast path free of a chrome.tabs.get round trip.
const pendingPeel = new Map();
// When each deferred tab was first seen, so the trace can report how long a
// peel actually took and which path it went down. The flash lasts exactly as
// long as this, so it is the only number that matters.
const peelSeenAt = new Map();

function peelTrace(tabId, path, url) {
  const started = peelSeenAt.get(tabId);
  const ms = started === undefined ? 0 : Math.round(performance.now() - started);
  peelSeenAt.delete(tabId);
  console.log(`noren peel: ${path} ${ms}ms ${String(url).slice(0, 60)}`);
}

function peelable(url) {
  return Boolean(url) && url !== 'about:blank' && url !== 'chrome://newtab/';
}

// Only peel tabs born in an ordinary tabbed window. A chrome-less --app window
// contains exactly one tab, and that tab IS the result of peeling: peel it again
// and we spawn a replacement, close this one, and the replacement's tab fires
// onCreated in turn. `noren open` then appears to do nothing at all, because
// every window it makes is destroyed on arrival.
//
// Popups are left alone on purpose. They are distinguishable from our windows
// (ours are 'app'), but a `window.open()` popup is usually an OAuth or payment
// flow that depends on `window.opener` and on being closed by the page that
// opened it. Peeling one into a chrome-less window breaks the login it belongs
// to.
// Window types, cached. `chrome.windows.get` is an IPC round trip to the browser
// process and it sits directly in the peel hot path -- and that path is watched:
// a link opening in a new window puts a full-chrome Chromium window on screen,
// which exists only until this decides to peel it. Every millisecond here is a
// millisecond of window the user sees and then sees destroyed.
//
// This shortens the flash. It cannot remove it: the window is Chromium's, drawn
// before any extension event fires. See DEVELOPMENT.md -- that flash is one of
// the two standing arguments for forking, and the standing answer is not to.
const windowTypes = new Map();

chrome.windows.onCreated.addListener((win) => {
  if (win && win.id !== undefined) windowTypes.set(win.id, win.type);
});
chrome.windows.onRemoved.addListener((id) => windowTypes.delete(id));

async function inTabbedWindow(windowId) {
  const known = windowTypes.get(windowId);
  if (known !== undefined) return known === 'normal';
  try {
    const win = await chrome.windows.get(windowId);
    if (win && win.id !== undefined) windowTypes.set(win.id, win.type);
    return Boolean(win) && win.type === 'normal';
  } catch (e) {
    return false;
  }
}

async function peelTab(tabId, windowId, url) {
  if (!(await inTabbedWindow(windowId))) return false;
  send({ type: 'spawn', url });
  chrome.tabs.remove(tabId, () => void chrome.runtime.lastError);
  return true;
}

chrome.tabs.onCreated.addListener(async (tab) => {
  peelSeenAt.set(tab.id, performance.now());
  await autoPeelReady;
  if (!autoPeel) {
    peelSeenAt.delete(tab.id);
    return;
  }

  const url = tab.pendingUrl || tab.url;
  if (!peelable(url)) {
    // Remember it; onUpdated finishes the job once a url turns up.
    if (await inTabbedWindow(tab.windowId)) {
      pendingPeel.set(tab.id, tab.windowId);
      console.log(`noren peel: deferred at onCreated (no url yet) tab=${tab.id}`);
    } else {
      peelSeenAt.delete(tab.id);
    }
    return;
  }

  if (await peelTab(tab.id, tab.windowId, url)) peelTrace(tab.id, 'oncreated', url);
  else peelSeenAt.delete(tab.id);
});

// -------------------------------------------------------------- page theming
//
// Omarchy's palette, rendered into CSS by the host and injected here. The
// extension cannot read the filesystem, so the host is the only thing that can
// see a theme at all; it pushes on connect and again whenever the theme changes.
//
//   respect   leave pages exactly as their authors built them
//   tint      paint the canvas, selection, scrollbars and form accents
//   immerse   repaint page surfaces too (experimental -- see DEVELOPMENT.md)

const MODES = ['respect', 'tint', 'immerse'];

let themeMode = 'tint';
let themeCss = null;

// Same gate as auto-peel: the worker answers navigation events before storage
// resolves, and a page loaded in that window would be judged against the
// default rather than the stored mode.
const themeReady = chrome.storage.local
  .get({ themeMode: 'tint' })
  .then((got) => {
    if (MODES.includes(got.themeMode)) themeMode = got.themeMode;
  })
  .catch((err) => {
    console.warn('noren: could not read stored theme mode —', err);
  });

// What we last injected per tab, so a mode or theme change can pull the old
// stylesheet before adding the new one. Navigation drops it for us; this covers
// everything else.
const injected = new Map();

function styleFor() {
  if (themeMode === 'respect' || !themeCss) return null;
  return themeCss[themeMode] || null;
}

// chrome:// pages, the web store, PDFs and other extensions reject injection,
// and the resulting rejections are noise rather than news.
function injectable(url) {
  return /^https?:|^file:/.test(url || '');
}

async function styleTab(tabId, url) {
  const previous = injected.get(tabId);
  if (previous) {
    injected.delete(tabId);
    try {
      await chrome.scripting.removeCSS({ target: { tabId }, css: previous, origin: 'USER' });
    } catch (e) {
      // The document already went away, or never had it. Either is fine.
    }
  }

  const css = styleFor();
  if (!css || !injectable(url)) {
    // Leaving immerse has to unwind the inline styles the pass wrote, which
    // only the page itself can do.
    if (surfaced.has(tabId)) await runSurfacePass(tabId, null);
    return;
  }

  try {
    // USER origin loses to a site's own !important rules, which is the point:
    // tint should lose an argument with a page that genuinely cares.
    await chrome.scripting.insertCSS({ target: { tabId }, css, origin: 'USER' });
    injected.set(tabId, css);
  } catch (e) {
    // Injection is refused on privileged pages; nothing to do about it.
  }

  const roles = themeCss && themeCss.roles;
  if (themeMode === 'immerse' && roles) {
    await runSurfacePass(tabId, { bg: roles.bg, fg: roles.fg, link: roles.link });
  } else if (surfaced.has(tabId)) {
    await runSurfacePass(tabId, null);
  }
}

// Tabs the surface pass is live in, so leaving immerse can unwind it rather
// than waiting for a navigation to drop it.
const surfaced = new Set();

async function runSurfacePass(tabId, palette) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      func: norenSurfacePass,
      args: [palette],
    });
    if (palette) surfaced.add(tabId);
    else surfaced.delete(tabId);
  } catch (e) {
    surfaced.delete(tabId);
  }
}

async function restyleAllTabs() {
  const tabs = await chrome.tabs.query({});
  await Promise.all(tabs.map((t) => styleTab(t.id, t.url)));
}

function applyTheme(theme) {
  if (!theme) return;
  themeCss = theme;
  themeReady.then(restyleAllTabs);
  // For the start page, which themes itself from these rather than being
  // injected into: it is an extension page, and injection refuses those.
  chrome.storage.local
    .set({ themeRoles: theme.roles || null, themePalette: theme.mode || null })
    .catch(() => {});
}

chrome.tabs.onRemoved.addListener((tabId) => {
  injected.delete(tabId);
  surfaced.delete(tabId);
});

// A tab opened by `target="_blank"` is created with no url at all: the
// navigation is renderer-initiated, so Chromium does not populate `pendingUrl`
// either. Waiting for `onUpdated` to carry one means waiting for the navigation
// to *commit* -- DNS, connect, response -- and the doomed full-chrome window is
// on screen for every millisecond of it. Measured on a cold site: 582ms.
//
// `onBeforeNavigate` fires before the request is made, so the destination is
// known almost immediately. Peeling here closes the tab before the page is ever
// fetched: no wasted load, and the flash stops tracking the network.
chrome.webNavigation.onBeforeNavigate.addListener(async (details) => {
  // Main frame only; a subframe navigating is not a new destination.
  if (!details || details.frameId !== 0) return;
  const windowId = pendingPeel.get(details.tabId);
  if (windowId === undefined) return;

  await autoPeelReady;
  if (!autoPeel) {
    pendingPeel.delete(details.tabId);
    return;
  }
  if (!peelable(details.url)) return;

  pendingPeel.delete(details.tabId);
  if (await peelTab(details.tabId, windowId, details.url)) {
    peelTrace(details.tabId, 'beforenavigate', details.url);
  }
});

// ------------------------------------------------------------- state updates

function pushState() {
  focusedTab().then((tab) =>
    send({ type: 'state', state: describe(tab), autoPeel, themeMode })
  );
}

chrome.tabs.onUpdated.addListener(async (tabId, info, tab) => {
  if (info.status || info.title || info.url) pushState();

  // Last-resort half of auto-peel: a tab that had no URL when it was created
  // and whose navigation onBeforeNavigate never reported. Slow by nature --
  // info.url only exists once the navigation has committed.
  if (pendingPeel.has(tabId)) {
    await autoPeelReady;
    const url = (info && info.url) || (tab && (tab.url || tab.pendingUrl)) || '';
    if (!autoPeel) {
      pendingPeel.delete(tabId);
    } else if (peelable(url)) {
      pendingPeel.delete(tabId);
      if (await peelTab(tabId, (tab && tab.windowId) || info.windowId, url)) {
        // Which field carried the url says whether we waited for the navigation
        // to commit (info.url) or acted on the intended destination
        // (pendingUrl). Only the second can be fast on a cold site.
        const via = info && info.url ? 'info.url' : (tab && tab.pendingUrl ? 'pendingUrl' : 'tab.url');
        peelTrace(tabId, `onupdated/${via}/status=${info && info.status}`, url);
        return;
      }
    }
  }
  // 'loading' is the earliest this API will tell us about a new document.
  // A navigation drops the previous stylesheet with the old document, so the
  // bookkeeping has to be cleared even when we do not re-inject.
  if (info.status === 'loading') {
    injected.delete(tabId);
    surfaced.delete(tabId);
    await themeReady;
    styleTab(tabId, (tab && tab.url) || info.url);
  } else if (info.status === 'complete' && themeMode === 'immerse') {
    // The first pass may have landed in a document that had nothing in it yet.
    // Re-entry with an unchanged palette is a cheap sweep, not a repaint.
    const roles = themeCss && themeCss.roles;
    if (roles && injectable((tab && tab.url) || '')) {
      await runSurfacePass(tabId, { bg: roles.bg, fg: roles.fg, link: roles.link });
    }
  }
});
chrome.tabs.onActivated.addListener(pushState);
chrome.tabs.onRemoved.addListener((tabId) => {
  pendingPeel.delete(tabId);
  peelSeenAt.delete(tabId);
  pushState();
});
chrome.windows.onFocusChanged.addListener(pushState);

// Establish the port as soon as the worker spins up. The first state push waits
// for the stored auto-peel value so `noren status` never reports a stale off.
connect();
autoPeelReady.then(pushState);
// Seed the window-type cache so the first peel after a worker restart is not
// the one that pays for the round trip.
chrome.windows
  .getAll()
  .then((wins) => wins.forEach((w) => windowTypes.set(w.id, w.type)))
  .catch(() => {});
// The worker restarts far more often than the host does, so ask rather than
// waiting for the next theme change to bring one.
themeReady.then(() => send({ type: 'wantTheme' }));

// ------------------------------------------------------------ surface remap
//
// A stylesheet cannot reach a site's own surfaces: `background-color` does not
// inherit, so there is no cascade path from `body` down to a card that paints
// itself white. Immerse-by-stylesheet therefore themes the page around the
// content and leaves the content white, which looks like damage rather than a
// theme (a social feed site is the worst case -- almost every surface is explicit).
//
// This walks the document, reads each element's *computed* colours, and remaps
// the site's neutrals onto the theme's ramp. Anything with real chroma is left
// alone, so brand colours, avatars, badges, charts and syntax highlighting
// survive: a themed GitHub has to keep its diff colours meaning what they mean.
//
// Injected with the palette as an argument rather than read from storage, so
// there is no round trip between the walk starting and the colours arriving.

function norenSurfacePass(palette) {
  const TAG = '__norenSurfaces';
  if (window[TAG]) {
    window[TAG].update(palette);
    return;
  }

  const PROPS = ['background-color', 'color', 'border-color'];
  // Everything we may write, for revert. `background-image` is handled
  // separately: gradients are rewritten stop by stop, not remapped as a colour.
  const OWNED = PROPS.concat(['background-image']);
  const COLOUR_RE = /rgba?\([^)]*\)/g;
  // Below this, a colour is a neutral the theme may own. Above it, it carries
  // meaning the palette knows nothing about -- a brand, a badge, a diff -- and
  // must be left exactly as it is.
  //
  // 0.06 sits in an empty gap. Measured against the feed site's own palette: its neutrals
  // run 0.000-0.029 (white 0.000, card 0.002, border 0.004, body text 0.013,
  // secondary text 0.029) and nothing it means runs below 0.156 (brand blue
  // 0.161, like red 0.250, retweet green 0.156, amber 0.181).
  const CHROMA_LIMIT = 0.06;
  const SKIP = new Set([
    'IMG', 'VIDEO', 'CANVAS', 'SVG', 'PICTURE', 'IFRAME',
    'EMBED', 'OBJECT', 'SOURCE', 'TRACK', 'MAP', 'AREA',
    'SCRIPT', 'STYLE', 'LINK', 'META', 'HEAD', 'TITLE', 'NOSCRIPT',
  ]);
  // Time budget per tick rather than a fixed element count. The previous
  // version drained 250 elements per requestIdleCallback, which is fine on an
  // idle page and useless on a loading one: while a video site is booting, the main
  // thread never goes idle, so the callbacks only fired at their 500ms timeout
  // and a large document stayed visibly unthemed for seconds. A budgeted loop on
  // a 0ms timer makes steady progress whether or not the page is busy, and still
  // yields often enough to keep rendering smooth.
  const BUDGET_MS = 8;
  const now = () =>
    typeof performance !== 'undefined' && performance.now ? performance.now() : Date.now();

  let theme = null;
  let baseL = 1;
  let seen = new WeakSet();
  // Elements sitting on a background we deliberately left alone. Their text was
  // chosen to be legible against *that* colour, so it has to be left alone too:
  // remapping white label text on a red badge toward the theme foreground makes
  // it unreadable, and the badge is exactly the kind of thing we promised not to
  // touch. The flag inherits, because the text is usually on a child of the
  // element carrying the colour.
  let coloredBg = new WeakSet();
  // Each element's colour as the site computed it, recorded on the way past so a
  // child can tell whether it actually departs from its parent.
  let origColor = new WeakMap();
  const cache = new Map();
  let queue = [];
  let scheduled = false;
  let observer = null;
  let rootObserver = null;
  let lastKey = null;
  // What we wrote on <html> and <body>, normalised as the browser stores it.
  // Those two are the only elements worth defending: a framework that rewrites
  // a card's style attribute costs one card, but one that rewrites body's costs
  // the whole page ground. A social feed site does exactly that -- its body carries an inline
  // black, and React puts it back after we remap it.
  let rootStyles = new Map();
  let reapplying = false;
  // Nothing may be painted before the site's own ground has been measured.
  let ready = false;

  // ------------------------------------------------------------------ colour

  function parse(str) {
    const m = /^rgba?\(([^)]+)\)/.exec(str || '');
    if (!m) return null;
    const p = m[1].split(/[\s,\/]+/).filter(Boolean).map(Number);
    if (p.length < 3 || p.some(Number.isNaN)) return null;
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  }

  function hexToRgb(hex) {
    const h = String(hex).replace('#', '');
    return {
      r: parseInt(h.slice(0, 2), 16),
      g: parseInt(h.slice(2, 4), 16),
      b: parseInt(h.slice(4, 6), 16),
      a: 1,
    };
  }

  function channel(c) {
    c /= 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  }

  function lum(c) {
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  }

  // OKLab chroma. The obvious cheap stand-in, (max-min)/255, is a trap: it
  // scores the feed site's secondary text at 0.118 and its brand blue at 0.827, so
  // any threshold that spares the blue also spares half the greys on the page.
  // In OKLab those are 0.029 and 0.161 -- a real gap. Every result is cached by
  // colour string, so the cube roots are paid once per distinct colour, not
  // once per element.
  function chroma(c) {
    const r = channel(c.r);
    const g = channel(c.g);
    const b = channel(c.b);
    const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    const A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    const B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    return Math.hypot(A, B);
  }

  function mix(a, b, t) {
    const k = Math.max(0, Math.min(1, t));
    return `rgb(${Math.round(a.r + (b.r - a.r) * k)}, ${Math.round(
      a.g + (b.g - a.g) * k
    )}, ${Math.round(a.b + (b.b - a.b) * k)})`;
  }

  // How far this colour sits from the page's own ground, re-expressed as a
  // distance from the theme's ground. Keeps the site's sense of elevation --
  // a card still reads as raised, a border still reads as a border -- without
  // keeping any of its actual colours.
  function remap(str, kind) {
    const key = kind + '|' + str;
    if (cache.has(key)) return cache.get(key);

    let out = null;
    const c = parse(str);
    if (c && c.a > 0.05 && chroma(c) <= CHROMA_LIMIT) {
      const d = Math.abs(lum(c) - baseL);
      if (kind === 'color') {
        // Text: reproduce how far it stood from its own background, so a page's
        // secondary text stays secondary instead of collapsing onto the primary
        // colour. Scaling this (an earlier attempt divided by 0.85) saturates
        // the top of the range and makes exactly that collapse happen -- on a social feed site,
        // body text at d=0.99 and secondary text at d=0.86 both pinned to 1.
        // The floor keeps a low-contrast site from arriving washed out.
        out = mix(theme.bg, theme.fg, Math.max(0.4, Math.min(1, d)));
      } else if (kind === 'border-color') {
        out = mix(theme.bg, theme.fg, Math.min(0.45, 0.12 + d * 1.5));
      } else {
        // Gain 4.0, not 2.4. On a white site every surface sits close to white,
        // so the distances are small and the lower gain compressed cards,
        // panels and the page itself into a band a tenth of the way from the
        // background -- correct, but it reads as flat. The 0.3 ceiling is what
        // stops this going muddy; the gain is what makes surfaces separate.
        out = mix(theme.bg, theme.fg, Math.min(0.3, d * 4.0));
      }
      if (c.a < 1) out = out.replace('rgb(', 'rgba(').replace(')', `, ${c.a})`);
    }

    cache.set(key, out);
    return out;
  }

  // ------------------------------------------------------------------- apply

  // A gradient of neutral stops is still a surface we can own -- recolour each
  // stop and keep the shape of the fade. A video site's masthead is the case: it is a
  // gradient at the top of the page and a flat colour once scrolled, so skipping
  // every background-image left the header black at scroll-top and themed
  // everywhere else. Returns null when the gradient is not ours to touch: a
  // url() is real artwork, and a coloured stop is carrying meaning.
  function remapGradient(img) {
    if (!img || img === 'none') return null;
    if (img.indexOf('url(') !== -1) return null;
    const stops = img.match(COLOUR_RE);
    if (!stops || !stops.length) return null;
    for (const stop of stops) {
      const c = parse(stop);
      if (!c) return null;
      if (c.a > 0.05 && chroma(c) > CHROMA_LIMIT) return null;
    }
    return img.replace(COLOUR_RE, (m) => remap(m, 'background-color') || m);
  }

  function paint(el) {
    if (seen.has(el)) return;
    seen.add(el);
    if (SKIP.has(el.tagName) || el.namespaceURI === 'http://www.w3.org/2000/svg') return;

    let style;
    try {
      style = getComputedStyle(el);
    } catch (e) {
      return;
    }
    if (!style) return;

    const saved = {};
    let touched = false;

    const ownColor = style.getPropertyValue('color');
    origColor.set(el, ownColor);
    const parent = el.parentElement;

    // Decide the background first: whether we own this element's surface is
    // what decides whether we may touch its text.
    //
    // A gradient or image counts as a surface we do not own. Only
    // `background-color` is remappable, so an element painted by
    // `background-image` keeps whatever colour it had -- and its text has to
    // keep the colour that was chosen to be legible against it. A webmail site is the
    // case that proved it: light-blue gradient cards on a dark page, whose dark
    // body text was being flipped to the theme's cream foreground and
    // disappearing.
    const bgImage = style.getPropertyValue('background-image');
    const hasImage = Boolean(bgImage) && bgImage !== 'none';
    const gradient = hasImage ? remapGradient(bgImage) : null;
    const ownBg = parse(style.getPropertyValue('background-color'));
    const opaqueBg = ownBg && ownBg.a > 0.05;
    const onColour = hasImage && !gradient
      ? true
      : opaqueBg
        ? chroma(ownBg) > CHROMA_LIMIT
        : Boolean(parent && coloredBg.has(parent));
    if (onColour) coloredBg.add(el);

    // The canvas gets the theme's ground exactly, never a remap.
    //
    // <html> *is* the page ground, so by construction it maps to the theme
    // background -- d is zero. Putting it through the generic remap makes it
    // depend on whether `baseL` happened to be read from html, from body, or
    // from the fallback, and on a social feed site that landed it one elevation step off
    // (rgb(34,48,58) against body's rgb(22,36,45)). The visible result is a
    // horizontal seam wherever body's box ends, which on a social feed site is one viewport down.
    // Assigning the ground directly is both simpler and immune to the ground
    // being misread.
    //
    // It also has to happen at all: immerse's stylesheet cannot paint <html>
    // without destroying the ground reading, and with `color-scheme` from the
    // palette and nothing painting it, Chromium fills its own canvas -- black in
    // a dark scheme -- so every region the site leaves transparent shows black.
    const isCanvas = el === document.documentElement && theme.bgCss;
    if (isCanvas && !gradient) {
      const inlineBg = el.style.getPropertyValue('background-color');
      if (inlineBg) saved['background-color'] = inlineBg;
      el.style.setProperty('background-color', theme.bgCss, 'important');
      touched = true;
    }

    if (gradient) {
      const inlineImg = el.style.getPropertyValue('background-image');
      if (inlineImg) saved['background-image'] = inlineImg;
      el.style.setProperty('background-image', gradient, 'important');
      touched = true;
    }

    // Links get the theme's link colour, but only where we own the surface
    // under them. On a gradient card we kept, the site's own link colour is the
    // one that was chosen to be legible there.
    if (el.tagName === 'A' && !onColour && theme.link) {
      const inline = el.style.getPropertyValue('color');
      if (inline) saved['color'] = inline;
      el.style.setProperty('color', theme.link, 'important');
      touched = true;
    }

    for (const prop of PROPS) {
      if (onColour && prop !== 'background-color') continue;
      if (isCanvas && prop === 'background-color') continue;
      if (prop === 'color' && el.tagName === 'A' && theme.link) continue;
      const value = style.getPropertyValue(prop);
      // `color` inherits. Writing it on every element would put an inline style
      // on essentially the whole document to no visual effect, so only write
      // where this element actually departs from its parent. The parent's
      // pre-paint value was recorded on the way past; the fallback is for
      // subtrees that arrive by mutation without their parent being re-walked.
      if (prop === 'color' && parent) {
        let inherited = origColor.get(parent);
        if (inherited === undefined) {
          try {
            inherited = getComputedStyle(parent).getPropertyValue('color');
          } catch (e) {
            inherited = undefined;
          }
        }
        if (inherited !== undefined && inherited === value) continue;
      }
      const next = remap(value, prop);
      if (!next) continue;
      // Only record an original that was actually inline; anything else comes
      // back on its own when the property is cleared.
      const inline = el.style.getPropertyValue(prop);
      if (inline) saved[prop] = inline;
      el.style.setProperty(prop, next, 'important');
      touched = true;
    }

    if (touched) {
      if (isRoot(el)) rememberRoot(el);
      el.setAttribute('data-noren-surface', '');
      if (Object.keys(saved).length) {
        el.setAttribute('data-noren-prev', JSON.stringify(saved));
      }
    }
  }

  function drain() {
    scheduled = false;
    if (!ready) return;
    const started = now();
    while (queue.length) {
      const el = queue.pop();
      if (el && el.isConnected) paint(el);
      if (now() - started > BUDGET_MS) break;
    }
    if (queue.length) schedule();
  }

  function schedule() {
    if (scheduled) return;
    scheduled = true;
    setTimeout(drain, 0);
  }

  function enqueue(root) {
    if (!root) return;
    if (root.querySelectorAll) {
      // Reverse, because `drain` pops from the end: this walks top-down, so a
      // parent's colour lands in the first frame instead of the page
      // repainting leaf-up and visibly crawling.
      const all = root.querySelectorAll('*');
      for (let i = all.length - 1; i >= 0; i--) {
        if (!seen.has(all[i])) queue.push(all[i]);
      }
    }
    if (root.nodeType === 1 && !seen.has(root)) queue.push(root);
    schedule();
  }

  function revert() {
    rootStyles = new Map();
    const touched = document.querySelectorAll('[data-noren-surface]');
    for (const el of touched) {
      let saved = {};
      try {
        saved = JSON.parse(el.getAttribute('data-noren-prev') || '{}');
      } catch (e) {
        saved = {};
      }
      for (const prop of OWNED) {
        el.style.removeProperty(prop);
        if (saved[prop]) el.style.setProperty(prop, saved[prop]);
      }
      el.removeAttribute('data-noren-surface');
      el.removeAttribute('data-noren-prev');
    }
  }

  // --------------------------------------------------------------- lifecycle

  function readBase() {
    // The site's own ground, read before anything is repainted. A page that
    // sets no background is already on the theme's canvas via `color-scheme`,
    // so the theme's background is the honest answer for it.
    for (const el of [document.documentElement, document.body]) {
      if (!el) continue;
      const c = parse(getComputedStyle(el).getPropertyValue('background-color'));
      if (c && c.a > 0.05) return { L: lum(c), resolved: true };
    }
    return { L: lum(theme.bg), resolved: false };
  }

  // Measuring the ground before the document has a body is not a small error --
  // it is the difference between a themed page and a washed-out one. The pass
  // is injected as soon as a navigation is visible, which on a slow load is
  // before <body> exists; readBase then falls back to the theme's own
  // background, every colour is measured against the wrong ground, and the
  // whole bg-to-fg range compresses. On a white site under a light theme that
  // turns 12:1 body text into 4:1. So: install the observer immediately, queue
  // whatever appears, and paint nothing until there is a real ground to read.
  function isRoot(el) {
    return el === document.documentElement || el === document.body;
  }

  function rememberRoot(el) {
    const props = {};
    for (const prop of OWNED) {
      const v = el.style.getPropertyValue(prop);
      if (v) props[prop] = v;
    }
    rootStyles.set(el, props);
  }

  function watchRoots() {
    if (!rootObserver) {
      rootObserver = new MutationObserver(() => {
        if (reapplying) return;
        reapplying = true;
        for (const [el, props] of rootStyles) {
          for (const prop in props) {
            if (el.style.getPropertyValue(prop) !== props[prop]) {
              el.style.setProperty(prop, props[prop], 'important');
            }
          }
        }
        reapplying = false;
      });
    }
    for (const el of [document.documentElement, document.body]) {
      if (el) rootObserver.observe(el, { attributes: true, attributeFilter: ['style'] });
    }
  }

  function restartPaint() {
    revert();
    queue = [];
    seen = new WeakSet();
    origColor = new WeakMap();
    coloredBg = new WeakSet();
    cache.clear();
    enqueue(document.documentElement);
    schedule();
  }

  // Waiting for <body> to exist is not the same as waiting for a ground. On a social feed site,
  // body is there almost immediately but has no background until the app boots,
  // so readBase fell back to the theme's own background and every colour was
  // measured against the wrong ground -- which is how <html> ended up at
  // rgb(34,48,58) instead of the theme background exactly. Keep looking for a
  // real ground for a short while, and repaint if one turns up after we started.
  let groundTries = 0;
  const GROUND_TRIES_MAX = 20; // ~2s at 100ms

  function tryGround() {
    const base = readBase();
    const settled = base.resolved || groundTries >= GROUND_TRIES_MAX;

    if (settled) {
      const moved = ready && Math.abs(base.L - baseL) > 0.004;
      baseL = base.L;
      if (!ready) {
        ready = true;
        watchRoots();
        schedule();
      } else if (moved) {
        restartPaint();
      }
      return;
    }

    groundTries++;
    // Paint on the fallback rather than leave the page bare, but keep looking:
    // if a real ground appears the page is repainted against it.
    if (!ready && groundTries > 3) {
      baseL = base.L;
      ready = true;
      watchRoots();
      schedule();
    }
    setTimeout(tryGround, 100);
  }

  function whenGrounded() {
    groundTries = 0;
    if (document.body || document.readyState !== 'loading') {
      tryGround();
    } else {
      document.addEventListener('DOMContentLoaded', tryGround, { once: true });
    }
  }

  function start(next) {
    lastKey = next.bg + '|' + next.fg + '|' + next.link;
    theme = {
      bg: hexToRgb(next.bg),
      fg: hexToRgb(next.fg),
      bgCss: next.bg,
      link: next.link || null,
    };
    ready = false;
    cache.clear();
    enqueue(document.documentElement);
    whenGrounded();

    if (!observer) {
      // childList only. Watching attributes would see our own writes and loop.
      observer = new MutationObserver((records) => {
        for (const r of records) {
          for (const node of r.addedNodes) {
            if (node.nodeType === 1) enqueue(node);
          }
        }
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
    }
  }

  window[TAG] = {
    update(next) {
      if (!next) {
        revert();
        if (observer) observer.disconnect();
        if (rootObserver) rootObserver.disconnect();
        observer = null;
        rootObserver = null;
        queue = [];
        delete window[TAG];
        return;
      }
      // Re-injected with the same palette -- which happens on every page load,
      // because the pass is run again once the document is complete in case it
      // was first injected into an empty one. Sweep for anything new instead of
      // tearing the whole page down and repainting it.
      const key = next.bg + '|' + next.fg + '|' + next.link;
      if (key === lastKey) {
        enqueue(document.documentElement);
        return;
      }
      lastKey = key;
      revert();
      queue = [];
      seen = new WeakSet();
      origColor = new WeakMap();
      coloredBg = new WeakSet();
      start(next);
    },
  };

  start(palette);
}

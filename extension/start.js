// Noren start page -- the guide a chrome-less browser otherwise lacks.
//
// A tabbed browser shows you where you might go before you have decided: the
// bookmarks bar is just there. Noren removed the chrome and that went with it,
// so a morning's first window was a blank question. This page answers it with
// what the browser already knows -- the bookmarks bar, then the sites you
// actually visit -- and your sets.
//
// A click goes there in this window, the way a new-tab page does: the start
// page is where the day begins, not a window to keep. Ctrl+click (or a middle
// click) opens a new window and leaves this page where it is. This is the
// reverse of the url bar's Enter / Ctrl+Enter, on purpose -- see DEVELOPMENT.md.
//
// Editing writes to the bookmarks bar itself. It is already an ordered list the
// browser stores, syncs and lets you rename, so "pin", "reorder" and "unpin"
// need no store of Noren's own -- and whatever you arrange here is also what a
// tabbed window's bar shows. Only hiding a most-visited site is Noren's, because
// history has no notion of it.

const FAVICON_SIZE = 64;

function favicon(url) {
  // Chromium's own favicon cache, served to extensions with the `favicon`
  // permission. Works offline, and costs the site nothing.
  const u = new URL(chrome.runtime.getURL('/_favicon/'));
  u.searchParams.set('pageUrl', url);
  u.searchParams.set('size', String(FAVICON_SIZE));
  return u.toString();
}

function hostOf(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '');
  } catch (e) {
    return url;
  }
}

// ------------------------------------------------------------------ theming

const ROLE_VARS = [
  'bg', 'fg', 'surface', 'surface-2', 'border', 'muted',
  'accent', 'link', 'success', 'warning', 'danger',
];

function applyRoles(roles, mode) {
  if (!roles) return;
  const style = document.documentElement.style;
  for (const role of ROLE_VARS) {
    if (roles[role]) style.setProperty('--noren-' + role, roles[role]);
  }
  if (mode === 'light' || mode === 'dark') style.setProperty('color-scheme', mode);
}

// The worker stores the palette whenever the host pushes one, so a theme switch
// repaints this page live without it having to ask.
chrome.storage.local.get({ themeRoles: null, themePalette: null }).then((got) => {
  applyRoles(got.themeRoles, got.themePalette);
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes.themeRoles) return;
  const mode = changes.themePalette ? changes.themePalette.newValue : null;
  applyRoles(changes.themeRoles.newValue, mode);
});

// -------------------------------------------------------------------- clock

function greetingFor(hour) {
  if (hour < 5) return 'Late night';
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  if (hour < 22) return 'Good evening';
  return 'Good night';
}

// ------------------------------------------------------------- time of day
//
// A faint light over the page that moves through the day: warm at dawn, clear
// by day, embered at dusk, cool at night. Every colour is one of the theme's own
// roles, so the light always belongs to the palette -- this table only says
// which two roles, and how strongly, at each point in the day. Between points
// the colours are mixed, so the change is continuous rather than stepped.
const DAYLIGHT = [
  // hour, top light, bottom light, strength
  [0, 'link', 'accent', 10],
  [5.5, 'warning', 'danger', 17],
  [8, 'accent', 'warning', 12],
  [13, 'accent', 'link', 9],
  [17.5, 'danger', 'warning', 17],
  [20.5, 'accent', 'link', 12],
  [24, 'link', 'accent', 10],
];

function setDaylight(hour) {
  let i = 0;
  while (i < DAYLIGHT.length - 2 && hour >= DAYLIGHT[i + 1][0]) i++;
  const [h0, top0, bottom0, s0] = DAYLIGHT[i];
  const [h1, top1, bottom1, s1] = DAYLIGHT[i + 1];
  const t = Math.min(1, Math.max(0, (hour - h0) / (h1 - h0)));
  const mix = (a, b) =>
    `color-mix(in oklab, var(--noren-${a}) ${Math.round((1 - t) * 100)}%, var(--noren-${b}))`;
  const style = document.documentElement.style;
  style.setProperty('--tod-top', mix(top0, top1));
  style.setProperty('--tod-bottom', mix(bottom0, bottom1));
  style.setProperty('--tod-strength', Math.round(s0 + (s1 - s0) * t) + '%');
}

function tick() {
  const now = new Date();
  const hour = now.getHours() + now.getMinutes() / 60;
  document.getElementById('clock').textContent = now.toLocaleTimeString([], {
    hour: 'numeric',
    minute: '2-digit',
  });
  document.getElementById('greeting').textContent = greetingFor(now.getHours());
  document.getElementById('day').textContent = now.toLocaleDateString([], {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  });
  setDaylight(hour);
}

// ---------------------------------------------------------------- wallpaper
//
// The desktop's own background, sent by the host whenever it changes. Without
// one the page is simply the theme's ground, as before.
function applyWallpaper(data) {
  const backdrop = document.getElementById('backdrop');
  if (!data) {
    document.body.classList.remove('has-wallpaper');
    backdrop.style.backgroundImage = '';
    return;
  }
  // Decode before showing, so it fades in whole instead of painting in strips.
  const probe = new Image();
  probe.onload = () => {
    backdrop.style.backgroundImage = `url("${data}")`;
    document.body.classList.add('has-wallpaper');
  };
  probe.src = data;
}

chrome.storage.local.get({ wallpaper: null }).then((got) => applyWallpaper(got.wallpaper));
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes.wallpaper) applyWallpaper(changes.wallpaper.newValue);
});

// ------------------------------------------------------------ tile glow/tilt
//
// Each tile lights in its site's own colour, read off the favicon. Chromium's
// favicon endpoint is same-origin to this page, so the canvas is not tainted and
// the pixels can be read. Greys, near-black and near-white are skipped -- a
// monochrome logo has no colour to lend, and gets the theme's accent instead.
const glowCache = new Map();
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

function dominantColor(img) {
  const size = 24;
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = size;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  try {
    ctx.drawImage(img, 0, 0, size, size);
    const { data } = ctx.getImageData(0, 0, size, size);
    const buckets = new Map();
    for (let i = 0; i < data.length; i += 4) {
      const [r, g, b, a] = [data[i], data[i + 1], data[i + 2], data[i + 3]];
      if (a < 128) continue;
      const max = Math.max(r, g, b);
      const min = Math.min(r, g, b);
      const sat = max === 0 ? 0 : (max - min) / max;
      const light = (max + min) / 510;
      if (sat < 0.3 || max < 48 || light > 0.9) continue;
      let hue;
      if (max === r) hue = ((g - b) / (max - min) + 6) % 6;
      else if (max === g) hue = (b - r) / (max - min) + 2;
      else hue = (r - g) / (max - min) + 4;
      const key = Math.floor(hue * 2); // twelve hue buckets
      const bucket = buckets.get(key) || { w: 0, r: 0, g: 0, b: 0, n: 0 };
      const w = sat * sat;
      bucket.w += w;
      bucket.r += r * w;
      bucket.g += g * w;
      bucket.b += b * w;
      bucket.n += 1;
      buckets.set(key, bucket);
    }
    let best = null;
    for (const bucket of buckets.values()) {
      if (bucket.n >= 6 && (!best || bucket.w > best.w)) best = bucket;
    }
    if (!best) return null;
    return `rgb(${Math.round(best.r / best.w)}, ${Math.round(best.g / best.w)}, ${Math.round(best.b / best.w)})`;
  } catch (e) {
    return null;
  }
}

function lightUp(tileEl, img, url) {
  const key = hostOf(url);
  const apply = (color) => {
    if (color) tileEl.style.setProperty('--glow', color);
  };
  if (glowCache.has(key)) {
    apply(glowCache.get(key));
    return;
  }
  const read = () => {
    const color = dominantColor(img);
    glowCache.set(key, color);
    apply(color);
  };
  if (img.complete && img.naturalWidth) read();
  else img.addEventListener('load', read, { once: true });
}

// A slight lean toward the pointer, and a light that follows it -- the same
// language as the overview's cover flow. Off in edit mode, where tiles are
// dragged, and for anyone who has asked their system for less motion.
function tilt(tileEl) {
  tileEl.addEventListener('pointermove', (event) => {
    if (editing || reduceMotion.matches) return;
    const box = tileEl.getBoundingClientRect();
    const x = (event.clientX - box.left) / box.width;
    const y = (event.clientY - box.top) / box.height;
    tileEl.style.setProperty('--rx', ((0.5 - y) * 9).toFixed(2) + 'deg');
    tileEl.style.setProperty('--ry', ((x - 0.5) * 11).toFixed(2) + 'deg');
    tileEl.style.setProperty('--mx', (x * 100).toFixed(1) + '%');
    tileEl.style.setProperty('--my', (y * 100).toFixed(1) + '%');
    tileEl.classList.add('tilting');
  });
  tileEl.addEventListener('pointerleave', () => {
    tileEl.classList.remove('tilting');
    tileEl.style.setProperty('--rx', '0deg');
    tileEl.style.setProperty('--ry', '0deg');
  });
}

tick();
// Line up with the minute so the clock never shows a stale one for most of it.
setTimeout(() => {
  tick();
  setInterval(tick, 60000);
}, 60000 - (Date.now() % 60000) + 50);

// ------------------------------------------------------------------ opening

function open(url, here) {
  if (here) {
    window.location.href = url;
    return;
  }
  chrome.runtime.sendMessage({ noren: 'open', url }).catch(() => {
    // No worker to spawn through. Better to go there than to do nothing.
    window.location.href = url;
  });
}

const BAR_ID = '1';

// Every tile in page order, so number keys match what the eye counts.
const tiles = [];
let editing = false;
// Most visited starts collapsed on every load and is never remembered open.
// It is a record of where you go, and the start page is the thing on screen
// when someone is looking over your shoulder. Opening it is one click; leaving
// it open by accident should not survive a reload.
let topOpen = false;
let hiddenCount = 0;

function setEditing(on) {
  editing = on;
  document.body.classList.toggle('editing', on);
  document.getElementById('edit').textContent = on ? 'Done' : 'Edit';
  render();
}

function button(label, title, onClick) {
  const b = document.createElement('button');
  b.className = 'tool';
  b.type = 'button';
  b.textContent = label;
  b.title = title;
  b.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    onClick();
  });
  return b;
}

// ------------------------------------------------------------------ dragging
//
// Pinned tiles reorder by dragging; a most-visited tile dragged into Pinned is
// pinned at the spot it lands. Both end as one bookmarks call.

let dragged = null;

function dropIndex(grid, event) {
  // The pinned tile under the pointer, and which half of it: dropping on the
  // right half means "after".
  const pinned = Array.from(grid.querySelectorAll('.tile[data-index]'));
  for (const el of pinned) {
    const box = el.getBoundingClientRect();
    if (event.clientY < box.top || event.clientY > box.bottom) continue;
    if (event.clientX < box.left || event.clientX > box.right) continue;
    const index = Number(el.dataset.index);
    return event.clientX > box.left + box.width / 2 ? index + 1 : index;
  }
  return pinned.length;
}

async function dropOnBar(event) {
  event.preventDefault();
  const grid = document.getElementById('bar');
  grid.classList.remove('over');
  if (!dragged) return;
  const to = dropIndex(grid, event);
  const source = dragged;
  dragged = null;
  try {
    if (source.id) {
      // Chromium reads a same-parent move's index as a position *before* the
      // node is taken out, and adjusts for it -- which is exactly what
      // dropIndex measures, dragged tile included. No correction here.
      await chrome.bookmarks.move(source.id, { parentId: BAR_ID, index: to });
    } else {
      await chrome.bookmarks.create({
        parentId: BAR_ID,
        index: to,
        title: source.title || hostOf(source.url),
        url: source.url,
      });
    }
  } catch (e) {
    console.warn('noren start: drop failed —', e);
  }
  render();
}

function wireBarDrops() {
  const grid = document.getElementById('bar');
  grid.addEventListener('dragover', (event) => {
    if (!editing || !dragged) return;
    event.preventDefault();
    grid.classList.add('over');
  });
  grid.addEventListener('dragleave', (event) => {
    if (!grid.contains(event.relatedTarget)) grid.classList.remove('over');
  });
  grid.addEventListener('drop', dropOnBar);
}

// --------------------------------------------------------------------- tiles

function tile(entry, where, index) {
  const a = document.createElement('a');
  a.className = 'tile';
  a.href = entry.url;
  a.title = entry.url;
  if (where === 'bar') a.dataset.index = String(index);

  if (!editing && tiles.length < 9) {
    const key = document.createElement('span');
    key.className = 'key';
    key.textContent = String(tiles.length + 1);
    a.appendChild(key);
  }

  const img = document.createElement('img');
  img.src = favicon(entry.url);
  img.alt = '';
  img.draggable = false;
  a.appendChild(img);
  lightUp(a, img, entry.url);
  tilt(a);

  const title = document.createElement('span');
  title.className = 'title';
  title.textContent = entry.title || hostOf(entry.url);
  a.appendChild(title);

  const host = document.createElement('span');
  host.className = 'host';
  host.textContent = hostOf(entry.url);
  a.appendChild(host);

  if (editing) {
    a.draggable = true;
    a.addEventListener('dragstart', (event) => {
      dragged = { id: entry.id || null, url: entry.url, title: entry.title };
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('text/uri-list', entry.url);
      a.classList.add('dragging');
    });
    a.addEventListener('dragend', () => {
      dragged = null;
      a.classList.remove('dragging');
    });

    const tools = document.createElement('div');
    tools.className = 'tools';
    if (where === 'bar') {
      tools.appendChild(
        button('×', 'Unpin -- removes it from the bookmarks bar', async () => {
          await chrome.bookmarks.remove(entry.id).catch(() => {});
          render();
        }),
      );
      // Page titles make poor labels ("Inbox (3) - Mail - ..."), so a pinned tile's
      // title is its own to set. It is the bookmark's name.
      title.contentEditable = 'plaintext-only';
      title.spellcheck = false;
      title.title = 'Click to rename';
      title.addEventListener('click', (event) => {
        event.preventDefault();
        event.stopPropagation();
      });
      title.addEventListener('keydown', (event) => {
        event.stopPropagation();
        if (event.key === 'Enter') {
          event.preventDefault();
          title.blur();
        } else if (event.key === 'Escape') {
          title.textContent = entry.title || hostOf(entry.url);
          title.blur();
        }
      });
      title.addEventListener('blur', async () => {
        const name = title.textContent.trim();
        if (name && name !== entry.title) {
          await chrome.bookmarks.update(entry.id, { title: name }).catch(() => {});
          entry.title = name;
        } else if (!name) {
          title.textContent = entry.title || hostOf(entry.url);
        }
      });
    } else {
      tools.appendChild(
        button('Pin', 'Add it to the bookmarks bar', async () => {
          await chrome.bookmarks
            .create({ parentId: BAR_ID, title: entry.title || hostOf(entry.url), url: entry.url })
            .catch(() => {});
          render();
        }),
      );
      tools.appendChild(
        button('×', 'Hide it from most visited', async () => {
          await chrome.runtime.sendMessage({ noren: 'hide', host: hostOf(entry.url) }).catch(() => {});
          render();
        }),
      );
    }
    a.appendChild(tools);
  }

  a.addEventListener('click', (event) => {
    // Handled rather than left to the link, so edit mode can swallow it and
    // Ctrl can mean "new window" instead of Chromium's background tab.
    event.preventDefault();
    if (editing) return;
    open(entry.url, !(event.ctrlKey || event.metaKey));
  });
  a.addEventListener('auxclick', (event) => {
    if (event.button !== 1 || editing) return;
    event.preventDefault();
    open(entry.url, false);
  });

  tiles.push(entry);
  return a;
}

// The "+" tile: pin something that is not in most visited yet.
function addTile() {
  const box = document.createElement('div');
  box.className = 'tile add';

  const input = document.createElement('input');
  input.type = 'text';
  input.placeholder = '+ add a site';
  input.spellcheck = false;
  input.addEventListener('keydown', async (event) => {
    event.stopPropagation();
    if (event.key === 'Escape') {
      input.value = '';
      input.blur();
      return;
    }
    if (event.key !== 'Enter') return;
    let raw = input.value.trim();
    if (!raw) return;
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(raw)) raw = 'https://' + raw;
    let url;
    try {
      url = new URL(raw);
    } catch (e) {
      input.classList.add('bad');
      return;
    }
    if (!/^https?:$/.test(url.protocol) || !url.hostname.includes('.')) {
      input.classList.add('bad');
      return;
    }
    await chrome.bookmarks
      .create({ parentId: BAR_ID, title: hostOf(url.href), url: url.href })
      .catch(() => {});
    render();
  });
  input.addEventListener('input', () => input.classList.remove('bad'));
  box.appendChild(input);
  return box;
}

// --------------------------------------------------------------------- keys

document.addEventListener('keydown', (event) => {
  if (event.target && event.target.isContentEditable) return;
  if (event.target && event.target.tagName === 'INPUT') return;
  if (event.altKey || event.shiftKey) return;

  if (event.key === 'e' && !event.ctrlKey && !event.metaKey) {
    event.preventDefault();
    setEditing(!editing);
    return;
  }
  if (event.key === 's' && !event.ctrlKey && !event.metaKey) {
    event.preventDefault();
    setSettings(!settingsOpen);
    return;
  }
  if (event.key === 'Escape' && settingsOpen) {
    event.preventDefault();
    setSettings(false);
    return;
  }
  if (event.key === 'Escape' && editing) {
    event.preventDefault();
    setEditing(false);
    return;
  }
  if (editing || !/^[1-9]$/.test(event.key)) return;
  const entry = tiles[Number(event.key) - 1];
  if (!entry) return;
  event.preventDefault();
  open(entry.url, !(event.ctrlKey || event.metaKey));
});

// -------------------------------------------------------------- settings
//
// One page for settings that live in three places: the extension's own storage,
// Noren's config file, and (for the search engine) both, since the browser and
// the CLI each have to turn typed words into a url. The page does not care --
// it asks the worker, and the worker knows who owns what.

let settingsOpen = false;
let justOpened = false;

const SEARCH_PRESETS = [
  { name: 'DuckDuckGo', url: 'https://duckduckgo.com/?q=%s' },
  { name: 'Kagi', url: 'https://kagi.com/search?q=%s' },
  { name: 'Google', url: 'https://www.google.com/search?q=%s' },
  { name: 'Startpage', url: 'https://www.startpage.com/sp/search?query=%s' },
];

async function readPrefs() {
  try {
    const reply = await chrome.runtime.sendMessage({ noren: 'prefs' });
    return (reply && reply.prefs) || null;
  } catch (e) {
    return null;
  }
}

async function readSites() {
  try {
    const reply = await chrome.runtime.sendMessage({ noren: 'sites' });
    return (reply && reply.sites) || [];
  } catch (e) {
    return [];
  }
}

async function siteOp(op, host) {
  try {
    const reply = await chrome.runtime.sendMessage({ noren: 'siteOp', op, host });
    return Boolean(reply && reply.ok);
  } catch (e) {
    return false;
  }
}

async function writePref(name, value) {
  try {
    await chrome.runtime.sendMessage({ noren: 'setPref', name, value });
  } catch (e) {
    // Nothing to do: the next render shows what actually stuck.
  }
}

function settingRow(name, why) {
  const row = el('div', 'setting');
  const what = el('div', 'what');
  what.appendChild(el('div', 'name', name));
  if (why) what.appendChild(el('div', 'why', why));
  row.appendChild(what);
  return row;
}

function toggleRow(name, why, value, onChange) {
  const row = settingRow(name, why);
  const button = el('button', 'switch' + (value ? ' on' : ''));
  button.type = 'button';
  button.setAttribute('role', 'switch');
  button.setAttribute('aria-checked', String(Boolean(value)));
  button.appendChild(el('span', 'knob'));
  button.addEventListener('click', async () => {
    const next = !button.classList.contains('on');
    button.classList.toggle('on', next);
    button.setAttribute('aria-checked', String(next));
    await onChange(next);
  });
  row.appendChild(button);
  return row;
}

function choiceRow(name, why, options, value, onChange) {
  const row = settingRow(name, why);
  const choices = el('div', 'choices');
  for (const option of options) {
    const button = el('button', 'choice' + (option === value ? ' on' : ''), option);
    button.type = 'button';
    button.addEventListener('click', async () => {
      for (const sibling of choices.children) {
        sibling.classList.toggle('on', sibling === button);
      }
      await onChange(option);
    });
    choices.appendChild(button);
  }
  row.appendChild(choices);
  return row;
}

function searchRow(value, onChange) {
  const row = settingRow('Search engine',
    'Where typed words go. %s is where they land.');
  row.classList.add('stacked');

  const line = el('div', 'row');
  const input = document.createElement('input');
  input.className = 'text';
  input.type = 'text';
  input.spellcheck = false;
  input.value = value;
  input.addEventListener('keydown', (event) => {
    event.stopPropagation();
    if (event.key === 'Enter') {
      event.preventDefault();
      input.blur();
    }
  });
  input.addEventListener('blur', () => {
    const wanted = input.value.trim();
    if (wanted && wanted !== value) onChange(wanted);
  });
  line.appendChild(input);
  row.appendChild(line);

  const picks = el('div', 'choices');
  picks.style.marginTop = '10px';
  for (const preset of SEARCH_PRESETS) {
    const button = el('button', 'choice' + (preset.url === value ? ' on' : ''), preset.name);
    button.type = 'button';
    button.addEventListener('click', () => {
      input.value = preset.url;
      onChange(preset.url);
    });
    picks.appendChild(button);
  }
  row.appendChild(picks);
  return row;
}

// What your agent (or you) installed for one site, and nothing more: a script
// that changes a site is invisible until something lists it, and the first one
// written here was reported as installed over a page that looked untouched.
// Listed, switchable, removable -- the source stays in ~/.config/noren/sites,
// which is where it can be read and edited.
function sitesRow(sites, onChange) {
  const row = settingRow('Site scripts',
    'CSS or JS Noren runs on one site. `noren site list` says where the files are.');
  row.classList.add('stacked');

  if (!sites.length) {
    row.appendChild(el('div', 'why',
      'None yet. SUPER + M → A asks your agent to write one for the page you are on.'));
    return row;
  }

  const list = el('div', 'sites');
  for (const site of sites) {
    const line = el('div', 'site');
    const what = el('div', 'what');
    what.appendChild(el('div', 'name', site.host));
    const kinds = (site.kinds || []).join(' + ') || 'nothing';
    const when = String(site.updated || '').replace('T', ' ').slice(0, 16);
    what.appendChild(el('div', 'why', when ? kinds + '  ·  ' + when : kinds));
    line.appendChild(what);

    const button = el('button', 'switch' + (site.enabled ? ' on' : ''));
    button.type = 'button';
    button.setAttribute('role', 'switch');
    button.setAttribute('aria-checked', String(Boolean(site.enabled)));
    button.title = 'Run this script on ' + site.host;
    button.appendChild(el('span', 'knob'));
    button.addEventListener('click', async () => {
      const next = !button.classList.contains('on');
      button.classList.toggle('on', next);
      button.setAttribute('aria-checked', String(next));
      await siteOp(next ? 'on' : 'off', site.host);
      onChange();
    });
    line.appendChild(button);

    // Two presses: this deletes the file, and the switch beside it is the
    // reversible way to stop a script.
    const del = el('button', 'tool danger', '✕');
    del.type = 'button';
    del.title = 'Delete the script for ' + site.host;
    let armed = null;
    del.addEventListener('click', async () => {
      if (!armed) {
        del.textContent = 'Sure?';
        del.classList.add('armed');
        armed = setTimeout(() => {
          armed = null;
          del.textContent = '✕';
          del.classList.remove('armed');
        }, 3000);
        return;
      }
      clearTimeout(armed);
      await siteOp('rm', site.host);
      onChange();
    });
    line.appendChild(del);
    list.appendChild(line);
  }
  row.appendChild(list);
  return row;
}

async function renderSettings() {
  const box = document.getElementById('settings');
  const section = document.getElementById('settings-section');
  section.hidden = !settingsOpen;
  if (!settingsOpen) {
    box.replaceChildren();
    return;
  }

  const [prefs, sites] = await Promise.all([readPrefs(), readSites()]);
  if (!prefs) {
    box.replaceChildren(Object.assign(document.createElement('div'), {
      className: 'why',
      textContent: 'Noren is not answering. Is the browser bridge up? `noren doctor` says.',
    }));
    return;
  }

  // Saved the moment they are changed, like everything else on this page. The
  // pref is re-read afterwards rather than assumed: the CLI validates, and what
  // it accepted is the truth.
  const save = (name) => async (value) => {
    await writePref(name, value);
    if (name === 'search') renderSettings();
  };

  const rows = [
    toggleRow('Tabbed mode',
      'New pages join the group of the page in front, like tabs.',
      prefs.tabbed, save('tabbed')),
    toggleRow('Auto-peel',
      'Every new tab becomes its own chrome-less window.',
      prefs.autoPeel, save('autoPeel')),
    toggleRow('Reveal bar',
      'The toolbar that slides down at the top edge of a page window.',
      prefs.revealBar, save('revealBar')),
    choiceRow('Closing a page',
      'Curtain parts into panels and drops; glass breaks into pieces.',
      ['curtain', 'glass', 'off'], prefs.shatter, save('shatter')),
    choiceRow('Page theming',
      'How far the Omarchy palette reaches into pages.',
      ['respect', 'tint', 'immerse'], prefs.themeMode, save('themeMode')),
    searchRow(prefs.search, save('search')),
    sitesRow(sites, () => renderSettings()),
  ];

  // Each row a beat behind the one above, so the panel fills the way cloth
  // settles rather than appearing all at once.
  rows.forEach((row, i) => {
    row.style.animationDelay = (60 + i * 45) + 'ms';
  });
  box.replaceChildren(...rows);

  // Only when it opens, never on a re-render after a toggle: parting the
  // curtain every time you flip a switch would be seasickness, not juice.
  if (justOpened) {
    justOpened = false;
    box.classList.add('parting');
    const left = el('div', 'curtain left');
    const right = el('div', 'curtain right');
    box.append(left, right);
    const sweep = setTimeout(() => {
      left.remove();
      right.remove();
      box.classList.remove('parting');
    }, 420);
    // A second open before this one finished must not leave a half-drawn
    // curtain behind.
    box.dataset.sweep = String(sweep);
  }
}

function setSettings(on) {
  settingsOpen = on;
  justOpened = on;
  const box = document.getElementById('settings');
  if (box.dataset.sweep) {
    clearTimeout(Number(box.dataset.sweep));
    delete box.dataset.sweep;
    box.classList.remove('parting');
    box.querySelectorAll('.curtain').forEach((half) => half.remove());
  }
  document.getElementById('settings-toggle').textContent = on ? 'Close settings' : 'Settings';
  renderSettings();
}

// --------------------------------------------------------------------- sets

// A set opens in place of the start page, like a tile: the start page is a
// launcher, and leaving it behind a freshly opened group is only clutter.
// Ctrl+click or a middle click opens the set alongside instead.
function openSet(name, event) {
  const alongside = Boolean(event && (event.ctrlKey || event.metaKey || event.button === 1));
  chrome.runtime.sendMessage({ noren: 'openSet', name, replace: !alongside }).catch(() => {});
}
//
// Every edit goes to the CLI through the worker and the host: `noren set put`
// owns the file format and all validation, so the page never writes sets.json
// and cannot disagree with `@name` in the url bar about what a set is. Each edit
// saves at once -- there is no Save button to forget.

// A re-render replaces every input, so one arriving mid-typing (a bookmark
// synced, the tab refocused) would throw away what is being typed.
function typing() {
  const el = document.activeElement;
  return Boolean(el && (el.isContentEditable || el.tagName === 'INPUT'));
}

async function setOp(op, data) {
  try {
    const reply = await chrome.runtime.sendMessage({ noren: 'setOp', op, data });
    return reply || { ok: false, error: 'Noren did not answer' };
  } catch (e) {
    return { ok: false, error: 'Noren is not running' };
  }
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function showError(card, message) {
  const line = card.querySelector('.set-error');
  line.textContent = message || '';
  line.hidden = !message;
}

// Save a changed copy of `set`. On failure the card stays as typed, with the
// CLI's reason under it; on success the page re-reads what was written.
async function putSet(card, set, changes) {
  const next = {
    name: set.name,
    urls: set.urls.slice(),
    grouped: Boolean(set.grouped),
    previous: set.name,
    ...changes,
  };
  const result = await setOp('put', next);
  if (!result.ok) {
    showError(card, result.error);
    return false;
  }
  render();
  return true;
}

function nameInput(value, placeholder) {
  const input = el('input', 'set-name');
  input.type = 'text';
  input.value = value;
  input.placeholder = placeholder;
  input.spellcheck = false;
  input.maxLength = 40;
  return input;
}

function pageInput(placeholder, onAdd) {
  const input = el('input', 'set-add');
  input.type = 'text';
  input.placeholder = placeholder;
  input.spellcheck = false;
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      input.value = '';
      input.blur();
    } else if (event.key === 'Enter' && input.value.trim()) {
      event.preventDefault();
      onAdd(input.value.trim());
    }
  });
  return input;
}

// Which page row is being dragged, within which set.
let rowDrag = null;

function setCard(set) {
  const card = el('div', 'set-card');
  set = { name: set.name, urls: (set.urls || []).slice(), grouped: Boolean(set.grouped) };

  // --- header: name, shape, open, delete
  const head = el('div', 'set-head');
  const name = nameInput(set.name, 'name');
  const commitName = () => {
    const wanted = name.value.trim();
    if (!wanted) {
      name.value = set.name;
      return;
    }
    if (wanted !== set.name) putSet(card, set, { name: wanted });
  };
  name.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      name.blur();
    } else if (event.key === 'Escape') {
      name.value = set.name;
      name.blur();
    }
  });
  name.addEventListener('blur', commitName);
  head.appendChild(el('span', 'set-sigil', '@'));
  head.appendChild(name);

  const shape = el('button', 'tool shape', set.grouped ? 'Group' : 'Tiled');
  shape.type = 'button';
  shape.title = set.grouped
    ? 'Opens as one Hyprland group -- click for tiled windows'
    : 'Opens as tiled windows -- click to open as one group';
  shape.addEventListener('click', () => putSet(card, set, { grouped: !set.grouped }));
  head.appendChild(shape);

  const openBtn = el('button', 'tool', 'Open');
  openBtn.type = 'button';
  openBtn.title = 'Open this set';
  openBtn.addEventListener('click', (event) => {
    openSet(set.name, event);
  });
  head.appendChild(openBtn);

  // Two presses, a few seconds apart at most. A set is quick to rebuild, but
  // it sits next to Open, and a stray click should not cost one.
  const del = el('button', 'tool danger', 'Delete');
  del.type = 'button';
  let armed = null;
  del.addEventListener('click', async () => {
    if (!armed) {
      del.textContent = 'Sure?';
      del.classList.add('armed');
      armed = setTimeout(() => {
        armed = null;
        del.textContent = 'Delete';
        del.classList.remove('armed');
      }, 3000);
      return;
    }
    clearTimeout(armed);
    const result = await setOp('rm', { name: set.name });
    if (result.ok) render();
    else showError(card, result.error);
  });
  head.appendChild(del);
  card.appendChild(head);

  // --- pages, reorderable
  const list = el('ol', 'set-pages');
  set.urls.forEach((url, index) => {
    const row = el('li', 'set-page');
    row.draggable = true;
    row.dataset.index = String(index);

    const icon = el('img');
    icon.src = favicon(url);
    icon.alt = '';
    icon.draggable = false;
    row.appendChild(icon);

    const label = el('span', 'set-url', url.replace(/^https?:\/\/(www\.)?/, '').replace(/\/$/, ''));
    label.title = url;
    row.appendChild(label);

    const remove = el('button', 'tool', '×');
    remove.type = 'button';
    remove.title = 'Remove this page from the set';
    remove.addEventListener('click', () => {
      if (set.urls.length === 1) {
        showError(card, 'A set needs at least one page -- delete the set instead.');
        return;
      }
      putSet(card, set, { urls: set.urls.filter((_, i) => i !== index) });
    });
    row.appendChild(remove);

    row.addEventListener('dragstart', (event) => {
      rowDrag = { name: set.name, from: index };
      event.dataTransfer.effectAllowed = 'move';
      row.classList.add('dragging');
    });
    row.addEventListener('dragend', () => {
      rowDrag = null;
      row.classList.remove('dragging');
    });
    row.addEventListener('dragover', (event) => {
      if (!rowDrag || rowDrag.name !== set.name) return;
      event.preventDefault();
    });
    row.addEventListener('drop', (event) => {
      if (!rowDrag || rowDrag.name !== set.name) return;
      event.preventDefault();
      const box = row.getBoundingClientRect();
      let to = event.clientY > box.top + box.height / 2 ? index + 1 : index;
      const from = rowDrag.from;
      rowDrag = null;
      // Positions are measured with the dragged row still in the list; take it
      // out first, then the insertion point shifts left if it was before.
      if (to > from) to -= 1;
      if (to === from) return;
      const urls = set.urls.slice();
      const [moved] = urls.splice(from, 1);
      urls.splice(to, 0, moved);
      putSet(card, set, { urls });
    });
    list.appendChild(row);
  });
  card.appendChild(list);

  card.appendChild(
    pageInput('+ add a page', (value) => putSet(card, set, { urls: set.urls.concat(value) })),
  );

  const error = el('div', 'set-error');
  error.hidden = true;
  card.appendChild(error);
  return card;
}

// Two ways to make one: name it and add a first page, or name what is open.
function newSetCard() {
  const card = el('div', 'set-card new');
  card.appendChild(el('div', 'set-title', 'New set'));

  const name = nameInput('', 'name');
  const nameRow = el('div', 'set-head');
  nameRow.appendChild(el('span', 'set-sigil', '@'));
  nameRow.appendChild(name);
  card.appendChild(nameRow);

  const create = async (url) => {
    const wanted = name.value.trim();
    if (!wanted) {
      showError(card, 'Give it a name first.');
      name.focus();
      return;
    }
    const result = await setOp('put', { name: wanted, urls: [url], grouped: false });
    if (result.ok) render();
    else showError(card, result.error);
  };
  card.appendChild(pageInput('first page, then Enter', create));

  const save = el('button', 'link', 'or save the pages open right now');
  save.type = 'button';
  save.addEventListener('click', async () => {
    const wanted = name.value.trim();
    if (!wanted) {
      showError(card, 'Give it a name first.');
      name.focus();
      return;
    }
    save.disabled = true;
    const result = await setOp('save', { name: wanted });
    save.disabled = false;
    if (result.ok) render();
    else showError(card, result.error);
  });
  card.appendChild(save);

  const error = el('div', 'set-error');
  error.hidden = true;
  card.appendChild(error);
  return card;
}

// --------------------------------------------------------------------- data

async function placeEntries() {
  // The worker ranks these, so the start page and the empty url bar always
  // show the same places in the same order.
  try {
    const reply = await chrome.runtime.sendMessage({ noren: 'places' });
    return {
      bar: (reply && reply.bar) || [],
      top: (reply && reply.top) || [],
      hidden: (reply && reply.hidden) || 0,
    };
  } catch (e) {
    return { bar: [], top: [], hidden: 0 };
  }
}

async function setEntries() {
  try {
    const reply = await chrome.runtime.sendMessage({ noren: 'sets' });
    return (reply && reply.sets) || [];
  } catch (e) {
    return [];
  }
}

// Renders can overlap -- an edit, then the bookmarks event it causes. Only the
// newest one may write to the page, or a stale list flashes back in.
let renderSeq = 0;

async function render() {
  const seq = ++renderSeq;
  const [{ bar, top, hidden }, sets] = await Promise.all([placeEntries(), setEntries()]);
  if (seq !== renderSeq) return;
  hiddenCount = hidden;

  tiles.length = 0;

  const barGrid = document.getElementById('bar');
  const barTiles = bar.map((entry, i) => tile(entry, 'bar', i));
  if (editing) barTiles.push(addTile());
  barGrid.replaceChildren(...barTiles);
  // In edit mode Pinned always shows: it is where things get dragged to.
  document.getElementById('bar-section').hidden = bar.length === 0 && !editing;
  document.getElementById('bar-hint').hidden = !(editing && bar.length === 0);

  // Collapsed means not rendered at all, not merely invisible: the tiles stay
  // out of the DOM and out of the number keys.
  const topGrid = document.getElementById('top');
  // One row: the worker ranks more than that for the url bar's longer list.
  const row = top.slice(0, 6);
  topGrid.replaceChildren(...(topOpen ? row.map((entry) => tile(entry, 'top')) : []));
  topGrid.hidden = !topOpen;
  const toggle = document.getElementById('top-toggle');
  toggle.setAttribute('aria-expanded', String(topOpen));
  toggle.classList.toggle('open', topOpen);
  document.getElementById('top-section').hidden = top.length === 0;

  const reset = document.getElementById('unhide');
  reset.hidden = !(editing && hiddenCount > 0);
  reset.textContent = 'Show ' + hiddenCount + ' hidden';

  const setsBox = document.getElementById('sets');
  setsBox.classList.toggle('chips', !editing);
  setsBox.classList.toggle('set-editor', editing);
  if (editing) {
    setsBox.replaceChildren(...sets.map(setCard), newSetCard());
  } else {
    setsBox.replaceChildren(
      ...sets.map((set) => {
        const b = document.createElement('button');
        b.className = 'chip';
        b.textContent = '@' + set.name;
        const count = document.createElement('span');
        count.className = 'count';
        count.textContent = String((set.urls || []).length);
        b.appendChild(count);
        b.title = (set.urls || []).map(hostOf).join('  ');
        b.addEventListener('click', (event) => openSet(set.name, event));
        b.addEventListener('auxclick', (event) => {
          if (event.button === 1) openSet(set.name, event);
        });
        return b;
      }),
    );
  }
  // In edit mode Sets always shows: it is where a new one gets made.
  document.getElementById('sets-section').hidden = sets.length === 0 && !editing;
  document.getElementById('empty').hidden = editing || bar.length + top.length + sets.length > 0;
}

document.getElementById('edit').addEventListener('click', () => setEditing(!editing));
document.getElementById('settings-toggle')
  .addEventListener('click', () => setSettings(!settingsOpen));
document.getElementById('top-toggle').addEventListener('click', () => {
  topOpen = !topOpen;
  render();
});
document.getElementById('unhide').addEventListener('click', async () => {
  await chrome.runtime.sendMessage({ noren: 'unhideAll' }).catch(() => {});
  render();
});
wireBarDrops();
// `start.html#edit` opens straight into edit mode.
if (location.hash === '#edit') setEditing(true);
else render();

// The bar can change from elsewhere -- a tabbed window's bar, `D` in the radial,
// sync. Follow it rather than going stale until the next visit.
for (const event of ['onCreated', 'onRemoved', 'onChanged', 'onMoved']) {
  chrome.bookmarks[event].addListener(() => {
    if (typing()) return;
    render();
  });
}

// Coming back to the page after a while should not show this morning's list.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') render();
});

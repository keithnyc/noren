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

const ROLE_VARS = ['bg', 'fg', 'surface', 'surface-2', 'border', 'muted', 'accent', 'danger'];

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

function tick() {
  const now = new Date();
  document.getElementById('clock').textContent = now.toLocaleTimeString([], {
    hour: 'numeric',
    minute: '2-digit',
  });
  document.getElementById('date').textContent = now.toLocaleDateString([], {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
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

  document.getElementById('top').replaceChildren(...top.map((entry) => tile(entry, 'top')));
  document.getElementById('top-section').hidden = top.length === 0;

  const reset = document.getElementById('unhide');
  reset.hidden = !(editing && hiddenCount > 0);
  reset.textContent = 'Show ' + hiddenCount + ' hidden';

  const chips = document.getElementById('sets');
  chips.replaceChildren(
    ...sets.map((set) => {
      const b = document.createElement('button');
      b.className = 'chip';
      b.textContent = '@' + set.name;
      const count = document.createElement('span');
      count.className = 'count';
      count.textContent = String((set.urls || []).length);
      b.appendChild(count);
      b.title = (set.urls || []).map(hostOf).join('  ');
      b.addEventListener('click', () => {
        chrome.runtime.sendMessage({ noren: 'openSet', name: set.name }).catch(() => {});
      });
      return b;
    }),
  );
  document.getElementById('sets-section').hidden = sets.length === 0;
  document.getElementById('empty').hidden = editing || bar.length + top.length + sets.length > 0;
}

document.getElementById('edit').addEventListener('click', () => setEditing(!editing));
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
    // Mid-rename, a re-render would throw away what is being typed.
    if (document.activeElement && document.activeElement.isContentEditable) return;
    render();
  });
}

// Coming back to the page after a while should not show this morning's list.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') render();
});

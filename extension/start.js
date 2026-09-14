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

// --------------------------------------------------------------------- sets
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
  openBtn.addEventListener('click', () => {
    chrome.runtime.sendMessage({ noren: 'openSet', name: set.name }).catch(() => {});
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
        b.addEventListener('click', () => {
          chrome.runtime.sendMessage({ noren: 'openSet', name: set.name }).catch(() => {});
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

# Noren 暖簾

> The split curtain hung at a shop door. You part it to go through.

An Omarchy plugin that drives Chromium from the shell. Every page can be its own
chrome-less Hyprland window; navigation, tab search and browser state live in
Omarchy rather than in browser furniture.

## Trying Noren

**With an agent:** point Claude (or any coding agent) at this repository and ask
it to install Noren. [`INSTALL.md`](INSTALL.md) is written for it — the agent
runs the steps and asks you before touching your browser, your shell or your
key bindings.

**By hand**, on Omarchy with Chromium as the default browser:

```bash
omarchy plugin add https://github.com/keithnyc/noren.git --enable
~/.config/omarchy/plugins/io.github.keithnyc.noren/install.sh
```

Then turn on **Developer mode** in `chrome://extensions`, quit and restart the
browser, run `omarchy-restart-shell`, add the key bindings from
`install.sh --print-binds` to `~/.config/hypr/bindings.lua`, and check with
`noren doctor`. [`INSTALL.md`](INSTALL.md) has each step, and how to update and
remove.

First things to try: `SUPER + B` and a url · `SUPER + M` then `H` for the start
page · `noren peel on` to make every new tab its own window.

Noren is early. Expect rough edges, and `noren doctor` when something is off.

## What it does today

- **URL bar as an Omarchy overlay** — `SUPER+B` parts the curtain. Type anything
  to filter your open tabs and jump to one, or type a URL and press Enter.

  **Enter always opens a new tiled window.** Never navigates what's behind the
  overlay. A launcher that sometimes mutates the window behind it is a launcher
  you can't trust, and the surprise lands exactly when you're moving fast.

  **Ctrl+Enter redirects the chrome-less window on this workspace**, and the
  footer names the window it would replace. This matters more than in a normal
  browser: a chrome-less window has no address bar, so the overlay is the *only*
  way to point one somewhere else. When there's no page on this workspace the
  hint greys out rather than silently doing nothing.
- **Bar widget** — shows the focused page's title, load state, and whether the
  browser is running at all. Left click opens the URL bar, right click reloads.
- **CLI** — `noren goto`, `go`, `open`, `back`, `forward`, `reload`, `tabs`,
  `focus`, `peel`, `theme`, `status`, `doctor`. Bindable from Hyprland,
  scriptable from anywhere.
- **Auto-peel (off by default)** — `noren peel on` makes every new tab open as
  its own window instead. This is the experiment; see below.
- **Page theming (tint by default)** — web pages follow the active Omarchy
  theme, live. See below.
- **Several urls at once** — type `social.example, search.example, video.example` and Enter opens
  three tiled windows; Ctrl+Enter opens them and folds them into one Hyprland
  group. The comma only separates when every part is a destination, so
  `bread, butter recipe` is still a search.
- **Url completion** — the overlay completes from open tabs, bookmarks and
  history, ranked together, and **works with the browser closed** by reading
  Chromium's own profile. A typed url stays literal until you arrow onto a
  suggestion. A leading sigil narrows the search: `*` bookmarks, `%` history,
  `#` open tabs — and `*` alone lists your bookmarks.
- **Bookmarks** — `D` in the radial (or `noren save`) bookmarks the page in
  front of you. A chrome-less window has no Ctrl+D and cannot host
  `chrome://bookmarks`, so without this a bookmark could only be read, never
  made. It saves silently to the default folder and will not duplicate a page
  you have already saved.
- **Radial menu** — `SUPER + M` rings back, forward, reload, copy, url bar,
  peel, gather and theme around the page in front of you. A chrome-less window
  has no toolbar, so these have nowhere else to live. Every item carries a
  mnemonic letter (`B` `F` `R` `C` `D` `U` `V` `P` `G` `O` `S` `T`) shown on the item, so the
  ring can be summoned and used in one gesture without reaching for arrows.

Back, forward and reload already work in a chrome-less window via Chromium's own
`Alt+←` / `Alt+→` / `Ctrl+R`. The CLI versions exist so you can bind them to
whatever keys you prefer.

## Architecture

```
overlay  ─ UrlBar.qml      url entry, tab search      ┐
service  ─ Service.qml     browser state + IpcHandler ├─ io.github.keithnyc.noren
widget   ─ BarWidget.qml   title, load state          ┘
                    ▲
                    │  omarchy-shell -q io.github.keithnyc.noren setState '{...}'
                    │
         host/noren-host   python, two protocols:
                    │        stdin/stdout  ↔ Chromium native messaging
                    │        unix socket   ↔ bin/noren and the shell
                    ▲
                    │  4-byte LE length + JSON
                    │
       extension/background-3.js    chrome.tabs.* , onCreated, onUpdated
                    ▲
                    ▼
              chromium --app windows
```

The host is started and owned by Chromium. It exits when Chromium does, and the
socket at `$XDG_RUNTIME_DIR/noren.sock` disappears with it — so
`noren ping` failing means the browser isn't running, not that something broke.

`goto` and `open` still work with the browser closed: they fall back to
`omarchy-launch-webapp`, which starts it. The extension then comes up and the
bridge with it. Everything else needs a live bridge, because it needs to ask the
browser something.

## Install

```bash
./install.sh                          # into your default browser
./install.sh --browser chromium       # or a specific one
./install.sh --remove                 # undo, everywhere
```

Then restart that browser completely, and `omarchy-restart-shell`.

### Developer Mode is required

Since Chromium M137, an unpacked extension loaded with `--load-extension` is
**disabled on load** unless Developer Mode is on. Nothing says so: not the UI,
not stderr. The only trace is in the profile's `Preferences`, as
`disable_reasons: [16777216]` — that is `1 << 24`,
`DISABLE_UNSUPPORTED_DEVELOPER_EXTENSION`.

So: `chrome://extensions` → **Developer mode** on.

Omarchy's own bundled extensions predate the restriction and were grandfathered
in, which is why they run without it and Noren does not.

`./bin/noren doctor` decodes this and every other failure in the chain.

The installer targets **one** browser — whichever `xdg-settings get
default-web-browser` reports, the same source `omarchy-launch-webapp` uses. That
matters: `noren open` spawns windows in the *default* browser, so if the
extension lives somewhere else those windows are invisible to Noren. Installing
also clears Noren out of any other browser, because the native host owns a
single socket and two instrumented browsers would fight over it.

Rather than hardcoding paths, it reads the browser's launcher script for
`USER_FLAGS_FILE` and `CHROME_USER_DATA_DIR`, which is how the Chromium-family
wrappers on Arch declare both facts.

It backs up the flags file to `.noren-backup` and appends to any existing
`--load-extension` list rather than replacing it — Omarchy ships three
extensions on that line.

### Brave: one flag per file

Brave's launcher ends with:

```bash
exec ".../brave-origin" "$USER_FLAGS" "$BRAVE_FLAGS" "$FLAG" "$@"
```

`"$USER_FLAGS"` is quoted, so the **entire flags file arrives as a single
argument**. One line works. Two or more lines reach the browser as one malformed
switch and every flag in the file is silently ignored — no error, nothing in
`chrome://version`.

So `brave-origin-beta-flags.conf` must stay at one line. If you need more flags,
put them in the `.desktop` Exec instead. The installer warns if it sees this.

This is also why `brave-flags.conf` on this machine lists four flags that never
reach Brave, including Omarchy's own three bundled extensions. Worth an upstream
issue.

### Hyprland binds

Recent Omarchy configures Hyprland in **Lua**, not `.conf`. In
`~/.config/hypr/bindings.lua`:

`./install.sh --print-binds` prints the suggested block — url bar, radial
menu, and next/previous page in a group:

```lua
o.bind("SUPER + B", "Noren url bar", [[omarchy-shell shell toggle io.github.keithnyc.noren '{}']])
o.bind("SUPER + M", "Noren radial menu", [[omarchy-shell shell toggle io.github.keithnyc.noren '{"mode":"radial"}']])
o.bind("SUPER + BRACKETRIGHT", "Next window in group", hl.dsp.group.next())
o.bind("SUPER + BRACKETLEFT", "Previous window in group", hl.dsp.group.prev())
```

`SUPER + B` because `SUPER + L` is the tiling layout toggle. Back and forward are
in the radial rather than on keys: `SUPER + ALT + LEFT/RIGHT`, the obvious pair,
already move a window into a group in stock Omarchy. Check what's free with
`omarchy menu keybindings --print`, then `hyprctl reload`.

## The experiment

`noren peel on` turns on tabs-as-windows: `chrome.tabs.onCreated` fires, the URL
goes to the host, the host spawns the browser binary with `--app=`, and the
originating tab closes. Only tabs in `type === "normal"` windows are peeled — an
app window holds exactly one tab and that tab *is* the peeled result, so peeling
it again would destroy every window Noren creates. Hyprland does the rest — grouping is your tab bar,
`changegroupactive` is tab switching.

Two things to watch for, because they are the only real case for ever forking
Chromium:

1. **The flash.** The tab exists briefly before it's moved out. Visible on every
   link click.
2. **The origin strip.** Navigate cross-origin inside an `--app` window and
   Chromium draws a small security bar at the top.

Live with it for a week before deciding anything.

## Per-site window rules

Chromium ignores `--class` for app windows on Wayland. It assigns the `app_id`
itself, from the URL and profile:

```
chrome-<host><path, / replaced by _>-<profile>
chrome-news.example.com__-Default
```

So per-site identity is free — you just don't get to pick the name. Match on it
in Hyprland directly:

```
windowrule = workspace 5, class:^chrome-video\.example.*$
windowrule = float, class:^chrome-.*$
windowrule = size 1280 720, class:^chrome-meet\.google\.com.*$
```

`hyprctl clients` shows the exact `app_id` for any open window.

## Page theming

Web pages follow the active Omarchy theme. Three modes, set with `noren theme`:

| mode | what it does |
|---|---|
| `respect` | leave pages exactly as their authors built them |
| `tint` | paint the canvas, selection, scrollbars and form accents (default) |
| `immerse` | remap the site's own surfaces and text onto the theme |

`tint` is the default because the canvas is the one surface no site owns: between
pages the browser paints its own base colour, and on a dark desktop that white
frame is the most jarring thing about browsing. Setting `color-scheme` from the
palette also hands scrollbars and form controls to the theme for free.

Colours are **contrast-corrected per theme**. Palette hues that read fine as
terminal text often fail WCAG AA against the same theme's page background — 90 of
434 role/background pairs across the 62 themes installed here, and 37 of 91 in
light themes. Noren solves lightness against the actual background, holding hue
and chroma, so `catppuccin-latte` green goes from 2.96:1 to 4.50:1 and is still
green. 344 of 434 colours come through untouched.

`immerse` is not a stylesheet — a stylesheet cannot reach a card that paints
itself white, because `background-color` does not inherit. It walks the page,
reads each element's computed colours, and remaps the site's *neutrals* onto the
theme while leaving anything with real chroma alone, so brand colours, badges,
avatars, charts and syntax highlighting keep meaning what they mean. Elevation
and text hierarchy are preserved by keeping each colour's distance from the
page's own background.

It has limits worth knowing: inline styles are dropped by a framework re-render
until that subtree changes again, hover backgrounds freeze on remapped elements,
and shadow DOM and cross-origin iframes are not reached.

The theme switches live: the host watches `colors.toml` and re-pushes on every
`omarchy-theme-set`.

A theme can override the result by shipping `noren.css` in its theme directory
(or rendering one from a template in `~/.config/omarchy/themed/`). It replaces
the generated rules and still gets the `--noren-*` variables.

## Tabbed mode

Tabs, when you want them, without arranging anything:

```bash
noren tabbed on     # every new page joins the group of the page in front
noren tabbed off    # back to a window of its own
noren tabbed        # report
```

Or **`J`** in the radial, which shows whether it is on. With it on, a page
opened from a page — the url bar, a tile, a link that peels — folds into that
page's group, making a group of the two if there was not one. The group bar is
the tab strip, so `SUPER + ]` / `SUPER + [` step through them.

Nothing else changes: `--tiled` opts a single `noren open` out, sets still open
in the shape they were saved, and the page in front is only ever joined when it
is the focused window — never a group you are not looking at.

## Sets

Pages you open together, named. Defining one requires typing no urls at all —
arrange the windows you want, then name what is already there:

From the overlay — `SUPER + B`, then `@`:

| you type | you get |
|---|---|
| `@` | your sets, with their page count, shape and hosts |
| `@news` (no such set) | a **save** row — Enter names the open pages `news` |
| `@news` (exists) | the set first, and a **replace** row below it |

A matching set stays first so Enter opens rather than overwrites; replacing is a
deliberate arrow-down. **Shift+Delete** on a highlighted set removes it — the
same gesture Chromium's omnibox uses to drop a suggestion. The footer says which
keys apply to whatever row is highlighted.

The same from the CLI:

```bash
noren set save news        # names the chrome-less windows open right now
noren set preview          # what a save would capture
noren set list             # what you have
noren set open news        # opens them, in the shape they were saved
noren set rm news
```

A set remembers whether it was a **group** when you saved it and comes back that
way, so `gather` your reading into one group, save it, and it reopens as one
group. The shape is part of what you saved.

A set also turns up when you simply type its name, so you do not have to know
the sigil exists.

**Where you open a set decides what happens to the page you were on:**

| opened from | click / Enter | Ctrl+click / Ctrl+Enter |
|---|---|---|
| start page | replaces the start page | opens alongside |
| reveal bar menu | replaces the page you are on | opens alongside |
| url bar (`@name`) | opens alongside | replaces the page in front |

Replacing turns that window into the set's first page, and a grouped set folds
the rest into it — nothing is left behind. If the page in front is already in a
group, a set opens alongside instead, so it never pours into an unrelated group.
From the CLI: `noren set open news --replace`.

Or manage them on the **start page**: press `E` and each set becomes a card.
Rename it in place, flip it between **Group** and **Tiled**, drag its pages into
order, remove one with `×`, add one by typing it, or delete the set (two clicks).
The **New set** card makes one from a name and a first page, or from the pages
open right now. Every edit saves immediately, through `noren set put`:

```bash
echo '{"name":"reading","urls":["news.example.com"],"grouped":true}' | noren set put
echo '{"name":"morning","previous":"reading","urls":["news.example.com"]}' | noren set put
```

## Start page

A tabbed browser shows you where you might go before you have decided — the
bookmarks bar is just there. A chrome-less window has no bar, so Noren gives the
guide back as a page:

```bash
noren start         # the page in front of you goes home to the start page
noren start --new   # a start page in a new window
```

Or `H` in the radial, which works like a browser's Home button. With no page in
front of you — a terminal, the desktop — it opens a start page instead, or raises
the one already open. It shows a clock, your **bookmarks bar** in its own order,
your **most visited** sites over the last month (one row of six, one tile per
site, ranked from history), and your **sets**. Most visited starts **collapsed**
on every load, for privacy — click its heading to open it.

It sits on your **desktop background**, blurred behind frosted tiles, and
follows it when you change backgrounds or themes. Each tile lights up in its
own site's colour when you hover it, leaning slightly toward the pointer. A
greeting and a faint light move through the day — warm at dawn and dusk, cool
at night — in your theme's colours. Motion is off if your system asks for
reduced motion. It repaints
with the Omarchy theme, live.

A **click opens the site in the same window**, the way a new-tab page does.
**Ctrl+click** (or a middle click) opens it as a new window and leaves the start
page where it is. `1`–`9` open tiles by number, with Ctrl for a new window.

The url bar does the same before you type anything: `SUPER + B` on an empty
query leads with **Start page** — so `SUPER + B`, Enter is always the way home,
even with no page open (Enter raises or opens it; Ctrl+Enter turns the page in
front into it) — then the bookmarks bar, most visited, sets, and everything
else open. A place that is already open shows as its tab, so Enter jumps to it
rather than opening a second copy. With the browser closed the list comes from
Chromium's profile on disk.

**Editing** — `E`, or Edit at the bottom. Pinned tiles are your bookmarks bar:
drag to reorder, click a title to rename, `×` to unpin, and the `+ add a site`
tile pins something new. A most-visited tile gets **Pin**, or `×` to hide it;
you can also drag it straight into Pinned at the spot you want. Hidden sites
come back with "Show N hidden". Esc when you are done.

Because pinned *is* the bookmarks bar, what you arrange here is what a tabbed
window's bar shows, and it syncs like any bookmark.

Your bookmarks bar is Chromium's. If it lives in another browser today, export
it there and import it through `chrome://settings/importData` in a tabbed
window.

## Reveal bar

A chrome-less window has no toolbar, so each one gets a bar that stays out of
sight: **rest the pointer on the window's top edge** and it slides down over the
page — back, forward, reload, the address with its favicon, your pinned sites,
and home. Click the
address to change it (it opens the url bar, where Ctrl+Enter redirects this
window). Move away, or press Esc, and it goes. A **tab strip** rides under the bar: every page in the group, with its favicon,
the one you are on highlighted, and a click to switch. Scatter the group and the
strip stays, showing the other pages on that workspace in a quieter style —
dashed, unfilled — because they are windows side by side rather than tabs, and
that is exactly when they are spread out and worth switching between. It follows
Hyprland live: gathering, scattering, opening or closing a page redraws it.

Pinning the bar pins it in **every** window, including ones opened later, and it
survives a browser restart. Hyprland's own group bar is 22px of translucent grey that Omarchy does
not use by default, so a new user has no reason to look at it; this says what is
in the group on the page itself, in your theme's colours.

The **bookmark** button drops down your pinned sites (the bookmarks bar) and
your sets: click a site to go there in this window (Ctrl+click or middle-click
for a new window), click a set to open it, or **Edit pins and sets…** to open the
start page in edit mode. The **pin** button keeps it down
on that window — across navigations, until you unpin it or quit the browser.
A pinned bar still floats over the top of the page rather than pushing it down.

```bash
noren bar          # show or hide it on the page in front of you (bindable)
noren bar off      # no reveal bar at all; `noren bar on` brings it back
```

It floats over the page rather than pushing it down, so it never breaks a
site's layout, and it hides during fullscreen. It appears only in Noren's
chrome-less windows — never in a tabbed window, which has a toolbar of its own —
and not on Chromium's own pages (`chrome://`, the Web Store), where extensions
cannot run. Pages open before the extension loaded get it on their next reload.

## Window identity

Omarchy's webapp launchers carry an icon but no `StartupWMClass`, so the window
that opens has app_id `chrome-app.example.com__-Default` and nothing connects it back
to `Example.desktop` — no name, no icon in alt-tab or the launcher. Noren knows the
app_id rule, so it can supply the missing key:

```bash
noren apps              # what each launcher is, and whether its id is confirmed
noren apps adopt        # give them their identity
noren apps revert       # undo — removes only the value Noren would have written
```

The id is a *prediction* until that app has been opened once; `noren apps` then
confirms it against the live window. `--class` is ignored on Wayland, so there is
no way to choose the name — only to predict it correctly.

## Overview

`V` in the radial lays out every page on the workspace in depth — live captures,
cover-flow style. Arrow keys, the scroll wheel, number keys or a click pick one;
**Shift+Delete** closes the highlighted page. It works on a group *or* on loose
windows, so it is a page switcher first and a group view second.

The selected page is sharp and the rest fall out of focus — depth of field on
the cards, not a shadow, so the depth is real rather than drawn.

This works because a *hidden* Hyprland group member can still be screencopied:
measured, an inactive member reports `hasContent` with full window dimensions.
That is why there is no frame caching here and no compositor plugin — it is a
Quickshell overlay like the rest of Noren, built on `HyprlandToplevel`, which
carries both Hyprland's address and the Wayland toplevel a `ScreencopyView` can
capture.

## Gather

`peel` scatters; `noren gather` brings them back. It pulls every chrome-less
window into one Hyprland group on the current workspace, so the compositor's
group bar becomes the tab strip and `hl.dsp.group.active` switches tabs.

```bash
noren gather              # every chrome-less window
noren gather github       # only those matching a host or title
noren pop                 # lift just the window in front of you back out
noren scatter             # break the focused group apart again
```

A group is a single tiled node in Hyprland's layout, so a popped-out window
tiles beside the group rather than replacing it.

It only touches `chrome-<host>-<profile>` windows, never an ordinary tabbed
window, and it confirms each move against Hyprland rather than assuming —
`into_group` takes a direction, not a target, so it tries each and checks.

## Optional: fade between tabs

Omarchy disables Hyprland's `fadeSwitch`, so changing the active window in a
group swaps instantly — and with tabs-as-windows, that swap is a tab change.
Noren does not touch this: animations are global, and a browser plugin should
not restyle your compositor. If you want the crossfade, put it in your own
`~/.config/hypr/looknfeel.lua`:

```lua
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 2.6, bezier = "almostLinear" })
```

## Not done yet

Per-site theming modes, deeper immerse, workspace sessions, per-site window
rules, peel history preservation.

## Development

```bash
omarchy-plugin-validate .     # manifest against the shell's schema
omarchy-restart-shell         # reload QML — not rescan
```

**Three separate reload paths, and forgetting one wastes a debugging round:**

| changed | needs |
|---|---|
| `*.qml` | `omarchy-restart-shell` |
| `host/noren-host` | cycle the host (kill it; the extension reconnects) |
| `extension/*.js` | bump the filename, restart the browser, **and** Reload in `chrome://extensions` |

Changing the background script requires bumping its filename (currently
`background-3.js`; rename it and update `extension/manifest.json`). Chromium caches service
workers for extensions loaded via `--load-extension`, so a new URL is what forces
new code to register. This is the same reason Omarchy's own `copy-url` extension
ships as `background-4.js`.

`host/noren-extension.pem` is the key that pins the extension ID. Keep it — the
native host manifest's `allowed_origins` is derived from it, and regenerating it
changes the ID and breaks the pairing.

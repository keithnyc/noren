# Noren 暖簾

> The split curtain hung at a shop door. You part it to go through.

An Omarchy plugin that drives Chromium from the shell. Every page can be its own
chrome-less Hyprland window; navigation, tab search and browser state live in
Omarchy rather than in browser furniture.

This is a v1 skeleton — the bridge is real and working, the feature set is
deliberately small.

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

```lua
o.bind("SUPER + B", "Noren url bar", [[omarchy-shell shell toggle io.github.keithnyc.noren '{}']])
o.bind("SUPER + ALT + Left",  "Noren back",    [[~/omarchy-help/noren/bin/noren back]])
o.bind("SUPER + ALT + Right", "Noren forward", [[~/omarchy-help/noren/bin/noren forward]])
```

`SUPER + B` because `SUPER + L` is the tiling layout toggle. Check what's free
with `omarchy menu keybindings --print`, then `hyprctl reload`.

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

## Gather

`peel` scatters; `noren gather` brings them back. It pulls every chrome-less
window into one Hyprland group on the current workspace, so the compositor's
group bar becomes the tab strip and `hl.dsp.group.active` switches tabs.

```bash
noren gather              # every chrome-less window
noren gather github       # only those matching a host or title
noren scatter             # break the focused group apart again
```

It only touches `chrome-<host>-<profile>` windows, never an ordinary tabbed
window, and it confirms each move against Hyprland rather than assuming —
`into_group` takes a direction, not a target, so it tries each and checks.

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

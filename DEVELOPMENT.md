# Noren developer handoff

Architecture, design decisions, and the environment facts behind the Noren v1
build. First stop for future development sessions.

Built 2026-09-11 in a single session. Everything below was verified on
devbox against Chromium 152.0.7977.82 and Omarchy `quattro` — the numbers
and behaviours are measured, not assumed.

## What this is

An Omarchy plugin that drives a Chromium-family browser from the shell, so that
navigation, tab search, and browser state live in Omarchy rather than in browser
furniture. Every page can be its own chrome-less Hyprland window.

Named for 暖簾 — the split curtain at a Japanese shop door, made of panels you
part to go through. Chosen after "Quantum" turned out to be Firefox's engine
project; the shortlist came from the *omakase* root of "Omarchy". `shoji` was
killed by ShojiWM (621★, an actual window manager).

## The premise under test

**Tabs-as-windows.** Every page is a real Hyprland window; the compositor's
group bar is the tab bar; `changegroupactive` is tab switching. `noren peel on`
turns it on, off by default.

Nobody has shipped this at Chromium scale. Whether it *feels* good after a week
of real use is the only genuine unknown in the project — everything else is
elaboration on it. Two things to watch, because they are the only real argument
for ever forking Chromium:

1. **The flash.** A peeled tab exists briefly before it is moved out. Visible on
   every link click.
2. **The origin strip.** Navigating cross-origin inside an `--app` window makes
   Chromium draw a small security bar at the top.

**Do not fork Chromium.** Multi-hour builds plus a security-patch treadmill that
never ends, for a solo project. Only the two items above, `chrome://` page
access, and restyling Chromium-drawn UI would need it. If the flash proves
intolerable, drop tabs-as-windows — do not pick up Chromium.

## Architecture

```
overlay  ─ UrlBar.qml      url entry, tab search      ┐
service  ─ Service.qml     browser state + IpcHandler ├─ io.github.keithnyc.noren
widget   ─ BarWidget.qml   title, load state          ┘
                    ▲
                    │  omarchy-shell -q io.github.keithnyc.noren setState '{...}'
                    │
         host/noren-host   python, two protocols:
                    │        stdin/stdout  ↔ native messaging (4-byte LE + JSON)
                    │        unix socket   ↔ bin/noren and the shell
                    │
         host/noren_theme.py   omarchy palette → page CSS, contrast-solved
                    ▲
       extension/background-N.js    chrome.tabs.*, onCreated, onUpdated
                    ▲
                    ▼
              browser --app windows
```

The host is spawned by the browser via native messaging and dies with it. The
socket at `$XDG_RUNTIME_DIR/noren.sock` appears and disappears with the host.

**No tabbed browser window is required.** The extension is a background service
worker owned by the browser *process*, not any window — a single chrome-less
`--app` window keeps the whole chain alive. Verified: one app window, zero tabbed
windows, `noren tabs` still answers.

`goto` and `open` additionally work with the browser **closed**: they fall back
to `omarchy-launch-webapp`, which starts it, and the bridge follows. So the first
`SUPER+B` → Enter of the day bootstraps everything.

## Design decisions, and why

**Enter always opens a new tiled window. Ctrl+Enter replaces the chrome-less
window on this workspace.** An earlier build made Enter context-aware — navigate
if a page is in front of you, else open a window. It was rejected in testing:
typing `search.example` then `other.example` silently replaced the search page instead of opening a
second window. A launcher that sometimes mutates the window behind it is a
launcher you cannot trust.

Ctrl+Enter still has to be *reachable*, not buried, because a chrome-less window
has no address bar — this overlay is the only way to point one somewhere else.
The footer names the window it would replace, and greys out when there is none.

**`peel on` persists in `chrome.storage.local`.** The flag started as a plain
service-worker variable, which reverts to off whenever Chromium tears the worker
down — always when the last window closes, and whenever it decides the worker is
idle. A setting that silently resets is indistinguishable from a broken feature,
and it made the week-long tabs-as-windows trial unmeasurable. Every read awaits
the stored value first (`autoPeelReady`), because the worker starts handling
`onCreated` before storage resolves and a tab created in that window would
otherwise be judged against the default. The extension carries the flag on its
state pushes so `noren status` and `noren peel status` can report it without a
round trip. This is what the `storage` permission is for.

**Page theming is generated in the host, not by a template.** Omarchy's
template renderer (`omarchy-theme-set-templates`) is pure `sed`: it substitutes
values and can `mix` two of them, but it cannot branch and cannot solve. Mapping
palette hues onto semantic roles needs both, because a palette colour that reads
fine as terminal text routinely fails WCAG AA against the same theme's page
background. Measured across the 62 themes installed here, **90 of 434
role/background pairs fail 4.5:1 untouched — 37 of 91 in light themes.**

It cannot be a constant either. The required lightness depends on the theme's own
background, so it has to be solved per theme: forcing one lightness on every
theme needs L=0.20 in light mode to clear AA everywhere, which flattens every hue
to near-black. `noren_theme.solve_contrast` instead moves lightness the minimum
distance that clears the target, holding hue and chroma. Across those same 62
themes that leaves **0 failures with 344 of 434 colours untouched** and a mean
lightness shift of 0.055 — `catppuccin-latte` green goes 2.96:1 → 4.50:1 and is
still green.

Surfaces mix *toward the foreground*, never "lighter", for the
`lighter_background` reason under environment facts.

The `.tpl` hook survives as an override: if the active theme directory contains
`noren.css` — shipped by the theme, or rendered from a user template in
`~/.config/omarchy/themed/` — it replaces the generated rules and still gets the
`--noren-*` variables, so an override can be a few lines rather than a
stylesheet. The host watches `colors.toml` and re-pushes on every theme switch.

**Immerse remaps computed colours at runtime; it is not a stylesheet.** A
stylesheet cannot reach a site's own surfaces — `background-color` does not
inherit, so there is no cascade path from `body` down to a card that paints
itself white. An earlier immerse tried anyway and themed the page *around* the
content: on a social feed site the feed column and every sidebar card stayed white inside a
lavender frame, which reads as damage rather than a theme.

`norenSurfacePass` instead walks the document, reads each element's *computed*
colours, and remaps the site's neutrals onto the theme's ramp, keeping the
distance each colour stood from the page's own ground so elevation and text
hierarchy survive. Three rules earn their place:

- **Chroma decides what is untouchable.** Below 0.06 OKLab chroma a colour is a
  neutral the theme may own; above it, the colour is the content. Measured on
  A social feed site: its neutrals run 0.000–0.029 and nothing it *means* runs below 0.156. The
  obvious cheap stand-in, `(max-min)/255`, is a trap — it scores the feed site's secondary
  text at 0.118 and its brand blue at 0.827, so no threshold separates them.
- **Text on a colour we kept is also kept.** White label text on a red badge was
  being remapped toward the theme foreground while the red stayed. The flag
  inherits, because the text is usually on a child of the coloured element.
- **A gradient of neutral stops is ours; anything else painted by
  `background-image` is not.** Gradients are rewritten stop by stop, keeping the
  shape of the fade; a `url()` is real artwork and a coloured stop carries
  meaning, so both are left alone along with their text. Skipping *every*
  background-image (the first fix) was too blunt — a video site's masthead is a
  gradient at scroll-top and a flat colour once scrolled, so the header stayed
  black at the top of the page and themed everywhere else. A webmail site is the other
  half of the same rule: its light-blue gradient cards were losing their dark
  body text to the theme foreground.
- **Links are coloured by the pass, not by the stylesheet.** A blanket
  `a:link { ... !important }` at USER origin overrides the pass's own refusal to
  touch text on a surface it does not own — on a webmail site it painted the theme link
  colour into those same gradient cards. The pass knows what each link sits on;
  a stylesheet cannot.
- **Do not rescale text distance.** Dividing by 0.85 saturated the top of the
  range and collapsed the feed site's secondary text onto its primary text — both pinned at
  1.0. Reproducing the distance directly keeps three legible tiers.

Nothing in the immerse stylesheet may paint `html` or `body`: the CSS lands
before the pass runs, and the pass measures everything against the site's real
ground. That is why `CANVAS` is split out of `TINT`.

**The pass paints the canvas; the stylesheet must not.** These are two halves of
one rule and both are needed. Immerse's CSS cannot touch `html`, or it destroys
the ground reading — but with `color-scheme` set from the palette and nothing
painting `<html>`, Chromium paints its own canvas, black in a dark scheme, and
every region a site leaves transparent shows through as black. On a social feed site that is the
whole left nav and right sidebar. So the pass sets the canvas itself, once the
ground has been read, and only when the site paints no background of its own.

**Measuring that ground too early is the failure mode to watch.** The pass is
injected as soon as a navigation is visible. `readBase` then falls back to the
theme's own background, everything is measured against the wrong ground, and the
whole bg-to-fg range compresses — on a white site under a light theme, 12:1 body
text becomes 4:1 and the page arrives washed out. It looks like a palette problem
and is not one.

**Waiting for `<body>` to exist is not the same as waiting for a ground.** That
was the first attempt and it is not enough: on a social feed site, body is present almost
immediately but carries no background until the app boots, so the fallback still
won and `<html>` settled at `rgb(34,48,58)` instead of the theme background
exactly. `tryGround` keeps looking for ~2s, paints on the fallback after a few
tries rather than leaving the page bare, and repaints from scratch if a real
ground turns up afterwards.

**One browser at a time.** The host owns a single socket, so two instrumented
browsers would fight over it. `install.sh` clears Noren out of every other
browser when it installs.

**The extension key is per-machine and untracked.** `install.sh` generates
`host/noren-extension.pem` if absent, derives the extension id from it, and
injects the public key into `extension/manifest.json` (also untracked — seeded
from `manifest.json.template`). The id must match `allowed_origins` in the native
host manifest or `connectNative` is rejected.

The key is mirrored to `~/.local/share/noren/noren-extension.pem` (0600, in a
0700 directory). `install.sh` restores from there when the repo copy is missing,
so a fresh clone keeps the same extension id and the host pairing survives —
drill-tested by deleting the key and reinstalling. Only if *both* copies are
gone is a new key generated, which is recoverable but costs a browser restart.
It is a private key and must never be committed.

## Environment facts that cost real time

**Developer Mode is required.** Since Chromium M137 an unpacked extension loaded
via `--load-extension` is *disabled on load* unless `chrome://extensions` →
Developer mode is on. Nothing reports it — not the UI, not stderr. The only
trace is `disable_reasons: [16777216]` in the profile's `Preferences`
(`1 << 24`, `DISABLE_UNSUPPORTED_DEVELOPER_EXTENSION`). Omarchy's own bundled
extensions predate the rule and were grandfathered, which is why they run
without it.

**In light themes `lighter_background` is *darker* than `background`** — and
darker than `dark_background`. Measured:

```
                    background  dark_bg   darker_bg  lighter_bg
catppuccin-latte    #eff1f5     #e3e4e8   #d7d8dc    #dce0e8
white               #ffffff     #f5f5f5   #e8e8e8    #c0c0c0
```

The names encode distance from the ground, not direction. Read `mode` first, or
better, do what `noren_theme.derive` does and mix toward the *foreground* — the
only rule that means the same thing in both modes.

**Omarchy's own `obsidian.css.tpl:42` maps ANSI hues straight onto semantic
roles**, which is the bug the contrast solver exists to avoid. It is worth an
upstream issue independent of Noren.

**`--class` is ignored** for `--app` windows on Wayland. Chromium assigns the
app_id itself:

```
chrome-<host><path, / replaced by _>-<profile>
chrome-news.example.com__-Default
```

Per-site identity is therefore free; you just do not choose the name. This is
what Hyprland `windowrule class:` must match, and what distinguishes a
chrome-less page from an ordinary tabbed window.

**`--app=` needs an absolute URL.** `--app=search.example` does not error — Chromium
ignores the switch and opens an ordinary window, which looks exactly like the
feature silently not working. Both the host and the CLI normalise.

**Omarchy exports `BROWSER=omarchy-launch-browser`**, which makes `xdg-settings`
refuse to answer. Omarchy's own scripts use `env -u BROWSER xdg-settings …`; so
do the installer and the host.

**Hyprland is configured in Lua here**, not `.conf` — `~/.config/hypr/bindings.lua`
using `o.bind("SUPER + B", "desc", [[command]])`.

**Brave is not supported.** Its launcher ends with

```bash
exec ".../brave-origin" "$USER_FLAGS" "$BRAVE_FLAGS" "$FLAG" "$@"
```

with `$BRAVE_FLAGS` and `$FLAG` unset, so two empty-string arguments land in
argv and `--app=` is swallowed. Worse, `"$USER_FLAGS"` is quoted, so a flags file
with more than one line arrives as a single malformed switch and every flag in it
is ignored — which is why `brave-flags.conf` on this machine lists Omarchy's
three bundled extensions that have never actually loaded. That is upstream's bug
to fix. `install.sh --browser <name>` still targets it if you want to try.

## Three reload paths

Forgetting one costs a debugging round, because an unreloaded layer looks
exactly like "the fix didn't work".

| changed | needs |
|---|---|
| `*.qml` | `omarchy-restart-shell` |
| `host/noren-host` | cycle the host — kill it, the extension reconnects on a backoff |
| `extension/*.js` | bump the filename, restart the browser, **and** Reload in `chrome://extensions` |

The filename bump is not optional: Chromium caches service workers for
`--load-extension` extensions, and only a new URL forces new code to register.
Omarchy's own `copy-url` ships as `background-4.js` for the same reason.

## Diagnosis

`./bin/noren doctor` checks the whole chain independently of the bridge —
default browser, browser running, expected extension id, service-worker file,
`--load-extension` present, host manifest pairing, the browser's own
`disable_reasons` decoded by name, and the live socket. It was written after a
four-round misdiagnosis and would have caught every failure in that session in
one command. Extend it rather than debugging by hand.

`noren ping` reports which browser owns the bridge, read from the host's parent
process. A host outlives nothing but its own browser, so with several browsers
installed "the bridge is up" and "the bridge is up, attached to the browser you
stopped using an hour ago" are otherwise indistinguishable.

## Bugs fixed — do not reintroduce

- **Auto-peel destroyed every window it created.** A spawned `--app` window's
  single tab fires `onCreated`, peel spawns a replacement and closes it, forever.
  Only peel tabs in `type === "normal"` windows.
- **Socket cleanup race.** A cycled host's replacement binds a new socket at the
  same path while the outgoing one is shutting down; an unconditional `unlink`
  on exit deleted the *successor's* socket. Cleanup compares inodes.
- **Stale sockets lie.** A host killed without cleanup leaves a file that fails
  with `ECONNREFUSED` rather than `ENOENT`, so callers cannot tell "browser
  closed" from "something is broken". Hence the signal handlers.
- **Silent `onDisconnect`.** A rejected `connectNative` looked identical to a
  clean shutdown until the reason was logged.

## Local gotcha

`pkill -f` / `pgrep -f` with a pattern matching the project path will match the
invoking shell and kill it. Hit twice in one session. Use explicit PIDs or
`-x` name matching.

## Not done

- **Per-site theming modes.** `noren theme` is global. The concept docs want it
  per site, which the `chrome-<host>__-<profile>` app_id makes easy to key on.

- **The surface pass does not survive a framework re-render**, except on `html`
  and `body`. Inline styles are dropped when React replaces a node, and the node
  is only repainted when the observer next sees that subtree added — the global
  observer watches `childList` only, because watching attributes would see its
  own writes and loop. `html` and `body` are defended by a separate observer
  with an `attributeFilter` of `style` and a re-entrancy guard: losing a card
  costs a card, losing body costs the whole page ground, and the feed site rewrites body's
  style attribute back to black after every remap.
- **Hover backgrounds freeze on remapped elements.** Inline `!important` beats
  the site's `:hover` rule. Fixing it means emitting rules keyed to a generated
  attribute instead of writing inline styles.
- **Shadow DOM and cross-origin iframes are not reached.** `querySelectorAll`
  does not cross shadow roots, and the pass runs in the main frame only.
- **A large document still themes progressively, not instantly.** The walk is
  budgeted at 8ms per tick so it cannot jank the page. `requestIdleCallback` was
  worse than it looks: a loading page never goes idle, so the callbacks only
  fired at their 500ms timeout and a video site stayed visibly unthemed for seconds.
  A budgeted loop on a 0ms timer makes progress whether the page is busy or not.

- **Workspace sessions** — each Hyprland workspace owning a named, restorable
  set of pages. Scope v1 to URL set + window order + profile. Restoring scroll
  position and page state is among the hardest problems in browsers and will
  swallow the project.
- **Gather** — the return path for peel. Pull a project's detached windows back
  into one group.
- **Per-site rules file** — the app_id format above makes declarative
  `windowrule` generation straightforward.

## Background

Two independent concept documents in `~/omarchy-help/quantum/`: `README.md`
(sol) and `astra-concept.md` (astra), written blind to each other. Both
independently landed on workspace-bound contexts, three per-site theming modes,
a global tab palette, first-class web apps, and a local plugin API — and both
recommended prototyping as an extension before touching Chromium source.
Neither proposed abolishing the tab strip.

A merged build spec, with every claim in both documents verified, is kept
outside the repository.

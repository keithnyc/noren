# Noren developer handoff

Architecture, design decisions, and the environment facts behind the Noren v1
build. First stop for future development sessions.

Built 2026-09-11, extended 2026-09-12. Everything below was verified on
devbox against Omarchy `quattro` — the numbers and behaviours are measured,
not assumed.

Browser versions are called out where they matter rather than stated once here,
because they move: the v1 findings were taken against Chromium 152.0.7977.82 and
still held on 153.0.8010.36, which is what is installed now. A claim tied to a
version that has since moved is worse than no version at all, so anything
re-measured on 153 says so at the point it is made.

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
elaboration on it. Two things were listed as the only real argument for ever
forking Chromium. One of them is now gone:

1. ~~**The flash.**~~ **Solved 2026-09-11 — no longer an argument for forking.**
   A whole tabbed window with full Chromium chrome was drawn and then destroyed,
   for 270–582ms, and it was worse in a group because the replacement also
   triggers a relayout. It looked like a Chromium-internals problem and was not:
   a `target="_blank"` tab is created with no url, so peel waited for
   `onUpdated`'s `info.url` — which only exists once the navigation *commits*.
   The window was on screen for exactly as long as the site took to answer.
   Peeling from `webNavigation.onBeforeNavigate` instead, which knows the
   destination before the request is made, takes it to **~3ms — not perceptible**.

   Two lessons worth keeping. A delay that scales with page load is not a delay
   in your own code; that correlation, noticed by eye, located this after the
   profiling guesses had all been wrong. And "this needs a fork" deserves
   suspicion until the cheap explanation has been ruled out — two of the reasons
   to fork were really one measurement, and it was never taken.
2. **The origin strip.** Navigating cross-origin inside an `--app` window makes
   Chromium draw a small security bar at the top.

**Do not fork Chromium.** Multi-hour builds plus a security-patch treadmill that
never ends, for a solo project. With the flash fixed, only the origin strip,
`chrome://` page access, and restyling Chromium-drawn UI would need it — and the
origin strip has not had the same scrutiny the flash just got, so assume it is
cheaper than it looks until measured.

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

**`<html>` is assigned the theme ground directly, never remapped.** It *is* the
page ground, so by construction it maps to the theme background — running it
through the generic remap only makes it depend on whether `baseL` happened to be
read from html, from body, or from the fallback. On a social feed site that left it one elevation
step off body (`rgb(34,48,58)` against `rgb(22,36,45)`), which shows as a
horizontal seam wherever body's box ends — one viewport down, since the feed site's body is
viewport-height and the real scroller is nested. Assigning the ground is simpler
and immune to the ground being misread.

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

**Window types, measured rather than assumed** (`noren windows`): a chrome-less
`--app` window reports `type: "app"`, not `"popup"`. So popups *are*
distinguishable from Noren's own windows — but auto-peel still leaves them alone
deliberately, because a `window.open()` popup is usually an OAuth or payment flow
that depends on `window.opener` and on being closed by the page that opened it.
Peeling one into a chrome-less window breaks the login it belongs to.

**Commands act on the *focused* browser window, not the first one on the
workspace.** `hypr_browser_window` used to take the first match in `hyprctl
clients` order, which was right only while a workspace held at most one browser
window. `gather` breaks that assumption by design: several windows share a
workspace and list order then picks an arbitrary member, usually the oldest. The
symptom is precise — open a link into a new window, hit Back, and the window you
came *from* goes back instead. The scan survives as the fallback for commands
issued while the browser is not focused at all (a terminal, a keybind), and it
also skips `hidden` windows — though measured 2026-09-12, Hyprland reports
`hidden: false` for *both* members of a two-window group, so that filter does
less than its name suggests and the active-window preference is what actually
fixes this.

**Only the bridge's own browser counts as a browser.** The match used to be any
of brave/chromium/chrome. Only one browser can hold the socket, so a window
belonging to a different one is a window the bridge cannot drive — passing its
title as `matchTitle` just makes the extension fall back to its own idea of
focus and act somewhere else entirely. Windows whose class starts with `chrome-`
always count, since those are the chrome-less ones Noren spawned.

**`gather` does not lock the group, and the reason is cosmetic.** Hyprland's
`auto_group` is on by default, so any window spawned while a group is focused
joins it — which is what makes a peeled page land in the right group, and also
what puts a terminal in your reading group. Locking the group fixes that
precisely, and Hyprland then paints the locked group's bar with
`group:col.border_locked_active`, default `66ff5500` — orange — which Omarchy
never overrides. Buying the behaviour costs a red tab bar, and fixing the colour
means writing global Hyprland config, which this plugin does not do. Anyone who
wants the behaviour can set `group { auto_group = false }` in their own
`looknfeel.lua`.

**`group.lock` is global, sticky, and silent.** Worth its own warning because it
cost a debugging session: it is Hyprland's `lockgroups` rather than the focused
group, it accepts a garbage argument and answers `ok`, and the state persists.
While it is set, every group refuses every new window — so `gather` folds nothing
and reports success, and nothing in `hyprctl`'s options, client fields or logs
says why. `hl.dsp.group.lock("unlock")` clears it. `lock_active` is the
per-group form.

**`gather` verifies rather than assumes.** `into_group` takes a *direction*, not
a target, so which way the group lies depends on how the layout happened to tile
the windows. `gather` tries each direction and confirms against `grouped` in
`hyprctl clients` — the only honest signal — and reports anything it could not
fold in rather than claiming success. It only ever touches `chrome-<host>-<profile>`
windows: an ordinary tabbed window has class `chromium`, and grouping that would
drag the extension's host window in with the pages.

**Ctrl+Enter means something different for several urls, and that does not
break the invariant.** Enter opens, Ctrl+Enter replaces — for *one* url. Replace
has no meaning for three, so there Ctrl+Enter takes the other reading: open them
all and fold them into a group. The single-url behaviour is untouched, which is
the part the invariant is actually about.

The comma only separates when *every* part is a destination, so
`bread, butter recipe` stays a search. That rule lives in `noren open`, which
does the splitting; the overlay keeps a copy only to decide what the footer
promises. Grouping cannot be fired straight after the spawns — the windows do
not exist yet — so `open --group` waits for them to appear and folds in only the
ones that were not there before, rather than gathering whatever was already open.

**Bookmarks had to become writable, not just readable.** A chrome-less window
has no Ctrl+D and cannot host `chrome://bookmarks` — that page is one of the
things a fork would be needed for — so until `saveBookmark` a bookmark could be
*found* by Noren and only *made* by opening a tabbed window, which defeats the
model. Saving is silent and goes to the default folder: one keystroke is the
point, and organising is still what a tabbed window is for. It refuses to
duplicate a url already saved, since pressing `D` twice is the obvious mistake.

**A leading sigil scopes the search** — `*` bookmarks, `%` history, `#` tabs.
The scope narrows the *sources* in `suggest()` rather than filtering results
afterwards, so a bookmarks-only search returns a full page of bookmarks instead
of whatever survived a mixed ranking. Everything downstream matches on `query`
rather than `filterText`; matching on the raw text would read `*foo.com` as a url
and Enter would try to open the sigil.

**A set is defined by capture, not by syntax.** The obvious design is a config
file listing urls, and it fails the actual requirement: the urls are already on
screen, and retyping them is the thing worth avoiding. `noren set save <name>`
reads the open chrome-less windows from the extension — `hyprctl` knows titles
and classes, not urls — and records whether they were a group, so the set
reopens in the shape it was saved. Group order is preferred over window order so
the tab strip comes back as it was.

Sets also appear unscoped in the overlay, not only behind `@`: a set named
`news` should turn up for someone who typed `news` and has never heard of the
sigil.

**Saving belongs in the url bar, not the radial.** A name is the only input a
save needs and the url bar is already where names get typed, so `@news` with no
such set turns the first row into the save. The radial would have needed a name
prompt of its own, and the ring is already at eleven items. When the name *does*
match, the existing set stays first so Enter opens rather than overwrites —
replacing is a deliberate arrow-down.

Deleting is Shift+Delete on the highlighted set, which is the gesture Chromium's
omnibox uses to drop a suggestion, so it is already learned. No confirmation
dialog: a set costs seconds to rebuild (gather, `@name`, Enter), and a modal
inside an overlay is worse than the mistake it prevents. The key is only
*consumed* when it actually removed something, so Shift+Delete still edits text
everywhere else in the field.

**Completion has to work with the browser closed**, because that is the first
summon of the day — and until it did, the url bar came up empty until a window
happened to be open. With no browser there is no bridge, so the extension cannot
answer; Chromium's own profile can. `Bookmarks` is JSON and `History` is SQLite,
and the locking works out in exactly the right direction: `History` is locked
while Chromium runs, which is precisely when this path is not needed. A locked
or missing database degrades to bookmarks-only rather than failing.

Two things worth knowing about it. `last_visit_time` is **microseconds since
1601-01-01**, not a unix timestamp — treat it as one and every result looks
ancient. And `suggest_offline`'s ranking is a second implementation of the
extension's `scoreEntry`: real duplication, accepted because the alternative is
an empty url bar, and the two need keeping in step. `doctor` reports whether the
profile is readable, since otherwise the failure is a silently empty list.

**A typed url stays literal until you arrow onto a suggestion.** Completion
ranks bookmarks and history together with open tabs, so the top row is often not
what was typed — and Enter acting on it would mean typing
`example.com/invoices` and landing on `example.com/inbox` because history ranked
it higher. Enter only honours a suggestion once the selection has actually been
moved for the current text; typing re-arms the rule. This is the same principle
as Enter never mutating the window behind the overlay: a launcher that sometimes
goes somewhere else is a launcher you cannot trust.

Ranking lives extension-side in `suggest()`: a host that *starts with* the typed
text outranks a page whose title merely mentions it, bookmarks carry a standing
bonus over history, and visit counts are flattened through `log2` so the tenth
visit does not outrank a good match.

**Noren must never change Hyprland's animations.** They are global — every
window on the desktop gets them — and a browser plugin has no business
restyling someone's compositor. `install.sh` touches none of it. Omarchy
disables `fadeSwitch`, so switching the active window in a group swaps with
nothing in between, and with tabs-as-windows that swap *is* a tab change;
enabling it is a real improvement, but it belongs in the user's own
`looknfeel.lua` as a documented suggestion, not in the installer.

Two others were tried for the peel flash and reverted: `windowsMove` slower and
`windowsIn` at `popin 95%`. They were aimed at the wrong cause — the flash is a
full-chrome window being created and destroyed, not an animation curve — and
they changed the whole desktop to treat a symptom.

**Selecting a page flies the card to the window's real geometry.** A fade would
have been easier and would have said nothing; animating to `at`/`size` from the
client map makes the card read as *becoming* the window, because it lands exactly
where the window is.

Two details that matter. The raise is dispatched when the flight *starts*, not
when it ends, so the compositor has already switched by the time the card
arrives — the card lands on a live window rather than on a stale picture of one.
And the scrim fades during the flight, so what it lands on is the real desktop
rather than a dimmed copy.

**The raise has to happen twice.** The overlay holds
`WlrKeyboardFocus.Exclusive`, and when it closes Hyprland restores focus to
whatever was focused before it opened — silently undoing the raise. The symptom
is precise and misleading: the animation is perfect and the page never changes,
which looks like the dispatch failing when it actually succeeded and was
reverted. So the window is raised again once the overlay is gone. Raising an
already-focused window is a no-op, so the second call costs nothing in the case
where the first survives.

`at`/`size` are global **logical** coordinates and the monitors here have
non-zero origins and different scales (DP-2 at -960, eDP-1 at -2560, scales 1.875
and 1.6), so the monitor origin has to be subtracted. The overlay ignores
exclusion zones, which is what makes its 0,0 the monitor's origin.

**Key hints are spelled out, not drawn.** `⇧⌦` for Shift+Delete rendered as an
illegible smudge at caption size in the menu font — found by cropping a
screenshot, not by reading the code, since it looks perfectly reasonable in a
source file. The same rule the radial menu already states applies to key hints
too: an action you cannot name is an action you cannot use, and that goes double
for the key that performs it. `←` `→` and `↵` do render legibly and stay.

**Only static cards are layered.** The overview's depth of field comes from
`layer.enabled` plus a `MultiEffect` blur on the *unselected* cards, which hold a
still frame, so the effect is a one-off render. The selected card captures
continuously and layering that would add a full render pass every frame — the
same instinct behind capturing live on one card only. Given this machine has a
history of Chromium GPU-process aborts, extra per-frame passes over a live
capture are worth avoiding even where they would look fine.

**A hidden group member can be screencopied — measured, not assumed.** The
overview depends entirely on this, and the instinct was that it would fail:
Hyprland does not render an inactive group member, so why would it hand over
frames? It does. Probed 2026-09-12 with a throwaway Quickshell config against a
live two-window group:

```
chrome-search.example__-Default | activated=true  | hasContent=true | 3795x2014
chrome-social.example__-Default    | activated=false | hasContent=true | 3795x2014
```

That killed the whole frame-caching design that would otherwise have been
needed — capture each member as it becomes active, show stills, blanks for
anything not yet visited. None of it is required. The lesson is the same one the
flash taught: probe before designing around a limit you have not confirmed.

`HyprlandToplevel` is the piece that makes it work without shelling out —
`address` matches Hyprland's own `grouped` list, `lastIpcObject` carries the
client map, and `wayland` is the Toplevel a `ScreencopyView` captures.

**One browser at a time — and one *instance* of it.** The host owns a single
socket, so two instrumented browsers would fight over it. `install.sh` clears
Noren out of every other browser when it installs.

Two processes of the *same* browser is the harder version, and `noren open` with
several urls caused it. From a cold start every url falls back to
`omarchy-launch-webapp`, and two of those firing in the same instant race
Chromium's singleton lock — both win. Observed: two browsers started in the same
second, one holding `--app=https://social.example` and the other `--app=https://search.example`,
with `SingletonLock -> devbox-17454`.

Both load the extension, but only one can own the native messaging socket, so
every window in the other silently has no working extension: nothing peels
there, and `noren windows` cannot even see them. The symptom is a link opening
as an ordinary tabbed window and simply staying that way, which looks like
auto-peel being broken and is not. `open_many` now launches the first url, waits
for the extension to connect, and sends the rest through the bridge — which
spawns them from the browser that already exists.

`doctor` reports the instance count, because nothing else does: the difference
is only visible in process arguments.

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

**`--class` is ignored** for `--app` windows on Wayland — and for ordinary
windows too, measured 2026-09-12: `chromium --class=noren-nursery --new-window`
still comes up as class `chromium`. Chromium assigns the app_id itself:

```
chrome-<host>_<path, / replaced by _>-<profile>
chrome-news.example.com__-Default      (root path -> two underscores)
chrome-mail.example.com__mail-Default      (/mail)
```

The separator underscore is easy to miss and this doc got it wrong: the rule was
written as "`/` replaced by `_`", which does not produce the two underscores in
its own example. Host, separator, then the path — every window observed on this
machine agrees. `noren apps` predicts it and confirms against a live window,
because a wrong app_id matches nothing while looking perfectly reasonable.

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

**Legacy string dispatchers are gone.** On Hyprland 0.56.2 `hyprctl dispatch
submap reset` is a *syntax error*; only `hl.dsp.submap("reset")` works. Every
dispatcher goes through the Lua API, which also makes the legacy fallback in
`omarchy-launch-or-focus` dead code on this machine. Take signatures from
Omarchy's own `bindings.lua` rather than from the Hyprland wiki's dispatcher
names — the mapping is not mechanical:

```lua
hl.dsp.focus({ window = "address:0x…" })          -- focuswindow
hl.dsp.group.toggle()                             -- togglegroup
hl.dsp.group.active({ index = n })                -- changegroupactive
hl.dsp.window.move({ into_group = "l" })          -- moveintogroup   (not group.*)
hl.dsp.window.move({ out_of_group = true })       -- moveoutofgroup
hl.dsp.window.move({ workspace = "3", follow = false })  -- movetoworkspacesilent
```

**Probing dispatchers live is not safe.** `hl.dsp.group.toggle(12345)` answers
`ok` and groups the focused window rather than rejecting the argument — several
of these ignore bad arguments instead of validating them. Read the config, do
not experiment on a running session.

**Relevant group settings**, all at their defaults: `groupbar:enabled` is on and
Omarchy styles it (height 22, monospace 12, themed gradients), `auto_group` is
on — so a window spawned while a group is focused *joins* it, which is what makes
`peel` land in the right place — and `group_on_movetoworkspace` is **off**, so
moving a window to a workspace does not add it to a group there. That last one is
why `gather` has to fold windows in explicitly.

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

- **A peeled link waited for the page to load.** `target="_blank"` creates the
  tab with no url at all — the navigation is renderer-initiated, so Chromium
  does not populate `pendingUrl` either — and the fallback then waited for
  `onUpdated` to carry `info.url`, which only exists once the navigation has
  *committed*. So the doomed full-chrome window stayed on screen for exactly as
  long as the site took to answer: measured 270ms on one cold site and 582ms on
  another, while an already-visited link was barely visible. `onBeforeNavigate`
  knows the destination before the request is made, so the peel happens there
  and the flash stops tracking the network. The tell was the symptom itself —
  a delay that scales with page load is not a delay in your own code.
- **Middle-click did not peel, intermittently.** `onCreated` said "wait for
  onUpdated to carry one" for a tab with no URL yet, and nothing in `onUpdated`
  ever did — so those tabs were dropped silently. Chromium creates a
  middle-clicked tab first and navigates it a moment later, so whether it peeled
  came down to whether the URL happened to land before `onCreated` fired. A
  comment describing a code path is not a code path.
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
  set of pages. `noren set` is the smaller half of this and deliberately stops
  short of it: a set is a list of urls plus whether it was grouped, with no
  workspace binding and no page state. Scope v1 to URL set + window order + profile. Restoring scroll
  position and page state is among the hardest problems in browsers and will
  swallow the project.
- **Per-site rules file** — the app_id format above makes declarative
  `windowrule` generation straightforward, and `noren apps` already derives the
  ids.
- **Window identity beyond the launcher.** `noren apps adopt` gives installed
  webapps a `StartupWMClass`, so their windows are matched to their launcher and
  show the app's name and icon. A window *peeled* from an arbitrary link has no
  launcher at all, so it still shows as its raw app_id — generating a desktop
  entry per peeled site is the next step, and it needs an icon source.

## Background

Two independent concept documents in `~/omarchy-help/quantum/`: `README.md`
(sol) and `astra-concept.md` (astra), written blind to each other. Both
independently landed on workspace-bound contexts, three per-site theming modes,
a global tab palette, first-class web apps, and a local plugin API — and both
recommended prototyping as an extension before touching Chromium source.
Neither proposed abolishing the tab strip.

A merged build spec, with every claim in both documents verified, is kept
outside the repository.

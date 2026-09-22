# Noren developer handoff

Architecture, design decisions, and the environment facts behind the Noren v1
build. First stop for future development sessions.

Built 2026-09-11, extended 2026-09-12. Everything below was verified on one
machine against Omarchy `quattro` — the numbers and behaviours are measured,
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
with `SingletonLock -> <hostname>-17454`.

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

**The start page is an extension page, not a web page.** It needs the
bookmarks bar and top sites, which only an extension can read, and a
`chrome-extension://` url needs no server and works with the network down. What
it cannot do is spawn a chrome-less window or read `sets.json`; both belong to
the host, so the page asks the worker (`chrome.runtime.sendMessage`, accepted
only from `start.html` itself) and the worker asks the host over the native
port. Sets open through `noren set open`, because grouping is Hyprland work the
CLI already does carefully, and the host passes on only a name that is actually
a saved set.

**Most visited is ranked from history, not `chrome.topSites`.** topSites is a
cache Chromium refreshes on its own schedule and seeds with defaults; on a
profile used daily it answered the Web Store, a benchmark and a localhost login
page, none of which were the sites actually visited most. `places()` in the worker sums visits per
site over 30 days and drops local dev servers and link shorteners (`t.co` ranks
high for anyone on a social feed site, because every link click there passes through it). The start page and the empty
url bar both read `places()`, and `offline_start` in the CLI mirrors it from the
History file, so all three show the same list.

**Editing writes to the bookmarks bar, not to a Noren list.** The bar is
already an ordered, renameable, synced list, so pin / reorder / rename / unpin
are single `chrome.bookmarks` calls and there is nothing of Noren's to migrate
or lose. `bookmarks.move` within the same parent takes the index as a position
*before* the node is removed and corrects for it itself; `dropIndex` measures
exactly that (dragged tile included), so no off-by-one adjustment is applied —
adding one is the classic bug here.

Hiding a most-visited site is the one piece Noren owns, since history cannot
forget a site without deleting it. It lives in `hiddenSites` in extension
storage; the worker mirrors it to the host, which writes
`~/.config/noren/start.json` so `offline_start` can honour it with the browser
closed. The page also re-renders on every `chrome.bookmarks` event, except
mid-rename, where a re-render would throw away what is being typed.

**The set editor never writes `sets.json`.** Every edit is `noren set put`
(JSON on stdin — urls carry `&` and `#`, names could start with `-`), `set rm`
or `set save`, run by the host on behalf of the worker. The CLI owns the format
and every rule — web urls only, a name, at least one page, no silent overwrite of
another set — so the page and `@name` in the url bar cannot disagree. A rename is
one write (`previous`), not a save and a delete that can half-happen.

The host runs these off its native-messaging loop. `set save` asks the extension
for its open windows through the host's socket, and that reply is read by the
main loop; running the CLI synchronously there deadlocks until the timeout.

`set save` also skips non-web windows now: the start page is a chrome-less
window too, and saving open pages captured its extension url.

**Reloading the extension is one command.** `noren reload-extension` asks the
worker to call `chrome.runtime.reload()`, which for an unpacked extension
re-reads every file from disk. Two things make it complete: the worker
re-injects `bar.js` into pages that are already open (`injectBars()`), and
`bar.js` *replaces* a previous copy of itself rather than refusing to load
(`window.__norenBar.destroy()`, every page-level listener hung off one
`AbortController`) -- refusing left a bar whose extension context was dead. That
re-injection is also a real fix: a fresh install used to leave every open page
without a bar until it was reloaded by hand.

`noren ping` reports how long ago the extension loaded. The host dies with the
extension's native port and a new one starts with it, so the host's own age *is*
the time since the last load -- a number that cannot go stale, unlike a
hand-edited build marker.

**Site scripts are safe because of where they run, not because of what they
promise.** `chrome.scripting.executeScript({ world: 'MAIN' })` puts them in the
page's own JavaScript world, where there are no extension APIs at all: no
`chrome.runtime`, so no route to this worker, the native host, the CLI, sets or
any other page. Verified rather than assumed — a test script wrote
`chrome.runtime && chrome.runtime.id` into a data attribute and read back
`blocked`, while its sibling change to the DOM landed. That is what lets an
agent write them: the blast radius is one site's layout, and `noren site off`
is the undo.

The CLI is the only installer (`noren site add`): it size-limits at 128KB,
parses JS with `node --check` when node is there, and flags `fetch`,
`eval`, `document.cookie` and storage for the user to read. Those are prompts
for a human, not a sandbox — the world is the sandbox.

Injection hangs off `webNavigation.onCommitted` (css, before first paint, so
there is no flash of the unstyled site) and `onCompleted` (js, once there is a
page to act on). It used to hang off `tabs.onUpdated` with
`status === 'complete'`, which is not something to build on: in a headless run
that status never arrived at all, and the shared handler returns early whenever
it peels a tab.

**An install that changes nothing looks like a feature that does not work.**
Installing a script used to leave the open page alone until the user reloaded
it, and the first time an agent wrote one that is exactly what happened: the
agent reported success over a page that had not moved, and the honest reading
from the outside was "it lied". So `noren site add` and `noren site on` end on
the live page: the CLI asks the host, the host pushes the new script *ahead* of
the injection (the extension learns about site scripts from a push, and its poll
is seconds away), and the worker's `applySite` command injects into every open
tab on that host. The CLI says how many pages it reached. `off` and `rm` do not
try the reverse — css could be pulled back out and js could not, and half an
undo is worse than a reload.

This is also why a script has to be idempotent and guard for elements that
already exist, which the skill now says outright: it is applied to a page that
is mid-life, not one that just loaded.

**The agent panel is a window onto a file, not the thing doing the work.** The
agent runs in its own terminal — `omarchy-agent-prompt`, the agent Omarchy is
set to — and writes its answer to a path Noren named. Two consequences that were
not obvious until it was used: the panel must be losable, and it must not act
like a modal. It was both, badly. A click on the Omarchy bar dismissed the
overlay, which read as "the question is gone" (it was not: the agent was still
working), and a full-screen scrim darkened every window on every workspace for
minutes on end to announce a text box. Now the composer draws no scrim, ignores
clicks outside the card, resumes from `noren ask --last` when it opens, and when
an answer lands while it is shut it says so through Omarchy's own OSD. `start
over` exists because an agent can be denied, shut down or simply told no, and
none of that reaches the file the panel is waiting on — waiting must never be a
dead end.

**One surface at a time.** Asking used to leave two things half-telling the
story: a panel that knew the question but nothing about the work, and a terminal
that knew the work but appeared from nowhere over whatever you were reading.
The panel now takes the middle of the screen only while it is being typed into.
The moment an ask is out it stands aside into a corner card, the overlay gives
up the keyboard (`WlrKeyboardFocus.None`) and narrows its input region to that
one card (`mask: Region { item: ... }`), and the desktop comes back — which
matters most for a site script, where the interesting thing is the page changing
behind it. The move is never seen: a curtain drops over the card that is leaving
and lifts off the one arriving, the same gesture as a closing window.

The ✕ on the corner card is not decoration. Once the surface is click-through
there is no keyboard to press Escape with, so the card has to carry its own way
out, and `start over` has to carry the way back to a composer.

**Ask the agent to narrate; do not parse it.** A spinner that says "Asking…" for
three minutes is indistinguishable from a hang. The fix is one line in the
prompt: overwrite a status file with a short line saying what you are doing now.
Noren polls that file beside the answer file and shows the last line, rising
into place as it changes. The alternative — reading the agent's own stream — was
rejected for the same reason Noren does not host the agent's terminal: there are
twelve agent CLIs behind `omarchy-default-agent` and their output is theirs, not
an API. An instruction in the prompt works with all of them, including ones that
do not exist yet.

**Tell the agent where things are; it cannot guess.** The first prompt said
"read the skill `noren-site`" and named `noren site add` as a bare command. On a
machine where the installer's symlinks had not been run, neither existed: the
agent spent two or three minutes searching the filesystem for Noren before it
could start. The prompt now carries absolute paths — this file's own checkout
for `SKILL.md`, `os.path.abspath(__file__)` for the CLI — and says outright not
to go looking for Noren's source or change it. An install step that is nice to
have for a human is load-bearing for an agent.

**What is installed has to be visible somewhere.** A script that changes a site
and appears in no list is indistinguishable from the site changing on its own.
The start page's settings panel lists every site script with a switch and a
delete (`getSites` → `site_summary()` in the host, `siteOp` → the CLI), and
`noren site list` prints the file paths, because the next question after "what
is installed" is "what does it do". The page gets a summary only, never the
source: an extension page has no business holding a script someone else wrote.

**Closing keeps the compositor in charge.** The obvious way to animate a close
is to own the close key: capture, play, then close. It was built that way and
then thrown out — `SUPER + W` is Omarchy's, it is used constantly, and a plugin
whose selling point is native window management has no business taking it.
Hyprland's `closewindow` event is the only universal signal, and by the time it
arrives the window is gone, so there is nothing to photograph.

So the host keeps one recent snapshot per page window (`grim` on the window's
region, ~90ms) refreshed when something actually changes: the window takes focus
(`activewindowv2`, +450ms so it has drawn) and its page finishes loading (the
worker sends `pageChanged`). On `closewindow` the host hands the shell that
snapshot with the window's last geometry. One path for every close — the
compositor's, a page closing itself, the overview's Shift+Del — and `noren
close` is now just a plain close.

Two styles, both in `Shatter.qml`: `curtain` is five panels hung from their top
edge, swinging out from the middle with the outer ones a beat behind, falling
over 520ms; `glass` is a 10×7 grid thrown outward and down over 380ms. With no
snapshot the panels are drawn from the theme instead, shaded down their length
with lit cut edges — that path only happens when a snapshot is missing or stale.

**And it is off by default, because the reactive design is always late.**
Measured 2026-09-22 with a socket2 listener polling `hyprctl layers` every 4ms:
`closewindow` → `noren-shatter` mapped took 102, 137, 99 and 121ms across four
real closes (the last one the browser's final window, so the host was on its
way out and still made it). Of that, `omarchy-shell -q` itself is 40–90ms. The
shell side is not the problem and cannot be tuned away. Meanwhile Hyprland plays
its own close on the window from the instant it goes -- Omarchy's is
`windowsOut popin 87%` plus `fadeOut`, ~150ms -- so what the user sees is the
page shrinking and fading, a beat of whatever is behind it, then the old page
reappearing full size and coming apart. Two things were tried and did not fix
it, so do not retry them alone:

- `hl.layer_rule({ match = { namespace = "^noren-shatter$" }, no_anim = true,
  animation = "none" })` -- Omarchy's own rule for its menus. It removes a
  real ~180ms `fadeLayersIn` on the panels' surface, and it is in the printed
  bindings block for when the animation is on, but the flick remains.
- A sheet of the theme's ground under the panels, fading out, so a grouped
  close's next tab arrives through them. Invisible next to the flick.

The only fix is to put the panels up *before* the window closes -- which is
owning the close key, the approach thrown out above. The version worth
building: `SUPER + W` bound to a shell IPC call that, for a `chrome-*` window,
bursts from the stored snapshot (its path is deterministic:
`$XDG_RUNTIME_DIR/noren-snap-<address>.png`), waits one frame, verifies focus,
then closes; any other window closes plainly; and the binding falls back to a
plain close if the shell does not answer, so a dead shell never leaves the user
without a close key. The host's reactive burst then has to skip the address the
shell just did. Until that exists, off is the honest default.

**Settings live where they are owned, and the page does not care.** The
extension owns what only the browser knows (auto-peel, page theming, the reveal
bar) in `storage.local`; the CLI owns what the shell and compositor act on
(tabbed mode, the close style, the search engine) in `config.json`. The start
page asks the worker for everything and writes back by name; the worker sets its
own and forwards the rest to the host, which runs the CLI — so a setting has one
validator and one format, whoever changed it.

The search engine is the reason a phrase typed into the url bar used to open
`https://two words`: the extension had its own hard-coded engine and the CLI had
none at all. Now `search_url()` in the CLI and `searchUrl()` in the worker read
the same setting, which the host pushes on connect and whenever it changes.

**The reveal bar is a content script, not a shell surface.** The first attempt
put the page's address and buttons in the Omarchy bar; with two pages tiled, the
strip was nowhere near the window it described. Drawing a toolbar over each
window from the shell means tracking every move, resize, animation, group switch
and fullscreen — the same fragility that ruled out favicons on the group bar. A
content script moves with its page for free.

What keeps it from fighting pages: `position: fixed` over the page (no layout
shift, sticky headers untouched), a **closed** shadow root (page CSS cannot reach
it, its CSS cannot leak), inline SVG icons (no dependency on the page having a
Nerd Font), a dwell at the top edge before it shows (so a site's own top menu
stays reachable), and hiding on `fullscreenchange`. It asks the worker before
starting and runs only when its window's type is `app`.

Content scripts are the least trusted code the extension has — a compromised
renderer can speak for one — so the worker gives the bar its own listener and
vocabulary: `hello`, `home`, `urlbar`, `pin`, `pins`, `openPin` and `openSet`, each acting on
`sender.tab` only. `pins` hands over the bookmarks bar's titles and urls — the
least a pins menu needs, and nothing outside that folder. `openPin` opens a new
window only for a url that is actually on the bar, so a compromised renderer
cannot turn it into "open any url". Sets reach the bar without their urls — a
name, a count, a shape and a few hosts — because `openSet` works by name, and the
host opens only a name that is actually saved. Going to a pin in place needs no worker at
all: the page can already set its own `location`. The
start page's listener still refuses anything not sent from `start.html`.

**Favicons reach the reveal bar as data urls — never make `_favicon` web
accessible.** The first version of the bar loaded
`chrome-extension://<id>/_favicon/?pageUrl=…` in the page, which requires listing
`_favicon/*` under `web_accessible_resources`. That makes it loadable by *every*
website, for *any* url. Chromium only caches a favicon for a site you have been
to, so any page could probe your history site by site, and fingerprint Noren.
Found by a hostile test page: `fetch` returned 200 and an `<img>` loaded for an
arbitrary url. Now the worker reads its own favicon cache (`faviconData()`) and
sends bytes, and only for the sender's own page and the bookmarks bar.

The same hostile page confirmed what does hold: the closed shadow root gave the
page `shadowRoot === null` and none of the menu's text, and no resource-timing
entry named a favicon. The `<noren-bar>` host element itself is visible to the
page once the bar has been shown, which reveals that Noren is installed but
nothing the bar contains.

**A set can replace the page it was opened from.** `set open --replace`
navigates the focused chrome-less window to the first url, then opens the rest
and, for a grouped set, gathers them with that window as the anchor
(`gather(anchor_address=…)`; before that, gather anchored on whichever window
came first on the workspace). It declines when the page in front is already in a
group — replacing a member would pour the set into an unrelated group. Click
means replace on the start page and in the reveal bar menu, as tiles and pins
already did; in the url bar Enter still opens alongside and Ctrl+Enter replaces,
because Enter must never mutate the window behind the overlay.

**The start page's backdrop comes from the host.** `push_wallpaper()` follows
`~/.local/state/omarchy/current/background`, shrinks it with `magick` (one ffmpeg
frame for a video background) until the data url is under 700KB — a native
message may not exceed 1MB — and the worker stores it as `wallpaper`. The page
blurs it and covers it with a veil of the theme's own `bg` at 74%, so text keeps
roughly the contrast its colours were solved against; body is transparent so the
fixed backdrop and veil, behind it, show at all. Checked in the watcher loop,
because cycling backgrounds within a theme never touches `colors.toml`.

Tile glow reads the favicon's pixels on a canvas — possible because the favicon
endpoint is same-origin to an extension page — and takes the heaviest saturated
hue bucket; greys, near-black and near-white are skipped, so a monochrome logo
glows in the theme accent. The time-of-day light is a table of theme *roles* per
hour, mixed in CSS between neighbours, so it always belongs to the palette.

**Gathering was slow because of flat sleeps, not Hyprland.** Measured on this
machine, an `hyprctl` call costs ~6ms — the waiting was ours. Three fixes:

- **Waiting for a new window** was a 0.2s poll plus a 0.25s settle. Hyprland's
  event stream (`$XDG_RUNTIME_DIR/hypr/<sig>/.socket2.sock` — hidden, easy to
  miss) announces `openwindow` with the address and class, so the wait is now as
  long as the window takes. The socket is opened *before* the spawn, or the
  window can appear in the gap. Polling remains the fallback.
- **The settle** is now `wait_mapped()`: a window still being mapped reports a
  zero size, and moving it then is what left windows outside the group. It waits
  for a real size instead of a fixed guess.
- **Each fold attempt** slept a flat 0.12s before looking, so every success paid
  it in full and every wrong direction paid it again. `_wait_grouped()` polls
  `activewindow` every 20ms instead, and `_fold_order()` tries the direction the
  anchor actually lies in first — a wrong direction is not free, it moves the
  window somewhere else before failing.

**The bar's tab strip is Hyprland's grouping joined to Chromium's windows by
title.** Neither side can answer alone: Hyprland has never heard of a url, and
Chromium has no idea its windows are grouped. `group_members()` reads the
focused client's `grouped` array (the bar only shows on the window the pointer
is over, which is the focused one) and hands over addresses and titles;
`groupTabs()` in the worker matches those titles to its own `app` windows for
the url and favicon — the same title match the host's command targeting uses.
Switching goes back through `raiseWindow`, which the host refuses for any
address outside that group: the request comes from a content script, which
speaks for a page.

With no group, `group_members()` falls back to the chrome-less pages on that
workspace (capped, ordered as they sit on screen) and says `grouped: false`, so
scattering does not take the switcher away with the group; the strip draws those
dashed and unfilled rather than as tabs.

Making room only works where the page pins nothing to the viewport.
`translateY` on `<body>` is what carries a site's fixed header down with the
page — and it also makes the page, not the window, the containing block for
everything else fixed, which put a video site's sidebar and a feed's columns off
screen or mis-sized. `pinsToViewport()` samples the sides and the bottom (not
the top: a header riding down is the point) and skips the shift when anything
fixed is there. Sampled at seven points rather than walked: `getComputedStyle`
over every node of a page that size costs far more than the answer is worth.
A page script cannot inset the viewport, which is how a browser's own toolbar
avoids all of this.

The bar and its pins menu sit in a layer above the strip. The strip's
`backdrop-filter` makes it a composited layer, so it painted over a menu hanging
down out of the bar and cut the top off the list.

Keeping it current needs Hyprland, not the browser: a window joining a group is
a compositor event Chromium cannot see, so the host watches the event socket
(`watch_hyprland()`, debounced 150ms — `gather` folding four windows is one
burst) and the worker relays a redraw to every bar. The pin is `revealBarPinned`
in `storage.local`, one setting for every window: each bar follows the key
through `storage.onChanged`, which is also how one window's pin reaches the
rest.

**Tabbed mode folds after the spawn, never before it.** `~/.config/noren/config.json`
is Noren's own settings file — the first of them is `tabbed` — read by the CLI
and the host, so it applies wherever a spawn came from. The host reads the
anchor (the focused chrome-less window) and the set of existing chrome-less
addresses *before* spawning, spawns immediately, and only then runs
`noren join --anchor … --exclude …` on a thread: a peeled link leaves a
full-chrome window on screen for exactly as long as the spawn takes, so nothing
may sit in front of it. The fold itself is `gather()` with an explicit anchor —
one code path for every group mutation, and one place that is careful about
targeting.

**A cold start blocks the start page.** Chromium creates the `--app` window
before it has loaded the extension, refuses `chrome-extension://…` as
`ERR_BLOCKED_BY_CLIENT`, and never retries — the window sits on an error page.
The worker's `reviveStartPages()` runs when it starts and again 1.5s later:
any tab on the start url with no live context in `runtime.getContexts` is
reloaded. A healthy page always has a context, so it is never reloaded.

It themes itself from `themeRoles` in `chrome.storage.local`, which the worker
writes whenever the host pushes a palette: injection refuses extension pages, and
`storage.onChanged` repaints it live on a theme switch.

`normalize_url` still refuses every non-web scheme. The start url is built from
`host/.extid` by `start_url()` rather than accepted from a caller, so the one
exception cannot be used to open arbitrary extension pages. `noren start` goes home in place when a chrome-less page is focused — the
extension's `home` command, which refuses to navigate unless the host's title
hint actually matches, because `focusedTab`'s last-focused fallback would
otherwise send some other window home. Otherwise it finds
an open start page by its exact title, `Noren Start`, *and* the extension id in
its app_id (`chrome-<ext id>__start.html-Default`), and raises it rather than
stacking another. Both, because the app_id is fixed when the window is created:
after a click navigates the start page in place, that window still carries the
start page's id while showing a site, and matching on the id alone raised the
window you were already on — `H` in the radial silently did nothing.

A click navigates in place and Ctrl+click opens a new window — the *reverse* of
the url bar's Enter / Ctrl+Enter, deliberately. It shipped the url bar's way
first (the start page as a home base that stays) and in use it was wrong: the
start page is where the day begins, like a new-tab page, and clicking a site
should become that site. The url bar's invariant is about not mutating a window
*behind* an overlay; here the page being replaced is the one you clicked in, so
nothing unseen changes. `noren start` brings a fresh one back.

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
| `host/noren-host` | `noren reload-extension` (it takes the host with it), or kill the host by PID |
| `extension/*` | `noren reload-extension` |

`noren reload-extension` is `chrome.runtime.reload()` over the bridge, which
re-reads every file from disk for an unpacked extension — so the filename bump
that used to be mandatory is not any more (see CLAUDE.md for the measurement).
What *is* still true is the reason behind it: **Chromium caches the
service-worker script, and starting the browser does not clear that cache.** A
browser launched after an edit answered a brand-new command with
`unknown command` and worked a second after a reload. Edit, then reload, whether
or not the browser was already running. `noren ping` prints how long ago the
extension loaded, which is the only honest answer to "did my reload take?".

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
- **A site script did nothing until the page was reloaded.** Reported by its
  author as installed, over an unchanged page. `site add` now applies to the
  open pages; see the design note above.
- **The Noren mark collapsed to one panel whenever an answer landed.** The
  panels are laid out by a `Row`, and each one also bound its own `x` to step
  aside during the parting. A positioner assigns `x` itself, so the first time
  `parted` changed the bindings overwrote the layout and stacked all four on top
  of each other. Stepping aside is a `transform: Translate` now. The same
  `parted` was left at 1 by its `Behavior` — a Behavior restores the value that
  was *assigned*, not the one its last animation wrote — so the second answer
  parted nothing; it is driven by a named `SequentialAnimation` instead.
- **The agent panel darkened the whole desktop and could be lost by a click.**
  Both came from reusing the url bar's overlay as-is: a scrim across every
  output and a click-anywhere-to-close. An ask outlives its panel, so the panel
  now behaves like it.

## The installer remembers what it touched

`--browser NAME` resolves any launcher that exists on the machine, so a
hardcoded table of browsers cannot undo every install the script allows. It
could not: installing into Chrome or Vivaldi and then running `--remove` left
the `--load-extension` flag and the native host manifest in place, silently,
with nothing to notice it by.

So install writes `~/.local/share/noren/installed.list`, one
`flags-file<TAB>host-manifest` per line, and `--remove` reads it back. The old
hardcoded lists stay as a fallback for installs that predate the record, or that
were made from a different checkout. Reproduced and fixed 2026-09-20 with a
sandboxed `$HOME` and a fake `vivaldi-stable.desktop`, which is the cheapest way
to exercise the installer without touching the real machine.

## Releasing

The version lives in one file, `VERSION`, and everything else is derived:

- `noren version` and the first row of `noren doctor` read it directly.
- `install.sh` copies it into the generated `extension/manifest.json` as
  `version_name`. It cannot go in `version`: Chrome refuses a manifest whose
  version is not one to four dotted integers, so `0.01-alpha` would stop the
  extension loading. `version` stays a plain number in
  `manifest.json.template` and is bumped by hand at a release.
- `manifest.json` (the Omarchy plugin manifest) carries the same string.
  Omarchy's validator only checks the field exists, so it can be the readable
  one.

To cut a release: edit `VERSION`, match the two manifests, add a
`CHANGELOG.md` entry, commit, tag `v<version>`.

A tester's `noren doctor` names both the version and the checkout it came from,
so a bug report cannot be about a Noren nobody can identify.

## Pieces (experimental)

A piece is a page window that shows one element of its page, live. The code is
`piece` / `piecePick` / `norenPicker` / `norenIsolate` in the service worker and
`piece` / `open_piece` / `place_piece` in the CLI. What cost time:

**Hide, never delete.** Removing the rest of the page breaks every framework
that expects its DOM. `body * { visibility: hidden }` plus `visible` on the
piece and its descendants leaves the site's code untouched -- `visibility`
inherits but a child can turn it back on. Ancestors get `transform`, `filter`
and `contain` cleared, because any of them makes that ancestor the containing
block for `position: fixed` and the piece would be pinned to it instead of the
window.

**A new window joins the focused group, and floating it floats the group.**
Hyprland opens a window *into* the focused group, and `window.float` on a
grouped window floats and resizes every member -- even with an explicit
`window = "address:..."`. The first test did exactly that to two of the user's
own pages. `place_piece` takes the window out of the group first, re-checks it
is alone, and refuses to float otherwise. Focus verification alone does not
catch this: the address is right, the damage is to its group-mates.

**Positions alone are fragile.** A module with no id on a finance portal came
back as a 13-level `nth-of-type` path, which pointed at a different module after
the site reshuffled its right rail (ads, sign-in state). The picker now records
the element's heading as well -- the first `h1`-`h6`, `[role=heading]` or
`<header>` inside it (that portal titles modules with `<header>`, which the first
version missed) -- and the re-finder checks it, searching by heading when the
path has moved. Paths use a position only where the tag is ambiguous among its
siblings. Class names are never used: generated ones change every deploy.

**Measure in the window it was picked in; scale, don't stretch.** The new
window opens at whatever size the tiler gives it, and a site can render a
different layout there. So the picked width and height travel with the piece,
and afterwards it keeps that layout and is `transform: scale`d to fit its
window. Stretching it to `100vw` pulled a 343px module's rows apart at 1170px.
Video is the exception -- it fills the window -- and is sized to the video's
own aspect ratio, since a player's box is taller than its picture.

**The picker must be restartable.** A pick left running (a second summon, or a
page whose hydration threw the outline away) made every later pick a silent
no-op. It now tears down any previous pick, puts its outline back if the page
removes it, and gives up after 90s. A 100vmax `box-shadow` did not render as a
dimmer on a real page; four plain panels do.

Not done: saving pieces across a browser restart; a site's own menus drawn
outside the element (portals) are hidden with the rest of the page; width
media queries still see the real window, so a site can still restyle a piece at
a breakpoint.

## The radial shows what applies

The ring had grown to 16 items. It now asks Hyprland directly (`hyprctl -j
activewindow` and `clients`, ~20ms) when it opens -- not `noren target`, whose
~120ms of Python startup made items pop in mid-animation -- and hides what does
not apply: overview needs two pages on the workspace, pop out and scatter a
group, gather something to gather, peel a tab in an ordinary window. `shortcuts`
holds every action, so a hidden item's letter still works. Settings (tabbed,
theme) live on the start page, not the ring.

## Tests

`python3 -m unittest discover -s tests` runs in CI and needs nothing but python3
and node. It covers the functions that are pure and easy to break without
noticing: `site_host()`, `solve_contrast()` / `derive()`, and the answer card's
`reflow()`.

The JS functions are **not copied** into the tests. `tests/_load.py` cuts
`reflow` out of `AgentPanel.qml` and `siteHostOf` out of the service worker by
brace matching and runs them under node, so a test cannot pass against a stale
copy while the real function drifts. If you rename either, the loader fails
loudly, which is the point.

The one test that is not about a single function: **the CLI and the extension
must agree on a site's key.** `noren site add` saves a script under
`site_host()`; the extension looks it up under `siteHostOf()`. If they disagree
the script installs cleanly and never runs, and nothing anywhere says why.

Every test was checked by breaking the function it covers and watching it fail.
Do the same for a new one -- a test that has never failed has not been shown to
test anything.

## Chromium flattens its own /proc cmdline

`/proc/<pid>/cmdline` is normally NUL-separated fields. Chromium rewrites its
argv in place to set process titles, which collapses the NULs into spaces, so
for exactly the processes Noren inspects the whole command line arrives as a
*single* field. Anything of the shape

```python
args = open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0")
any(a.startswith(b"--type=") for a in args)      # never true
```

silently never matches. `browser_instances()` used that to filter out helper
processes; with 18 helpers running it excluded none of them, and only looked
correct because helpers do not carry `--load-extension` and so failed the
earlier test instead. `proc_cmdline()` flattens to one blob and every check is
a substring test against it.

## The url bar read the wrong profile's bookmarks

`profile_dir()` assumed `~/.config/<browser>/Default`. Chromium keeps bookmarks
and history inside whatever `--user-data-dir` it was launched with, so a browser
started on another profile was offered the default profile's data. The bridge
was always right -- `suggest` asks the extension, which sees the live profile --
and only the offline fallback was wrong, which made it look like a leak rather
than a bug: correct-looking results from one source, someone else's from the
other. `running_profile_dir()` reads the flag off the live process, falls back
to the default, and caches per invocation.

Found while recording a demo: a throwaway `--user-data-dir` with no history at
all still offered a full list. Worth remembering that the offline path and the
bridge path can disagree, and that the offline one is the one on screen when
the browser is closed.

## abspath does not resolve a symlink

`install.sh` links `bin/noren` into `~/.local/bin`, so every invocation a user
makes arrives through that link. `os.path.abspath(__file__)` returns
`~/.local/bin/noren` unchanged — it normalises, it does not resolve — so the
root came out as `~/.local`, and `doctor` went looking for the extension, the
pinned key and `noren_theme` inside it. It reported five failures and told the
user to reinstall a working install. Invisible from the repo, because
`./bin/noren doctor` is not a symlink and every test here had used that.

`NOREN_BIN` / `NOREN_ROOT` are computed once with `realpath` and everything
reads them. CI runs the CLI through a symlink on every push, which is the only
check that would have caught it.

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

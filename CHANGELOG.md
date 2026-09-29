# Changelog

## Unreleased

- **Stash.** `SUPER + M` → `Z` closes the page in front of you and keeps your
  place: scroll position and typed text included. A count on the Noren icon
  shows what is stashed. Bring pages back from the url bar (`~`), the bar
  or the reveal bar. The stash is a private local file that never syncs and
  never expires. `noren stash` from a terminal.
- **Party mode.** `SUPER + M` → `X`: a video playing in the window in front
  of you lights up the desktop. The window's border and glow take the colour
  of the picture; the bar gets drifting pools of light, a lit edge and an
  underglow; and it all moves with the music, a flare across the bar on every
  beat. Everything goes back to your theme the moment the video stops.
  `noren party on|off|toggle`, or the switch on the start page.
- Long page titles are trimmed in Noren's windows, keeping the site's name
  ("... / Site"), so a tab in a Hyprland group no longer spills off both ends of
  the group bar. History keeps the shorter title too.
- A window rule's border colour shows on the window when it is not focused
  too. `noren rules apply` rewrites the rules after an update like this one.
- **Window rules on the start page.** "When a page is on a site, has a login
  form, is playing... then change its opacity, border, rounding, blur, dim
  around it, or float it": saved and live the moment you change it, with
  recipes and the Lua it becomes. `noren rules` from a terminal.
- **Party mode is much lighter.** It was costing Hyprland ~25 ms of its own
  thread per frame, thirty times a second, which made the cursor lag. The
  group border alone was 20 ms; it is now set once, and the colours go at most
  fifteen times a second. The bar overlay and the page's sampling cost about
  half what they did.
- **Theatre mode.** `SUPER + M` → `E`: the video's player fills its window and
  everything else on screen dims. Escape leaves. It follows the player when a
  site moves it, so re-tiling the window does not lose the picture.
- **Window tags.** Every page window carries `noren:*` tags in Hyprland --
  its site, loading, playing, audible, a login form, unsent typing, theatre --
  so your own window rules can match on what a window shows. `noren tags`
  lists them.
- **Party in the background.** `noren party background on`, or its switch on
  the start page: the bar keeps dancing to a video playing beside the window
  you are working in.
- A group of one is not a group: close tabs down to the last page and it leaves
  group mode instead of keeping a tab strip with nothing to switch to.
- The Noren icon shows in the bar again. It had been in the layout at zero
  width. Its tooltip is the bar's own now, rather than an unstyled box drawn
  over the icon, and it no longer flips to an X-in-a-box while the shell or
  extension restarts.

- The service worker is plain `background.js` now. The filename used to be
  bumped to force Chromium to load new code; `noren reload-extension` does that,
  so the number only confused people. `install.sh` regenerates the manifest, so
  updating the documented way picks it up.
- Updating no longer asks for a browser restart and a click in
  `chrome://extensions` -- `noren reload-extension` loads the new code.
- Unit tests for site keys, contrast solving and answer reflow, run in CI.
- The closing animation is **off by default**. It hears about a close only
  after the window is gone, so it played 100–135 ms late, after Hyprland's own
  close animation: a flick, then the panels. `noren shatter curtain` turns it
  back on. Doing it properly means the panels go up before the window closes;
  DEVELOPMENT.md has the measurements and the plan.
- **Clips (experimental).** `SUPER + M` → `L`: point at part of a page and it
  opens as a small floating window showing only that, live. It scales with its
  window, survives a reload, and finds its element by heading when the page
  reorders itself. `noren clip` from a terminal.
- The radial shows only what applies to the window in front of you, and every
  letter still works when its item is hidden. Tabs and Theme moved to the start
  page's settings, where the other settings already were.
- `gather` leaves floating windows alone -- a clip, or a page set aside on
  purpose.
- **Steal a theme (experimental).** `SUPER + M` → `T` turns the colours of the
  page in front of you into an Omarchy theme, in a window with a live preview:
  repaint any colour from the page's own, flip it dark or light, turn the
  vividness up or down, and pick a wallpaper (yours, one of the page's
  pictures, or a gradient in the new colours, with a full-screen peek). Try it,
  put it back, or keep it. `noren steal` from a terminal.

## 0.01 alpha — 2026-09-20

First release anyone else can install. Noren has been driven daily on one
machine; this is the point where that stops being the only evidence.

**What works**

- **URL bar** (`SUPER + B`) — type to filter open tabs, bookmarks and history,
  or type a url. Enter opens a new tiled window; Ctrl+Enter replaces the page in
  front of you.
- **Radial menu** (`SUPER + M`) — back, forward, reload, the start page, the
  overview, gather, theme, and the agent.
- **Pages as windows** — `noren peel on` gives every new tab its own chrome-less
  Hyprland window. `gather` folds them into a group, `scatter` breaks it apart,
  `pop` lifts one out.
- **Start page** — bookmarks bar, most visited, and settings, all rendered from
  your Omarchy theme.
- **Reveal bar** — the browser furniture, on the page, only when you reach for it.
- **Sets** — name the pages you have open, reopen them in the shape you saved.
- **Page theming** — `respect`, `tint` or `immerse`, solved against the theme's
  own background so the result passes WCAG AA rather than merely matching hues.
- **Closing animation** — a page leaves like a curtain, or like glass.
- **Site scripts** — per-site CSS or JS, installed with `noren site add`, listed
  on the start page, switchable and deletable. They run on the pages you already
  have open, not just the next navigation.
- **Ask** (`SUPER + M` → `A`) — put a question about the page to whichever agent
  Omarchy is set to. The composer hands off to a card in the corner that narrates
  what the agent is doing and shows the answer when it lands. `--site` has it
  write a site script for the page you are on.
- **`noren doctor`** — checks the whole chain, browser to bridge, and names the
  broken link. Run it before anything else.

**Known rough edges**

- One browser at a time: the host owns a single socket, so a second instrumented
  browser silently has no extension. Doctor catches this.
- **Chromium only.** Other Chromium-family browsers will install and run, but
  are untested in 0.01 and support for them comes next; Firefox has no
  equivalent of the flags-file load at all.
- Developer mode must stay on in `chrome://extensions`, or Chromium disables the
  extension without saying why. Doctor decodes the reason.
- Brave's launcher passes its flags file as one quoted argument, so a file with
  more than one line drops every flag in it, silently. The installer warns. This
  is the kind of per-browser trap that keeps 0.01 to Chromium.
- Site scripts and `noren ask` are as safe as what you install and what you
  browse. [`SECURITY.md`](SECURITY.md) is not boilerplate; read it.
- Nothing here is API-stable. Settings, file layout and command names can move.

**Fixed after tagging**

- `--remove` could not undo an install made with `--browser` into a browser the
  script had no hardcoded entry for (Chrome, Vivaldi, Edge). It now removes what
  the installer recorded it wrote.
- `noren doctor` names the Omarchy and Hyprland versions, and says when Hyprland
  is not the one Noren's window handling was measured against.
- **The url bar offered the wrong profile's bookmarks and history** when
  Chromium ran with a non-default `--user-data-dir`. The offline reader assumed
  `~/.config/<browser>/Default`; it now reads the flag off the running process.
- **`noren doctor`'s helper-process filter never matched.** Chromium rewrites
  its argv in place, so `/proc/<pid>/cmdline` comes back as one space-separated
  blob rather than NUL-separated fields, and `--type=` was never found. The
  instance count was right only by accident.
- **`noren doctor` reported five failures on a working install** when run as
  `noren` rather than `./bin/noren`. The CLI derived its own location with
  `os.path.abspath`, which does not resolve a symlink — and install.sh puts a
  symlink on PATH, so this was every invocation a user would ever make. It told
  them to reinstall. Fixed with `realpath`, and CI now runs the CLI through a
  symlink on every push.

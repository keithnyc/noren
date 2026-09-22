# Changelog

## Unreleased

- The service worker is plain `background.js` now. The filename used to be
  bumped to force Chromium to load new code; `noren reload-extension` does that,
  so the number only confused people. `install.sh` regenerates the manifest, so
  updating the documented way picks it up.
- Updating no longer asks for a browser restart and a click in
  `chrome://extensions` -- `noren reload-extension` loads the new code.
- Unit tests for site keys, contrast solving and answer reflow, run in CI.

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

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
                    ▲
       extension/background-4.js    chrome.tabs.*, onCreated, onUpdated
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

**One browser at a time.** The host owns a single socket, so two instrumented
browsers would fight over it. `install.sh` clears Noren out of every other
browser when it installs.

**The extension key is per-machine and untracked.** `install.sh` generates
`host/noren-extension.pem` if absent, derives the extension id from it, and
injects the public key into `extension/manifest.json` (also untracked — seeded
from `manifest.json.template`). The id must match `allowed_origins` in the native
host manifest or `connectNative` is rejected. Losing the `.pem` changes the id
and breaks pairing; it is a private key and must never be committed.

## Environment facts that cost real time

**Developer Mode is required.** Since Chromium M137 an unpacked extension loaded
via `--load-extension` is *disabled on load* unless `chrome://extensions` →
Developer mode is on. Nothing reports it — not the UI, not stderr. The only
trace is `disable_reasons: [16777216]` in the profile's `Preferences`
(`1 << 24`, `DISABLE_UNSUPPORTED_DEVELOPER_EXTENSION`). Omarchy's own bundled
extensions predate the rule and were grandfathered, which is why they run
without it.

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

- **Theming.** The highest-certainty value and fully independent of everything
  above. Omarchy renders `/usr/share/omarchy/default/themed/*.tpl` into
  `~/.local/state/omarchy/current/theme/` on every theme switch, and
  `obsidian.css.tpl` / `vscode-theme.json.tpl` prove it already generates full
  structured theme files for third-party apps. Ship a `noren.css.tpl`.

  The template language has `{{ mix a b 20% }}` but **no contrast function**, so
  the clamp has to happen in the host. Do not map ANSI hues to semantic roles
  directly: measured on this machine, `success ← green` is 2.96:1 on
  catppuccin-latte and 4.39:1 on flexoki-light — both fail WCAG AA. Take hue and
  chroma from the palette, then solve lightness against the surface until it
  clears 4.5:1. Omarchy's shipped `obsidian.css.tpl:42` has exactly this bug and
  it is worth an upstream issue independent of Noren.

  Also: in light themes `lighter_background` is *darker* than `background` (and
  darker than `dark_background`). Read `mode` first; the names encode distance
  from the ground, not direction.

- **Workspace sessions** — each Hyprland workspace owning a named, restorable
  set of pages. Scope v1 to URL set + window order + profile. Restoring scroll
  position and page state is among the hardest problems in browsers and will
  swallow the project.
- **Gather** — the return path for peel. Pull a project's detached windows back
  into one group.
- **`peel on` is not sticky.** It lives in the service worker, so it resets when
  the last browser window closes. Worth persisting before a week-long test.
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

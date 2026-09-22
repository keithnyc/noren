# Installing Noren — a runbook for your agent

Point your coding agent at this repository and ask it to install Noren. This
file is written for the agent: it can run every step, and it stops to ask you
wherever a choice is yours or something on your screen is about to change.

People can follow it by hand too. Every step is an ordinary command.

---

## Agent: read this first

You are installing an Omarchy shell plugin plus a Chromium extension and a small
native host. The user may be new to Omarchy. Work through the steps in order,
say briefly what each one does before running it, and follow these rules:

- **Ask before anything the user would notice.** Quitting their browser closes
  their windows and tabs. Restarting the shell flickers the bar. Editing
  `~/.config/hypr/bindings.lua` changes their keyboard. Say what will happen and
  wait for a yes.
- **The user chooses the keys.** Propose the defaults in step 6, check them
  against what is already bound, and ask. Never overwrite an existing binding
  without asking.
- **Do not experiment with Hyprland dispatchers** (`hyprctl dispatch ...`,
  `hl.dsp.*`) to see what they do. Several act on whatever window is focused and
  ignore bad arguments — including the user's terminal. `hl.dsp.group.lock` is
  global and sticky. Nothing in this install needs a dispatcher.
- **When something fails, run `noren doctor` before guessing.** It checks the
  whole chain and names the broken link.
- **Show the user `SECURITY.md` before step 3.** This is an alpha that adds an
  extension with access to their tabs, bookmarks and history, turns on the
  browser's Developer mode, and — if they use `noren ask` — hands the page they
  are reading to their agent. Summarise those three facts in your own words and
  get a yes before running the installer. Do not paraphrase them away.
- `CLAUDE.md` and `DEVELOPMENT.md` are for people changing Noren's code. You do
  not need them to install it.

---

## 1. Check the machine

```bash
omarchy version 2>/dev/null || cat /usr/share/omarchy/version
ls ~/.config/hypr/bindings.lua
xdg-settings get default-web-browser
command -v python3 openssl git
```

- **Omarchy with Lua Hyprland config.** `~/.config/hypr/bindings.lua` must
  exist. Older Omarchy used `.conf` files; Noren's bindings are Lua.
- **Default browser must be Chromium.** Noren installs into whichever browser
  this reports, and 0.01 supports `chromium.desktop` only — Omarchy's default.
  Other Chromium-family browsers are coming; if this reports one of those, say
  so and let the user decide whether to switch their default or wait. If it
  reports something that is not Chromium-based at all, stop: Noren cannot work
  there.
- `python3`, `openssl` and `git` ship with Omarchy; if one is missing, say so.

## 2. Get the code

```bash
omarchy plugin add https://github.com/keithnyc/noren.git --enable --yes
```

If that fails with a 404 or an authentication prompt, the repository is not
public yet and the user needs access to it:

```bash
gh auth status || gh auth login          # interactive: the user signs in
gh auth setup-git
```

`gh auth login` opens a browser flow — tell the user it is coming and let them
do it, then run the `omarchy plugin add` again.

That clones into `~/.config/omarchy/plugins/io.github.keithnyc.noren/`. Use that
path as `NOREN` below.

```bash
NOREN=~/.config/omarchy/plugins/io.github.keithnyc.noren
```

## 3. Run the installer

```bash
"$NOREN/install.sh"
```

It generates a per-machine extension key (never committed), registers the
native host with the browser, adds the extension to the browser's flags file
(backing it up to `*.noren-backup` first), and links the `noren` command into
`~/.local/bin`. It is safe to run again. Show the user its output.

## 4. Turn on Developer mode — the user does this

Chromium disables extensions loaded from a folder unless Developer mode is on,
and says nothing when it does. This is a browser setting the user flips:

> Open **chrome://extensions** in a normal browser window and switch on
> **Developer mode** (top right).

Wait for them to confirm.

## 5. Restart the browser and the shell

**Ask first** — quitting the browser closes every window they have open.

```bash
pkill -x chromium        # use the real process name for their browser
omarchy-restart-shell
```

Do not use `pkill -f` with a path: it can match and kill the shell running the
command. Then ask the user to start the browser again (or run
`omarchy-launch-browser`), and wait a few seconds for it to come up.

## 6. Key bindings — ask the user

The suggested bindings:

```bash
"$NOREN/install.sh" --print-binds
```

| keys | does |
|---|---|
| `SUPER + B` | url bar: type a url, or search tabs, bookmarks and history |
| `SUPER + M` | radial menu: back, forward, reload, home, overview, gather, theme… |
| `SUPER + ]` / `SUPER + [` | next / previous page in a group, like switching tabs |

These are free on a stock Omarchy. Check this user's setup, since they may have
customised it:

```bash
hyprctl binds -j | python3 -c '
import json, sys
wanted = {(64, "b"), (64, "m"), (64, "bracketright"), (64, "bracketleft")}
for b in json.load(sys.stdin):
    if (b["modmask"], b["key"].lower()) in wanted:
        print(b["key"], "->", b.get("description") or b.get("arg"))'
```

(`modmask` 64 is SUPER alone.) Then **ask the user**, showing them the table and
any conflicts:

- use these keys as they are,
- pick different keys for any of them, or
- skip bindings for now (everything still works from the `noren` command).

If a key is taken, say what it currently does and offer an alternative such as
`SUPER + SHIFT + <key>` — check that one too before suggesting it. Only after
they agree, back up the file and append the block, with their chosen keys:

```bash
cp ~/.config/hypr/bindings.lua ~/.config/hypr/bindings.lua.noren-backup
"$NOREN/install.sh" --print-binds >> ~/.config/hypr/bindings.lua   # then edit keys if they chose others
hyprctl reload
```

The block is fenced by `-- >>> noren bindings` / `-- <<< noren bindings`, so it
is easy to find and remove later. `hyprctl reload` only re-reads config; it does
not move any windows. If a key they chose was already bound by Omarchy, use
`o.rebind` for it instead of `o.bind` (see the comments at the top of their
`bindings.lua`).

## 7. Verify

```bash
noren doctor
```

Every row should read `ok` once the browser is running. The usual failures:

| doctor row | means | fix |
|---|---|---|
| `extension enabled` — DEVELOPER MODE IS OFF | Chromium disabled the extension | step 4, then restart the browser |
| `--load-extension` fails | the flags file lacks Noren | run `install.sh` again, then step 5 |
| `native host manifest` fails | host not registered, or id mismatch | run `install.sh` again |
| `browser running` — no | nothing to connect to | start the browser |
| `bridge` — no socket | the extension has not connected yet | browser started before install, or not restarted fully: step 5 |
| browser instances — more than one | two copies started at once | quit every window of the browser, start it once |

`page theme` and `offline completion` are informational; a warning there does not
stop Noren working.

## 8. Show the user around

Suggest they try, in this order:

1. **`SUPER + B`**, type a site, **Enter** — it opens as a window with no browser
   chrome. **Ctrl + Enter** sends the window in front somewhere else instead.
2. **`SUPER + M`**, then **`H`** — the start page: pinned sites, most visited
   (collapsed; click to open), and sets. Press **`E`** there to edit.
3. **`noren peel on`** — every new tab (a middle-click, a link that opens a new
   tab) becomes its own window. This is the experiment Noren is built around;
   `noren peel off` undoes it.
4. Open two or three pages, then **`SUPER + M`**, **`G`** to gather them into one
   group, and **`SUPER + ]`** / **`SUPER + [`** to move between them.
5. In the url bar, **`@`** lists saved sets: type a name to save the pages open
   now, and Enter on a set reopens it later.

The README has the rest.

---

## Updating

```bash
omarchy plugin update io.github.keithnyc.noren
"$NOREN/install.sh"
```

Then load the new code: `noren reload-extension` (the extension and the host;
no browser restart needed) and `omarchy-restart-shell` (the overlay). If the
browser is closed, start it first -- starting it alone does not load new
extension code, the reload does. `noren doctor` should be all `ok` afterwards.

## Removing

```bash
"$NOREN/install.sh" --remove
omarchy plugin remove io.github.keithnyc.noren
```

Then delete the `-- >>> noren bindings` block from `~/.config/hypr/bindings.lua`
(ask first), run `hyprctl reload`, restart the browser and
`omarchy-restart-shell`.

`--remove` keeps the user's state -- saved sets, settings, site scripts -- and
prints where each piece is. `"$NOREN/install.sh" --purge` removes those too,
including the extension key, which means a later reinstall gets a new extension
id. Ask before purging.

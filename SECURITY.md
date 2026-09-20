# Security

Noren asks for a lot of access to your browser. This file says exactly how much,
what it does with it, and where the sharp edges are. Read it before you install
the alpha.

Found something that belongs here? Open an issue, or mail the address on the
GitHub profile if it is the kind of thing that should not be an issue yet.

## What gets installed

| | where | what it is |
|---|---|---|
| extension | `extension/`, loaded unpacked | a Chromium MV3 extension, added to your browser's flags file as `--load-extension=` |
| native host | `host/noren-host` | a Python process Chromium starts; it speaks native messaging on stdio and listens on a unix socket |
| shell plugin | `~/.config/omarchy/plugins/io.github.keithnyc.noren` | a symlink to this checkout; QML the Omarchy shell loads |
| command | `~/.local/bin/noren` | a symlink to `bin/noren` |
| skill | `~/.claude/skills/noren-site` | a symlink, only if `~/.claude` already exists |

`./install.sh --remove` undoes all five, using a record the installer keeps of
exactly which browser files it wrote to. `--purge` also deletes the state below.

Nothing is installed system-wide, nothing runs as root, and the installer never
asks for a password.

## Browser permissions, and why each one

- `tabs`, `webNavigation` — the url bar lists your open tabs and
  jumps to them; peeling moves a tab into its own window.
- `bookmarks`, `history` — the url bar completes from both. Read only, read
  locally, and the results go to Noren's own overlay.
- `scripting`, `host_permissions: http/https/file` — the reveal bar and site
  scripts are injected into pages.
- `nativeMessaging` — the bridge to `noren-host`.
- `storage`, `favicon` — settings, and tab icons drawn from Chromium's own cache.

The content script (`bar.js`) runs on every http/https page. It draws the reveal
bar and reports the page's title and url to the worker. It is not a keylogger,
it reads no form fields, and the worker refuses messages from anything but
Noren's own pages — but it is on every page, and you should know that.

Turning on **Developer mode** in `chrome://extensions` is required for an
unpacked extension. It also lets *any* unpacked extension run. That is a real
loosening of your browser, done for Noren's benefit, and it stays on after you
remove Noren unless you turn it off.

## Where the trust boundaries are

- **The host talks to one extension.** `install.sh` generates a 2048-bit RSA key
  per machine, derives the extension id from it, and writes that id into the
  native host manifest's `allowed_origins`. No other extension can start the
  host. The key is `chmod 600`, is in `.gitignore`, and never leaves your
  machine.
- **The socket is yours alone.** `$XDG_RUNTIME_DIR/noren.sock`, `chmod 600`, in
  a directory the kernel already restricts to your uid. Anything that can open
  it can drive your browser — which is to say, anything already running as you.
- **The page cannot reach the bridge.** A web page has no way to send a runtime
  message; `externally_connectable` is not set, so other extensions cannot
  either. The worker checks `sender.id` on every message, and the settings
  channel additionally requires the sender to be Noren's own start page.
- **Site scripts run in the page's world**, where there are no extension APIs at
  all. A site script cannot reach the bridge, the host, the CLI or Noren's state.

## Nothing leaves your machine — except one thing

Noren makes no network requests. Not the extension, not the host, not the CLI.
No telemetry, no analytics, no update check. The single `fetch()` in the
extension reads `chrome-extension://<id>/_favicon/`, which is Chromium's local
icon cache.

The exception is deliberate and you trigger it:

> **`noren ask` sends the page to your agent.** The page's url, title, your
> selection and its visible text are written to a file, and the agent Omarchy is
> configured to run is told to read it. If that agent is a cloud model, that
> page goes to whoever runs it. Do not ask about a page you would not paste.

Those files live in `$XDG_RUNTIME_DIR/noren-ask/`, a directory only you can
read. Anything older than six hours is swept on the next ask, and the whole
directory goes when you log out. `noren ask --last` shows what the most recent
one held.

## Site scripts: the sharpest edge

A site script is CSS or JavaScript you (or your agent) install for one host. It
is injected into that site's pages in the **main world**, with the site's own
origin. That means it can read and change anything on that site — including a
page you are logged into.

This is the same power as pasting into devtools, made persistent. Noren does not
sandbox it, because the page's world *is* the sandbox: the blast radius is one
site, and it is your site.

What Noren does do:

- refuses anything over 128 KB, and runs `node --check` on JavaScript if node is
  installed;
- warns when a script contains `fetch(`, `XMLHttpRequest`, `WebSocket`,
  `sendBeacon`, `eval(`, `document.cookie`, `import(` or `localStorage` — a
  script that styles a page needs none of them;
- keeps every script as a plain file under `~/.config/noren/sites/`, so you can
  read it;
- lists them all on the start page under Settings, with a switch and a delete,
  and at `noren site list`.

`noren site off <host>` disables one without deleting it; reload the page to get
it back as the site made it.

**Read what your agent wrote before you keep it.** Which leads to:

## Prompt injection

`noren ask --site` hands your agent the text of the page you are looking at, and
that page is not on your side. A page can contain text written to be read by an
agent rather than by you — instructions to install a script that does something
other than what you asked.

Your agent runs in your terminal, as you. Noren narrows what it is pointed at —
the prompt names the skill, the captured page, and the `noren site` subcommands,
and tells it not to go looking through Noren's source — but a prompt is guidance,
not a boundary. There is no sandbox here in 0.01.

So, for the alpha:

- run `noren ask` on pages you have some reason to trust;
- read the script it installs (`noren site list` prints the path);
- if a page's own content seems to be arguing with you about what the agent
  should do, that is the attack, and `noren site rm <host>` is the answer.

## State Noren keeps

| path | what |
|---|---|
| `~/.config/noren/` | settings, named sets, site scripts, the generated page theme |
| `~/.local/share/noren/` | the extension key backup, so a fresh clone keeps its id, and a list of the browser files the installer touched |
| `~/.cache/noren/host.log` | what the host spawned and why |
| `$XDG_RUNTIME_DIR/noren.sock`, `noren-ask/` | the bridge, and asks in flight |

`host.log` records urls Noren opened on your behalf. `noren log` prints it. It
is local, and `--purge` deletes it — worth knowing before you paste it into a
bug report.

## Reporting a bug

`noren doctor` is the right thing to attach. It prints paths (so, your username)
but no urls and no history. `noren log` does contain urls you visited — read it
before you paste it.

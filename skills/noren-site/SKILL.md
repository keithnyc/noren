---
name: noren-site
description: Write, install and iterate on a Noren site script — per-site CSS or JS that changes how one website behaves in Noren's chrome-less windows. Use when the user asks to fix, hide, restyle or improve a specific site ("hide the sidebar on this site", "make the comments wider", "dark-mode this page properly"), or mentions `noren site`.
---

# Noren site scripts

A site script is CSS or JS that Noren injects into **one website**. It is how a
user says "this site should behave differently for me" without anyone forking a
browser.

Your job: read the live page, write the smallest script that does what was
asked, install it, look at the result, and iterate.

## The rules

**Never edit Noren itself.** Not its source, not its plugin directory, not
`~/.config/noren/*.json`. Everything you need is a `noren site` command. If a
request seems to need changing Noren, say so and stop — that is a conversation
for the user, not a patch.

**One site per script.** A script installed for `x.example` runs only there.
Never ask for "all sites"; there is no such thing here, deliberately.

**It runs in the page's own world.** There are no extension APIs: `chrome.*` is
unreachable, and so are Noren's bridge, host, sets, bookmarks and every other
page. This is enforced by Chromium, not by you being careful. The practical
consequences:

- The page's own scripts *can* see what you write, so never put a secret,
  token or personal datum in a site script.
- You cannot call anything of Noren's from inside one. Don't try.
- The worst a bad script can do is break that one site's layout, which the user
  undoes with `noren site off <host>`.

**Do not fetch.** A script that styles a page has no reason to talk to the
network. `noren site add` flags network calls, `eval`, cookies and storage for
the user to read before trusting it — do not make them read that for no reason.

**Prefer CSS.** It cannot loop, cannot throw, and survives the site's own
re-rendering. Reach for JS only when the change is structural or needs an event.

## The workflow

```bash
noren site inspect            # the live page in front of the user, structurally
noren site inspect x.example  # or name the site
```

`inspect` prints the page's landmarks and biggest blocks with real selectors,
read from the page the user is logged into — which is not the page a fetch would
return. **Start here.** Selectors guessed from outside are why site scripts rot.

Write the file somewhere temporary, then:

```bash
noren site add x.example /tmp/x.css    # or .js
noren site shot x.example              # screenshot of that window; look at it
```

`shot` prints a PNG path. Open it. Iterate until the page looks right, then tell
the user what you installed and how to undo it:

```bash
noren site list               # what is installed, and the file paths
noren site off x.example      # keep the file, stop running it
noren site rm x.example       # delete it
```

**`add` runs the script on the pages that are already open** — it says so
(`running on 1 open page`). The user does not have to reload, and you should not
ask them to: if nothing changed, the script is wrong, not waiting. `noren site
apply x.example` runs it again after you edit the file in place.

Two consequences worth keeping in mind:

- Your script runs on a page that is mid-life, not one that just loaded. Guard
  for elements that already exist, and be idempotent — that is what makes
  applying to a live page safe.
- `off` and `rm` cannot un-run what a page already did. They stop the *next*
  load, so say "reload to get the site back as it was" rather than implying the
  page reverts on its own.

The user can see everything installed on the start page, under `S` → Site
scripts, and switch one off there without a terminal.

## Writing one that lasts

- **Guard everything.** `const el = document.querySelector(...); if (!el) return;`
  A site that changed its markup should leave the page alone, not throw.
- **Be idempotent.** Scripts re-run on every navigation within the site.
  Check for your own marker before adding anything.
- **Watch only if you must.** Sites that re-render will undo a one-shot change;
  a small `MutationObserver` on a specific container is the answer, never one on
  `document` that reacts to everything.
- **Keep selectors loose.** Prefer roles, landmarks and stable ids over
  generated class names (`.css-1x2y3z` will not survive the week).
- **Small.** A site script is a patch, not an application. The limit is 128KB
  and a good one is a page of CSS.

## What to tell the user afterwards

Name the file, what it does in one line, and the two commands that undo it. If
`noren site add` printed a note about `fetch`, `eval` or storage, explain why
your script uses it — or rewrite it so it does not.

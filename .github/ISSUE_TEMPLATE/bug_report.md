---
name: Something is broken
about: Noren did the wrong thing, or nothing
labels: bug
---

**Before anything else, run `noren doctor` and paste it here.**

```
(noren doctor output)
```

It prints paths, so your username is in it. It does not print urls or history.
`noren log` does contain urls you visited — read it before pasting any of it.

**What you did**

**What you expected**

**What happened instead**

**Which reload did you do?** (the answer is often the bug)

- [ ] `omarchy-restart-shell` — after changing QML
- [ ] `noren reload-extension` — after changing the extension or the host
- [ ] restarted the browser — note that this is *not* a reload: Chromium serves
      the cached service worker until something explicitly reloads the extension

**Machine**

- Omarchy version: `omarchy version`
- Noren version: `noren version`
- Browser:

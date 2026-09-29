// Noren signals -- what a page is doing, for Hyprland's window rules.
//
// Noren puts `noren:*` tags on each page window so Hyprland rules can match on
// what a window shows, not just its class. The worker knows the site, whether
// the tab is loading and whether it makes sound; only the page itself knows
// the rest, and this reports it:
//
//   playing  a video or audio element is playing (muted or not)
//   login    a password field is on the page
//   typing   you have typed something into a field that has not been sent
//
// Three booleans, sent only when one changes. Never a value, never what you
// typed: a rule needs to know *that* you are mid-sentence, nothing more.

(() => {
  if (window.top !== window) return;
  if (window.__norenSignals && typeof window.__norenSignals.destroy === 'function') {
    try {
      window.__norenSignals.destroy();
    } catch (e) {
      // Replaced either way.
    }
  }
  const stop = new AbortController();
  const signal = stop.signal;

  let last = '';
  let timer = null;
  const edited = new Set(); // fields the user has typed into

  function filled(el) {
    if (!el.isConnected) return false;
    if (el.isContentEditable) return (el.textContent || '').trim().length > 0;
    return String(el.value || '').trim().length > 0;
  }

  function measure() {
    let playing = false;
    for (const m of document.querySelectorAll('video, audio')) {
      if (!m.paused && !m.ended && m.readyState > 2) {
        playing = true;
        break;
      }
    }
    // Visible ones only: plenty of pages keep a hidden login form around.
    const login = Array.from(document.querySelectorAll('input[type="password"]'))
      .some((el) => el.offsetParent !== null || el.getClientRects().length > 0);
    for (const el of edited) if (!filled(el)) edited.delete(el);
    return { playing, login, typing: edited.size > 0 };
  }

  function report() {
    timer = null;
    const now = measure();
    const key = JSON.stringify(now);
    if (key === last) return;
    last = key;
    try {
      chrome.runtime.sendMessage({ norenSignals: now }).catch(() => {});
    } catch (e) {
      // The extension was reloaded under this copy; the new one takes over.
    }
  }

  function soon(ms = 250) {
    if (!timer) timer = setTimeout(report, ms);
  }

  // Typing: a person's keystrokes into a text field. Password fields are left
  // to `login`. Sent when the form is submitted, or emptied.
  document.addEventListener('input', (e) => {
    const el = e.target;
    if (!e.isTrusted || !el || el.type === 'password') return;
    if (el.isContentEditable || el.tagName === 'TEXTAREA'
      || (el.tagName === 'INPUT' && /^(text|search|email|url|tel|number|)$/.test(el.type || ''))) {
      edited.add(el);
      soon();
    }
  }, { capture: true, signal });
  document.addEventListener('submit', (e) => {
    for (const el of Array.from(edited)) if (e.target.contains(el)) edited.delete(el);
    soon();
  }, { capture: true, signal });

  // Media events do not bubble but do pass the document on the way down.
  for (const type of ['playing', 'pause', 'ended', 'emptied']) {
    document.addEventListener(type, () => soon(50), { capture: true, signal });
  }

  // A login form can appear without a navigation (single-page apps).
  const watcher = new MutationObserver(() => soon(600));
  watcher.observe(document.documentElement, { childList: true, subtree: true });

  window.__norenSignals = {
    destroy() {
      clearTimeout(timer);
      watcher.disconnect();
      stop.abort();
    },
  };

  soon(0);
})();

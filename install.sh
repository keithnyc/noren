#!/bin/bash
# Noren installer. Idempotent, and everything it touches is backed up or a symlink.
#   ./install.sh                  install into the default browser
#   ./install.sh --browser NAME   install into a specific one (chromium, brave-origin-beta, ...)
#   ./install.sh --remove         undo, from every browser it knows about
#   ./install.sh --print-binds    print suggested Hyprland bindings (changes nothing)

set -euo pipefail

NOREN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="io.github.keithnyc.noren"
PLUGIN_LINK="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
HOST_NAME="com.noren.bridge"
EXT_DIR="$NOREN_DIR/extension"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"

CLI_LINK="$HOME/.local/bin/noren"

say()  { printf '\033[32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[31m==>\033[0m %s\n' "$1" >&2; exit 1; }

# --- which browser -----------------------------------------------------------
#
# Only one browser can carry Noren at a time: the native host owns a single
# socket, so two instrumented browsers would fight over it. Default to whatever
# xdg-settings says, which is what omarchy-launch-webapp uses too.

detect_browser() {
  local desktop
  desktop="$(env -u BROWSER xdg-settings get default-web-browser 2>/dev/null || true)"
  [[ -n $desktop ]] || die "cannot determine the default browser; pass --browser"
  printf '%s' "${desktop%.desktop}"
}

# Chromium-family launchers on Arch are shell wrappers that declare both facts
# we need. Read them rather than hardcoding a table that rots.
resolve_paths() {
  local name="$1" bin desktop
  desktop="$(ls "$HOME/.local/share/applications/$name.desktop" \
                "/usr/share/applications/$name.desktop" 2>/dev/null | head -1 || true)"
  if [[ -n $desktop ]]; then
    bin="$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$desktop" | head -1)"
  else
    bin="$(command -v "$name" || true)"
  fi
  [[ -n $bin && -e $bin ]] || die "cannot find the launcher for '$name'"

  FLAGS_FILE=""
  DATA_DIR=""
  if file -b "$bin" | grep -qi 'shell script'; then
    FLAGS_FILE="$(sed -n 's/.*USER_FLAGS_FILE="\([^"]*\)".*/\1/p' "$bin" | head -1)"
    DATA_DIR="$(sed -n 's/.*CHROME_USER_DATA_DIR=\(.*\)$/\1/p' "$bin" | head -1)"
    FLAGS_FILE="${FLAGS_FILE/\$XDG_CONFIG_HOME/$CFG}"
    FLAGS_FILE="${FLAGS_FILE/\$HOME/$HOME}"
    DATA_DIR="${DATA_DIR/#\~/$HOME}"
    DATA_DIR="${DATA_DIR/\$HOME/$HOME}"
  fi
  # Plain chromium reads chromium-flags.conf and keeps its profile in ~/.config/chromium.
  [[ -n $FLAGS_FILE ]] || FLAGS_FILE="$CFG/$name-flags.conf"
  [[ -n $DATA_DIR   ]] || DATA_DIR="$CFG/$name"
  NMH_DIR="$DATA_DIR/NativeMessagingHosts"
}

# Every location Noren might have written to, for --remove.
KNOWN_FLAGS=(
  "$CFG/chromium-flags.conf"
  "$CFG/brave-flags.conf"
  "$CFG/brave-origin-flags.conf"
  "$CFG/brave-origin-beta-flags.conf"
)
KNOWN_NMH=(
  "$CFG/chromium/NativeMessagingHosts"
  "$CFG/BraveSoftware"/*/NativeMessagingHosts
)

strip_flag() {
  local file="$1"
  [[ -f $file ]] || return 0
  python3 - "$file" "$EXT_DIR" <<'PY'
import sys, pathlib
path, ext = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = path.read_text().splitlines()
out = []
for line in lines:
    if line.startswith("--load-extension="):
        parts = [p for p in line.split("=", 1)[1].split(",") if p and p != ext]
        if parts:
            out.append("--load-extension=" + ",".join(parts))
        continue
    out.append(line)
text = "\n".join(out)
path.write_text(text + "\n" if text.strip() else "")
PY
}

# --- suggested bindings ------------------------------------------------------
#
# Printed, never written: bindings.lua is the user's own file, and the keys are
# theirs to choose. INSTALL.md walks an agent through asking first. These keys
# are free on a stock Omarchy -- checked against default/hypr/bindings/*.lua.
# SUPER + ALT + LEFT/RIGHT are NOT: Omarchy uses them to move a window into a
# group, so back/forward live in the radial menu instead.

print_binds() {
  cat <<'LUA'
-- >>> noren bindings (managed by Noren's INSTALL.md; safe to edit)
-- Url bar: type a url, search tabs, bookmarks and history.
o.bind("SUPER + B", "Noren url bar", [[omarchy-shell shell toggle io.github.keithnyc.noren '{}']])
-- Radial menu: back, forward, reload, home, overview, gather, theme...
o.bind("SUPER + M", "Noren radial menu", [[omarchy-shell shell toggle io.github.keithnyc.noren '{"mode":"radial"}']])
-- Step through the pages in a group, like switching tabs.
o.bind("SUPER + BRACKETRIGHT", "Next window in group", hl.dsp.group.next())
o.bind("SUPER + BRACKETLEFT", "Previous window in group", hl.dsp.group.prev())
-- <<< noren bindings
LUA
}

if [[ ${1-} == "--print-binds" ]]; then
  print_binds
  exit 0
fi

# --- remove ------------------------------------------------------------------

if [[ ${1-} == "--remove" ]]; then
  [[ -L $PLUGIN_LINK ]] && rm -f "$PLUGIN_LINK" && say "unlinked plugin"
  [[ -L $CLI_LINK && $(readlink "$CLI_LINK") == "$NOREN_DIR/bin/noren" ]] \
    && rm -f "$CLI_LINK" && say "removed $CLI_LINK"
  for d in "${KNOWN_NMH[@]}"; do
    [[ -f $d/$HOST_NAME.json ]] && rm -f "$d/$HOST_NAME.json" && say "removed host manifest from $d"
  done
  for f in "${KNOWN_FLAGS[@]}"; do
    if [[ -f $f ]] && grep -q -- "$EXT_DIR" "$f"; then
      strip_flag "$f"
      say "removed extension from $(basename "$f")"
    fi
  done
  warn "restart your browser and run: omarchy-restart-shell"
  exit 0
fi

# --- install -----------------------------------------------------------------

BROWSER=""
if [[ ${1-} == "--browser" ]]; then
  BROWSER="${2-}"
  [[ -n $BROWSER ]] || die "--browser needs a name"
else
  BROWSER="$(detect_browser)"
fi

resolve_paths "$BROWSER"
say "target browser: $BROWSER"
say "  flags file:   $FLAGS_FILE"
say "  host dir:     $NMH_DIR"

# 0. extension identity -------------------------------------------------------
# The key pins the extension id, which the native host manifest's
# allowed_origins must match. Generate it once, per machine — it is a private
# key and never belongs in the repository.
KEY_BACKUP="${XDG_DATA_HOME:-$HOME/.local/share}/noren/noren-extension.pem"
if [[ ! -f $NOREN_DIR/host/noren-extension.pem ]]; then
  if [[ -f $KEY_BACKUP ]]; then
    # A fresh clone must keep the same extension id, or the host manifest's
    # allowed_origins stops matching and connectNative is silently rejected.
    install -m 600 "$KEY_BACKUP" "$NOREN_DIR/host/noren-extension.pem"
    say "restored extension key from $KEY_BACKUP"
  else
    openssl genrsa -out "$NOREN_DIR/host/noren-extension.pem" 2048 2>/dev/null
    chmod 600 "$NOREN_DIR/host/noren-extension.pem"
    say "generated a new extension key"
  fi
fi
# Keep the off-repo copy current, so the id survives deleting the checkout.
if [[ ! -f $KEY_BACKUP ]]; then
  mkdir -p "$(dirname "$KEY_BACKUP")" && chmod 700 "$(dirname "$KEY_BACKUP")"
  install -m 600 "$NOREN_DIR/host/noren-extension.pem" "$KEY_BACKUP"
  say "backed up extension key to $KEY_BACKUP"
fi
if [[ ! -f $NOREN_DIR/host/.extid || ! -f $NOREN_DIR/host/.pubkey ]]; then
  PUB=$(openssl rsa -in "$NOREN_DIR/host/noren-extension.pem" -pubout -outform DER 2>/dev/null | base64 -w0)
  printf '%s' "$PUB" >"$NOREN_DIR/host/.pubkey"
  python3 -c "
import base64, hashlib
der = base64.b64decode('$PUB')
h = hashlib.sha256(der).hexdigest()[:32]
print(''.join(chr(ord('a') + int(c, 16)) for c in h))
" >"$NOREN_DIR/host/.extid"
  say "derived extension id $(cat "$NOREN_DIR/host/.extid")"
fi
# manifest.json is generated, not tracked: it carries this machine's public key
# so the extension id stays stable across reloads. Seed it from the template.
if [[ ! -f $NOREN_DIR/extension/manifest.json ]]; then
  cp "$NOREN_DIR/extension/manifest.json.template" "$NOREN_DIR/extension/manifest.json"
  say "created extension/manifest.json from template"
fi
python3 - "$NOREN_DIR/extension/manifest.json" "$(cat "$NOREN_DIR/host/.pubkey")" <<'PYKEY'
import json, sys, pathlib
path, key = pathlib.Path(sys.argv[1]), sys.argv[2]
man = json.loads(path.read_text())
if man.get("key") != key:
    man["key"] = key
    path.write_text(json.dumps(man, indent=2) + "\n")
PYKEY

# 1. plugin -------------------------------------------------------------------
mkdir -p "$HOME/.config/omarchy/plugins"
if [[ $(realpath -m "$PLUGIN_LINK") == "$NOREN_DIR" ]]; then
  # Installed with `omarchy plugin add`, which clones straight into place.
  say "plugin already in place"
elif [[ -e $PLUGIN_LINK && ! -L $PLUGIN_LINK ]]; then
  warn "$PLUGIN_LINK exists and is not a symlink — leaving it alone"
else
  ln -sfn "$NOREN_DIR" "$PLUGIN_LINK"
  say "linked plugin"
fi

# 2. native messaging host ----------------------------------------------------
# Clear any stale pairing in other browsers first, so only one host can start.
for d in "${KNOWN_NMH[@]}"; do
  [[ -d $d && $d != "$NMH_DIR" && -f $d/$HOST_NAME.json ]] && rm -f "$d/$HOST_NAME.json" \
    && warn "removed an older host manifest from $d"
done
for f in "${KNOWN_FLAGS[@]}"; do
  if [[ -f $f && $f != "$FLAGS_FILE" ]] && grep -q -- "$EXT_DIR" "$f"; then
    strip_flag "$f"
    warn "removed Noren from $(basename "$f") so only one browser carries it"
  fi
done

EXT_ID="$(cat "$NOREN_DIR/host/.extid")"
mkdir -p "$NMH_DIR"
cat > "$NMH_DIR/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Noren browser bridge",
  "path": "$NOREN_DIR/host/noren-host",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXT_ID/"
  ]
}
EOF
say "installed native host manifest for extension $EXT_ID"

# 3. flags --------------------------------------------------------------------
touch "$FLAGS_FILE"
cp -f "$FLAGS_FILE" "$FLAGS_FILE.noren-backup"
python3 - "$FLAGS_FILE" "$EXT_DIR" <<'PY'
import sys, pathlib
path, ext = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = [l for l in path.read_text().splitlines() if l.strip()]
for i, line in enumerate(lines):
    if line.startswith("--load-extension="):
        parts = [p for p in line.split("=", 1)[1].split(",") if p]
        if ext not in parts:
            parts.append(ext)
        lines[i] = "--load-extension=" + ",".join(parts)
        break
else:
    lines.append("--load-extension=" + ext)
path.write_text("\n".join(lines) + "\n")
PY
say "added extension to $(basename "$FLAGS_FILE") (backup alongside it)"

# Brave's launcher passes the whole flags file as ONE quoted argument
# ("$USER_FLAGS"), so a file with more than one line reaches the browser as a
# single malformed switch and every flag in it is silently ignored.
if [[ $(grep -c . "$FLAGS_FILE") -gt 1 ]] && grep -q 'USER_FLAGS' "$(command -v "$BROWSER" || echo /dev/null)" 2>/dev/null; then
  warn "$(basename "$FLAGS_FILE") now has more than one line."
  warn "This launcher passes the file as a single quoted argument, so multiple"
  warn "lines are silently ignored. Noren may not load. See README."
fi

chmod +x "$NOREN_DIR/host/noren-host" "$NOREN_DIR/bin/noren"

# 4. the cli on PATH ------------------------------------------------------------
# Every doc says `noren doctor`; that should work without knowing where the
# plugin was cloned. Never replace a `noren` that is not ours.
mkdir -p "$(dirname "$CLI_LINK")"
if [[ -e $CLI_LINK && ! -L $CLI_LINK ]]; then
  warn "$CLI_LINK exists and is not a symlink -- leaving it alone"
else
  ln -sfn "$NOREN_DIR/bin/noren" "$CLI_LINK"
  say "linked the noren command into $(dirname "$CLI_LINK")"
fi

cat <<EOF

Installed for $BROWSER. Left to do:

  1. In $BROWSER, open chrome://extensions and turn on Developer mode
     (Chromium silently disables Noren's extension without it)
  2. Quit $BROWSER completely, then start it again
  3. omarchy-restart-shell
  4. Add key bindings -- see: $NOREN_DIR/install.sh --print-binds

Then check everything:

  noren doctor

EOF

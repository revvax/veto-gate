#!/usr/bin/env bash
# install.sh — installs veto-gate into ~/.claude (symlinks + settings.json wiring).
# Never overwrites a foreign file. Backs up settings.json before touching it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET_HOOKS="$HOME/.claude/hooks"
TARGET_LIB="$TARGET_HOOKS/lib/veto-gate"
SETTINGS="$HOME/.claude/settings.json"

echo "veto-gate installer"
echo

MISSING=0
# perl is a hard dependency, not a nicety: grounding's A2 stage is written in it
# and silently checks nothing without it (same list as in `veto-gate doctor` —
# checked here too, so a broken system is caught before anything is linked).
# Naming the fix on the spot, not just the gap: "jq missing" sends people to a
# search engine, `brew install jq` sends them to a working install.
for dep in git python3 jq perl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "⛔ required, missing: $dep"; MISSING=1; }
done
if [ "$MISSING" = 1 ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "   git/python3/perl:  xcode-select --install"
    echo "   jq:                brew install jq"
  else
    echo "   install them with your package manager"
  fi
fi
if [ "${BASH_VERSINFO[0]}" -lt 3 ]; then echo "⛔ bash too old (required: >=3)"; MISSING=1; fi
if [ "$MISSING" = 1 ]; then echo "Aborted — required dependencies are missing. Nothing was changed."; exit 1; fi

if command -v codex >/dev/null 2>&1; then
  echo "✓ codex CLI found"
else
  echo "⚠ codex CLI missing — the gate then blocks EVERY commit (fail-closed):"
  echo "   npm install -g @openai/codex && codex login"
fi

# settings.json validity is checked FIRST, before any symlink is created —
# checking it only after linking would leave a half-installed state (hooks
# linked, but the abort on invalid JSON happens too late and the gate still
# isn't wired in).
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if ! jq -e '.' "$SETTINGS" >/dev/null 2>&1; then
  echo "⛔ settings.json ist kein gültiges JSON — nichts wird angefasst: $SETTINGS"
  exit 1
fi

mkdir -p "$TARGET_LIB"
FAIL=0
link() {
  local src="$1" dst="$2"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "⛔ $dst existiert schon (keine Verknüpfung) — nicht überschrieben"; FAIL=1; return
  fi
  if [ -L "$dst" ] && [ "$(readlink "$dst")" != "$src" ]; then
    echo "⛔ $dst zeigt schon auf etwas anderes — nicht überschrieben"; FAIL=1; return
  fi
  if ln -sf "$src" "$dst"; then
    echo "✓ $dst → $src"
  else
    echo "⛔ Verknüpfen fehlgeschlagen: $dst → $src"; FAIL=1
  fi
}
link "$HERE/hooks/veto-gate.sh" "$TARGET_HOOKS/veto-gate.sh"
link "$HERE/hooks/lib/veto-cfg.sh" "$TARGET_HOOKS/lib/veto-cfg.sh"
for f in "$HERE"/hooks/lib/veto-gate/*; do
  link "$f" "$TARGET_LIB/$(basename "$f")"
done
if [ "$FAIL" = 1 ]; then echo "Installation unvollständig — s.o."; exit 1; fi

cp "$SETTINGS" "$SETTINGS.bak-$(date +%s)"
ALREADY=$(jq '[(.hooks.PreToolUse // [])[] | select(.matcher=="Bash" and .hooks==[{"type":"command","command":"$HOME/.claude/hooks/veto-gate.sh"}])] | length' "$SETTINGS")
if [ "$ALREADY" -gt 0 ]; then
  echo "✓ settings.json: veto-gate schon verdrahtet"
else
  TMP=$(mktemp)
  if jq '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/veto-gate.sh"}]}])' \
       "$SETTINGS" > "$TMP" && [ -s "$TMP" ]; then
    mv "$TMP" "$SETTINGS"
    echo "✓ settings.json: veto-gate verdrahtet (Backup: $SETTINGS.bak-*)"
  else
    rm -f "$TMP"
    echo "⛔ settings.json NICHT geändert — jq-Lauf ist fehlgeschlagen. Gate ist NICHT aktiv. Original unverändert: $SETTINGS"
    exit 1
  fi
fi

# `veto-gate enable` lives here, so the last hand-written step of the install
# only disappears when this link exists — worth creating the directory for.
mkdir -p "$HOME/.local/bin" 2>/dev/null || true
if [ -d "$HOME/.local/bin" ]; then
  # optional convenience only — the gate is already fully active at this point
  # (hooks linked, settings.json wired above), so a conflict here is a warning,
  # not a reason to fail the whole install; link() already prints the ⛔ line.
  link "$TARGET_LIB/veto-gate-cli.sh" "$HOME/.local/bin/veto-gate"
else
  echo "ⓘ ~/.local/bin not usable — call it directly: bash $TARGET_LIB/veto-gate-cli.sh"
fi

# Run from boot.sh, the closing advice is printed there — once, and including the
# steps boot knows about (codex login). Two "Next:" blocks in a row read like the
# thing ran twice.
if [ "${VETO_GATE_BOOT:-0}" != 1 ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "ⓘ ~/.local/bin is not on your PATH — add it, or call: bash $TARGET_LIB/veto-gate-cli.sh";;
  esac
  echo
  echo "Done. Next:"
  echo "  veto-gate doctor                        # self-check"
  echo "  cd <your-project> && veto-gate enable   # switch the gate on for one repo"
fi

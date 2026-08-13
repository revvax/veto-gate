#!/usr/bin/env bash
# uninstall.sh — removes exactly what install.sh created. Backups are left in
# place (safety net, not this script's job to restore).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET_HOOKS="$HOME/.claude/hooks"
TARGET_LIB="$TARGET_HOOKS/lib/veto-gate"
SETTINGS="$HOME/.claude/settings.json"

unlink_if_ours() {
  local src="$1" dst="$2"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    rm "$dst"; echo "✓ entfernt: $dst"
  fi
}
unlink_if_ours "$HERE/hooks/veto-gate.sh" "$TARGET_HOOKS/veto-gate.sh"
unlink_if_ours "$HERE/hooks/lib/veto-cfg.sh" "$TARGET_HOOKS/lib/veto-cfg.sh"
for f in "$HERE"/hooks/lib/veto-gate/*; do
  unlink_if_ours "$f" "$TARGET_LIB/$(basename "$f")"
done
if [ -L "$HOME/.local/bin/veto-gate" ] && [ "$(readlink "$HOME/.local/bin/veto-gate")" = "$TARGET_LIB/veto-gate-cli.sh" ]; then
  rm "$HOME/.local/bin/veto-gate"; echo "✓ entfernt: ~/.local/bin/veto-gate"
fi
if [ -L "$HOME/.local/bin/veto2" ] && [ "$(readlink "$HOME/.local/bin/veto2")" = "$TARGET_LIB/veto2.sh" ]; then
  rm "$HOME/.local/bin/veto2"; echo "✓ entfernt: ~/.local/bin/veto2"
fi

if [ -f "$SETTINGS" ]; then
  TMP=$(mktemp)
  if jq '.hooks.PreToolUse = [(.hooks.PreToolUse // [])[] | select(
           (.matcher != "Bash") or
           (.hooks != [{"type":"command","command":"$HOME/.claude/hooks/veto-gate.sh"}])
         )]' "$SETTINGS" > "$TMP" && [ -s "$TMP" ]; then
    mv "$TMP" "$SETTINGS"
    echo "✓ settings.json: veto-gate-Eintrag entfernt (Backups bleiben liegen: $SETTINGS.bak-*)"
  else
    rm -f "$TMP"
    echo "⛔ settings.json NICHT geändert — jq-Lauf ist fehlgeschlagen. Gate-Eintrag ist NOCH AKTIV. Von Hand prüfen: $SETTINGS"
    exit 1
  fi
fi
echo "Fertig."

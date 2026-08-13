#!/usr/bin/env bash
# secret-scan.sh — scans a tree for secret-shaped strings before any push.
# Usage: secret-scan.sh [DIR]   (default: this script's own directory)
# Exit 0 = clean. Exit 1 = at least one match (printed as file:line, redacted).
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")" && pwd)}"
PATTERN='sk-[a-zA-Z0-9]{10,}|api[_-]?key["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][a-zA-Z0-9]|-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----|ghp_[a-zA-Z0-9]{20,}|discord\.com/api/webhooks/[0-9]|/Users/[a-zA-Z0-9_-]+/'

FOUND=0
while IFS= read -r -d '' f; do
  # Only file:line, NEVER the matched content itself — printing the real
  # secret into a scan log would defeat the whole point (a saved CI/terminal
  # log would then hold the secret permanently, in plain text).
  if LINES=$(grep -noEI "$PATTERN" "$f" 2>/dev/null | cut -d: -f1); then
    printf '%s\n' "$LINES" | while IFS= read -r ln; do
      printf '%s:%s: [GESCHWÄRZT — Geheimnis-Muster gefunden, Inhalt nicht ausgegeben]\n' "$f" "$ln"
    done
    FOUND=1
  fi
done < <(find "$ROOT" -type f -not -path '*/.git/*' -print0)
# Every file, not just a curated extension list — .env/.pem/.key/extensionless
# files must be caught too. `-I` on grep skips binaries on its own.

if [ "$FOUND" = 1 ]; then
  echo "⛔ secret-scan: Treffer oben — NICHT pushen, bis geklärt" >&2
  exit 1
fi
echo "✓ secret-scan: sauber, kein Treffer"
exit 0

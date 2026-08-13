#!/usr/bin/env bash
# diff-size.sh — deterministic size of a diff: changed (+/-) lines, EXCLUDING
# doc files (.md/.txt/.log — same doc definition as auto-push.sh) and diff
# headers. Doc exemption is by design: plans and the sanctioned auto-sync doc
# channel must never size-block (F18c); code lines always count. 0 tokens.
#
# --lockfile-lines reports the machine-written share (see generated-files.sh) of
# that same count, as a SEPARATE number. Deliberately not an exemption inside the
# total: pre-commit.sh treats CHANGED==0 as "docs only" and skips the reviewers
# entirely, so a lockfile that vanished from the total would make a lockfile-only
# commit — an unreviewed `npm install` — look exactly like a doc commit. The size
# gate subtracts this number itself; every other caller keeps the honest total.
set -uo pipefail
# A missing shared list must fail LOUDLY, not quietly count everything as code or
# nothing at all: callers decide from this number whether a commit is too big, and
# both pre-commit.sh and the gate treat a non-numeric answer as "checker broken →
# block". Printing a number here on a broken install would be the silent-pass hole.
if ! . "$(dirname "$0")/generated-files.sh" 2>/dev/null || [ -z "${VETO_GENERATED_ERE:-}" ]; then
  echo "diff-size: generated-files.sh fehlt oder ist unbrauchbar — Zählung unmöglich" >&2
  exit 70
fi
DIFF=""; MODE=code
while [ $# -gt 0 ]; do case "$1" in
  --diff) DIFF="$2"; shift 2;;
  --lockfile-lines) MODE=lock; shift;;
  *) echo "unknown arg: $1" >&2; exit 64;;
esac; done
[ -f "$DIFF" ] || { echo 0; exit 0; }
# deletions have '+++ /dev/null' — classify them via the '--- a/' side and
# reset per file so a deleted code file after a doc file still counts
# (codex live finding); '+++ b/' wins when both sides exist (renames).
#
# The lockfile pattern travels through ENVIRON, not -v: awk runs escape processing
# on a -v value, which would turn every `\.` in the pattern into a bare `.` and
# quietly widen it to match any character.
GEN="$VETO_GENERATED_ERE" MODE="$MODE" awk '
  BEGIN { gen=ENVIRON["GEN"]; mode=ENVIRON["MODE"] }
  /^diff --git/ { doc=0; lock=0; next }
  /^--- a\//    { g=substr($0,7); doc=(g ~ /\.(md|txt|log)$/); lock=(g ~ gen); next }
  /^\+\+\+ b\// { f=substr($0,7); doc=(f ~ /\.(md|txt|log)$/); lock=(f ~ gen); next }
  /^(\+\+\+|---)/ { next }
  /^[+-]/ { if (mode == "lock") { if (lock) n++ } else if (!doc) n++ }
  END { print n+0 }
' "$DIFF"

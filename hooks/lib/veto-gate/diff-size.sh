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
  --ws-lines) MODE=ws; shift;;
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
#
# --ws-lines reports the share of that count that changed ONLY in whitespace — a
# re-indent. Measured on a real product commit: 1081 changed lines, 15 with `git diff -w`.
# Same contract as the lockfile share: a SEPARATE number, subtracted only by the size
# gate. CHANGED stays whole, because in Python or YAML an indent IS logic and the
# reviewers must still see and weigh it — only the "too big to judge" limit ignores it.
# Pairing is per hunk: a removed and an added line that are equal once all whitespace
# is gone cancel out, both lines counted. Lockfile lines are left out here, so the two
# shares can never subtract the same line twice.
GEN="$VETO_GENERATED_ERE" MODE="$MODE" awk '
  function flush(   k) {
    for (k in add) { while (add[k] > 0 && rem[k] > 0) { add[k]--; rem[k]--; ws += 2 } }
    split("", add); split("", rem)
  }
  BEGIN { gen=ENVIRON["GEN"]; mode=ENVIRON["MODE"] }
  /^diff --git/ { flush(); doc=0; lock=0; next }
  /^@@/         { flush(); next }
  /^--- a\//    { flush(); g=substr($0,7); doc=(g ~ /\.(md|txt|log)$/); lock=(g ~ gen); next }
  /^\+\+\+ b\// { flush(); f=substr($0,7); doc=(f ~ /\.(md|txt|log)$/); lock=(f ~ gen); next }
  /^(\+\+\+|---)/ { next }
  /^[+-]/ {
    if (mode == "lock") { if (lock) n++ } else if (!doc) n++
    if (mode == "ws" && !doc && !lock) {
      k = substr($0, 2); gsub(/[ \t\r]/, "", k)
      if (substr($0, 1, 1) == "+") add[k]++; else rem[k]++
    }
  }
  END { flush(); if (mode == "ws") print ws+0; else print n+0 }
' "$DIFF"

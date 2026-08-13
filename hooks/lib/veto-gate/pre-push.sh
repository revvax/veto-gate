#!/usr/bin/env bash
# pre-push.sh — the SECOND evidence stage (council 2026-07-14).
#
# The commit gate proves the CHANGE: only the tests related to the changed files, seconds.
# This proves the SUITE: every unit test. The merge proves EVERYTHING, in CI, where it cannot be
# bypassed.
#
# Why not everything at commit time: 1090 test files per commit is not safety, it is how a gate gets
# bypassed — --no-verify, disabled hooks, giant commits — and then nothing is checked at all.
#   "Der lokale Commit ist nicht die letzte Sicherheitsgrenze. Der Merge ist sie."
#
# This file is also the RECEIPT for that decision. Narrowing the commit-time run and merely PROMISING
# that the full suite runs at the push would have been a claim without evidence — the very thing the
# gate blocks in commit messages. A promise nobody built is a comforting noise.
#
# Exit 1 blocks the push. A check that COULD NOT run never blocks — but it never stays silent either.
set -uo pipefail

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$REPO" ] || exit 0
LIB="$(cd "$(dirname "$0")" && pwd)"

RES=$(bash "$LIB/run-tests.sh" --repo "$REPO" --scope push 2>/dev/null)
ST=$(printf '%s' "$RES" | jq -r '.status // ""' 2>/dev/null)
DT=$(printf '%s' "$RES" | jq -r '.detail // "?"' 2>/dev/null)
DUR=$(printf '%s' "$RES" | jq -r '.dur // 0' 2>/dev/null)
[ -n "$ST" ] || { ST=unavailable; DT="run-tests.sh lieferte keine Antwort — nichts bewiesen"; }

case "$ST" in
  pass)
    echo "✅ VETO-GATE (push): Unit-Suite grün (${DUR}s) — $DT" >&2
    exit 0;;
  fail)
    {
      echo "⛔ VETO-GATE (push): Unit-Suite ROT — Push geblockt."
      echo "  $DT"
      echo "Das ist der Schaden, den die Commit-Prüfung nicht sehen konnte: sie testet nur die"
      echo "geänderten Dateien. Erst grün machen, dann pushen."
      echo "Notausgang (bewusst): git push --no-verify"
    } >&2
    exit 1;;
  *)
    # not_applicable / unavailable / skipped → never block a push, but never stay silent either:
    # 'nothing was proven' is information, and hiding it is how a gate becomes decoration.
    echo "⚠️ VETO-GATE (push): Unit-Suite NICHT gelaufen — $DT" >&2
    exit 0;;
esac

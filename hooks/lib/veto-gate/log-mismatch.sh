#!/usr/bin/env bash
# log-mismatch.sh — one line per run that triage sized 'light' but that a reviewer
# blocked anyway with a real finding. That is the closed loop (UL-006): a wrong sizing
# punishes itself with evidence. Stufe 1b later raises the floor from these entries.
#
# Own file, not a field in runs.jsonl: log-run.sh caps that log at 1000 lines, and
# mismatches are exactly the rare data 1b needs — they must not rotate out first.
#
# Append-only, and deliberately NOT self-truncating: truncation was the only step that
# needed a lock (a concurrent run could replace the file right after another appended
# to it, losing that entry — codex find). A mismatch is by definition rare, so a cap
# buys nothing; and a ledger that does grow is a signal to act on, not a storage
# problem. Each line is one small O_APPEND write, which needs no lock of its own.
set -uo pipefail
LOG_DIR="${VETO_GATE_LOG_DIR:-}"
if [ -z "$LOG_DIR" ]; then
  # No VETO_GATE_LOG_DIR and no HOME → nowhere safe to write. Exit 0, because the promise
  # is never to break a caller (bare $HOME would abort here under `set -u`), and a
  # relative path would litter whatever directory the commit happened to run in.
  [ -n "${HOME:-}" ] || exit 0
  LOG_DIR="$HOME/.claude/veto-gate"
fi
REPO=""; BRANCH=""; PROFILE=""; EFFORT=""; CHANGED=0; RESULT=""; BLOCKING=0
# ${2:-} everywhere: a flag without its value would abort under `set -u`, and a script
# that promises never to crash a commit must not die on its own caller's typo (codex).
# The shift is shared: a bare `shift 2` on a trailing flag shifts NOTHING (it fails
# when fewer than 2 args remain), so $# never reaches 0 and the loop spins forever —
# worse than the crash it was meant to prevent. Shift what is actually there.
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:-}";;
    --branch)   BRANCH="${2:-}";;
    --profile)  PROFILE="${2:-}";;
    --effort)   EFFORT="${2:-}";;
    --changed)  CHANGED="${2:-0}";;
    --result)   RESULT="${2:-}";;
    --blocking) BLOCKING="${2:-0}";;
    *) shift; continue;;
  esac
  shift 2 2>/dev/null || shift $#
done
# Only a LIGHT run can be a mismatch. The condition lives here, at one place, so every
# caller may call unconditionally and no block site can forget it.
[ "$PROFILE" = light ] || exit 0
case "$BLOCKING" in ''|*[!0-9]*) BLOCKING=0;; esac
# An unreadable --changed is NOT 0. Here 0 means "pure doc diff" — the very state that
# unlocks the light profile — so storing it for an unknown value would teach Stufe 1b
# a fact that was never measured. null keeps "we don't know" apart from "zero code
# lines", the same distinction triage.sh makes with -1 (codex find).
case "$CHANGED" in ''|*[!0-9]*) CHANGED=null;; esac
# ...and only a block with a REAL finding proves the sizing was wrong. A block with no
# findings (or an unreadable count) is not evidence: logging it would teach Stufe 1b
# from noise and tighten the floor for nothing (codex find).
[ "$BLOCKING" -gt 0 ] || exit 0
# Bound every text field, so one entry always stays a single small write — that, not a
# lock, is what makes the append safe: an unbounded field could grow a line past what
# one write() delivers atomically and interleave with a concurrent run's (codex find).
# Bounding the input is cheaper and clearer than a lock directory, and nothing reading
# this ledger needs more than a repo name, a branch and a result label.
b(){ printf '%.200s' "$1"; }
REPO=$(b "$REPO"); BRANCH=$(b "$BRANCH"); RESULT=$(b "$RESULT")
EFFORT=$(b "$EFFORT"); PROFILE=$(b "$PROFILE")
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
LOG="$LOG_DIR/triage-mismatch.jsonl"
# A ledger that crashes a commit would be worse than a missing entry — every failure
# path below exits 0.
jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg repo "$REPO" --arg br "$BRANCH" \
  --arg profile "$PROFILE" --arg effort "$EFFORT" --argjson changed "$CHANGED" \
  --arg res "$RESULT" --argjson blk "$BLOCKING" \
  '{ts:$ts,repo:$repo,branch:$br,profile:$profile,effort:$effort,changed:$changed,result:$res,blocking:$blk}' \
  >> "$LOG" 2>/dev/null || exit 0
exit 0

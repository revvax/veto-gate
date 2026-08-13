#!/usr/bin/env bash
# codex-diff-review.sh — run codex read-only over a diff bundle, emit verdict JSON.
# Two capped attempts: attempt 1 = $VETO_GATE_TIMEOUT s (default 60), attempt 2 =
# $VETO_GATE_TIMEOUT2 s (default = attempt 1). If codex runs longer it is KILLED.
# Exit 0 with verdict on success. Exit 3 if BOTH attempts time out / fail — the
# caller treats exit 3 as "could not review" and BLOCKS the commit (fail-closed),
# it is NOT waved through. Exit 64 on bad args.
set -uo pipefail

BUNDLE=""; EFFORT="high"
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2;;
    --effort) EFFORT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 64;;
  esac
done
[ -d "$BUNDLE" ] || { echo "bundle not found: $BUNDLE" >&2; exit 64; }
[ -f "$BUNDLE/REVIEW_PROMPT.md" ] || { echo "no REVIEW_PROMPT.md in bundle" >&2; exit 64; }

CODEX_BIN="${CODEX_BIN:-codex}"
T1="${VETO_GATE_TIMEOUT:-60}"
T2="${VETO_GATE_TIMEOUT2:-$T1}"
VERDICT="$BUNDLE/verdict.txt"; EVENTS="$BUNDLE/events.jsonl"

# One capped attempt ($1 = timeout seconds). Returns 0 iff a valid verdict was
# produced within the cap; if codex runs longer it is killed (→ non-zero).
attempt() {
  local T="$1"
  : > "$EVENTS"; : > "$VERDICT"
  "$CODEX_BIN" exec -s read-only --skip-git-repo-check -C "$BUNDLE" \
    -c model_reasoning_effort="$EFFORT" --json -o "$VERDICT" - \
    < "$BUNDLE/REVIEW_PROMPT.md" > "$EVENTS" 2>/dev/null &
  local p=$!
  # NB: redirect the watcher's fds so it never holds the command-substitution
  # stdout pipe open — otherwise $(...) blocks for the full timeout even on a
  # fast success (an orphaned `sleep` would keep the pipe alive).
  ( sleep "$T"; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 </dev/null & local w=$!
  disown "$w" 2>/dev/null || true   # don't let bash print a "Killed" job notice
  # fail FAST on a codex error event (quota/auth/…): the error is final,
  # waiting out the full cap would burn minutes for nothing (F20)
  ( while kill -0 "$p" 2>/dev/null; do
      grep -q '"type":"error"' "$EVENTS" 2>/dev/null && { kill -KILL "$p" 2>/dev/null; break; }
      sleep 1
    done ) >/dev/null 2>&1 </dev/null & local e=$!
  disown "$e" 2>/dev/null || true
  wait "$p" 2>/dev/null
  kill -KILL "$w" 2>/dev/null       # stop the watcher subshell
  pkill -KILL -P "$w" 2>/dev/null   # and its `sleep` child (no orphans)
  wait "$w" 2>/dev/null
  kill -KILL "$e" 2>/dev/null       # stop the error watcher too
  pkill -KILL -P "$e" 2>/dev/null
  wait "$e" 2>/dev/null
  grep -q '"type":"thread.started"' "$EVENTS" 2>/dev/null \
    && [ -s "$VERDICT" ] \
    && jq -e 'has("blocking")' "$VERDICT" >/dev/null 2>&1
}

# a reported codex error (quota, auth, …) is FINAL — retrying cannot heal it
codex_error(){ jq -r 'select(.type=="error") | .message' "$EVENTS" 2>/dev/null | head -1; }

LOG_DIR="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}"

# B7: remember the quota window. If a usage-limit error names a reset time
# ('try again at 5:28 PM' / 'try again in 2 hours 30 minutes'), persist it so
# the gate stops running into a closed window and the panel can count down.
# Written ATOMICALLY (tmp in the same dir + mv — a parallel gate run must
# never read a half-written file, codex plan-review finding B7-RACE-1).
# Unparseable message → no file, today's fail-fast behaviour stays.
save_quota(){
  local msg="$1" epoch at
  case "$msg" in *"usage limit"*) ;; *) return 0;; esac
  epoch=$(printf '%s' "$msg" | python3 -c '
import re, sys, datetime
m = sys.stdin.read()
now = datetime.datetime.now()
t = None
r = re.search(r"try again at (\d{1,2}):(\d{2})\s*(AM|PM)?", m, re.I)
if r:
    h, mi = int(r.group(1)), int(r.group(2))
    ap = (r.group(3) or "").upper()
    if ap == "PM" and h != 12: h += 12
    if ap == "AM" and h == 12: h = 0
    t = now.replace(hour=h, minute=mi, second=0, microsecond=0)
    if t <= now: t += datetime.timedelta(days=1)
else:
    r = re.search(r"try again in (?:(\d+)\s*hours?)?\s*(?:(\d+)\s*minutes?)?", m, re.I)
    if r and (r.group(1) or r.group(2)):
        t = now + datetime.timedelta(hours=int(r.group(1) or 0), minutes=int(r.group(2) or 0))
if t: print(int(t.timestamp()))
' 2>/dev/null)
  [ -n "$epoch" ] || return 0
  at=$(python3 -c "import datetime;print(datetime.datetime.fromtimestamp($epoch).strftime('%H:%M'))" 2>/dev/null)
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  jq -cn --argjson e "$epoch" --arg m "$msg" --arg at "${at:-?}" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '{reset_epoch:$e,reset_at:$at,msg:$m,ts:$ts}' > "$LOG_DIR/quota.json.tmp.$$" 2>/dev/null \
    && mv "$LOG_DIR/quota.json.tmp.$$" "$LOG_DIR/quota.json" 2>/dev/null \
    || rm -f "$LOG_DIR/quota.json.tmp.$$" 2>/dev/null || true
}

if attempt "$T1"; then rm -f "$LOG_DIR/quota.json" 2>/dev/null; cat "$VERDICT"; exit 0; fi
ERR=$(codex_error)
if [ -n "$ERR" ]; then
  save_quota "$ERR"
  echo "codex: Fehler gemeldet — kein Review: $ERR" >&2
  exit 3
fi
echo "codex: Versuch 1 nach ${T1}s abgebrochen — Versuch 2 mit ${T2}s" >&2
if attempt "$T2"; then rm -f "$LOG_DIR/quota.json" 2>/dev/null; cat "$VERDICT"; exit 0; fi
ERR=$(codex_error)
if [ -n "$ERR" ]; then
  save_quota "$ERR"
  echo "codex: Fehler gemeldet: $ERR" >&2
fi
echo "codex: beide Versuche gescheitert (${T1}s + ${T2}s) — kein Review" >&2
exit 3

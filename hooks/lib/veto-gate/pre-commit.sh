#!/usr/bin/env bash
# pre-commit.sh — real git pre-commit hook (opt-in via `veto-gate
# install-precommit`). Catches EVERY commit, also headless auto-sync (F11
# residual channel). Deterministic stages only (size + grounding): codex/qwen
# stay in the PreToolUse gate — a background committer must never wait
# minutes. The ONLY escape is --no-verify (git standard, visible in the
# command; a silent env switch was rejected in the plan review, F28).
set -uo pipefail
LIB="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
# THE STRICTEST config state governs (codex finds, rounds 2-4): the commit
# being made must not silence the hook for itself (enabled:false or a looser
# max_lines staged alongside bad code counts only from the NEXT commit on),
# and an unstaged working-tree edit must not disarm an unrelated commit.
# States considered: HEAD (last committed) and the COMMIT state (index entry,
# or the file for untracked configs). Neither present → repo not opted in.
# only COMMITTED/STAGED states govern — an untracked working-tree file is not
# part of any commit and must neither arm nor disarm the hook (codex round 5)
# sound means EXACTLY ONE JSON object: empty, non-object AND multi-document
# files all count as unsound (a bare type=="object" probe accepted
# concatenated objects whose .enabled read then returned garbage, codex find)
cfg_sound(){ [ "$(printf '%s' "$1" | jq -rs 'length==1 and (.[0]|type=="object")' 2>/dev/null)" = "true" ]; }

# rename transition: per STATE the new file name wins by EXISTENCE (git show
# fails only when the path is absent in that state — no parse involved).
# Presence is decided on RAW git state ONLY, before anything touches jq — a
# jq-dependent probe here would let a missing jq discard an armed state and
# end the hook successfully (codex find).
HEADRAW_NEW=$(git show HEAD:.claude/config/veto-gate.json 2>/dev/null) || HEADRAW_NEW=""
CFG_NAME=veto-gate.json
if IDXRAW=$(git show :.claude/config/veto-gate.json 2>/dev/null); then
  COMMITRAW="$IDXRAW"; COMMIT_PRESENT=1
else
  COMMITRAW=""; COMMIT_PRESENT=0
fi
CFG="$TOP/.claude/config/$CFG_NAME"
[ "$COMMIT_PRESENT" = 0 ] && [ -z "$HEADRAW_NEW" ] && exit 0
# a config exists → jq is required from here on; a missing jq must block,
# not silently skip every check (codex round 6)
if ! command -v jq >/dev/null 2>&1; then
  echo "⛔ VETO-GATE (pre-commit): jq fehlt — Config nicht prüfbar, Commit geblockt. jq installieren; Notausgang: --no-verify" >&2
  exit 1
fi
# HEAD only ARMS, never blocks: a broken committed state must not stop the very
# commit that repairs it. The INDEX state does fail closed, just below.
HEADRAW="$HEADRAW_NEW"
# the state being COMMITTED must be sound — unsound fails CLOSED. A broken
# HEAD state is ignored instead: the fixing commit must get through.
if [ "$COMMIT_PRESENT" = 1 ]; then
  if [ -z "$COMMITRAW" ] || ! cfg_sound "$COMMITRAW"; then
    echo "⛔ VETO-GATE (pre-commit): $CFG ist kaputt (leer, kein JSON-Objekt oder mehr als eines) — Commit geblockt. Config fixen; Notausgang: --no-verify" >&2
    exit 1
  fi
fi
HEADVALID=0
[ -n "$HEADRAW" ] && cfg_sound "$HEADRAW" && HEADVALID=1
cfg_enabled(){ printf '%s' "$1" | jq -r 'if type=="object" then (.enabled // false) else false end' 2>/dev/null; }
cfg_maxl(){
  local m; m=$(printf '%s' "$1" | jq -r 'if type=="object" then (.max_lines // 300) else 300 end' 2>/dev/null)
  # non-numeric or absurdly long (shell integer overflow would silently
  # disarm the -gt comparison, codex round 5) → safe default
  { [ -z "${m##*[!0-9]*}" ] || [ "${#m}" -gt 9 ]; } && m=300
  printf '%s' "$m"
}
ENABLED=false
[ "$HEADVALID" = 1 ] && [ "$(cfg_enabled "$HEADRAW")" = "true" ] && ENABLED=true
[ "$(cfg_enabled "$COMMITRAW")" = "true" ] && ENABLED=true
[ "$ENABLED" = "true" ] || exit 0
if [ "$COMMIT_PRESENT" = 1 ]; then MAXL=$(cfg_maxl "$COMMITRAW"); else MAXL=$(cfg_maxl "$HEADRAW"); fi
# strictest wins: loosening max_lines in the same commit must not apply yet;
# a broken HEAD contributes nothing (its silent default must not min() a
# valid repair commit into a block, codex round 5)
if [ "$HEADVALID" = 1 ]; then
  HM=$(cfg_maxl "$HEADRAW")
  [ "$HM" -lt "$MAXL" ] && MAXL=$HM
fi

# this hook BLOCKS, so its own infrastructure fails CLOSED in enabled repos
# (codex design findings: GNU mktemp -t can fail; a crashed checker must not
# silently open the very channel this hook exists to close). Portable temp
# file, explicit rc checks.
if ! DIFF=$(mktemp "${TMPDIR:-/tmp}/veto-gate-precommit.XXXXXX" 2>/dev/null) || [ -z "$DIFF" ]; then
  echo "⛔ VETO-GATE (pre-commit): Temp-Datei nicht erzeugbar — Prüfung unmöglich, Commit geblockt. Notausgang: --no-verify" >&2
  exit 1
fi
trap 'rm -f "$DIFF"' EXIT
# at pre-commit time the index is ALWAYS complete (git stages -a/add chains
# before running hooks) → --cached is exact, no superset problem (F6).
# A failing diff blocks: an enabled repo must never commit unchecked (codex).
if ! git diff --cached --unified=3 > "$DIFF" 2>/dev/null; then
  echo "⛔ VETO-GATE (pre-commit): git diff --cached fehlgeschlagen — Prüfung unmöglich, Commit geblockt. Notausgang: --no-verify" >&2
  exit 1
fi
[ -s "$DIFF" ] || exit 0

# rc AND numeric output must both be sound (codex: a crashing checker that
# still prints a number is not a successful check)
if ! CHANGED=$(bash "${VETO_GATE_DIFFSIZE_BIN:-$LIB/diff-size.sh}" --diff "$DIFF" 2>/dev/null); then
  echo "⛔ VETO-GATE (pre-commit): Größenprüfung selbst fehlgeschlagen — Commit geblockt. Notausgang: --no-verify" >&2
  exit 1
fi
case "$CHANGED" in
  ''|*[!0-9]*)
    echo "⛔ VETO-GATE (pre-commit): Größenprüfung selbst fehlgeschlagen — Commit geblockt. Notausgang: --no-verify" >&2
    exit 1;;
esac
# Lockfile lines are left out of the COMPARISON, exactly as in veto-gate.sh: the package
# manager wrote them, nobody reviews them by hand, and manifest + lockfile cannot be split
# into two commits. CHANGED itself stays whole — the doc-only skip further down depends on
# it, so a lockfile-only commit still reaches the reviewers instead of looking like docs.
# A checker that cannot run leaves LOCKL at 0, i.e. nothing is subtracted (fail strict).
LOCKL=$(bash "${VETO_GATE_DIFFSIZE_BIN:-$LIB/diff-size.sh}" --diff "$DIFF" --lockfile-lines 2>/dev/null)
case "${LOCKL:-}" in ''|*[!0-9]*) LOCKL=0;; esac
[ "$LOCKL" -gt "$CHANGED" ] && LOCKL="$CHANGED"
CODEL=$(( CHANGED - LOCKL ))
if [ "$CODEL" -gt "$MAXL" ]; then
  echo "⛔ VETO-GATE (pre-commit): Diff zu groß ($CODEL geänderte Code-Zeilen > $MAXL) — bitte aufteilen: ein Thema = ein Commit. Notausgang (bewusst): --no-verify" >&2
  exit 1
fi

if ! GROUND=$(bash "${VETO_GATE_GROUNDING_BIN:-$LIB/grounding-check-diff.sh}" --diff "$DIFF" --repo "$TOP" 2>/dev/null); then
  N=$(printf '%s' "$GROUND" | jq -r '.count // 0' 2>/dev/null)
  # non-zero exit WITHOUT verified findings = the checker itself broke →
  # fail CLOSED (this hook blocks; only the warn-only pre-write hook may
  # stay silent on checker failure)
  case "$N" in
    ''|*[!0-9]*|0)
      echo "⛔ VETO-GATE (pre-commit): Import-Prüfung selbst fehlgeschlagen — Commit geblockt. Notausgang: --no-verify" >&2
      exit 1;;
  esac
  {
    echo "⛔ VETO-GATE (pre-commit): $N erfundene(r) Import(e)/Symbol(e) im Diff — Commit geblockt."
    printf '%s' "$GROUND" | jq -r '.violations[]? | "  \(.file): \(.import)\(if .symbol then " → Symbol \(.symbol) fehlt" else "" end)"' 2>/dev/null
    echo "Notausgang (bewusst): --no-verify"
  } >&2
  exit 1
fi

# Stage 3 — the real reviewers (owner 2026-07-29). This channel is the ONLY one
# that can see a change the COMMAND created: a PreToolUse hook reads the working
# tree from before the command runs, so `cat > f <<EOF && git commit` leaves it
# nothing to read. Measured live 2026-07-29 — the identical 400-line violation
# blocked when the file existed beforehand and produced no log entry at all when
# the command wrote it. Here the index is complete, so the diff is exact.
#
# Doc-only diffs (CHANGED==0, diff-size.sh does not count .md/.txt/.log) skip
# this stage. That KEEPS the F11 promise "a background committer must never wait
# minutes" instead of trading it away: auto-push.sh is the only background
# committer and commits doc-only changes by construction — code changes it
# merely REPORTS (gated-only). So no env switch is needed here, and F28's
# rejection of a silent one stands.
[ "$CHANGED" -eq 0 ] && exit 0

# Already reviewed? The gate leaves a single-use note naming the blobs it had
# under review. Every staged blob present there means this exact content already
# went through the reviewers — reviewing it again would only cost a second wait
# and a second slice of quota. Anything else runs the reviewers: no note, a blob
# the gate never saw, a note from an older attempt.
#
# The note may name MORE than the commit stages, and must: the gate reads the
# whole worktree while the commit takes a part of it. Less is not enough.
#
# Deletions (a new blob of all zeros) are not matched — nothing was added, and
# the diff the gate reviewed contained the removal. Requiring them would make
# every commit that deletes a file pay for a second review.
#
# Consumed either way, before any decision: a note that survives its commit
# would silence the NEXT one, which nobody reviewed.
NOTE=""
GD=$(git rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$GD" ] && NOTE="$GD/veto-gate-reviewed"
if [ -n "$NOTE" ] && [ -f "$NOTE" ]; then
  SEEN=1
  while IFS= read -r RL; do
    [ -n "$RL" ] || continue
    RSHA=$(printf '%s' "$RL" | awk '{print $4}')
    case "$RSHA" in 0000000000000000000000000000000000000000) continue;; esac
    RPATH=${RL#*	}
    grep -qxF "$RSHA $RPATH" "$NOTE" || { SEEN=0; break; }
  done < <(git diff --cached --raw --abbrev=40 2>/dev/null)
  rm -f "$NOTE"
  [ "$SEEN" = 1 ] && exit 0
fi

# Local infrastructure fails CLOSED (this hook blocks, see above); an external
# SERVICE does not — see the codex branch below.
if ! BUNDLE=$(bash "${VETO_GATE_PACKDIFF_BIN:-$LIB/pack-diff.sh}" --diff "$DIFF" --repo "$TOP" --cap "${VETO_GATE_CAP:-120000}" 2>/dev/null) || [ -z "$BUNDLE" ]; then
  echo "⛔ VETO-GATE (pre-commit): Review-Bündel nicht baubar — nichts geprüft, Commit geblockt. Notausgang: --no-verify" >&2
  exit 1
fi

report_findings(){  # $1 verdict json, $2 reviewer name, $3 count
  {
    echo "⛔ VETO-GATE (pre-commit): $2 fand $3 blockierende(s) Problem(e) — Commit geblockt."
    printf '%s' "$1" | jq -r '.blocking[] | "  [\(.id)] \(.claim)\n     warum: \(.why)\n     fix: \(.fix)"' 2>/dev/null
    echo "Notausgang (bewusst): --no-verify"
  } >&2
}

# Free local filter first, exactly like the gate's stage 2.5: its findings block
# without spending codex quota. A DEAD pre-reviewer is not a verdict — it falls
# through to codex, so the channel never gets weaker than codex alone.
PRE=$(jq -r 'if type=="object" then (.prechecker // "none") else "none" end' "$CFG" 2>/dev/null) || PRE=none
if [ "$PRE" != none ] && [ -n "$PRE" ]; then
  if PV=$(bash "${VETO_GATE_PRECHECK_BIN:-$LIB/minimax-diff-review.sh}" --diff "$DIFF" 2>/dev/null); then
    PB=$(printf '%s' "$PV" | jq '.blocking | length' 2>/dev/null) || PB=0
    case "$PB" in ''|*[!0-9]*) PB=0;; esac
    if [ "$PB" -gt 0 ]; then report_findings "$PV" "Vorprüfer ($PRE)" "$PB"; exit 1; fi
  fi
fi

CFG_TO=$(jq -r 'if type=="object" then (.timeout // empty) else empty end' "$CFG" 2>/dev/null)
CFG_TO2=$(jq -r 'if type=="object" then (.timeout2 // empty) else empty end' "$CFG" 2>/dev/null)
if ! VERDICT=$(VETO_GATE_TIMEOUT="${VETO_GATE_TIMEOUT:-$CFG_TO}" VETO_GATE_TIMEOUT2="${VETO_GATE_TIMEOUT2:-$CFG_TO2}" \
     bash "${VETO_GATE_CODEX_BIN:-$LIB/codex-diff-review.sh}" --bundle "$BUNDLE" 2>/dev/null); then
  # The gate's own header says it fails OPEN on codex infra errors. The residual
  # channel must not be STRICTER than the channel it backs up — an exhausted
  # quota would otherwise freeze every commit in an armed repo. But it must not
  # be silent either: an unreviewable commit that says nothing is the exact
  # failure F11 exists against (UL-006).
  echo "⚠ VETO-GATE (pre-commit): Prüfer nicht erreichbar — dieser Commit ist UNGEPRÜFT durchgelaufen." >&2
  exit 0
fi
BLK=$(printf '%s' "$VERDICT" | jq '.blocking | length' 2>/dev/null) || BLK=0
case "$BLK" in ''|*[!0-9]*) BLK=0;; esac
if [ "$BLK" -gt 0 ]; then report_findings "$VERDICT" "Codex" "$BLK"; exit 1; fi
exit 0

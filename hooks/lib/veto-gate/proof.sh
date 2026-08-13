#!/usr/bin/env bash
# proof.sh — evidence ledger for the commit gate.
#
# Every stage leaves a note instead of a silent yes/no. Five states:
#   pass            checked, clean
#   fail            checked, found a problem       → block
#   skipped         deliberately not checked       → silent (doc-only commit)
#   not_applicable  this checker cannot exist here → silent (a bash repo HAS no typechecker)
#   unavailable     the checker SHOULD be here and is gone / a service is down → alarm
#
# COUNCIL 2026-07-14 (codex gpt-5.6-sol): the first draft folded the last two together, and
# that was wrong. "A bash repo has no typechecker" is NORMAL. "The typechecker vanished from
# a TypeScript repo" is an ALARM. Merging them means either crying wolf every commit (and
# you stop reading the alerts — 'Discord allein ist keine Kontrolle') or staying silent about
# a real regression. What is MANDATORY is declared per repo; mandatory + unavailable BLOCKS.
#
# The point: today a stage can vanish without a trace (no package.json → no
# typechecker → nobody notices). A missing check must be as loud as a failing one.
#
# Sourced by the gate — defines functions, runs nothing on its own.

PROOF_FILE=""
PROOF_BROKEN=0     # the ledger itself failed — never let that look like "all clean"
PROOF_N=0          # notes successfully written — a sheet that HAD notes and has none is broken

proof_init(){
  PROOF_FILE="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}/proofs-$$.jsonl"
  PROOF_BROKEN=0
  PROOF_N=0
  mkdir -p "$(dirname "$PROOF_FILE")" 2>/dev/null || PROOF_BROKEN=1
  : > "$PROOF_FILE" 2>/dev/null || PROOF_BROKEN=1
  command -v jq >/dev/null 2>&1 || PROOF_BROKEN=1
}

# Notes were written to the ledger and are no longer all there (file deleted, truncated,
# temp dir swept). proof_json would simply print what is left — and a `fail` that WAS on the
# sheet disappears without a word (codex, round 5).
#
# Asking "is the file empty" was not enough (codex, round 6): delete the sheet after a fail,
# write one more note, and it is non-empty again — with the fail gone and a pass in its place.
# So we COUNT. Fewer notes on the sheet than we wrote is a broken sheet, however full it looks.
proof_selfcheck(){
  local n
  n=$(proof_json 2>/dev/null | jq 'length' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=-1;; esac        # unreadable counts as "fewer than written"
  [ "$n" -lt "${PROOF_N:-0}" ] && PROOF_BROKEN=1
  return 0
}

# proof_add <stage> <status> <detail>
# An unknown status is recorded as `unavailable`, never as a silent pass — a typo
# in a caller must not disarm a check.
#
# B3 (codex, plan review): the ledger must not fail silently EITHER. If jq is gone
# or the file is unwritable, every note would vanish and proof_json would return []
# — a run with zero checks would look exactly like a run where everything passed.
# A broken ledger is therefore remembered and reported as a gap.
proof_add(){
  [ -n "$PROOF_FILE" ] || proof_init
  local st="$2"
  case "$st" in pass|fail|skipped|not_applicable|unavailable) ;; *) st="unavailable";; esac
  # 2>/dev/null FIRST: redirections are applied left to right, so an unwritable
  # PROOF_FILE reports its error into /dev/null instead of the user's terminal.
  if jq -cn --arg s "$1" --arg t "$st" --arg d "${3:-}" \
       '{stage:$s,status:$t,detail:$d}' 2>/dev/null >> "$PROOF_FILE"; then
    PROOF_N=$((PROOF_N+1))
  else
    PROOF_BROKEN=1
  fi
}

# Prints the notes, and SIGNALS a read failure through its exit code (1).
#
# It must not set PROOF_BROKEN itself: every caller uses it as `$(proof_json)`, and a
# command substitution is a SUBSHELL — the assignment would be thrown away the moment it
# returned (bash 3.2). An unreadable ledger would then have printed `[]` and read exactly
# like a clean run. The caller sets the flag, in the shell that still exists afterwards.
proof_json(){
  [ -s "${PROOF_FILE:-}" ] || { printf '[]'; return 0; }
  jq -sc '.' "$PROOF_FILE" 2>/dev/null || { printf '[]'; return 1; }
}

# 0 = all good · 1 = block · 2 = no fail, but a gap (pass + report)
#
# proof_verdict <required-json>   e.g. '["tests","typecheck"]' (from .claude/config/veto-gate.json)
# A checker on the REQUIRED list that ends up 'unavailable' BLOCKS: in a TypeScript repo the
# typechecker is not optional, and letting it vanish quietly is how a gate becomes decoration
# (council: codex). Everything not on the list still only reports.
proof_verdict(){
  local j req
  proof_selfcheck
  j=$(proof_json) || PROOF_BROKEN=1            # flag set HERE, not inside the subshell

  # The ledger itself broke: notes were lost, or they are there and cannot be read. We do
  # not know what was in them — a `fail` may be sitting in exactly the lines we can no
  # longer parse. Lost evidence is not evidence of innocence, so this BLOCKS (codex,
  # round 3). Escape hatch, as everywhere: the override file, as a separate, deliberate act.
  [ "$PROOF_BROKEN" = 1 ] && return 1

  # A required-list nobody can parse must not disarm the rule in silence: jq errors out on
  # a malformed --argjson, the `&&` below never fires, and "mandatory checkers block" is
  # quietly gone. A broken rule blocks; it does not shrug (codex, round 3).
  #
  # Validated through --argjson itself, not through `jq 'type=="array"'` (codex, round 4):
  # that reads a STREAM of values and judges the LAST one, so '{"a":1} ["x"]' passed the
  # check and then blew up unnoticed at the point of use. The validator must speak exactly
  # the same language as the consumer, or it is not validating the consumer's input.
  #
  # And an array of the WRONG THING is still the wrong thing (codex, round 5): `index($s)`
  # against [1,2] simply never matches, so every mandatory checker would quietly turn
  # optional. It must be a list of NAMES.
  req="${1:-[]}"
  if ! jq -ne --argjson r "$req" '$r | type == "array" and all(.[]; type == "string")' >/dev/null 2>&1; then
    proof_add config fail "Pflicht-Liste (required) ist keine Liste von Namen: $req"
    return 1
  fi

  printf '%s' "$j" | jq -e 'any(.[]; .status == "fail")' >/dev/null 2>&1 && return 1
  # required + unavailable → block
  printf '%s' "$j" | jq -e --argjson r "$req" \
    'any(.[]; .status == "unavailable" and (.stage as $s | $r | index($s)))' >/dev/null 2>&1 && return 1
  printf '%s' "$j" | jq -e 'any(.[]; .status == "unavailable")' >/dev/null 2>&1 && return 2
  return 0
}

proof_missing(){
  local j m
  proof_selfcheck
  j=$(proof_json) || PROOF_BROKEN=1
  m=$(printf '%s' "$j" | jq -r '[.[] | select(.status == "unavailable") | .stage] | join(", ")' 2>/dev/null) || m=""
  [ "$PROOF_BROKEN" = 1 ] && m="${m:+$m, }Beweis-Sammler selbst (jq fehlt oder Zettel-Datei unlesbar)"
  printf '%s' "$m"
}

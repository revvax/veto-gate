#!/usr/bin/env bash
# log-mismatch.sh: one line per run that was sized 'light' but blocked anyway with a
# real reviewer finding. This is the closed loop (UL-006): a wrong sizing must leave
# evidence, or the calibration can never learn.
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/log-mismatch.sh"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1', want '$2')"; fi; }
# mktemp FIRST, then export: a failed mktemp would leave VETO_GATE_LOG_DIR empty and the
# script under test would fall back to the real ~/.claude/veto-gate — a test must never
# touch the owner's live ledger (codex find).
TMPD=$(mktemp -d) || { echo "log-mismatch: mktemp failed"; exit 1; }
[ -n "$TMPD" ] && [ -d "$TMPD" ] || { echo "log-mismatch: no temp dir"; exit 1; }
export VETO_GATE_LOG_DIR="$TMPD"; trap 'rm -rf "$TMPD"' EXIT
LOG="$VETO_GATE_LOG_DIR/triage-mismatch.jsonl"

# T1: a light run that blocked → exactly one entry, with the facts that let 1b learn later
bash "$S" --repo r1 --branch b1 --profile light --effort low --changed 0 --result codex-block --blocking 2
ok "$(wc -l < "$LOG" | tr -d ' ')" "1" "T1 light+block → exactly one entry"
ok "$(jq -r '.repo' "$LOG")"     "r1"          "T1b repo logged"
ok "$(jq -r '.result' "$LOG")"   "codex-block" "T1c result logged"
ok "$(jq -r '.blocking' "$LOG")" "2"           "T1d blocking count logged"
ok "$(jq -r '.changed' "$LOG")"  "0"           "T1e code-line count logged"
ok "$(jq -e '.ts | type=="string"' "$LOG" >/dev/null && echo yes)" "yes" "T1f has a timestamp"

# T2: a NORMAL-profile block is not a mismatch — nothing was mis-sized
bash "$S" --repo r1 --branch b1 --profile normal --effort high --changed 50 --result codex-block --blocking 1
ok "$(wc -l < "$LOG" | tr -d ' ')" "1" "T2 normal profile → no new entry"

# T3: a block with ZERO findings is not a mismatch (codex find). Only a real finding
# proves the sizing was wrong; logging anything else would teach Stufe 1b from noise
# and tighten the floor for no reason.
bash "$S" --repo r1 --branch b1 --profile light --effort low --changed 0 --result codex-block --blocking 0
ok "$(wc -l < "$LOG" | tr -d ' ')" "1" "T3 light block with 0 findings → no entry"

# T3b: an unreadable blocking count is not a proven finding either — same rule
bash "$S" --repo r1 --branch b1 --profile light --effort low --changed 0 --result codex-block --blocking xx
ok "$(wc -l < "$LOG" | tr -d ' ')" "1" "T3b unreadable blocking count → no entry"

# T4: never crash a caller — a flag without its value must not abort under `set -u`
bash "$S" --repo >/dev/null 2>&1
ok "$?" "0" "T4 flag without value → rc 0, no crash"

# T5: every line is valid JSON on its own — a jsonl the dashboard cannot parse is
# no ledger at all
bash "$S" --repo 'r "quoted"' --branch $'b\ttab' --profile light --effort low \
  --changed 0 --result codex-block --blocking 1
ok "$(jq -s 'length' "$LOG" >/dev/null 2>&1 && echo yes)" "yes" "T5 all lines stay valid JSON"

# T6: append-only — the ledger never truncates itself. Truncation was the only step
# that needed a lock (a concurrent run could replace the file right after another had
# appended to it, losing that entry — codex find), and a mismatch is by definition
# rare. Pre-fill past the old 200-line cap and append once: a truncating ledger would
# fall back to 200. One call, not 210 — the same proof without a 60s test suite.
: > "$LOG"
i=0; while [ "$i" -lt 209 ]; do echo '{"filler":1}' >> "$LOG"; i=$((i+1)); done
bash "$S" --repo r --branch b --profile light --effort low --changed 0 --result codex-block --blocking 1
ok "$(wc -l < "$LOG" | tr -d ' ')" "210" "T6 append-only, no self-truncation past 200"

# T7: an unreadable --changed is not 0 (codex find). 0 means "pure doc diff" here —
# the state that unlocks the light profile — so an unknown value must stay telling
# apart from a measured zero, or Stufe 1b learns a fact nobody measured.
: > "$LOG"
bash "$S" --repo r --branch b --profile light --effort low --changed xx --result codex-block --blocking 1
ok "$(jq -r '.changed' "$LOG")" "null" "T7 unreadable changed → null, not 0"

# T8: text fields are bounded, so one entry stays a single small write — that is what
# makes the lock-free append safe (codex find)
: > "$LOG"
BIG=$(printf 'x%.0s' $(seq 1 5000))
bash "$S" --repo "$BIG" --branch b --profile light --effort low --changed 0 --result codex-block --blocking 1
ok "$(wc -l < "$LOG" | tr -d ' ')" "1" "T8 huge field → still exactly one line"
ok "$([ "$(jq -r '.repo' "$LOG" | wc -c | tr -d ' ')" -le 210 ] && echo yes)" "yes" "T8b huge field bounded"

echo "log-mismatch: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

#!/usr/bin/env bash
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/watch.sh"
export VETO_GATE_LOG_DIR="$(mktemp -d)"; trap 'rm -rf "$VETO_GATE_LOG_DIR"' EXIT
P=0; F=0; ok(){ case "$1" in *"$2"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL $3";; esac; }
LOG="$VETO_GATE_LOG_DIR/runs.jsonl"

# empty log
OUT=$(bash "$S" --once | sed $'s/\033\\[[0-9;]*m//g')
ok "$OUT" "noch keine Läufe" "empty log message"

# fixture: 2 pass, 1 block
printf '%s\n' \
  '{"ts":"2026-07-09T20:00:00Z","repo":"beispiel-repo","branch":"main","files":1,"result":"codex-pass","blocking":0,"dur":10,"thread":"t1"}' \
  '{"ts":"2026-07-09T20:01:00Z","repo":"beispiel-repo","branch":"main","files":2,"result":"codex-block","blocking":2,"dur":20,"thread":"t2"}' \
  '{"ts":"2026-07-09T20:02:00Z","repo":"beispiel-repo","branch":"main","files":1,"result":"codex-pass","blocking":0,"dur":12,"thread":"t3"}' \
  > "$LOG"
OUT=$(bash "$S" --once | sed $'s/\033\\[[0-9;]*m//g')
ok "$OUT" "Läufe(50): 3" "count 3"
ok "$OUT" "geblockt: 33%" "block rate 33"
ok "$OUT" "codex-block" "shows block row"
echo "watch: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

#!/usr/bin/env bash
# watch.sh — live dashboard for veto-gate runs. `veto-gate watch` | `veto-gate` | `--once`.
set -uo pipefail
LOG="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}/runs.jsonl"
ONCE=0
for a in "$@"; do [ "$a" = "--once" ] && ONCE=1; done

render() {
  printf '\033[H'   # home only — no full clear, avoids flicker
  printf '\033[1;36m═══ veto-gate — live ═══\033[0m\033[K\n'
  if [ ! -s "$LOG" ]; then printf 'noch keine Läufe.\033[K\n\033[J'; return; fi
  last50=$(tail -n 50 "$LOG")
  n=$(printf '%s\n' "$last50" | grep -c .)
  blocked=$(printf '%s\n' "$last50" | jq -r 'select(.result=="codex-block" or .result=="grounding-block" or .result=="timeout-block")|1' 2>/dev/null | grep -c 1)
  avg=$(printf '%s\n' "$last50" | jq -s 'if length>0 then (map(.dur)|add/length|floor) else 0 end' 2>/dev/null)
  lastts=$(printf '%s\n' "$last50" | tail -1 | jq -r '.ts // ""' 2>/dev/null)
  lastth=$(printf '%s\n' "$last50" | tail -1 | jq -r '.thread // ""' 2>/dev/null)
  pct=0; [ "$n" -gt 0 ] && pct=$(( blocked * 100 / n ))
  printf 'Läufe(50): %s   geblockt: %s%%   Ø %ss   letzter: %s  thread:%s\033[K\n\033[K\n' \
    "$n" "$pct" "$avg" "$lastts" "${lastth:0:12}"
  tail -n 12 "$LOG" | tail -r | while IFS= read -r line; do
    [ -z "$line" ] && continue
    ts=$(printf '%s' "$line" | jq -r '.ts' | sed 's/.*T//; s/Z//')
    repo=$(printf '%s' "$line" | jq -r '.repo'); br=$(printf '%s' "$line" | jq -r '.branch')
    res=$(printf '%s' "$line" | jq -r '.result'); blk=$(printf '%s' "$line" | jq -r '.blocking')
    dur=$(printf '%s' "$line" | jq -r '.dur')
    case "$res" in
      codex-pass) e="✅"; c="0;32";; codex-block) e="🛑"; c="1;31";;
      grounding-block) e="⛔"; c="1;31";; timeout-block) e="⏱"; c="1;31";;
      fail-open-*) e="⚠ "; c="0;33";; *) e="·"; c="0";; esac
    printf '\033[%sm%s %s  %-12s %-20s %-16s b:%s %ss\033[0m\033[K\n' \
      "$c" "$e" "$ts" "${repo:0:12}" "${br:0:20}" "$res" "$blk" "$dur"
  done
  printf '\033[J'   # clear any leftover lines below when list shrinks
}

if [ "$ONCE" = "1" ]; then render; exit 0; fi
trap 'printf "\033[?25h"; exit 0' INT
printf '\033[?25l'   # hide cursor
while :; do render; sleep 1; done

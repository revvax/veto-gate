#!/usr/bin/env bash
# converge.sh — a correction sequence must come to an END. Deterministic, 0 tokens.
#
# Measured 2026-09-28 over 1000 gate runs: after at least one reviewer block, 151
# sequences ended in an override and 36 in a pass. Every round was judged cold: a
# finding at a line that already stood in round 1 blocked round 2 exactly like a
# new one, so round 1 never had to be complete and each fix bought a fresh search.
#
# This script takes the reviewer's verdict and decides, per blocking finding,
# whether it still blocks. What stops blocking is NOT dropped: it moves to
# non_blocking with the reason, and is listed under `demoted` for the author to
# carry into the project's list.
#
#   hard kinds (sicherheit, datenverlust, falsch-gruen) — block ALWAYS: any role,
#       any round, any line. The floor nothing here can lower.
#   falsch-rot — never blocks: a check that is only too strict shows itself on
#       its first run; one that passes wrongly stays invisible, that is the asymmetry.
#   role werkzeug (tool/proof code, decided by triage.sh) — only hard kinds block.
#   round 1 — everything else blocks.
#   round 2 — blocks only a prior finding that is NOT fixed, or a finding whose quote
#       hits a line the fix wrote NEW (added now, not added in the previous round's
#       diff). "Not fixed" is recognised three ways, because the reviewer may forget
#       to say so: its `vorrunde` names a stored prior id, its own id IS a stored prior
#       id, or its quote equals a stored prior quote. All three err strict — a reused
#       id for a different finding keeps blocking, never the other way round.
#   round 3+ — only hard kinds.
#
# Whatever cannot be measured falls STRICT: an unknown round is round 1, a missing
# previous diff keeps the round-2 finding blocking, an unreadable verdict passes
# through untouched. Exit 0 always — the gate reads stdout, a crash here must not
# decide a commit (same contract as kreisel.sh).
set -uo pipefail
VERDICT=""; ROUND=1; ROLE=normal; PRIOR=""; DIFF=""; PREV=""
while [ $# -gt 0 ]; do case "$1" in
  --verdict) VERDICT="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --round) ROUND="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --role) ROLE="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --prior) PRIOR="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --diff) DIFF="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --prev-diff) PREV="${2:-}"; shift 2 2>/dev/null || shift $#;;
  *) shift;;
esac; done
case "$ROUND" in ''|*[!0-9]*) ROUND=1;; esac
[ "$ROUND" -lt 1 ] && ROUND=1
case "$ROLE" in werkzeug) ;; *) ROLE=normal;; esac

V=$(cat "$VERDICT" 2>/dev/null) || V=""
# not a verdict we understand → hand it back unchanged, nothing demoted
if ! printf '%s' "$V" | jq -e 'type=="object" and (.blocking|type=="array")' >/dev/null 2>&1; then
  printf '%s' "$V"; exit 0
fi

# prior finding ids — accepts the gate's {vorrunden:[…]} file and kreisel's raw list
PIDS='[]'; PQS='[]'; PCUT=0
NZ='def nz: tostring | gsub("\\s+";" ") | ltrimstr(" ") | rtrimstr(" ") | ltrimstr("+") | ltrimstr(" ");'
if [ -n "$PRIOR" ] && [ -f "$PRIOR" ]; then
  PF='[(if type=="object" then (.vorrunden // .prior // []) else . end)[]? | .findings[]?]'
  PIDS=$(jq -c "$PF"' | [.[] | .id? | select(type=="string" and length>0)] | unique' "$PRIOR" 2>/dev/null) || PIDS='[]'
  PQS=$(jq -c "$NZ $PF"' | [.[] | (.quote // "") | nz | select(length>=5)] | unique' "$PRIOR" 2>/dev/null) || PQS='[]'
  printf '%s' "$PIDS" | jq -e 'type=="array"' >/dev/null 2>&1 || PIDS='[]'
  printf '%s' "$PQS" | jq -e 'type=="array"' >/dev/null 2>&1 || PQS='[]'
  # kreisel.sh keeps at most 10 findings per round. A round that hit the cap may have
  # had more, and an unfixed 11th would have nothing to be matched against — so the
  # prior list is INCOMPLETE and the round-2 rule cannot be trusted: strict (review).
  [ "$(jq '[(if type=="object" then (.vorrunden // .prior // []) else . end)[]? | (.findings // []) | length] | any(. >= 10)' "$PRIOR" 2>/dev/null)" = false ] || PCUT=1
fi

# which findings quote a line the fix wrote NEW — only asked in round 2, and only
# measurable with the previous round's diff on disk. Same anchor rule as kreisel.sh:
# content, whitespace-squeezed, lines under 5 chars are structure, not content.
FRESH_OK=0; HITS='[]'
if [ "$ROUND" -eq 2 ] && [ -f "$PREV" ] && [ -f "$DIFF" ]; then
  FRESH_OK=1
  norm(){ sed -e 's/^+//' -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'; }
  HITS=$({ grep '^+' "$PREV" 2>/dev/null | grep -vE '^\+\+\+ (b/|/dev/null)' | norm | sed 's/^/P /'
           grep '^+' "$DIFF" 2>/dev/null | grep -vE '^\+\+\+ (b/|/dev/null)' | norm | sed 's/^/C /'
           printf '%s' "$V" | jq -r '.blocking | to_entries[] | .key as $k
             | ((.value.quote // "") | tostring | split("\n")[]) | "\($k)\t\(.)"' 2>/dev/null \
             | while IFS="$(printf '\t')" read -r k q; do
                 printf 'Q %s %s\n' "$k" "$(printf '%s\n' "$q" | norm)"
               done
         } | awk '
    /^P /{prev[substr($0,3)]=1; next}
    /^C /{l=substr($0,3); if(!(l in prev) && length(l)>=5) neu[l]=1; next}
    /^Q /{rest=substr($0,3); k=rest; sub(/ .*/,"",k); q=rest; sub(/^[^ ]* ?/,"",q)
          if(length(q)<5 || (k in hit)) next
          if(q in neu){hit[k]=1; next}
          for(l in neu) if(index(l,q) || index(q,l)){hit[k]=1; break}}
    END{s=""; for(k in hit) s=s (s==""?"":",") k; print "[" s "]"}' 2>/dev/null)
  printf '%s' "$HITS" | jq -e 'type=="array"' >/dev/null 2>&1 || { FRESH_OK=0; HITS='[]'; }
fi

OUT=$(printf '%s' "$V" | jq -c --argjson round "$ROUND" --arg role "$ROLE" \
  --argjson pids "$PIDS" --argjson pqs "$PQS" --argjson hits "$HITS" --argjson fresh "$FRESH_OK" \
  --argjson pcut "$PCUT" "$NZ"'
  def unfixed: ((.vorrunde // "") | tostring) as $v | ((.id // "") | tostring) as $i
    | ((.quote // "") | nz) as $q
    | ($v != "" and ($pids | index($v) != null)) or ($i != "" and ($pids | index($i) != null))
      or ($q != "" and ($pqs | index($q) != null));
  def art: ((.art // "") | tostring | ascii_downcase | gsub("[üÜ]";"ue") | gsub("_";"-")) as $a
    | if ($a|IN("sicherheit","datenverlust","falsch-gruen","falsch-rot")) then $a else "fehler" end;
  def why($k):
    art as $a
    | if ($a|IN("sicherheit","datenverlust","falsch-gruen")) then null
      elif $a == "falsch-rot" then "falsch-rot: macht eine Prüfung nur zu streng und zeigt sich beim ersten Lauf selbst"
      elif $role == "werkzeug" then "Werkzeug-Code: hier blocken nur Sicherheit, Datenverlust und falsch-grün"
      elif $round <= 1 then null
      elif $round == 2 then
        if unfixed then null
        elif $fresh != 1 or $pcut == 1 then null
        elif ($hits | index($k) != null) then null
        else "Runde 2: neu gefunden an einer Zeile, die der Fix nicht neu geschrieben hat" end
      else "ab Runde 3 blocken nur Sicherheit, Datenverlust und falsch-grün" end;
  (.blocking | to_entries | map(.key as $k | .value + {_why: (.value | why($k))})) as $all
  | .blocking = [$all[] | select(._why == null) | del(._why)]
  | .demoted = [$all[] | select(._why != null) | {id, art: art, claim, fix, grund: ._why}]
  | .non_blocking = ((.non_blocking // []) + [.demoted[] | {id, note: "[\(.grund)] \(.claim // "") — \(.fix // "")"}])
' 2>/dev/null)
if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '.blocking|type=="array"' >/dev/null 2>&1; then
  printf '%s\n' "$OUT"
else
  printf '%s' "$V"
fi
exit 0

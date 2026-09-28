#!/usr/bin/env bash
# converge.sh — one row of the round table per test, plus the strict fallbacks.
# Background (2026-09-28): 151 of 187 sequences that saw a reviewer block ended in
# an override, because every round judged the diff cold and found something new.
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/converge.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }

V="$TMP/v.json"; PR="$TMP/prior.json"; D1="$TMP/r1.diff"; D2="$TMP/r2.diff"
# round 1 added two lines; the fix in round 2 added a third
printf '+++ b/src/a.ts\n+const alpha = readAll();\n+const beta = parse(alpha);\n' > "$D1"
printf '+++ b/src/a.ts\n+const alpha = readAll();\n+const beta = parse(alpha);\n+if (!beta) throw new Error("x");\n' > "$D2"
printf '{"runde":2,"vorrunden":[{"round":1,"findings":[{"id":"B1","claim":"c","fix":"f","quote":""},{"id":"B7","claim":"c","fix":"f","quote":"const alpha =   readAll();"}]}]}' > "$PR"

f(){ # $1 = id, $2 = art, $3 = quote, $4 = vorrunde
  printf '{"id":"%s","art":"%s","claim":"claim %s","why":"w","fix":"fix %s","quote":"%s","vorrunde":"%s"}' "$1" "$2" "$1" "$1" "$3" "$4"; }
verdict(){ printf '{"blocking":[%s],"non_blocking":[{"id":"N0","note":"alt"}],"questions":[],"context_requests":[],"unverified_claims":[]}' "$1" > "$V"; }
blk(){ bash "$S" --verdict "$V" "$@" | jq -r '[.blocking[].id] | join(",")'; }
dem(){ bash "$S" --verdict "$V" "$@" | jq -r '[.demoted[].id] | join(",")'; }
R2="--round 2 --prior $PR --diff $D2 --prev-diff $D1"

# C1: round 1 — everything but falsch-rot blocks
verdict "$(f A fehler '' ''),$(f B falsch-rot '' ''),$(f C sicherheit '' '')"
ok "$(blk --round 1)" "A,C" "C1 round 1 blocks all but falsch-rot"
ok "$(dem --round 1)" "B" "C1b falsch-rot is demoted, not dropped"
ok "$(bash "$S" --verdict "$V" --round 1 | jq -r '[.non_blocking[].id] | join(",")')" "N0,B" "C1c demoted lands in non_blocking after the old ones"

# C2: round 2 — new finding at an OLD line demotes, at a FIX line blocks
verdict "$(f A fehler 'const beta = parse(alpha);' ''),$(f B fehler 'if (!beta) throw new Error(\"x\");' '')"
ok "$(blk $R2)" "B" "C2 round 2: only the fix line blocks"
ok "$(dem $R2)" "A" "C2b the old-line finding is demoted"

# C3: round 2 — a prior finding named as NOT fixed keeps blocking; an invented id does not
verdict "$(f A fehler '' 'B1'),$(f B fehler '' 'B9')"
ok "$(blk $R2)" "A" "C3 unfixed prior finding blocks, invented prior id does not"
# C3b: the reviewer forgot to say "not fixed" — the same id, or the same quote, still counts
verdict "$(f B1 fehler '' ''),$(f X fehler '+const alpha = readAll();' ''),$(f Y fehler 'export const zeta = 1;' '')"
ok "$(blk $R2)" "B1,X" "C3b same id or same quote as a prior finding = not fixed"

# C4: round 2 — hard kinds block at any line
verdict "$(f A datenverlust 'const alpha = readAll();' ''),$(f B falsch-gruen '' '')"
ok "$(blk $R2)" "A,B" "C4 hard kinds block in round 2 at old lines"

# C5: round 3 — only hard kinds
verdict "$(f A fehler 'if (!beta) throw new Error(\"x\");' 'B1'),$(f B sicherheit '' '')"
ok "$(blk --round 3 --prior "$PR" --diff "$D2" --prev-diff "$D1")" "B" "C5 round 3 blocks only hard kinds"

# C6: role werkzeug — only hard kinds, even in round 1
verdict "$(f A fehler '' ''),$(f B falsch-gruen '' '')"
ok "$(blk --round 1 --role werkzeug)" "B" "C6 werkzeug: only hard kinds block"

# C7: missing or unknown art counts as fehler (normal rules), umlaut spelling is understood
printf '{"blocking":[{"id":"A","claim":"c","fix":"f"},{"id":"B","art":"FALSCH-GRÜN","claim":"c","fix":"f"}]}' > "$V"
ok "$(blk --round 3)" "B" "C7 no art = fehler; FALSCH-GRÜN = falsch-gruen"

# C8: STRICT fallbacks — no previous diff keeps round 2 blocking; bad round = round 1
verdict "$(f A fehler 'const beta = parse(alpha);' '')"
ok "$(blk --round 2 --prior "$PR" --diff "$D2" --prev-diff "$TMP/none")" "A" "C8 unmeasurable fix lines keep blocking"
ok "$(blk --round abc)" "A" "C8b unreadable round = round 1"
ok "$(blk --round 3 --role quatsch)" "" "C8c unknown role = normal (round 3 still demotes)"

# C8d: the prior round hit kreisel's 10-finding cap — an unfixed 11th could not be
# matched, so round 2 does not demote at all
PR10="$TMP/prior10.json"
jq -cn '{runde:2,vorrunden:[{round:1,findings:[range(10) as $i | {id:"P\($i)",claim:"c",fix:"f",quote:""}]}]}' > "$PR10"
verdict "$(f A fehler 'const beta = parse(alpha);' '')"
ok "$(blk --round 2 --prior "$PR10" --diff "$D2" --prev-diff "$D1")" "A" "C8d capped prior list keeps round 2 strict"

# C9: a verdict we cannot read passes through unchanged, exit 0
printf 'kein json' > "$V"
ok "$(bash "$S" --verdict "$V" --round 3; echo ":$?")" "kein json:0" "C9 garbage passes through untouched"

# C10: quotes under 5 chars are no anchor; a leading '+' in the quote is tolerated
verdict "$(f A fehler '}' ''),$(f B fehler '+if (!beta) throw new Error(\"x\");' '')"
ok "$(blk $R2)" "B" "C10 short quote is no anchor, '+' prefix tolerated"

# C11: the other verdict fields survive
verdict "$(f A fehler '' '')"
ok "$(bash "$S" --verdict "$V" --round 3 | jq -c '[has("questions"),has("unverified_claims"),has("context_requests")]')" "[true,true,true]" "C11 other fields untouched"

echo "converge: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

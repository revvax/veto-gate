#!/usr/bin/env bash
# kreisel.sh: correction-sequence store + spiral verdict. A sequence is repo+branch+HEAD;
# it survives blocked rounds (HEAD does not move) and renews itself on a passed commit.
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/kreisel.sh"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1', want '$2')"; fi; }
export VETO_GATE_LOG_DIR=$(mktemp -d); trap 'rm -rf "$VETO_GATE_LOG_DIR"' EXIT
KD="$VETO_GATE_LOG_DIR/kreisel"
D1=$(mktemp); D2=$(mktemp)
V='{"blocking":[{"id":"B1","claim":"kaputt","why":"w","fix":"f","quote":"export const b = 2;"}]}'

# T1: fresh sequence → round 1, nothing stored
R=$(bash "$S" state --repo r --branch b --base abc)
ok "$(printf '%s' "$R" | jq -r .round)"  "1" "T1 fresh → round 1"
ok "$(printf '%s' "$R" | jq -r .rounds)" "0" "T1b nothing stored"
ok "$(printf '%s' "$R" | jq '.prior|length')" "0" "T1c no prior findings"

# T2: record one block → state file + diff snapshot exist, next round is 2
printf '+alt\n' > "$D1"
printf '%s' "$V" | bash "$S" record --repo r --branch b --base abc --changed 10 --result codex-block --diff "$D1" >/dev/null
R=$(bash "$S" state --repo r --branch b --base abc)
ok "$(printf '%s' "$R" | jq -r .round)"  "2" "T2 one block → next round 2"
ok "$(printf '%s' "$R" | jq -r '.prior[0].findings[0].id')" "B1" "T2b finding stored"
ok "$(printf '%s' "$R" | jq -r '.prior[0].changed')" "10" "T2c size stored"
SEQ=$(printf '%s' "$R" | jq -r .seq)
ok "$([ -f "$KD/$SEQ.diff" ] && echo yes)" "yes" "T2d exact previous diff stored"

# T3: a different BASE is a different sequence — independent changes must never read
# as one correction loop (spec: the id exists exactly for this)
ok "$(bash "$S" state --repo r --branch b --base other | jq -r .round)" "1" "T3 other base → own sequence"

# T4: clear removes the sequence
bash "$S" clear --repo r --branch b --base abc
ok "$(bash "$S" state --repo r --branch b --base abc | jq -r .rounds)" "0" "T4 clear → gone"

# T5: expired window → sequence is over, next block starts a fresh round 1
printf '%s' "$V" | bash "$S" record --repo r --branch b --base w1 --changed 5 --result codex-block --diff "$D1" >/dev/null
SEQ=$(bash "$S" state --repo r --branch b --base w1 | jq -r .seq)
jq -c '.rounds[0].epoch = 1000' "$KD/$SEQ.json" > "$KD/$SEQ.json.t" && mv "$KD/$SEQ.json.t" "$KD/$SEQ.json"
ok "$(bash "$S" state --repo r --branch b --base w1 | jq -r .round)" "1" "T5 expired window → round 1"

# T6: bounded state — 11 findings are capped at 10, long claims truncated
LONG=$(python3 -c 'print("x"*500)')
BIG=$(jq -cn --arg c "$LONG" '{blocking:[range(11) as $i | {id:("F\($i)"),claim:$c,why:"w",fix:"f",quote:"q"}]}')
printf '%s' "$BIG" | bash "$S" record --repo r --branch b --base cap --changed 1 --result codex-block --diff "$D1" >/dev/null
R=$(bash "$S" state --repo r --branch b --base cap)
ok "$(printf '%s' "$R" | jq '.prior[0].findings|length')" "10" "T6 findings capped at 10"
ok "$(printf '%s' "$R" | jq '.prior[0].findings[0].claim|length')" "300" "T6b claim truncated"

# T7: never crash a caller — garbage args, missing diff, broken state file → rc 0
bash "$S" record --repo r --branch b --base g --changed xx --result "" --diff /nope/nix </dev/null >/dev/null 2>&1
ok "$?" "0" "T7 garbage record → rc 0"
echo 'kein json' > "$KD/deadbeef.json"
printf '%s' "$V" | bash "$S" record --repo r --branch b --base g2 --changed 1 --result x --diff "$D1" >/dev/null 2>&1
ok "$?" "0" "T7b broken neighbour state → rc 0"

# T8: housekeeping — files older than 7 days are removed on the next call
touch -t 202601010000 "$KD/old.json"
bash "$S" state --repo r --branch b --base abc >/dev/null
ok "$([ -f "$KD/old.json" ] || echo yes)" "yes" "T8 old state cleaned up"

# T-REL: an UNRELATED change on the same repo/branch/HEAD is a NEW sequence (review B1) —
# otherwise an abandoned attempt's findings would haunt the next, unrelated change.
# Names are GIT output (one path per line) — spaces and deletions arrive exactly as
# git spells them (review round 7), never parsed out of diff text.
DA=$(mktemp); NA=$(mktemp); NB=$(mktemp)
printf '+const alt = 1;\n' > "$DA"
printf 'src/mein modul.ts\n' > "$NA"      # space in the name — the round-7 case
printf 'src/anderes.ts\n' > "$NB"
printf '%s' "$V" | bash "$S" record --repo r --branch b --base rel --changed 10 --result codex-block --diff "$DA" --names "$NA" >/dev/null
ok "$(bash "$S" state --repo r --branch b --base rel --names "$NA" | jq -r .round)" "2" "T-REL same file (with space) → same sequence"
ok "$(bash "$S" state --repo r --branch b --base rel --names "$NB" | jq -r .round)" "1" "T-REL2 no shared file → fresh sequence"
ok "$(bash "$S" state --repo r --branch b --base rel | jq -r .round)" "2" "T-REL3 no names given → conservative, sequence kept"
rm -f "$NA" "$NB"

# T-PERM: stored diffs may hold secrets — dir 700, files 600 (review B3)
SEQP=$(bash "$S" state --repo r --branch b --base rel | jq -r .seq)
ok "$(stat -f '%Lp' "$KD")" "700" "T-PERM state dir 0700"
ok "$(stat -f '%Lp' "$KD/$SEQP.diff")" "600" "T-PERM2 diff snapshot 0600"
rm -f "$DA"

# --- spiral verdict ----------------------------------------------------------
mkdiff(){ # $1 = out file, $2... = added lines
  local f="$1"; shift
  { echo 'diff --git a/x.ts b/x.ts'; echo '+++ b/x.ts'; echo '@@ -0,0 +1 @@'
    for l in "$@"; do echo "+$l"; done; } > "$f"
}
rec(){ # $1 base, $2 changed, $3 quote, $4 diff-file → prints kreisel flag
  printf '{"blocking":[{"id":"B","claim":"c","why":"w","fix":"f","quote":"%s"}]}' "$3" \
    | bash "$S" record --repo r --branch b --base "$1" --changed "$2" --result codex-block --diff "$4" \
    | jq -r .kreisel
}

# T9: the real spiral — 3 rounds, growing diff, finding quotes a line the previous fix added
mkdiff "$D1" "const a = 1;"
mkdiff "$D2" "const a = 1;" "const b = 2;"
ok "$(rec spi 10 'irrelevant' "$D1")" "false" "T9 round 1 → never"
ok "$(rec spi 20 'const b = 2;' "$D2")" "false" "T9b round 2 → below threshold"
mkdiff "$D1" "const a = 1;" "const b = 2;" "const c = 3;"
R=$(printf '{"blocking":[{"id":"B","claim":"c","why":"w","fix":"f","quote":"const c = 3;"}]}' \
  | bash "$S" record --repo r --branch b --base spi --changed 30 --result codex-block --diff "$D1")
ok "$(printf '%s' "$R" | jq -r .kreisel)" "true" "T9c round 3 + growth + fresh-line hit → fires"
ok "$(printf '%s' "$R" | jq -r .from)"    "10"   "T9d growth reported from round 1"
ok "$(printf '%s' "$R" | jq -r .to)"      "30"   "T9e …to now"

# T10: same rounds/growth, but the quote hits a line that ALREADY existed → no spiral
bash "$S" clear --repo r --branch b --base old
mkdiff "$D1" "const a = 1;"
mkdiff "$D2" "const a = 1;" "const b = 2;"
rec old 10 'x' "$D1" >/dev/null; rec old 20 'x' "$D2" >/dev/null
mkdiff "$D1" "const a = 1;" "const b = 2;" "const c = 3;"
ok "$(rec old 30 'const a = 1;' "$D1")" "false" "T10 hit on an OLD line → converging, no spiral"

# T11: shrinking diff → converging, no spiral (growth must be monotone AND above round 1)
bash "$S" clear --repo r --branch b --base shr
mkdiff "$D1" "const a = 1;" "const b = 2;"
mkdiff "$D2" "const a = 1;" "const b = 2;" "const c = 3;"
rec shr 20 'x' "$D1" >/dev/null; rec shr 30 'x' "$D2" >/dev/null
mkdiff "$D1" "const a = 1;" "const d = 4;"
ok "$(rec shr 15 'const d = 4;' "$D1")" "false" "T11 shrinking diff → no spiral"

# T12: tiny quotes ('fi', '}') must not count as a content hit — anti-noise floor
bash "$S" clear --repo r --branch b --base tiny
mkdiff "$D1" "old line here;"
mkdiff "$D2" "old line here;" "fi"
rec tiny 10 'x' "$D1" >/dev/null; rec tiny 20 'x' "$D2" >/dev/null
mkdiff "$D1" "old line here;" "fi" "done"
ok "$(rec tiny 30 'fi' "$D1")" "false" "T12 a 2-char quote is noise, not an anchor"

# T13: quotes may arrive with a leading '+' and extra whitespace — normalized match
bash "$S" clear --repo r --branch b --base ws
mkdiff "$D1" "const x = 1;"
mkdiff "$D2" "const x = 1;" "const neu = 2;"
rec ws 10 'x' "$D1" >/dev/null; rec ws 20 'x' "$D2" >/dev/null
mkdiff "$D1" "const x = 1;" "const neu = 2;" "const ganzneu = 3;"
ok "$(rec ws 30 '+const   ganzneu = 3;' "$D1")" "true" "T13 '+' and whitespace normalized away"

# T14: a prechecker round WITHOUT quotes still counts toward the round threshold
bash "$S" clear --repo r --branch b --base pre
mkdiff "$D1" "const p = 1;"
printf '{"blocking":[{"id":"Q1","claim":"c","why":"w","fix":"f"}]}' \
  | bash "$S" record --repo r --branch b --base pre --changed 10 --result qwen-block --diff "$D1" >/dev/null
mkdiff "$D2" "const p = 1;" "const q = 2;"
rec pre 20 'x' "$D2" >/dev/null
mkdiff "$D1" "const p = 1;" "const q = 2;" "const r3 = 3;"
ok "$(rec pre 30 'const r3 = 3;' "$D1")" "true" "T14 qwen round counted, codex round fires"

# T15: threshold is an env seam — VETO_GATE_KREISEL_ROUNDS=2 fires one round earlier
bash "$S" clear --repo r --branch b --base env2
mkdiff "$D1" "const e = 1;"
rec env2 10 'x' "$D1" >/dev/null
mkdiff "$D2" "const e = 1;" "const f2 = 2;"
ok "$(VETO_GATE_KREISEL_ROUNDS=2 rec env2 20 'const f2 = 2;' "$D2")" "true" "T15 threshold configurable"

# T-FLAT: a flat step is not growth — the spec says GROWS round over round (codex B2)
bash "$S" clear --repo r --branch b --base flat
mkdiff "$D1" "const f1 = 1;"
rec flat 10 'x' "$D1" >/dev/null
mkdiff "$D2" "const f1 = 1;" "const f2 = 2;"
rec flat 10 'x' "$D2" >/dev/null
mkdiff "$D1" "const f1 = 1;" "const f2 = 2;" "const f3 = 3;"
ok "$(rec flat 20 'const f3 = 3;' "$D1")" "false" "T-FLAT equal middle round → no growth, no spiral"

# T-TOTAL: the round number counts ALL rounds ever, not just the 12 kept ones (codex B3)
bash "$S" clear --repo r --branch b --base tot
mkdiff "$D1" "const t = 1;"
rec tot 1 'x' "$D1" >/dev/null
SEQT=$(bash "$S" state --repo r --branch b --base tot | jq -r .seq)
jq -c '.total = 13' "$KD/$SEQT.json" > "$KD/$SEQT.json.t" && mv "$KD/$SEQT.json.t" "$KD/$SEQT.json"
ok "$(bash "$S" state --repo r --branch b --base tot | jq -r .round)" "14" "T-TOTAL round number survives the 12-round cap"

# T-EMPTY: a previous round that only DELETED lines (no '+' at all) must not derail
# the three-stream classification (codex B4: an empty file shifts awk's file counter)
bash "$S" clear --repo r --branch b --base del
mkdiff "$D1" "const a = 1;"
rec del 5 'x' "$D1" >/dev/null
printf -- '-const weg = 1;\n' > "$D2"
rec del 10 'x' "$D2" >/dev/null
mkdiff "$D1" "const neu = 2;"
ok "$(rec del 20 'const neu = 2;' "$D1")" "true" "T-EMPTY deletion-only previous diff → fresh lines still detected"

# T-PLUSPLUS: an added code line that itself starts with '++' arrives as '+++…' in
# the diff and must not be mistaken for a file header (codex round 3)
bash "$S" clear --repo r --branch b --base pp
mkdiff "$D1" "const p = 1;"
rec pp 5 'x' "$D1" >/dev/null
mkdiff "$D2" "const p = 1;" "const q = 2;"
rec pp 10 'x' "$D2" >/dev/null
mkdiff "$D1" "const p = 1;" "const q = 2;" "++zaehler;"
ok "$(rec pp 20 '++zaehler;' "$D1")" "true" "T-PLUSPLUS '++' code line is content, not a header"

# T16: a round whose diff copy cannot be made must DROP the old snapshot (codex B3) —
# otherwise the next spiral check would compare against a foreign, older round's diff
bash "$S" clear --repo r --branch b --base stale
mkdiff "$D1" "const s = 1;"
rec stale 10 'x' "$D1" >/dev/null
SEQ=$(bash "$S" state --repo r --branch b --base stale | jq -r .seq)
ok "$([ -f "$KD/$SEQ.diff" ] && echo yes)" "yes" "T16 snapshot exists after round 1"
printf '%s' "$V" | bash "$S" record --repo r --branch b --base stale --changed 20 --result codex-block --diff /nope/nix >/dev/null
ok "$([ -f "$KD/$SEQ.diff" ] || echo weg)" "weg" "T16b unreadable diff → stale snapshot removed"

# T17: `state` reports what the CALLER needs to tell a patch from a new approach.
# The stop in veto-gate.sh used to know only the round number, so a fourth patch
# and a rewrite looked identical to it — while these numbers were sitting here,
# computed and thrown away (2026-08-12).
bash "$S" clear --repo r --branch b --base meas
mkdiff "$D1" "const keep = 1;"
N1=$(mktemp); printf 'src/a.ts\nsrc/b.ts\n' > "$N1"
printf '%s' "$V" | bash "$S" record --repo r --branch b --base meas \
  --changed 40 --result codex-block --diff "$D1" --names "$N1" >/dev/null

# same files, same content → nothing here says "new approach"
ST=$(bash "$S" state --repo r --branch b --base meas --names "$N1" --diff "$D1")
ok "$(printf '%s' "$ST" | jq -r .prev_changed)" "40" "T17 previous size reported"
ok "$(printf '%s' "$ST" | jq -r .prev_files)"   "2"  "T17b previous file count reported"
ok "$(printf '%s' "$ST" | jq -r .shared_files)" "2"  "T17c both files shared"
ok "$(printf '%s' "$ST" | jq -r .carry_pct)"    "100" "T17d every added line carried over"

# PARTLY other files — the case the rewrite rule is actually about. Zero overlap
# is already handled upstream (read_state drops the sequence), so the interesting
# number is a real, small share.
N2=$(mktemp); printf 'src/a.ts\nsrc/x.ts\nsrc/y.ts\n' > "$N2"
mkdiff "$D2" "const fresh = 2;"
ST=$(bash "$S" state --repo r --branch b --base meas --names "$N2" --diff "$D2")
ok "$(printf '%s' "$ST" | jq -r .shared_files)" "1" "T17e one of three files still shared"
ok "$(printf '%s' "$ST" | jq -r .carry_pct)"    "0" "T17f none of the added lines carried over"

# no file at all in common → the sequence itself is dropped, so there is no
# previous round to compare with, and every number says "nothing to compare"
N3=$(mktemp); printf 'src/x.ts\n' > "$N3"
ST=$(bash "$S" state --repo r --branch b --base meas --names "$N3" --diff "$D2")
ok "$(printf '%s' "$ST" | jq -r .round)"       "1"  "T17e2 unrelated work → fresh sequence"
ok "$(printf '%s' "$ST" | jq -r .prev_changed)" "-1" "T17e3 …and no previous size to read"
rm -f "$N3"

# no diff handed in → not measurable, and it must say so rather than claim 0:
# a 0 would read as "completely rewritten" and wave a real spiral through
ST=$(bash "$S" state --repo r --branch b --base meas --names "$N1")
ok "$(printf '%s' "$ST" | jq -r .carry_pct)" "-1" "T17g unmeasurable is -1, never a fake 0"

# an unreadable name list is "unknown", not "nothing in common" — the latter is
# the shape of a rewrite and would wave the round-4 question through (codex B1)
ST=$(bash "$S" state --repo r --branch b --base meas --diff "$D1")
ok "$(printf '%s' "$ST" | jq -r .shared_files)" "-1" "T17h no name list → -1, not 0"

# a sequence the window has dropped must not be measured against its leftover
# diff snapshot: that file outlives the rounds it belonged to (codex B2).
# The stored epoch is aged instead of setting WINDOW=0 — with a window of 0 the
# test passes or fails depending on whether the clock ticked between record and
# read, which is how it went green here and red on the exported copy.
SEQM=$(bash "$S" state --repo r --branch b --base meas | jq -r .seq)
jq -c '.rounds[-1].epoch = 1000' "$KD/$SEQM.json" > "$KD/$SEQM.json.t" && mv "$KD/$SEQM.json.t" "$KD/$SEQM.json"
ST=$(bash "$S" state --repo r --branch b --base meas --names "$N1" --diff "$D1")
ok "$(printf '%s' "$ST" | jq -r .carry_pct)" "-1" "T17i expired sequence → nothing to carry from"
rm -f "$N1" "$N2"

rm -f "$D1" "$D2"
echo "kreisel: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

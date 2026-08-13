#!/usr/bin/env bash
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/log-run.sh"
export VETO_GATE_LOG_DIR="$(mktemp -d)"; trap 'rm -rf "$VETO_GATE_LOG_DIR"' EXIT
P=0; F=0; ok(){ [ "$1" = "$2" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL $3: '$1'≠'$2'"; }; }
LOG="$VETO_GATE_LOG_DIR/runs.jsonl"

bash "$S" --repo beispiel-repo --branch feat/x --files 3 --result codex-pass --blocking 0 --dur 18 --thread 019f
ok "$(wc -l < "$LOG" | tr -d ' ')" "1" "one line written"
ok "$(jq -r .result "$LOG")" "codex-pass" "result field"
ok "$(jq -r .repo "$LOG")" "beispiel-repo" "repo field"
ok "$(jq -r .blocking "$LOG")" "0" "blocking numeric"
ok "$(jq -r .dur "$LOG")" "18" "dur numeric"

# cap at 1000
for i in $(seq 1 1005); do bash "$S" --repo r --branch b --result codex-pass --blocking 0 --dur 1 --thread t; done
ok "$(wc -l < "$LOG" | tr -d ' ')" "1000" "capped at 1000"

# verdict + violations persisted (new in E1)
bash "$S" --repo r --branch b --result codex-block --blocking 1 \
  --verdict '{"blocking":[{"id":"B1","claim":"Import erfunden","why":"Datei gibt es nicht","fix":"Pfad korrigieren"}],"non_blocking":[]}'
ok "$(tail -1 "$LOG" | jq -r '.verdict.blocking[0].id')" "B1" "verdict persisted"
bash "$S" --repo r --branch b --result grounding-block --blocking 2 \
  --violations '[{"file":"a.ts","import":"./nope"}]'
ok "$(tail -1 "$LOG" | jq -r '.violations[0].import')" "./nope" "violations persisted"
# invalid json → field omitted, entry still written
bash "$S" --repo r --branch b --result codex-pass --verdict 'kaputt{'
ok "$(tail -1 "$LOG" | jq -r 'has("verdict")')" "false" "invalid verdict omitted"
ok "$(tail -1 "$LOG" | jq -r '.result')" "codex-pass" "entry still written"
# B5: valid but wrongly-typed JSON → field omitted (verdict!=object, violations!=array-of-objects)
bash "$S" --repo r --branch b --result codex-block --verdict '[]'
ok "$(tail -1 "$LOG" | jq -r 'has("verdict")')" "false" "non-object verdict omitted"
bash "$S" --repo r --branch b --result grounding-block --violations '{}'
ok "$(tail -1 "$LOG" | jq -r 'has("violations")')" "false" "non-array violations omitted"
bash "$S" --repo r --branch b --result grounding-block --violations '[1,2]'
ok "$(tail -1 "$LOG" | jq -r 'has("violations")')" "false" "non-object elements omitted"

# ── the evidence ledger reaches the run log ────────────────────────────────
# Notes without a reader are worthless: the dashboard and every statistic read runs.jsonl.
: > "$LOG"
bash "$S" --repo r --branch main --files 1 --result codex-pass --blocking 0 \
  --proofs '[{"stage":"tests","status":"unavailable","detail":"Dienste aus"}]'
ok "$(jq -r '.proofs[0].stage' "$LOG")"  "tests"       "T-PROOFS stage in runs.jsonl"
ok "$(jq -r '.proofs[0].status' "$LOG")" "unavailable" "T-PROOFS status in runs.jsonl"

# no --proofs → field is null, never a crash (every existing caller keeps working)
: > "$LOG"
bash "$S" --repo r --branch main --files 1 --result codex-pass --blocking 0
ok "$(jq -r '.proofs' "$LOG")" "null" "T-PROOFS absent → null, no crash"

# Unreadable notes must NOT be dropped the way an invalid verdict is. A missing `proofs`
# field reads as "no stage ran anything" — which is exactly the silent gap this whole
# feature exists to kill. So the loss itself is recorded, as a gap.
: > "$LOG"
bash "$S" --repo r --branch main --result codex-pass --proofs 'kaputt{'
ok "$(jq -r '.proofs[0].status' "$LOG")" "unavailable" "T-PROOFS broken notes → logged as a gap, not dropped"
ok "$(jq -r '.result' "$LOG")" "codex-pass" "T-PROOFS entry still written"
: > "$LOG"
bash "$S" --repo r --branch main --result codex-pass --proofs '{"stage":"x"}'
ok "$(jq -r '.proofs[0].stage' "$LOG")" "protokoll" "T-PROOFS wrongly-typed notes → gap note, not dropped"

# An EMPTY --proofs is not the same as no --proofs: the caller HAD a ledger and it came
# back with nothing. Treating that as "old caller, no field" is how the gap hides again.
: > "$LOG"
bash "$S" --repo r --branch main --result codex-pass --proofs ''
ok "$(jq -r '.proofs[0].status' "$LOG")" "unavailable" "T-PROOFS empty value → gap note, not silence"

# --- Stufe 2: sequence identity + diff facts per run -------------------------
NF=$(mktemp)
printf 'src/a.ts\nsrc/b.ts\nsrc/a.ts\n' > "$NF"
bash "$S" --repo r2 --branch b2 --result codex-block --changed 42 --names "$NF" --seq abcd1234 --seq-round 3
L=$(tail -1 "$LOG")
ok "$(printf '%s' "$L" | jq -r .changed)"        "42"       "K1 changed logged"
ok "$(printf '%s' "$L" | jq -r '.names|length')" "2"        "K2 names deduped"
ok "$(printf '%s' "$L" | jq -r .seq)"            "abcd1234" "K3 sequence id logged"
ok "$(printf '%s' "$L" | jq -r .seq_round)"      "3"        "K4 round logged"
# K5: cap — 35 names stay 30 (runs.jsonl is a stats ledger, not an archive)
i=0; : > "$NF"; while [ "$i" -lt 35 ]; do echo "f$i.ts" >> "$NF"; i=$((i+1)); done
bash "$S" --repo r2 --branch b2 --result codex-pass --names "$NF"
ok "$(tail -1 "$LOG" | jq -r '.names|length')" "30" "K5 names capped at 30"
# K6: an entry without the new flags carries none of the new fields (old callers)
bash "$S" --repo r2 --branch b2 --result codex-pass
ok "$(tail -1 "$LOG" | jq -r 'has("seq"),has("changed"),has("names")' | tr '\n' ' ')" "false false false " "K6 absent flags → absent fields"
# K7: garbage numbers → 0, never a crash
bash "$S" --repo r2 --branch b2 --result x --changed xx --seq s --seq-round yy
ok "$(tail -1 "$LOG" | jq -r '.changed,.seq_round' | tr '\n' ' ')" "0 0 " "K7 garbage numbers → 0"
# K8: kreisel flag — only literal true/false, anything else is omitted
bash "$S" --repo r2 --branch b2 --result codex-block --kreisel true
ok "$(tail -1 "$LOG" | jq -r .kreisel)" "true" "K8 kreisel flag logged"
bash "$S" --repo r2 --branch b2 --result codex-block --kreisel maybe
ok "$(tail -1 "$LOG" | jq -r 'has("kreisel")')" "false" "K8b garbage kreisel → omitted"
# K8c: a FAILED spiral check is a gap, not an all-clear — it must not read as false
bash "$S" --repo r2 --branch b2 --result codex-block --kreisel unavailable
ok "$(tail -1 "$LOG" | jq -r .kreisel)" "unavailable" "K8c failed check logged as unavailable"
# K9: a round number without a sequence id is half-data — it must not masquerade
# as a genuine round 1 when the state read failed (codex)
bash "$S" --repo r2 --branch b2 --result codex-block --seq-round 3
ok "$(tail -1 "$LOG" | jq -r 'has("seq_round")')" "false" "K9 round without seq → omitted"
rm -f "$NF"

# K10: bundle size. pack-diff copies every touched file WHOLE, so the reading
# work grows with the FILE size, not with the diff size. Without this number in
# the ledger every timeout theory stays a guess (testbau-repo measurement 2026-07-28:
# four runs of 94 changed lines, three timed out, one produced a verdict).
bash "$S" --repo r2 --branch b2 --result codex-pass --bundle-tokens 4711
ok "$(tail -1 "$LOG" | jq -r .bundle_tokens)" "4711" "K10 bundle size persisted"
bash "$S" --repo r2 --branch b2 --result codex-pass
ok "$(tail -1 "$LOG" | jq -r 'has("bundle_tokens")')" "false" "K10b no flag → no field"
# garbage is DROPPED here, not zeroed like --changed: a bogus 0 would read as
# "tiny bundle" and mislead exactly the measurement this field exists for
bash "$S" --repo r2 --branch b2 --result codex-pass --bundle-tokens kaputt
ok "$(tail -1 "$LOG" | jq -r 'has("bundle_tokens")')" "false" "K10c garbage → omitted, never a bogus 0"

# ── K11: the WHY of a deliberate bypass ─────────────────────────────────────
# Measured 2026-08-13: 335 of the 1000 entries in the live ledger are overrides
# and not one says why. "The gate is too strict" and "we were in a hurry" leave
# the same trace, so neither can be answered.
bash "$S" --repo r3 --branch b3 --result override --reason 'Lockfile, der Prüfer kann das nicht'
ok "$(tail -1 "$LOG" | jq -r .reason)" "Lockfile, der Prüfer kann das nicht" "K11 reason persisted"
bash "$S" --repo r3 --branch b3 --result override
ok "$(tail -1 "$LOG" | jq -r 'has("reason")')" "false" "K11b no flag → no field"
# An empty reason is NOT the same as no flag: somebody bypassed and wrote
# nothing. Reading that as "an old caller" would hide the very gap we measure.
bash "$S" --repo r3 --branch b3 --result override --reason ''
ok "$(tail -1 "$LOG" | jq -r .reason)" "" "K11c an empty reason is still recorded"
# free text goes into a JSON ledger — quotes and backslashes must not split it
bash "$S" --repo r3 --branch b3 --result override --reason 'er sagte "nein" \ und ging'
ok "$(tail -1 "$LOG" | jq -r .reason)" 'er sagte "nein" \ und ging' "K11d quotes and backslashes survive"
ok "$(tail -1 "$LOG" | jq -r .result)" "override" "K11e the line is still valid JSON"
# a reason can end up on a terminal — an escape sequence in it must not
bash "$S" --repo r3 --branch b3 --result override --reason "$(printf 'a\033[2Jb')"
ok "$(tail -1 "$LOG" | jq -r .reason)" "a[2Jb" "K11f control characters are stripped at write"
# a reason is ONE line by definition — a reader counting lines would otherwise
# see a single bypass as two
bash "$S" --repo r3 --branch b3 --result override --reason "$(printf 'erste\nzweite')"
ok "$(tail -1 "$LOG" | jq -r .reason)" "erstezweite" "K11g a newline never survives into a reason"
# U+009B is a terminal command that shows up as nothing at all — a filter
# written as a list of dangerous bytes keeps missing this range
bash "$S" --repo r3 --branch b3 --result override --reason "$(printf 'a\302\233[2Jb')"
ok "$(tail -1 "$LOG" | jq -r .reason)" "a[2Jb" "K11h an invisible control character is stripped too"

echo "log-run: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

#!/usr/bin/env bash
# log-run.sh — append one veto-gate run as JSON to $VETO_GATE_LOG_DIR/runs.jsonl (cap 1000).
set -uo pipefail
LOG_DIR="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}"
REPO=""; BRANCH=""; RESULT=""; BLOCKING=0; DUR=0; THREAD=""; FILES=0
VERDICT_JSON=""; VIOLATIONS_JSON=""; PROOFS_JSON=""; PROOFS_GIVEN=0
CHANGED_IN=""; NAMES_FILE=""; SEQ=""; SEQ_ROUND=""; KREISEL=""; BTOK=""
REASON=""; REASON_GIVEN=0
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2;; --branch) BRANCH="$2"; shift 2;;
  --result) RESULT="$2"; shift 2;; --blocking) BLOCKING="${2:-0}"; shift 2;;
  --dur) DUR="${2:-0}"; shift 2;; --thread) THREAD="$2"; shift 2;;
  --files) FILES="${2:-0}"; shift 2;;
  --verdict) VERDICT_JSON="$2"; shift 2;;
  --violations) VIOLATIONS_JSON="$2"; shift 2;;
  --proofs) PROOFS_JSON="${2:-}"; PROOFS_GIVEN=1; shift 2;;
  --changed) CHANGED_IN="${2:-}"; shift 2;;
  --names) NAMES_FILE="${2:-}"; shift 2;;
  --seq) SEQ="${2:-}"; shift 2;;
  --seq-round) SEQ_ROUND="${2:-}"; shift 2;;
  --kreisel) KREISEL="${2:-}"; shift 2;;
  --bundle-tokens) BTOK="${2:-}"; shift 2;;
  # why somebody stepped around the gate. An EMPTY --reason is not the same as
  # no --reason: it means a bypass that wrote nothing, and that is the gap this
  # field measures. So the flag's presence is remembered, not just its value.
  # Control characters are stripped HERE, not only at the gate's door: every
  # caller writes through this script, and from the ledger a reason reaches a
  # terminal. \p{C} is the whole class, not a list of bytes — the invisible C1
  # range (U+0080–U+009F) is a terminal command just like ESC. The newline goes
  # with them: a reason is one line, and a reader counting lines would otherwise
  # see one bypass as two.
  --reason) REASON=$(printf '%s' "${2:-}" | jq -Rsr 'gsub("\\p{C}";"")'); REASON_GIVEN=1; shift 2;;
  *) shift;;
esac; done
mkdir -p "$LOG_DIR"; LOG="$LOG_DIR/runs.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[ -z "${BLOCKING##*[!0-9]*}" ] && BLOCKING=0
[ -z "${DUR##*[!0-9]*}" ] && DUR=0
[ -z "${FILES##*[!0-9]*}" ] && FILES=0
# Stufe 2 fields — all optional: an entry without them must look exactly like before
# (old callers, old tests). Garbage numbers become 0, never a crash.
[ -n "$CHANGED_IN" ] && [ -z "${CHANGED_IN##*[!0-9]*}" ] && CHANGED_IN=0
[ -n "$SEQ_ROUND" ] && [ -z "${SEQ_ROUND##*[!0-9]*}" ] && SEQ_ROUND=0
NAMES_JSON=""
if [ -n "$NAMES_FILE" ] && [ -f "$NAMES_FILE" ]; then
  # capped at 30: runs.jsonl is a stats ledger, not an archive — `files` keeps the true count
  NAMES_JSON=$(sort -u "$NAMES_FILE" 2>/dev/null | grep -v '^$' | head -30 | jq -R . | jq -sc . 2>/dev/null)
  printf '%s' "$NAMES_JSON" | jq -e 'type=="array"' >/dev/null 2>&1 || NAMES_JSON=""
fi
# How much reading the review actually was (pack-diff SIZE.json). Garbage is DROPPED
# here, not zeroed like --changed: a bogus 0 would read as "tiny bundle" and mislead
# exactly the measurement this field exists for. Absent is honest, wrong is not.
[ -n "$BTOK" ] && [ -n "${BTOK##*[!0-9]*}" ] || BTOK=""
# 'unavailable' = the spiral check itself failed — a gap, never an all-clear (UL-006)
case "$KREISEL" in true|false|unavailable) ;; *) KREISEL="";; esac
# invalid or wrongly-typed JSON in verdict/violations → drop the field, keep
# the entry. verdict must be an object, violations an array of objects (B5:
# a valid-but-mistyped value would crash consumers like serve.py /data).
printf '%s' "$VERDICT_JSON"    | jq -e 'type=="object"' >/dev/null 2>&1 || VERDICT_JSON=""
printf '%s' "$VIOLATIONS_JSON" | jq -e 'type=="array" and all(.[]; type=="object")' >/dev/null 2>&1 || VIOLATIONS_JSON=""
# The evidence ledger (proof.sh) — but it is NOT dropped when it does not parse, the way a
# broken verdict is. A missing `proofs` field reads as "no stage checked anything", which is
# precisely the silent gap this feature exists to kill. So the LOSS is recorded, as a gap.
#
# And an EMPTY --proofs is not the same as no --proofs at all: the caller HAD a ledger and it
# came back with nothing to say. Reading that as "an old caller without the flag" would hide
# the gap all over again — so we remember whether the flag was passed, not just its value.
if [ "$PROOFS_GIVEN" = 1 ]; then
  jq -ne --argjson p "$PROOFS_JSON" '$p | type=="array" and all(.[]; type=="object")' >/dev/null 2>&1 \
    || PROOFS_JSON='[{"stage":"protokoll","status":"unavailable","detail":"Beweis-Zettel unlesbar oder leer — nicht protokolliert"}]'
fi
jq -cn --arg ts "$TS" --arg repo "$REPO" --arg br "$BRANCH" --argjson files "$FILES" \
  --arg res "$RESULT" --argjson blk "$BLOCKING" --argjson dur "$DUR" --arg th "$THREAD" \
  --argjson verdict "${VERDICT_JSON:-null}" --argjson violations "${VIOLATIONS_JSON:-null}" \
  --argjson proofs "${PROOFS_JSON:-null}" \
  --arg changed "$CHANGED_IN" --arg names "$NAMES_JSON" --arg seq "$SEQ" \
  --arg round "$SEQ_ROUND" --arg kreisel "$KREISEL" --arg btok "$BTOK" \
  --arg reason "$REASON" --arg rgiven "$REASON_GIVEN" \
  '{ts:$ts,repo:$repo,branch:$br,files:$files,result:$res,blocking:$blk,dur:$dur,thread:$th}
   + (if $verdict != null then {verdict:$verdict} else {} end)
   + (if $violations != null then {violations:$violations} else {} end)
   + (if $proofs != null then {proofs:$proofs} else {} end)
   + (if $changed != "" then {changed:($changed|tonumber)} else {} end)
   + (if $names != "" then {names:($names|fromjson)} else {} end)
   + (if $btok != "" then {bundle_tokens:($btok|tonumber)} else {} end)
   + (if $rgiven == "1" then {reason:$reason} else {} end)
   + (if $seq != "" then {seq:$seq} else {} end)
   + (if $seq != "" and $round != "" then {seq_round:($round|tonumber)} else {} end)
   + (if $kreisel == "unavailable" then {kreisel:"unavailable"}
      elif $kreisel != "" then {kreisel:($kreisel=="true")} else {} end)' >> "$LOG"
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
  tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

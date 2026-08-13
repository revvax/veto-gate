#!/usr/bin/env bash
# `veto-gate reasons` — what the deliberate bypasses said.
#
# The ledger records WHY somebody stepped around the gate (since 2026-08-13).
# Collecting without ever looking is how the last watcher rotted: 1058 findings
# sat unread in a .pending file for weeks (UL-006). So the reading is a command,
# not a promise to grep it someday.
set -uo pipefail
X="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/veto-gate-cli.sh"
export VETO_GATE_LOG_DIR="$(mktemp -d)"; trap 'rm -rf "$VETO_GATE_LOG_DIR"' EXIT
LOG="$VETO_GATE_LOG_DIR/runs.jsonl"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1', want '$2')"; fi; }
has(){ case "$1" in *"$2"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL: $3 (got '$1')";; esac; }

# ── T1: no ledger at all is a sentence, never a stack trace ─────────────────
OUT=$(bash "$X" reasons 2>&1); RC=$?
ok "$RC" "0" "T1 a missing ledger is not an error"
has "$OUT" "kein" "T1 it says there is nothing yet"

# ── fixture: 4 bypasses of three kinds + 2 runs that are not bypasses ───────
{
  printf '{"ts":"2026-08-01T10:00:00Z","repo":"r","result":"override","reason":"Lockfile, das kann der Prüfer nicht"}\n'
  printf '{"ts":"2026-08-02T10:00:00Z","repo":"r","result":"override","reason":"Lockfile, das kann der Prüfer nicht"}\n'
  printf '{"ts":"2026-08-03T10:00:00Z","repo":"r","result":"override","reason":""}\n'
  printf '{"ts":"2026-08-04T10:00:00Z","repo":"r","result":"override"}\n'
  printf '{"ts":"2026-08-05T10:00:00Z","repo":"r","result":"codex-pass"}\n'
  printf '{"ts":"2026-08-06T10:00:00Z","repo":"r","result":"codex-block","reason":"nicht gezählt"}\n'
} > "$LOG"

OUT=$(bash "$X" reasons 2>&1); RC=$?
ok "$RC" "0" "T2 a filled ledger reports cleanly"

# ── T3: the head line counts, and it counts only bypasses ──────────────────
has "$OUT" "4 von 6" "T3 four bypasses out of six runs"

# ── T4: the same reason twice is one line with a count of 2 ────────────────
has "$OUT" "2" "T4 the repeated reason is counted"
has "$OUT" "Lockfile, das kann der Prüfer nicht" "T4 the reason itself is shown"

# ── T5: the two kinds of silence are told apart ────────────────────────────
# empty = somebody bypassed and wrote nothing (the gap we want to see shrink)
# absent = logged before the field existed, and no reproach to anybody
has "$OUT" "ohne Grund" "T5 an empty reason is named as such"
has "$OUT" "vor dem Grund-Feld" "T5 an entry older than the field is named separately"

# ── T6: a run that is not a bypass never appears, whatever it carries ──────
case "$OUT" in *"nicht gezählt"*) F=$((F+1)); echo "  FAIL: T6 a non-bypass reason was counted";; *) P=$((P+1));; esac

# ── T7: the ring buffer is stated, not implied ─────────────────────────────
# runs.jsonl keeps the last 1000 entries; a share read as "all time" would be
# wrong by however much has already scrolled out
has "$OUT" "1000" "T7 the report says the ledger only keeps the last 1000 runs"

# ── T8: a broken line does not take the whole report down ──────────────────
printf 'das ist kein JSON\n' >> "$LOG"
OUT=$(bash "$X" reasons 2>&1); RC=$?
ok "$RC" "0" "T8 a corrupt line does not break the report"
has "$OUT" "Lockfile, das kann der Prüfer nicht" "T8 …and the intact lines are still read"

# ── T9: head line and list are read from ONE snapshot ──────────────────────
# Counting the runs and collecting the bypasses from two separate reads lets a
# run that lands in between report more bypasses than runs. The invariant that
# catches it without a race: the counts in the list must add up to the head line.
OUT=$(bash "$X" reasons 2>&1)
SUM=$(printf '%s\n' "$OUT" | sed -n 's/^\([0-9][0-9]*\) ×.*/\1/p' | awk '{s+=$1} END{print s+0}')
HEAD=$(printf '%s\n' "$OUT" | sed -n 's/^Umgehungen: \([0-9][0-9]*\) von.*/\1/p')
ok "$SUM" "$HEAD" "T9 the head line agrees with the list it heads"

# ── T10: a control character in a stored reason never reaches the terminal ──
# The gate strips them on the way in, but the ledger can be written by anything
# that calls log-run.sh, and old entries predate the stripping. Whoever PRINTS
# is where the terminal is, so the reader cleans up too.
printf '%s\n' '{"ts":"2026-08-07T10:00:00Z","repo":"r","result":"override","reason":"harmlos\u001b[2Jgeloescht"}' >> "$LOG"
OUT=$(bash "$X" reasons 2>&1)
ok "$(printf '%s' "$OUT" | tr -dc '\033' | wc -c | tr -d ' ')" "0" "T10 no escape character reaches the output"
has "$OUT" "harmlos" "T10 …and the readable part still shows"

# ── T11: a newline inside a stored reason is still ONE bypass ──────────────
# log-run.sh strips it on the way in, but an older or foreign writer may have
# put one in. Counted as text lines, that single bypass would count twice — and
# a report can then claim more bypasses than runs.
printf '%s\n' '{"ts":"2026-08-08T10:00:00Z","repo":"r","result":"override","reason":"erste\nzweite"}' >> "$LOG"
OUT=$(bash "$X" reasons 2>&1)
SUM=$(printf '%s\n' "$OUT" | sed -n 's/^\([0-9][0-9]*\) ×.*/\1/p' | awk '{s+=$1} END{print s+0}')
HEAD=$(printf '%s\n' "$OUT" | sed -n 's/^Umgehungen: \([0-9][0-9]*\) von.*/\1/p')
ok "$SUM" "$HEAD" "T11 a two-line reason does not become two bypasses"

# ── T12: the log path is an environment variable and prints scrubbed too ───
BADD="$(mktemp -d)/$(printf 'x\033[2Jy')"; mkdir -p "$BADD"
OUT=$(VETO_GATE_LOG_DIR="$BADD" bash "$X" reasons 2>&1); RC=$?
ok "$RC" "0" "T12 a missing ledger under an odd path is still not an error"
ok "$(printf '%s' "$OUT" | tr -dc '\033' | wc -c | tr -d ' ')" "0" "T12 no escape character from the path either"
rm -rf "$(dirname "$BADD")"

# ── T13: the invisible half of the control characters counts too ───────────
# U+009B is a terminal command like ESC and shows up as nothing at all. Filters
# written as a list of dangerous bytes keep missing this range; a rule written
# as "no control character" does not.
printf '%s\n' '{"ts":"2026-08-09T10:00:00Z","repo":"r","result":"override","reason":"harmlos\u009b[2Jc1"}' >> "$LOG"
OUT=$(bash "$X" reasons 2>&1)
ok "$(printf '%s' "$OUT" | grep -c "$(printf '\302\233')" || true)" "0" "T13 an invisible C1 control character is gone too"
has "$OUT" "harmlos" "T13 …and the readable part still shows"

echo "veto-gate-reasons: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

#!/usr/bin/env bash
# The spiral brake must judge, not count.
#
# It used to fire on the round number alone. Measured 2026-08-12: one sequence
# where round 4 SHRANK 162→154 lines (the author had done exactly what round 3
# demanded) and one where round 4 was the rewrite the reviewer had asked for.
# Both were stopped without a reviewer ever seeing them. These tests pin the
# three ways out — smaller, different, or a switch that lifts the brake and
# still reviews — and that the stop counts itself, so rework can earn a review
# back instead of only waiting out the clock.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"
unset DISCORD_VETO_WEBHOOK
HOOK="$(cd "$(dirname "$0")/.." && pwd)/veto-gate.sh"
KRE="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/kreisel.sh"
export VETO_GATE_LOG_DIR="$(mktemp -d)"
export VETO_GATE_TIMEOUT=5
export VETO_GATE_HERMES_BIN="/nonexistent/hermes"
TMP=$(mktemp -d); trap 'rm -rf "$TMP" "$VETO_GATE_LOG_DIR" "$VETO_HB_DIR"' EXIT
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }

R="$TMP/repo"; mkdir -p "$R/src" "$R/.claude/config" "$R/.claude/session-flags"
git -C "$R" init -q
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf '{"enabled":true,"effort":"high","max_lines":4000}\n' > "$R/.claude/config/veto-gate.json"
printf 'export const seed=1;\n' > "$R/src/seed.ts"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -qm base >/dev/null 2>&1

# A spy reviewer: it records that it ran. Whether this file grows is the whole
# question — the stop's promise is that no reviewer is called.
SPY="$TMP/codex-spy"; cat > "$SPY" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
echo ran >> "$SPY_MARK"
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$SPY"
export SPY_MARK="$TMP/spy"

BR=$(git -C "$R" branch --show-current)
BASE=$(git -C "$R" rev-parse --short=12 HEAD)

# Build a stored round the way the gate would: 3 rounds, one file, growing.
seed_round(){ # $1 = code lines, $2… = file paths of that round
  local ch="$1"; shift
  local nf; nf=$(mktemp); printf '%s\n' "$@" > "$nf"
  # the REAL staged diff, not a placeholder: the carry check compares added
  # lines, so a one-line dummy would make every attempt look newly written
  local df; df=$(mktemp)
  git -C "$R" diff --cached --unified=3 > "$df" 2>/dev/null
  [ -s "$df" ] || printf '+const x = 1;\n' > "$df"
  printf '{"blocking":[{"id":"B1","claim":"c","why":"w","fix":"f","quote":"q"}]}' \
    | bash "$KRE" record --repo "$(basename "$R")" --branch "$BR" --base "$BASE" \
        --changed "$ch" --result codex-block --diff "$df" --names "$nf" >/dev/null 2>&1
  rm -f "$nf" "$df"
}
run_gate(){ # stdin-less helper: returns the hook's exit code, stderr in $ERR
  ERR=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
        | CODEX_BIN="$SPY" bash "$HOOK" 2>&1 >/dev/null); return $?
}
reset_spy(){ : > "$SPY_MARK"; }
# grep -c exits 1 on zero matches; wc always answers with one number
spy_count(){ wc -l < "$SPY_MARK" 2>/dev/null | tr -d " "; }

# ── A. the plain spiral still stops ────────────────────────────────────────
printf 'export const a=1;\n%s\n' "$(seq 1 200 | sed 's/^/export const n/;s/$/=1;/')" > "$R/src/a.ts"
git -C "$R" add src/a.ts >/dev/null 2>&1
seed_round 60 src/a.ts; seed_round 90 src/a.ts; seed_round 120 src/a.ts
reset_spy; run_gate; RC=$?
ok "$RC" "2" "A round 4, bigger, same file → still stopped"
ok "$(spy_count)" "0" "A no reviewer was called"
case "$ERR" in *BAUFORM*) P=$((P+1));; *) F=$((F+1)); echo "FAIL A asks the form question";; esac
ok "$(jq -r '.result' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" "kreisel-stop" "A recorded in the ledger"

# ── B. the stop counts itself ──────────────────────────────────────────────
# Without this the counter froze: every later attempt was round 4 again, so no
# amount of rework could earn a review back — only the clock or a bypass.
ROUND_AFTER=$(bash "$KRE" state --repo "$(basename "$R")" --branch "$BR" --base "$BASE" | jq -r .round)
ok "$ROUND_AFTER" "5" "B the stop was stored as a round, the counter moved on"

# ── C. smaller is a way out ────────────────────────────────────────────────
# The round-3 message demands "make the fix smaller". Doing it must be rewarded
# with a review, not with the same wall.
git -C "$R" reset -q
printf 'export const a=1;\nexport const b=2;\n' > "$R/src/a.ts"
git -C "$R" add src/a.ts >/dev/null 2>&1
reset_spy; run_gate; RC=$?
ok "$(spy_count)" "1" "C shrunk diff → the reviewer runs"
case "$ERR" in *"kleiner geworden"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL C says why the brake let go: $ERR";; esac

# ── D. a docs-only commit is never a spiral ────────────────────────────────
# Splitting the work into a docs-first commit is the move the stop wants to
# encourage; the old brake refused it, with zero code lines to spiral on.
seed_round 200 src/a.ts; seed_round 260 src/a.ts; seed_round 320 src/a.ts
git -C "$R" reset -q
printf '# notes\nsome prose\n' > "$R/NOTES.md"
git -C "$R" add NOTES.md >/dev/null 2>&1
reset_spy; run_gate; RC=$?
ok "$RC" "0" "D docs-only passes"
case "$ERR" in *"nur Doku"*|*"") P=$((P+1));; *) F=$((F+1)); echo "FAIL D docs reason: $ERR";; esac

# ── E. a rewrite reaches for other files ───────────────────────────────────
# The old reset needed ZERO files in common, which never happens when you
# rebuild the same function. Majority-new is the honest line.
git -C "$R" reset -q; rm -f "$R/NOTES.md"
# 2 lines, so the real diff below is BIGGER — otherwise the shrink rule answers
# first and this case never reaches the rewrite check
seed_round 2 src/a.ts src/b.ts src/f.ts src/g.ts
# 1 of 4 previous files still touched, three are new → a rewrite, not a patch
printf 'export const a=2;\n' > "$R/src/a.ts"
printf 'export const c=1;\n' > "$R/src/c.ts"
printf 'export const d=1;\n' > "$R/src/d.ts"
printf 'export const e=1;\n' > "$R/src/e.ts"
git -C "$R" add src/a.ts src/c.ts src/d.ts src/e.ts >/dev/null 2>&1
reset_spy; run_gate; RC=$?
ok "$(spy_count)" "1" "E different files → the reviewer runs"
case "$ERR" in *"Bauform gewechselt"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL E names the rewrite: $ERR";; esac

# ── F. the second switch lifts the brake and still reviews ─────────────────
# The old message offered "or have it reviewed anyway" and named the override,
# which exits the hook — nobody reviewed anything. Text and behaviour now agree.
git -C "$R" reset -q; rm -f "$R/src/c.ts" "$R/src/d.ts" "$R/src/e.ts"
seed_round 20 src/a.ts; seed_round 30 src/a.ts; seed_round 40 src/a.ts
printf 'export const a=1;\n%s\n' "$(seq 1 100 | sed 's/^/export const m/;s/$/=1;/')" > "$R/src/a.ts"
git -C "$R" add src/a.ts >/dev/null 2>&1
touch "$R/.claude/session-flags/s1-kreisel-override"
reset_spy; run_gate; RC=$?
ok "$(spy_count)" "1" "F kreisel-override → the reviewer DOES run"
ok "$([ -f "$R/.claude/session-flags/s1-kreisel-override" ] && echo yes || echo no)" "no" \
   "F the switch is single-use, consumed"

# ── G. the two switches stay different ─────────────────────────────────────
# The stop names both, and the difference is the whole point: one lifts the
# brake and keeps every reviewer, the other skips the review entirely. A test
# for only the new one would let them drift back together (prechecker B3).
git -C "$R" reset -q
seed_round 20 src/a.ts; seed_round 30 src/a.ts; seed_round 40 src/a.ts
printf 'export const a=1;\n%s\n' "$(seq 1 100 | sed 's/^/export const p/;s/$/=1;/')" > "$R/src/a.ts"
git -C "$R" add src/a.ts >/dev/null 2>&1
touch "$R/.claude/session-flags/s1-veto-gate-override"
reset_spy; run_gate; RC=$?
ok "$RC" "0" "G the plain override still passes the commit"
ok "$(spy_count)" "0" "G …and skips the review entirely — that is the difference"

# ── H. resubmitting the same size unchanged is not converging ──────────────
# "smaller" has to mean strictly smaller. Equal would let the identical change
# buy a fresh review on every attempt — the one move the brake exists to stop.
git -C "$R" reset -q
rm -f "$R/.claude/session-flags/s1-veto-gate-override" "$R/.claude/session-flags/s1-kreisel-override"
printf 'export const a=1;\nexport const b=2;\nexport const c=3;\n' > "$R/src/h.ts"
git -C "$R" add src/h.ts >/dev/null 2>&1
SAME=$(bash "$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/diff-size.sh" \
        --diff <(git -C "$R" diff --cached --unified=3) 2>/dev/null)
seed_round "$SAME" src/h.ts; seed_round "$SAME" src/h.ts; seed_round "$SAME" src/h.ts
reset_spy; run_gate; RC=$?
ok "$RC" "2" "H same size, same file → still stopped"
ok "$(spy_count)" "0" "H no reviewer bought with an unchanged resubmit"

# ── I. narrowing a wide patch is not a rewrite ─────────────────────────────
# Ten files last round and one of them now is the SAME patch, narrowed. Measured
# against the previous list that cleared the threshold easily; the share has to
# be taken from the current attempt (codex R07).
git -C "$R" reset -q
# five lines, so the diff GROWS past the seeded rounds — otherwise the shrink
# rule answers first and the file check never runs
printf 'export const w1=1;\nexport const w2=2;\nexport const w3=3;\nexport const w4=4;\nexport const w5=5;\n' > "$R/src/w.ts"
git -C "$R" add src/w.ts >/dev/null 2>&1
seed_round 1 src/w.ts src/x1.ts src/x2.ts src/x3.ts src/x4.ts src/x5.ts
seed_round 2 src/w.ts src/x1.ts src/x2.ts src/x3.ts src/x4.ts src/x5.ts
seed_round 3 src/w.ts src/x1.ts src/x2.ts src/x3.ts src/x4.ts src/x5.ts
reset_spy; run_gate; RC=$?
ok "$RC" "2" "I one of six files, bigger → still the same patch, stopped"
ok "$(spy_count)" "0" "I no reviewer for a narrowed patch"

# ── J. a rewrite inside ONE file at the same size ──────────────────────────
# Names and line counts are blind to this: same file, same length, completely
# different content. Only the stored diff can tell (codex BRK-02).
git -C "$R" reset -q
JD=$(mktemp)
{ echo "+++ b/src/j.ts"; for i in 1 2 3 4 5 6; do echo "+export const old$i = 'aaaaaaaa';"; done; } > "$JD"
JN=$(mktemp); echo "src/j.ts" > "$JN"
for c in 6 7 8; do
  printf '{"blocking":[{"id":"B1","claim":"c","why":"w","fix":"f","quote":"q"}]}' \
    | bash "$KRE" record --repo "$(basename "$R")" --branch "$BR" --base "$BASE" \
        --changed "$c" --result codex-block --diff "$JD" --names "$JN" >/dev/null 2>&1
done
# same file, MORE lines than round 3 (so the shrink rule cannot answer), but
# every line is new content
{ for i in 1 2 3 4 5 6 7 8 9; do echo "export const fresh$i = 'zzzzzzzz';"; done; } > "$R/src/j.ts"
git -C "$R" add src/j.ts >/dev/null 2>&1
reset_spy; run_gate; RC=$?
ok "$(spy_count)" "1" "J rewritten content in the same file → the reviewer runs"
case "$ERR" in *"Inhalt neu geschrieben"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL J names the rewrite: $ERR";; esac
rm -f "$JD" "$JN"

echo "kreisel-stop: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

#!/usr/bin/env bash
# End to end: a correction sequence comes to an end on its own.
#
# Measured 2026-09-28: after a first reviewer block, 151 of 187 sequences ended in an
# override — every round judged the diff cold and found something new at lines that
# already stood in round 1. These tests drive the real gate through rounds with a
# scripted reviewer and pin the round table of converge.sh as the gate applies it,
# plus the one channel Claude hears on a pass: additionalContext on stdout.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"
unset DISCORD_VETO_WEBHOOK
HOOK="$(cd "$(dirname "$0")/.." && pwd)/veto-gate.sh"
export VETO_GATE_LOG_DIR="$(mktemp -d)"
export VETO_GATE_TIMEOUT=5
export VETO_GATE_HERMES_BIN="/nonexistent/hermes"
TMP=$(mktemp -d); trap 'rm -rf "$TMP" "$VETO_GATE_LOG_DIR" "$VETO_HB_DIR"' EXIT
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }

R="$TMP/repo"; mkdir -p "$R/src" "$R/e2e/testbau-repo" "$R/.claude/config" "$R/.claude/session-flags"
git -C "$R" init -q
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf '{"enabled":true,"effort":"high","max_lines":4000,"prechecker":"none"}\n' > "$R/.claude/config/veto-gate.json"
printf 'export const seed = 1;\n' > "$R/src/a.ts"
printf 'export const h = 1;\n' > "$R/e2e/testbau-repo/h.mjs"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm base >/dev/null 2>&1
BASEREF=$(git -C "$R" rev-parse HEAD)

# scripted reviewer: answers with the verdict in $MOCK_V, keeps the prompt it was given
MOCK="$TMP/codex"; cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
OUT=""; DIR=""
while [ $# -gt 0 ]; do case "$1" in -o) OUT="$2"; shift 2;; -C) DIR="$2"; shift 2;; *) shift;; esac; done
cat > /dev/null
cp "$DIR/REVIEW_PROMPT.md" "$MOCK_PROMPT" 2>/dev/null
cp "$MOCK_V" "$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$MOCK"
export MOCK_V="$TMP/v.json" MOCK_PROMPT="$TMP/prompt"

say(){ # $1 = id, $2 = art, $3 = quote  → a one-finding verdict
  jq -cn --arg id "$1" --arg a "$2" --arg q "$3" \
    '{blocking:[{id:$id,art:$a,claim:"claim \($id)",why:"w",fix:"fix \($id)",quote:$q}],non_blocking:[],questions:[],context_requests:[],unverified_claims:[]}' > "$MOCK_V"; }
run(){ # → exit code; stdout in $TMP/out, stderr in $TMP/err
  printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
    | CODEX_BIN="$MOCK" bash "$HOOK" >"$TMP/out" 2>"$TMP/err"; echo $?; }
branch(){ git -C "$R" checkout -q -B "$1" "$BASEREF"; git -C "$R" reset -q --hard; }
ctx(){ jq -r '.hookSpecificOutput.additionalContext // empty' "$TMP/out" 2>/dev/null; }
last(){ tail -1 "$VETO_GATE_LOG_DIR/runs.jsonl" | jq -r "$1"; }

# K1/K2: round 1 blocks; round 2's NEW finding at a line round 1 already had passes
branch k1
printf 'export const seed = 1;\nexport const alpha = readAll();\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts
say B1 fehler 'export const alpha = readAll();'
ok "$(run)" "2" "K1 round 1: a plain finding blocks"
ok "$(grep -c 'VOLLE RUNDE' "$MOCK_PROMPT")" "1" "K1b round 1 is told it is the full round"
printf 'export const seed = 1;\nexport const alpha = readAll() ?? [];\nexport const beta = 2;\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts
say B2 fehler 'export const seed = 1;'
ok "$(run)" "0" "K2 round 2: a new finding at an OLD line no longer blocks"
ok "$(grep -c 'Ab jetzt blockt nur noch' "$MOCK_PROMPT")" "1" "K2b round 2 is told the rule"
ok "$(ctx | grep -c '\[B2\]')" "1" "K2c the rest reaches Claude via additionalContext"
ok "$(last '.verdict.demoted | length')" "1" "K2d the ledger keeps the demoted finding"
ok "$(last .result)" "codex-pass" "K2e …as a pass"

# K3: round 2 finding in a line the FIX wrote → still blocks
branch k3
printf 'export const seed = 1;\nexport const alpha = readAll();\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts
say B1 fehler 'export const alpha = readAll();'; run >/dev/null
printf 'export const seed = 1;\nexport const alpha = readAll();\nif (!alpha) throw new Error("leer");\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts
say B2 fehler 'if (!alpha) throw new Error("leer");'
ok "$(run)" "2" "K3 round 2: a bug in the fix's own line blocks"
ok "$(ctx)" "" "K3b a block sends no pass context"

# K4: round 3 — only hard kinds block
branch k4
printf 'export const seed = 1;\nexport const a1 = one();\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts
say B1 fehler 'export const a1 = one();'; run >/dev/null
printf 'export const seed = 1;\nexport const a1 = one();\nexport const a2 = two();\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts
say B2 fehler 'export const a2 = two();'; ok "$(run)" "2" "K4 round 2 fix-line block (setup)"
printf 'export const seed = 1;\nexport const a1 = one();\nexport const a2 = two();\nexport const a3 = three();\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts
say B3 fehler 'export const a3 = three();'
ok "$(run)" "0" "K4b round 3: a plain finding, even in a fix line, no longer blocks"
say B4 sicherheit 'export const seed = 1;'
ok "$(run)" "2" "K4c round 3: security still blocks, at any line"

# K5: role werkzeug — only hard kinds, from round 1 on
branch k5
printf 'export const h = 1;\nexport const probe = () => 1;\n' > "$R/e2e/testbau-repo/h.mjs"; git -C "$R" add e2e/testbau-repo/h.mjs
say W1 fehler 'export const probe = () => 1;'
ok "$(run)" "0" "K5 werkzeug round 1: a plain finding does not block"
ok "$(grep -c 'WERKZEUG:' "$MOCK_PROMPT")" "1" "K5b the reviewer is told the role"
say W2 falsch-gruen 'export const probe = () => 1;'
ok "$(run)" "2" "K5c werkzeug: false green still blocks"

# K6: false red never blocks, even in product code round 1
branch k6
printf 'export const seed = 1;\nexport const strict = check();\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts
say FR falsch-rot 'export const strict = check();'
ok "$(run)" "0" "K6 false red does not block"
ok "$(ctx | grep -c 'falsch-rot')" "1" "K6b …and is named to Claude"

echo "konvergenz: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

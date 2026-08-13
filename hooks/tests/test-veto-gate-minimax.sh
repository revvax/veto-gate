#!/usr/bin/env bash
# minimax-diff-review.sh — pre-reviewer via MiniMax-M3 through the hermes CLI.
# hermes is mocked (VETO_GATE_HERMES_BIN seam); no paid call is ever made here.
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/minimax-diff-review.sh"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1' want '$2')"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
D="$TMP/d.patch"; printf '+++ b/src/a.ts\n+const x = 1;\n' > "$D"

mock(){ # $1 = what the fake hermes prints
  printf '#!/usr/bin/env bash\nprintf %s "$1"\n' "'$1'" > "$TMP/hermes"
  chmod +x "$TMP/hermes"
}
# the mock above ignores its args; this one records them instead
cat > "$TMP/hermes-rec" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SEEN_ARGS"
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
EOF
chmod +x "$TMP/hermes-rec"

# T1: a clean verdict passes through
mock '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
OUT=$(VETO_GATE_HERMES_BIN="$TMP/hermes" bash "$S" --diff "$D"); RC=$?
ok "$RC" "0" "T1 clean rc=0"
ok "$(printf '%s' "$OUT" | jq -r '.blocking|length')" "0" "T1 verdict parsed"

# T2: a blocking verdict passes through
mock '{"blocking":[{"id":"M1","claim":"c","why":"w","fix":"f"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
OUT=$(VETO_GATE_HERMES_BIN="$TMP/hermes" bash "$S" --diff "$D"); RC=$?
ok "$RC" "0" "T2 rc=0"
ok "$(printf '%s' "$OUT" | jq -r '.blocking[0].id')" "M1" "T2 finding passed through"

# T3: prose around the JSON is tolerated — the object is cut out
mock 'Hier mein Urteil: {"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]} Ende.'
OUT=$(VETO_GATE_HERMES_BIN="$TMP/hermes" bash "$S" --diff "$D"); RC=$?
ok "$RC" "0" "T3 wrapped JSON still parses"

# T4: garbage → 3 (infra), so the caller falls open to codex, never a block
mock 'ich bin kein json'
VETO_GATE_HERMES_BIN="$TMP/hermes" bash "$S" --diff "$D" >/dev/null 2>&1; ok "$?" "3" "T4 garbage → 3"

# T5: a claimless finding is garbage too — shape alone must not block
mock '{"blocking":[{"id":"M1"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
VETO_GATE_HERMES_BIN="$TMP/hermes" bash "$S" --diff "$D" >/dev/null 2>&1; ok "$?" "3" "T5 claimless finding → 3"

# T6: hermes missing → 3, never a silent pass
VETO_GATE_HERMES_BIN="$TMP/gibtsnicht" bash "$S" --diff "$D" >/dev/null 2>&1; ok "$?" "3" "T6 no hermes → 3"

# T7: oversized diff → 4 (skip this stage, go straight to codex)
BIG="$TMP/big.patch"; head -c 70000 /dev/zero | tr '\0' 'x' > "$BIG"
VETO_GATE_MINIMAX_MAXBYTES=60000 VETO_GATE_HERMES_BIN="$TMP/hermes" bash "$S" --diff "$BIG" >/dev/null 2>&1
ok "$?" "4" "T7 too big → 4"

# T8: the call really asks for MiniMax-M3 via the oauth provider, and the prompt
# carries both the rules and the diff
export SEEN_ARGS="$TMP/args"
VETO_GATE_HERMES_BIN="$TMP/hermes-rec" bash "$S" --diff "$D" >/dev/null 2>&1
ok "$(grep -c '^MiniMax-M3$' "$SEEN_ARGS")" "1" "T8 model is MiniMax-M3"
ok "$(grep -c '^minimax-oauth$' "$SEEN_ARGS")" "1" "T8b provider is minimax-oauth"
ok "$(grep -c 'BESCHREIBT' "$SEEN_ARGS")" "1" "T8c prompt separates describing from causing"
ok "$(grep -c 'const x = 1;' "$SEEN_ARGS")" "1" "T8d the diff itself travels"
unset SEEN_ARGS

# T9: no credential may live in the script — hermes holds it, we never do.
# Comments are stripped first: the file EXPLAINS the rule, and the explanation
# must not read as a violation of it.
# The check targets ASSIGNMENTS, not the word: the review prompt legitimately
# tells the model to look for secrets, and that sentence is not a credential.
CODE=$(grep -vE '^[[:space:]]*#' "$S")
ok "$(printf '%s' "$CODE" | grep -ciE '^[[:space:]]*[A-Za-z_]*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)[A-Za-z_]*=')" \
   "0" "T9 nothing credential-shaped is assigned"
# …and nothing is read from a secrets file either
ok "$(printf '%s' "$CODE" | grep -ciE 'secrets\.env|Authorization|-H .*[Bb]earer')" "0" "T9b no secret is read or sent"

echo "minimax-review: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

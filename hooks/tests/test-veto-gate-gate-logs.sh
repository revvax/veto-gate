#!/usr/bin/env bash
# Gate → runs.jsonl logging: results, verdict/violations payloads, running marker.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
# Never post test findings to the real Discord: the gate calls notify_discord
# on every block, and these fixtures would land on the owner's phone as garbage.
unset DISCORD_VETO_WEBHOOK
HOOK="$(cd "$(dirname "$0")/.." && pwd)/veto-gate.sh"
export VETO_GATE_LOG_DIR="$(mktemp -d)"
export VETO_GATE_TIMEOUT=5
R=$(mktemp -d); TMP=$(mktemp -d); trap 'rm -rf "$R" "$TMP" "$VETO_GATE_LOG_DIR"' EXIT
P=0; F=0; ok(){ [ "$1" = "$2" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL $3: '$1'≠'$2'"; }; }
mkdir -p "$R/src" "$R/.claude/config"; git -C "$R" init -q
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf '{"enabled":true}' > "$R/.claude/config/veto-gate.json"
printf 'export const b=1;\n' > "$R/src/b.ts"
RUNS="$VETO_GATE_LOG_DIR/runs.jsonl"

# mock codex: blocking verdict; also snapshots the running marker mid-review
MOCK_BLOCK="$TMP/codex-block"; cat > "$MOCK_BLOCK" <<EOF
#!/usr/bin/env bash
OUT=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && { OUT="\$2"; shift 2; continue; }; shift; done
cat > /dev/null
ls "\$VETO_GATE_LOG_DIR/running" 2>/dev/null | wc -l | tr -d ' ' > "$TMP/marker_count"
cat "\$VETO_GATE_LOG_DIR"/running/gate-*.json 2>/dev/null | jq -r .stage > "$TMP/marker_stage"
printf '{"blocking":[{"id":"B1","claim":"c","why":"w","fix":"f"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "\$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$MOCK_BLOCK"

# 1) grounding-block → violations persisted
printf "import { ghost } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s"}' "$R" \
  | bash "$HOOK" >/dev/null 2>&1
ok "$(tail -1 "$RUNS" | jq -r .result)" "grounding-block" "grounding logged"
ok "$(tail -1 "$RUNS" | jq -r '.violations | length')" "1" "violations persisted"

# 2) codex-block → verdict persisted; marker present with stage=codex mid-run
printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s"}' "$R" \
  | CODEX_BIN="$MOCK_BLOCK" bash "$HOOK" >/dev/null 2>&1
ok "$(tail -1 "$RUNS" | jq -r .result)" "codex-block" "codex block logged"
ok "$(tail -1 "$RUNS" | jq -r '.verdict.blocking[0].id')" "B1" "verdict persisted"
ok "$(tr -d ' ' < "$TMP/marker_count" 2>/dev/null)" "1" "marker present during review"
ok "$(cat "$TMP/marker_stage" 2>/dev/null)" "codex" "stage=codex during review"

# 3) marker cleaned after gate exit
ok "$(ls "$VETO_GATE_LOG_DIR/running" 2>/dev/null | wc -l | tr -d ' ')" "0" "running marker cleaned"

echo "gate-logs: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

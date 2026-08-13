#!/usr/bin/env bash
# Timeout+retry for codex-diff-review.sh: each attempt capped at VETO_GATE_TIMEOUT,
# killed + retried once; both-fail → exit 3.
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/codex-diff-review.sh"
B=$(mktemp -d); CNT=$(mktemp); MOCK=$(mktemp); MOCK2=$(mktemp)
trap 'rm -rf "$B" "$CNT" "$MOCK" "$MOCK2"' EXIT
echo "prompt" > "$B/REVIEW_PROMPT.md"
export VETO_GATE_TIMEOUT=1
P=0; F=0

# Mock A: 1st call sleeps (→timeout kill), 2nd call returns clean → retry succeeds
cat > "$MOCK" <<EOF
#!/usr/bin/env bash
OUT=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && { OUT="\$2"; shift 2; continue; }; shift; done
cat > /dev/null
N=\$(cat "$CNT" 2>/dev/null || echo 0); echo \$((N+1)) > "$CNT"
if [ "\$N" -eq 0 ]; then sleep 4; exit 0; fi
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}' > "\$OUT"
echo '{"type":"thread.started","thread_id":"t"}'
EOF
chmod +x "$MOCK"
T0=$(date +%s)
OUT=$(CODEX_BIN="$MOCK" bash "$S" --bundle "$B" --effort high 2>/dev/null); RC=$?
D=$(( $(date +%s) - T0 ))
[ "$RC" = "0" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL A rc=$RC (want 0)"; }
echo "$OUT" | jq -e 'has("blocking")' >/dev/null 2>&1 && P=$((P+1)) || { F=$((F+1)); echo "FAIL A no verdict"; }
[ "$D" -lt 4 ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL A took ${D}s (timeout didn't kill?)"; }

# Mock B: always sleeps → both attempts time out → exit 3
cat > "$MOCK2" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null; sleep 4; exit 0
EOF
chmod +x "$MOCK2"
T0=$(date +%s)
CODEX_BIN="$MOCK2" bash "$S" --bundle "$B" --effort high >/dev/null 2>&1; RC=$?
D=$(( $(date +%s) - T0 ))
[ "$RC" = "3" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL B rc=$RC (want 3)"; }
[ "$D" -lt 4 ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL B took ${D}s (2x1s cap expected)"; }

# Mock C (F20): codex reports a FINAL error (quota/auth) then hangs — the
# review must fail FAST (not wait out the cap), surface the message on
# stderr, and must NOT retry (the error will not heal in attempt 2)
MOCK3=$(mktemp); CNT2=$(mktemp)
cat > "$MOCK3" <<EOF
#!/usr/bin/env bash
cat > /dev/null
N=\$(cat "$CNT2" 2>/dev/null || echo 0); echo \$((N+1)) > "$CNT2"
echo '{"type":"thread.started","thread_id":"t"}'
echo '{"type":"error","message":"You have hit your usage limit"}'
sleep 8
EOF
chmod +x "$MOCK3"
T0=$(date +%s)
ERR=$(VETO_GATE_TIMEOUT=10 CODEX_BIN="$MOCK3" bash "$S" --bundle "$B" --effort high 2>&1 >/dev/null); RC=$?
D=$(( $(date +%s) - T0 ))
rm -f "$MOCK3"
[ "$RC" = "3" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL C rc=$RC (want 3)"; }
[ "$D" -lt 8 ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL C took ${D}s (fail-fast expected)"; }
case "$ERR" in *"usage limit"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL C message not surfaced: $ERR";; esac
[ "$(cat "$CNT2")" = "1" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL C retried on final error ($(cat "$CNT2") attempts)"; }
rm -f "$CNT2"

# Mock D (B7): quota error WITH reset time → quota.json written, future epoch
MOCK4=$(mktemp); QDIR=$(mktemp -d)
cat > "$MOCK4" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo '{"type":"thread.started","thread_id":"t"}'
echo '{"type":"error","message":"You have hit your usage limit. try again at 5:28 PM"}'
exit 1
EOF
chmod +x "$MOCK4"
VETO_GATE_LOG_DIR="$QDIR" VETO_GATE_TIMEOUT=10 CODEX_BIN="$MOCK4" bash "$S" --bundle "$B" --effort high >/dev/null 2>&1
[ -f "$QDIR/quota.json" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL D quota.json missing"; }
RE=$(jq -r '.reset_epoch' "$QDIR/quota.json" 2>/dev/null)
NOW=$(date +%s)
[ -n "$RE" ] && [ "$RE" != "null" ] && [ "$RE" -gt "$NOW" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL D epoch not future ($RE)"; }
[ -n "$(jq -r '.reset_at' "$QDIR/quota.json" 2>/dev/null)" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL D reset_at missing"; }
ls "$QDIR"/quota.json.tmp.* >/dev/null 2>&1 && { F=$((F+1)); echo "FAIL D tmp file left behind"; } || P=$((P+1))
rm -f "$MOCK4"

# Mock D2 (B7): relative form 'try again in 2 hours 30 minutes'
MOCK4b=$(mktemp)
cat > "$MOCK4b" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo '{"type":"thread.started","thread_id":"t"}'
echo '{"type":"error","message":"usage limit reached, try again in 2 hours 30 minutes"}'
exit 1
EOF
chmod +x "$MOCK4b"
rm -f "$QDIR/quota.json"
VETO_GATE_LOG_DIR="$QDIR" VETO_GATE_TIMEOUT=10 CODEX_BIN="$MOCK4b" bash "$S" --bundle "$B" --effort high >/dev/null 2>&1
RE=$(jq -r '.reset_epoch' "$QDIR/quota.json" 2>/dev/null); NOW=$(date +%s)
[ -n "$RE" ] && [ "$RE" != "null" ] && [ "$RE" -gt $((NOW + 8000)) ] && [ "$RE" -lt $((NOW + 9600)) ] \
  && P=$((P+1)) || { F=$((F+1)); echo "FAIL D2 relative epoch wrong ($RE vs now $NOW)"; }
rm -f "$MOCK4b"

# Mock E (B7): quota error WITHOUT parseable time → NO quota.json
MOCK5=$(mktemp)
cat > "$MOCK5" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo '{"type":"thread.started","thread_id":"t"}'
echo '{"type":"error","message":"You have hit your usage limit."}'
exit 1
EOF
chmod +x "$MOCK5"
rm -f "$QDIR/quota.json"
VETO_GATE_LOG_DIR="$QDIR" VETO_GATE_TIMEOUT=10 CODEX_BIN="$MOCK5" bash "$S" --bundle "$B" --effort high >/dev/null 2>&1
[ ! -f "$QDIR/quota.json" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL E quota.json written without time"; }
rm -f "$MOCK5"

# Mock F (B7): SUCCESS clears a stale quota.json (window is open again)
printf '{"reset_epoch":1,"reset_at":"00:00","msg":"stale","ts":"x"}' > "$QDIR/quota.json"
CNT3=$(mktemp); MOCK6=$(mktemp)
cat > "$MOCK6" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}' > "$OUT"
echo '{"type":"thread.started","thread_id":"t"}'
EOF
chmod +x "$MOCK6"
VETO_GATE_LOG_DIR="$QDIR" VETO_GATE_TIMEOUT=10 CODEX_BIN="$MOCK6" bash "$S" --bundle "$B" --effort high >/dev/null 2>&1
[ ! -f "$QDIR/quota.json" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL F stale quota not cleared"; }
rm -f "$MOCK6" "$CNT3"; rm -rf "$QDIR"

echo "timeout-retry: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

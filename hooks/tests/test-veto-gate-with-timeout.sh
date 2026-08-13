#!/usr/bin/env bash
set -uo pipefail
P=0; F=0; ok(){ case "$1" in *"$2"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL $3: got '$1'";; esac; }
LIB="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)"

# A real cap: a command that runs longer than the cap must be killed, with
# rc >= 124 (the value every real caller in run-tests.sh already checks for).
T0=$(date +%s)
( . "$LIB/with-timeout.sh"; with_timeout 1 sleep 5 ) >/dev/null 2>&1
RC=$?
T1=$(date +%s)
ok "$([ "$RC" -ge 124 ] && echo ja || echo nein)" "ja" "capped command exits >=124"
ok "$([ $((T1-T0)) -le 3 ] && echo ja || echo nein)" "ja" "capped command returns near the cap, not after the full sleep"
# LOWER bound too: a broken/missing with_timeout (e.g. "command not found", rc 127)
# would ALSO satisfy ">=124" and "<=3s" by failing instantly — only a genuine cap
# actually waits out ~the requested second before killing the child.
ok "$([ $((T1-T0)) -ge 1 ] && echo ja || echo nein)" "ja" "capped command actually ran for ~the cap, not an instant unrelated failure"

# A command that finishes well within the cap must pass its OWN exit code through untouched.
# Exact-match (not the shared ok()'s substring match): "7" is a substring of 127
# ("command not found" from an undefined with_timeout), which would have made
# this assertion a false pass against a completely missing implementation.
( . "$LIB/with-timeout.sh"; with_timeout 5 bash -c 'exit 7' ) >/dev/null 2>&1
ok "$([ "$?" = "7" ] && echo ja || echo nein)" "ja" "uncapped command's own exit code passes through exactly"

# Preference: when a `timeout`-named binary is on PATH, with_timeout must call THAT,
# not fall straight to perl. A fake `timeout` stub proves which branch actually ran —
# and records its argv, because the NEXT assert needs to see the kill-escalation flag.
STUB=$(mktemp -d)
cat > "$STUB/timeout" <<'EOF'
#!/usr/bin/env bash
echo "FAKE_TIMEOUT_CALLED $*" >> "$STUB_MARKER"
while [ "${1:-}" = "-k" ]; do shift 2; done
shift
exec "$@"
EOF
chmod +x "$STUB/timeout"
MARKER=$(mktemp)
( export PATH="$STUB:$PATH" STUB_MARKER="$MARKER"
  . "$LIB/with-timeout.sh"; with_timeout 5 bash -c 'exit 0' ) >/dev/null 2>&1
ok "$(cat "$MARKER" 2>/dev/null)" "FAKE_TIMEOUT_CALLED" "prefers a real 'timeout' binary when present on PATH"
# GNU timeout's first move is a polite SIGTERM; a child that ignores TERM would then
# run forever. The -k flag arms the follow-up SIGKILL — its absence is a real hang
# risk on Linux, so its presence in the argv is asserted, not assumed.
ok "$(cat "$MARKER" 2>/dev/null)" "-k " "passes a kill-after escalation flag to the timeout binary"
rm -rf "$STUB" "$MARKER"

# Behavior, backend-independent: a child that ignores the polite stop signal must
# STILL die within cap + grace. The perl backend kills via SIGALRM (untrapped here),
# GNU timeout only passes with the -k escalation above — a missing -k means this
# child sleeps out its full 15s and the elapsed-time assert fails.
T0=$(date +%s)
( . "$LIB/with-timeout.sh"; with_timeout 1 bash -c 'trap "" TERM; sleep 15' ) >/dev/null 2>&1
RC=$?
T1=$(date +%s)
ok "$([ "$RC" -ge 124 ] && echo ja || echo nein)" "ja" "TERM-ignoring child still exits >=124"
ok "$([ $((T1-T0)) -le 10 ] && echo ja || echo nein)" "ja" "TERM-ignoring child dies within cap+grace, not after the full sleep"

echo "with-timeout: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

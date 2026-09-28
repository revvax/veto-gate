#!/usr/bin/env bash
# The size limit must count what a reviewer has to JUDGE, and lifting it must not
# lift the review.
#
# Measured 2026-09-28: a re-indent of one component was 1081 "code lines" (15 with
# `git diff -w`, on a real product commit), and five of 31 size blocks carried screenshots
# that a `git add x && git commit` read as text, line by line. The only way past was
# the override — which skipped the size check AND every reviewer at once.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"
unset DISCORD_VETO_WEBHOOK
HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS/veto-gate.sh"
PRE="$HOOKS/lib/veto-gate/pre-commit.sh"
export VETO_GATE_LOG_DIR="$(mktemp -d)"
export VETO_GATE_TIMEOUT=5
export VETO_GATE_HERMES_BIN="/nonexistent/hermes"
export VETO_GATE_KREISEL_STOP=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP" "$VETO_GATE_LOG_DIR" "$VETO_HB_DIR"' EXIT
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }

R="$TMP/repo"; mkdir -p "$R/src" "$R/.claude/config" "$R/.claude/session-flags"
git -C "$R" init -q
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf '{"enabled":true,"effort":"high","max_lines":10,"prechecker":"none"}\n' > "$R/.claude/config/veto-gate.json"
: > "$R/src/a.ts"
for i in $(seq 1 40); do printf 'export const a%s = %s;\n' "$i" "$i" >> "$R/src/a.ts"; done
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm base >/dev/null 2>&1

# a spy reviewer: records that it ran and what the bundle's diff held
SPY="$TMP/codex-spy"; cat > "$SPY" <<'EOF'
#!/usr/bin/env bash
OUT=""; DIR=""
while [ $# -gt 0 ]; do case "$1" in -o) OUT="$2"; shift 2;; -C) DIR="$2"; shift 2;; *) shift;; esac; done
cat > /dev/null
echo ran >> "$SPY_MARK"
cp "$DIR/DIFF.patch" "$SPY_DIFF" 2>/dev/null
if [ -n "${SPY_BLOCK:-}" ]; then
  printf '{"blocking":[{"id":"B1","claim":"x","why":"y","fix":"z","quote":""}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
else
  printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
fi
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$SPY"
export SPY_MARK="$TMP/spy" SPY_DIFF="$TMP/spy.diff"

run(){ # $1 = command → exit code; stderr lands in $TMP/err
  printf '{"tool_input":{"command":"%s"},"cwd":"%s","session_id":"s1"}' "$1" "$R" \
    | CODEX_BIN="$SPY" bash "$HOOK" >/dev/null 2>"$TMP/err"; echo $?
}
reset_repo(){ git -C "$R" reset -q --hard; git -C "$R" clean -qfd -e .claude; rm -f "$SPY_MARK" "$SPY_DIFF"; }

# S1: a pure re-indent of 40 lines is far over max_lines 10 — and must not size-block
reset_repo
sed -i '' 's/^/    /' "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(run "git commit -m x")" "0" "S1 re-indent does not size-block"
ok "$(grep -c 'Diff zu groß' "$TMP/err")" "0" "S1b no size message"
ok "$(grep -c ran "$SPY_MARK" 2>/dev/null)" "1" "S1c …and the reviewer still judged it"

# S2: a real 20-line change still blocks, and the message names the size-only switch
reset_repo
for i in $(seq 1 20); do printf 'export const b%s = %s;\n' "$i" "$i" >> "$R/src/a.ts"; done
git -C "$R" add src/a.ts
ok "$(run "git commit -m x")" "2" "S2 real code over the limit still blocks"
ok "$(grep -c 'veto-size-override' "$TMP/err")" "1" "S2b the message offers the size-only switch"
ok "$(grep -c ran "$SPY_MARK" 2>/dev/null || echo 0)" "0" "S2c no reviewer on a size block"

# S3: the size-only switch lifts the limit and the reviewer RUNS — its block holds
touch "$R/.claude/session-flags/s1-veto-size-override"
ok "$(SPY_BLOCK=1 run "git commit -m x")" "2" "S3 size lifted, reviewer finding still blocks"
ok "$(grep -c 'codex fand' "$TMP/err")" "1" "S3b the block is the reviewer's, not the size's"
ok "$([ -f "$R/.claude/session-flags/s1-veto-size-override" ] && echo left || echo used)" "used" "S3c the switch is single use"
ok "$(run "git commit -m x")" "2" "S3d next attempt is size-checked again"
ok "$(grep -c 'Diff zu groß' "$TMP/err")" "1" "S3e …by the size stage"

# S4: a screenshot added in the same command counts 0 lines and ships no bytes
reset_repo
printf 'export const c = 1;\n' >> "$R/src/a.ts"
head -c 20000 /dev/urandom > "$R/shot.png"
ok "$(run "git add src/a.ts shot.png && git commit -m x")" "0" "S4 a binary file does not size-block"
ok "$(grep -c 'Binary files /dev/null and b/shot.png differ' "$SPY_DIFF")" "1" "S4b the bundle names the binary file"
ok "$(grep -c '^+++ b/shot.png' "$SPY_DIFF")" "0" "S4c …and ships no text hunk for it"

# S5: the residual channel (real git pre-commit) subtracts the re-indent too
reset_repo
sed -i '' 's/^/  /' "$R/src/a.ts"; git -C "$R" add src/a.ts
CLEAN="$TMP/clean-verdict"; printf '#!/usr/bin/env bash\necho %s\n' \
  "'{\"blocking\":[],\"non_blocking\":[],\"questions\":[],\"context_requests\":[],\"unverified_claims\":[]}'" > "$CLEAN"
chmod +x "$CLEAN"
git -C "$R" add .claude/config/veto-gate.json >/dev/null 2>&1
( cd "$R" && VETO_GATE_CODEX_BIN="$CLEAN" bash "$PRE" ) 2>"$TMP/perr"; PRC=$?
ok "$PRC" "0" "S5 pre-commit: re-indent passes the size limit"
ok "$(grep -c 'Diff zu groß' "$TMP/perr")" "0" "S5b no size message there either"

echo "size-honest: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

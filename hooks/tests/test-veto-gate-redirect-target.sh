#!/usr/bin/env bash
# A `>` in the command must not decide which repo gets reviewed.
#
# Found live on 2026-07-29 in testbau-repo. The same file, the same bug,
# the same commit message:
#
#   cd <repo> && git add f && git commit -m "…"                → blocked
#   cd <repo> && cat > f <<EOF … EOF; git add f && git commit  → committed
#
# The gate never ran on the second one. Its heartbeat says why: it resolved the
# target to the SESSION directory instead of the repo the commit went to, and
# that directory's gate is off — so it exited 0 in silence. One entry even names
# an unrelated third repo. Writing a file and committing it in one command is
# how most commits in this setup are made, so this was not an edge case.
#
# Fail-OPEN, and that is what makes it severe: gate-rules R01 says a diff no
# reviewer judged is never waved through, and CONVENTIONS promises a block when
# the target cannot be determined. Both were untrue here.
#
# The control case is the point of the file: without the redirect the very same
# command IS gated, so this cannot be explained away as "cd parsing is hard".
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
unset DISCORD_VETO_WEBHOOK
HOOK="$(cd "$(dirname "$0")/.." && pwd)/veto-gate.sh"
export VETO_GATE_LOG_DIR="$(mktemp -d)"
export VETO_GATE_TIMEOUT=5
export VETO_GATE_HERMES_BIN="/nonexistent/hermes"   # never a real paid call
export VETO_GATE_KREISEL_STOP=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP" "$VETO_GATE_LOG_DIR"' EXIT
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1' want '$2')"; fi; }

# the repo the commit really goes to — gated
R="$TMP/repo"; mkdir -p "$R/src" "$R/.claude/config"
git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"
printf 'export const b=1;\n' > "$R/src/b.ts"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm base

# the session sits somewhere else, and that somewhere is NOT gated — exactly the
# situation the live run was in
SESS="$TMP/session"; mkdir -p "$SESS"
git -C "$SESS" init -q

MOCK="$TMP/codex-block"; cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '{"blocking":[{"id":"B1","claim":"kaputt","why":"weil","fix":"fix"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$MOCK"

run(){ # $1 = full shell command as the model would send it
  printf 'x' > "$R/src/a.ts"; git -C "$R" add src/a.ts >/dev/null 2>&1
  jq -nc --arg c "$1" --arg w "$SESS" \
     '{tool_input:{command:$c},cwd:$w,session_id:"s1"}' \
  | CODEX_BIN="$MOCK" bash "$HOOK" >/dev/null 2>&1; echo $?
}

# ---- A: the control. Same target, same commit, no redirect.
ok "$(run "cd $R && git add src/a.ts && git commit -m x")" "2" "A1 a plain chain into a gated repo is reviewed"

# ---- B: the same thing with a file being written first. Every shape below is
# how a file actually gets created in this setup.
ok "$(run "cd $R && printf 'x' > $R/src/c.ts && git add src/a.ts && git commit -m x")" "2" \
   "B1 a redirect before the commit must not disarm the gate"
ok "$(run "$(printf 'cd %s && cat > %s/src/d.ts <<%sEOF%s\nzeile\nEOF\ngit add src/a.ts && git commit -m x' "$R" "$R" "'" "'")")" "2" \
   "B2 a heredoc before the commit must not disarm the gate"
ok "$(run "cd $R && git add src/a.ts > /dev/null && git commit -m x")" "2" \
   "B3 …not even a redirect on the git call itself"

# ---- C: the guarantee behind it. If the target cannot be resolved, the answer
# is a block, never a silent pass — R01, and the reason the two above are bugs.
ok "$(run "cd $R && echo bereit && git add src/a.ts && git commit -m x")" "2" \
   "C1 a foreign command without a redirect was always fine"

echo "veto-gate-redirect-target: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

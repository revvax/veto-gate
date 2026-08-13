#!/usr/bin/env bash
# Regression: veto config lookup must survive a git WORKTREE.
#
# The .claude/config/veto*.json files are gitignored, so a `git worktree add`
# checkout has none. Every veto hook resolved the config from the worktree
# toplevel only, found nothing and exited 0 — silently. A real project shipped 133
# unreviewed commits from its worktrees (2026-07-13) before this surfaced.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
# Never post test findings to the real Discord: the gate calls notify_discord
# on every block, and these fixtures would land on the owner's phone as garbage.
unset DISCORD_VETO_WEBHOOK
HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
export VETO_GATE_LOG_DIR="$(mktemp -d)"    # isolate: never touch the real run log
export VETO_GATE_TIMEOUT=5
export VETO_GATE_QWEN_URL="http://127.0.0.1:4/nix"   # hermetic: no real LM Studio
export VETO_GATE_QWEN_TIMEOUT=2
# physical path: git resolves /var → /private/var on macOS, so the expectations
# below would compare two spellings of the same dir
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP" "$VETO_GATE_LOG_DIR"' EXIT
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }

# main checkout, opted in — config gitignored exactly like the real repos
MAIN="$TMP/main"; mkdir -p "$MAIN/src" "$MAIN/.claude/config"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@t.t; git -C "$MAIN" config user.name t
printf '.claude/config/veto-gate.json\n' > "$MAIN/.gitignore"
printf '{"enabled":true,"effort":"high"}\n' > "$MAIN/.claude/config/veto-gate.json"
printf 'export const a=1;\n' > "$MAIN/src/a.ts"
git -C "$MAIN" add -A >/dev/null 2>&1
git -C "$MAIN" commit -qm init >/dev/null 2>&1

# the worktree the sessions actually work in — no config of its own
WT="$TMP/wt"
git -C "$MAIN" worktree add -q -b feat "$WT" >/dev/null 2>&1
[ -f "$WT/.claude/config/veto-gate.json" ] && { echo "SETUP BROKEN: worktree has a config"; exit 1; }

# ---- A: the lib resolves the main checkout's config from inside the worktree.
# veto_gate_cfg takes NO file name — a caller that cannot name a file cannot
# outlive a rename, which is what kept three hooks dead for eleven days.
# shellcheck source=/dev/null
. "$HOOKS/lib/veto-cfg.sh"
ok "$(veto_gate_cfg "$WT")" "$MAIN/.claude/config/veto-gate.json" "A1 worktree falls back to main config"
ok "$(veto_gate_cfg "$MAIN")" "$MAIN/.claude/config/veto-gate.json" "A2 main checkout resolves itself"
ok "$(veto_gate_cfg "$WT/src")" "$MAIN/.claude/config/veto-gate.json" "A3 subdir of worktree resolves too"
veto_gate_cfg "$TMP" >/dev/null 2>&1; ok "$?" "1" "A4 non-repo dir without config → rc 1"
# a non-repo dir CARRYING a config still resolves — the gate's opt-in check over
# raw -C/cd candidates is path-based and must not require a repo (codex find #20)
mkdir -p "$TMP/plain/.claude/config"; printf '{"enabled":true}\n' > "$TMP/plain/.claude/config/veto-gate.json"
ok "$(veto_gate_cfg "$TMP/plain")" "$TMP/plain/.claude/config/veto-gate.json" "A4b non-repo dir with config → path"
# a worktree config of its OWN still wins (opt-out per worktree stays possible)
mkdir -p "$WT/.claude/config"; printf '{"enabled":false}\n' > "$WT/.claude/config/veto-gate.json"
ok "$(veto_gate_cfg "$WT")" "$WT/.claude/config/veto-gate.json" "A5 worktree's own config wins"
veto_gate_armed "$WT"; ok "$?" "1" "A6 …and its opt-out really disarms"
rm -rf "$WT/.claude/config"
veto_gate_armed "$WT"; ok "$?" "0" "A7 without its own config the worktree is armed again"
# the generic resolver stays available for the OTHER config (answer-style veto.json)
printf '{"enabled":true}\n' > "$MAIN/.claude/config/veto.json"
ok "$(veto_cfg "$WT" veto.json)" "$MAIN/.claude/config/veto.json" "A8 generic lookup still serves veto.json"
rm -f "$MAIN/.claude/config/veto.json"

# ---- B: the commit gate actually fires on a commit made INSIDE the worktree
MOCK_BLOCK="$TMP/codex-block"; cat > "$MOCK_BLOCK" <<'MOCK'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '{"blocking":[{"id":"B1","claim":"drops user table","why":"data loss","fix":"remove"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
MOCK
chmod +x "$MOCK_BLOCK"

printf 'export const b=2;\n' > "$WT/src/b.ts"
git -C "$WT" add -A >/dev/null 2>&1
IN=$(jq -nc --arg cwd "$WT" '{session_id:"wt-test",cwd:$cwd,tool_name:"Bash",tool_input:{command:"git commit -m x"}}')
OUT=$(printf '%s' "$IN" | CODEX_BIN="$MOCK_BLOCK" bash "$HOOKS/veto-gate.sh" 2>&1); RC=$?
ok "$RC" "2" "B1 gate blocks a blocking verdict from inside a worktree"
case "$OUT" in *VETO-GATE*) ok "yes" "yes" "B2 gate printed its verdict";; *) ok "no" "yes" "B2 gate printed its verdict";; esac

# ---- C: the override flag is single-use — one deliberate skip never becomes a
# standing exemption
mkdir -p "$WT/.claude/session-flags"
touch "$WT/.claude/session-flags/wt-test-veto-gate-override"
OUT=$(printf '%s' "$IN" | CODEX_BIN="$MOCK_BLOCK" bash "$HOOKS/veto-gate.sh" 2>&1); RC=$?
ok "$RC" "0" "C1 override lets the commit pass"
[ -f "$WT/.claude/session-flags/wt-test-veto-gate-override" ] && LEFT=yes || LEFT=no
ok "$LEFT" "no" "C2 the flag is consumed by the run it let through"
OUT=$(printf '%s' "$IN" | CODEX_BIN="$MOCK_BLOCK" bash "$HOOKS/veto-gate.sh" 2>&1); RC=$?
ok "$RC" "2" "C3 the next commit blocks again"

# ---- D: a config that is not exactly one JSON object is BROKEN, not "off".
# Two concatenated objects once made a later .enabled read return garbage and
# disarmed an armed gate — so this fails CLOSED and names the file.
printf 'kaputt{' > "$MAIN/.claude/config/veto-gate.json"
veto_gate_armed "$MAIN"; ok "$?" "1" "D1 a broken config is not 'armed'"
OUT=$(printf '%s' "$IN" | CODEX_BIN="$MOCK_BLOCK" bash "$HOOKS/veto-gate.sh" 2>&1); RC=$?
ok "$RC" "2" "D2 …but the gate blocks on it instead of going silently off"
case "$OUT" in *kaputt*) ok yes yes "D3 the message names the broken file";;
  *) ok no yes "D3 the message names the broken file";; esac
printf '{}\n{"enabled":false}\n' > "$MAIN/.claude/config/veto-gate.json"
OUT=$(printf '%s' "$IN" | CODEX_BIN="$MOCK_BLOCK" bash "$HOOKS/veto-gate.sh" 2>&1); RC=$?
ok "$RC" "2" "D4 two concatenated objects count as broken, never as a disarm"
printf '{"enabled":true,"effort":"high"}\n' > "$MAIN/.claude/config/veto-gate.json"

# ---- E: end-to-end — a commit hidden in a substitution with perl unavailable
# must still fail closed
IN2=$(jq -nc --arg cwd "$WT" '{session_id:"wt-test",cwd:$cwd,tool_name:"Bash",tool_input:{command:"eval \"$(git commit -m x)\""}}')
OUT=$(printf '%s' "$IN2" | VETO_GATE_NO_PERL=1 CODEX_BIN="$MOCK_BLOCK" bash "$HOOKS/veto-gate.sh" 2>&1); RC=$?
ok "$RC" "2" "E1 hidden commit without perl still fails closed"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

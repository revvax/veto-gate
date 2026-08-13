#!/usr/bin/env bash
# The residual channel reviews too, not just size+grounding (owner 2026-07-29).
#
# Why it must: a PreToolUse hook reads the working tree from BEFORE the command
# runs, so a change the command CREATES (`cat > f <<EOF`, `for … > f`) is
# invisible to it. Measured live 2026-07-29: the identical 400-line violation
# blocked when the file existed beforehand and produced no log entry at all when
# the command wrote it. At pre-commit time the index is always complete, so this
# is the only place that can see it.
#
# Why doc-only diffs skip the reviewers: the F11 promise is "a background
# committer must never wait minutes". auto-push.sh is the only background
# committer and commits doc-only changes BY CONSTRUCTION (code changes it merely
# reports, gated-only) — so exempting doc-only keeps that promise without a
# silent switch, which plan review F28 rejected.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
LIB="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)"
# hermetic: never a real paid call. The stubs below cover the cases that reach a
# reviewer; these two catch any path that does not, so a future case cannot make
# a real call by omission.
export VETO_GATE_HERMES_BIN=/nonexistent/hermes
export CODEX_BIN=/nonexistent/codex
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got $1, want $2)"; fi; }

TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT

# stub reviewers. Each records that it RAN, so "was not called" is provable
# rather than inferred from a passing commit.
mk_stub(){  # $1 path  $2 exit  $3 stdout
  printf '#!/usr/bin/env bash\necho "ran" >> "%s"\ncat <<'"'"'J'"'"'\n%s\nJ\nexit %s\n' \
    "$TD/called-$(basename "$1")" "$3" "$2" > "$1"
  chmod +x "$1"
}
FOUND='{"blocking":[{"id":"B01","claim":"c","why":"w","fix":"f"}]}'
CLEAN='{"blocking":[]}'

# pack-diff stub: the real one needs a repo bundle; here only its existence and
# the path it prints matter.
PACK="$TD/pack.sh"
printf '#!/usr/bin/env bash\nmkdir -p "%s/bundle"\n: > "%s/bundle/REVIEW_PROMPT.md"\necho "%s/bundle"\n' \
  "$TD" "$TD" "$TD" > "$PACK"; chmod +x "$PACK"

new_repo(){
  local R; R=$(mktemp -d)
  mkdir -p "$R/src" "$R/.claude/config"
  git -C "$R" init -q; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
  printf '{"enabled":true}' > "$R/.claude/config/veto-gate.json"
  printf 'export const dep = 1;\n' > "$R/src/dep.ts"
  git -C "$R" add -A; git -C "$R" commit -qm baseline --no-verify
  echo "$R"
}
inst(){ bash "$LIB/veto-gate-cli.sh" install-precommit "$1" >/dev/null; }
# a commit whose import resolves, so only the review stage can block it
stage_code(){ printf "import { dep } from './dep';\nexport const x%s = %s;\n" "$2" "$2" > "$1/src/c$2.ts"; git -C "$1" add "src/c$2.ts"; }

export VETO_GATE_PACKDIFF_BIN="$PACK"

# T1: reviewer finds something → commit blocked
R=$(new_repo); inst "$R"; stage_code "$R" 1
rm -f "$TD"/called-*
mk_stub "$TD/codex.sh" 0 "$FOUND"
VETO_GATE_CODEX_BIN="$TD/codex.sh" git -C "$R" commit -qm "feat: one" >/dev/null 2>&1
ok "$?" "1" "T1 reviewer finding blocks"

# T2: reviewer clean → commit passes, and it really ran.
# Every case stages its OWN file: sharing one would make a case depend on
# whether the previous case blocked, and "nothing to commit" also exits 1.
rm -f "$TD"/called-*
stage_code "$R" 2
mk_stub "$TD/codex.sh" 0 "$CLEAN"
VETO_GATE_CODEX_BIN="$TD/codex.sh" git -C "$R" commit -qm "feat: two" >/dev/null 2>&1
ok "$?" "0" "T2 clean review passes"
[ -f "$TD/called-codex.sh" ] && P=$((P+1)) || { F=$((F+1)); echo "  FAIL T2b reviewer never ran"; }

# T3: doc-only diff → reviewer NOT called (auto-push must never wait)
rm -f "$TD"/called-*
printf 'a doc line\n' > "$R/README.md"; git -C "$R" add README.md
mk_stub "$TD/codex.sh" 0 "$FOUND"
VETO_GATE_CODEX_BIN="$TD/codex.sh" git -C "$R" commit -qm "docs: note" >/dev/null 2>&1
ok "$?" "0" "T3 doc-only passes"
[ -f "$TD/called-codex.sh" ] && { F=$((F+1)); echo "  FAIL T3b reviewer ran on doc-only"; } || P=$((P+1))

# T4: the local pre-reviewer blocks BEFORE codex — the free filter must spend
# no codex quota (same order as the gate, stage 2.5)
rm -f "$TD"/called-*
stage_code "$R" 4
mk_stub "$TD/pre.sh" 0 "$FOUND"; mk_stub "$TD/codex.sh" 0 "$CLEAN"
printf '{"enabled":true,"prechecker":"minimax"}' > "$R/.claude/config/veto-gate.json"
git -C "$R" add .claude/config/veto-gate.json
VETO_GATE_PRECHECK_BIN="$TD/pre.sh" VETO_GATE_CODEX_BIN="$TD/codex.sh" \
  git -C "$R" commit -qm "feat: four" >/dev/null 2>&1
ok "$?" "1" "T4 pre-reviewer blocks"
[ -f "$TD/called-codex.sh" ] && { F=$((F+1)); echo "  FAIL T4b codex ran despite pre-block"; } || P=$((P+1))

# T5: a dead pre-reviewer must not block — it falls through to codex, exactly
# like the gate. A broken free filter is not a verdict.
rm -f "$TD"/called-*
stage_code "$R" 5
mk_stub "$TD/pre.sh" 3 ""; mk_stub "$TD/codex.sh" 0 "$CLEAN"
VETO_GATE_PRECHECK_BIN="$TD/pre.sh" VETO_GATE_CODEX_BIN="$TD/codex.sh" \
  git -C "$R" commit -qm "feat: five" >/dev/null 2>&1
ok "$?" "0" "T5 dead pre-reviewer falls through"
[ -f "$TD/called-codex.sh" ] && P=$((P+1)) || { F=$((F+1)); echo "  FAIL T5b codex not reached"; }

# T6: codex unreachable (exit 3) → OPEN, like the gate. The gate's own header
# says it fails open on codex infra errors; the residual channel must not be
# stricter than the channel it backs up, or an exhausted quota freezes every
# commit. It must SAY so though — silence is what F11 exists against.
rm -f "$TD"/called-*
stage_code "$R" 6
mk_stub "$TD/codex.sh" 3 ""
OUT=$(VETO_GATE_CODEX_BIN="$TD/codex.sh" git -C "$R" commit -qm "feat: six" 2>&1)
ok "$?" "0" "T6 codex infra error passes"
case "$OUT" in *VETO-GATE*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL T6b failure was silent";; esac

# T7: local infrastructure missing → CLOSED. pack-diff is ours, not a service:
# if it cannot run, nothing was reviewed and the commit must not proceed.
rm -f "$TD"/called-*
stage_code "$R" 7
VETO_GATE_PACKDIFF_BIN=/nonexistent/pack VETO_GATE_CODEX_BIN="$TD/codex.sh" \
  git -C "$R" commit -qm "feat: seven" >/dev/null 2>&1
ok "$?" "1" "T7 missing pack-diff blocks"

# T8: repo not opted in → no reviewer at all
rm -f "$TD"/called-*
R2=$(new_repo); inst "$R2"; printf '{"enabled":false}' > "$R2/.claude/config/veto-gate.json"
git -C "$R2" add -A; git -C "$R2" commit -qm off >/dev/null 2>&1
stage_code "$R2" 8
mk_stub "$TD/codex.sh" 0 "$FOUND"
VETO_GATE_CODEX_BIN="$TD/codex.sh" git -C "$R2" commit -qm "feat: eight" >/dev/null 2>&1
ok "$?" "0" "T8 disabled repo passes"
[ -f "$TD/called-codex.sh" ] && { F=$((F+1)); echo "  FAIL T8b reviewer ran in disabled repo"; } || P=$((P+1))
rm -rf "$R" "$R2"

echo "precommit-review: PASS=$P FAIL=$F"
[ "$F" = 0 ]

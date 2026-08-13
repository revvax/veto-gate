#!/usr/bin/env bash
# The gate leaves a single-use note naming what it reviewed; the residual
# channel reads it and skips its own review for exactly that content.
#
# Why: since the review stage moved into pre-commit.sh, every NORMAL commit in
# an armed repo would be reviewed twice — once in the gate, once here. Double
# wait, double codex quota. A time window would be too coarse a proof (it would
# wave through a second, unreviewed commit that merely arrives quickly), so the
# note carries the blob ids of the content the gate actually saw.
#
# Blob ids, not the diff text: the gate builds `git diff HEAD` (a superset, the
# index is still empty when it runs) while pre-commit sees `--cached`. The texts
# differ by construction; the blob of a file does not. And a worktree change is
# NOT in the object store yet, so `git diff HEAD --raw` prints zeros for it —
# the note is built with hash-object, verified below.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
LIB="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)"
HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
export VETO_GATE_HERMES_BIN=/nonexistent/hermes
export CODEX_BIN=/nonexistent/codex
unset DISCORD_VETO_WEBHOOK   # T7/T8 drive the real gate — no test may post outward
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got $1, want $2)"; fi; }

TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
# reviewer stub that records being called and always finds something, so
# "was skipped" and "did run" are both provable from the commit's exit code
printf '#!/usr/bin/env bash\necho ran >> "%s/called"\necho '"'"'{"blocking":[{"id":"B","claim":"c","why":"w","fix":"f"}]}'"'"'\n' "$TD" > "$TD/rev.sh"
chmod +x "$TD/rev.sh"
PACK="$TD/pack.sh"
printf '#!/usr/bin/env bash\nmkdir -p "%s/b"\n: > "%s/b/REVIEW_PROMPT.md"\necho "%s/b"\n' "$TD" "$TD" "$TD" > "$PACK"
chmod +x "$PACK"
export VETO_GATE_PACKDIFF_BIN="$PACK" VETO_GATE_CODEX_BIN="$TD/rev.sh"

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
note_path(){ echo "$(git -C "$1" rev-parse --absolute-git-dir)/veto-gate-reviewed"; }
stage(){ printf "import { dep } from './dep';\nexport const x%s = %s;\n" "$2" "$2" > "$1/src/c$2.ts"; git -C "$1" add "src/c$2.ts"; }
# the note as the GATE would write it: hash-object over the worktree file
write_note(){ local R=$1 p=$2; printf '%s %s\n' "$(git -C "$R" hash-object --path "$p" "$R/$p")" "$p" > "$(note_path "$R")"; }

R=$(new_repo); inst "$R"

# T1: no note → the channel reviews (and the stub blocks)
rm -f "$TD/called"; stage "$R" 1
git -C "$R" commit -qm "feat: one" >/dev/null 2>&1; ok "$?" "1" "T1 no note reviews"

# T2: matching note → review skipped, commit passes
rm -f "$TD/called"; write_note "$R" src/c1.ts
git -C "$R" commit -qm "feat: one" >/dev/null 2>&1; ok "$?" "0" "T2 matching note skips"
[ -f "$TD/called" ] && { F=$((F+1)); echo "  FAIL T2b reviewer ran despite note"; } || P=$((P+1))

# T3: the note is single-use — the next commit has none again
rm -f "$TD/called"; stage "$R" 3
git -C "$R" commit -qm "feat: three" >/dev/null 2>&1; ok "$?" "1" "T3 note is consumed"

# T4: note from OTHER content → no proof for this diff, review runs
rm -f "$TD/called"; printf '%s src/c3.ts\n' "$(printf 'something else' | git hash-object --stdin)" > "$(note_path "$R")"
git -C "$R" commit -qm "feat: three" >/dev/null 2>&1; ok "$?" "1" "T4 stale note reviews"

# T5: note covers only PART of the staged set → review runs. The gate seeing a
# superset is fine; seeing less than the commit is not.
rm -f "$TD/called"; stage "$R" 5
write_note "$R" src/c3.ts    # c5.ts staged too, but not in the note
git -C "$R" commit -qm "feat: five" >/dev/null 2>&1; ok "$?" "1" "T5 partial note reviews"

# T6: note is a SUPERSET (gate saw an extra file) → still counts, that is the
# normal shape: the gate reads the whole worktree, the commit stages a part.
rm -f "$TD/called"
{ printf '%s src/c3.ts\n' "$(git -C "$R" hash-object --path src/c3.ts "$R/src/c3.ts")"
  printf '%s src/c5.ts\n' "$(git -C "$R" hash-object --path src/c5.ts "$R/src/c5.ts")"
  printf '%s src/unrelated.ts\n' "$(printf 'x' | git hash-object --stdin)"; } > "$(note_path "$R")"
git -C "$R" commit -qm "feat: five" >/dev/null 2>&1; ok "$?" "0" "T6 superset note skips"
rm -rf "$R"

# T7: the GATE actually writes the note. Without this the whole mechanism is a
# contract with nobody on the other end.
R=$(new_repo)
printf 'export const y = 2;\n' > "$R/src/e.ts"
IN=$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && git add src/e.ts && git commit -m \\"feat: e\\""}}' "$R")
printf '%s' "$IN" | VETO_GATE_LOG_DIR="$TD/log" bash "$HOOKS/veto-gate.sh" >/dev/null 2>&1
N=$(note_path "$R")
if [ -f "$N" ]; then
  P=$((P+1))
  WANT=$(git -C "$R" hash-object --path src/e.ts "$R/src/e.ts")
  grep -q "^$WANT src/e.ts$" "$N" && P=$((P+1)) || { F=$((F+1)); echo "  FAIL T7b note lacks the blob it reviewed"; }
else
  F=$((F+2)); echo "  FAIL T7 gate wrote no note"
fi
rm -rf "$R"

# T8: a repo that is NOT armed gets no note — otherwise a note would disarm the
# residual channel in a repo the gate never inspected.
R=$(new_repo); printf '{"enabled":false}' > "$R/.claude/config/veto-gate.json"
printf 'export const z = 3;\n' > "$R/src/f.ts"
IN=$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && git add src/f.ts && git commit -m \\"feat: f\\""}}' "$R")
printf '%s' "$IN" | VETO_GATE_LOG_DIR="$TD/log" bash "$HOOKS/veto-gate.sh" >/dev/null 2>&1
[ -f "$(note_path "$R")" ] && { F=$((F+1)); echo "  FAIL T8 note written in unarmed repo"; } || P=$((P+1))
rm -rf "$R"

# T9: the contract end to end. T7 proves the gate writes a note and T2 proves a
# note is honoured, but not that the note the GATE writes is one the channel
# accepts — the two build it from different git views (worktree vs index), which
# is exactly where this could quietly fail and cost a second review forever.
# Both real scripts, no hand-written note.
R=$(new_repo); inst "$R"
printf "import { dep } from './dep';\nexport const g = 9;\n" > "$R/src/g.ts"
IN=$(printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && git add src/g.ts && git commit -m \\"feat: g\\""}}' "$R")
printf '%s' "$IN" | VETO_GATE_LOG_DIR="$TD/log" bash "$HOOKS/veto-gate.sh" >/dev/null 2>&1
rm -f "$TD/called"
git -C "$R" add src/g.ts
git -C "$R" commit -qm "feat: g" >/dev/null 2>&1; ok "$?" "0" "T9 gate-written note is honoured"
[ -f "$TD/called" ] && { F=$((F+1)); echo "  FAIL T9b reviewed twice despite the gate's own note"; } || P=$((P+1))
rm -rf "$R"

echo "reviewed-note: PASS=$P FAIL=$F"
[ "$F" = 0 ]

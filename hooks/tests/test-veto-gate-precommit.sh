#!/usr/bin/env bash
# Real git pre-commit hook: catches ALL commits (also auto-sync, F11 residual
# channel). Deterministic stages only (size + grounding); the ONLY escape is
# --no-verify (git standard, visible in the command — no silent env switch,
# codex design finding F28).
set -uo pipefail
LIB="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)"
# hermetic: never a real paid call. Since the review stage moved in here
# (2026-07-29) a clean commit reaches codex, and without this the suite made
# real calls — measured at 118-140s per run and flaky with it. HERMES_BIN
# covers the local pre-reviewer, CODEX_BIN the CLI behind codex-diff-review.
export VETO_GATE_HERMES_BIN=/nonexistent/hermes
export CODEX_BIN=/nonexistent/codex
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got $1, want $2)"; fi; }

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

# T1: installer writes an executable hook
R=$(new_repo); inst "$R"
[ -x "$R/.git/hooks/pre-commit" ] && P=$((P+1)) || { F=$((F+1)); echo "  FAIL T1 not installed"; }

# T2: hallucinated import staged → commit blocked
printf "import { g } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T2 hallucination blocks"

# T3: --no-verify escapes (git standard)
git -C "$R" commit -qm x --no-verify >/dev/null 2>&1; ok "$?" "0" "T3 no-verify passes"

# T4: clean commit passes
printf "import { dep } from './dep';\n" > "$R/src/b.ts"; git -C "$R" add src/b.ts
git -C "$R" commit -qm y >/dev/null 2>&1; ok "$?" "0" "T4 clean passes"

# T5: >max_lines code → blocked; --no-verify escapes (the ONLY escape)
printf '{"enabled":true,"max_lines":10}' > "$R/.claude/config/veto-gate.json"
for i in $(seq 1 20); do echo "export const v$i = $i;"; done > "$R/src/big.ts"
git -C "$R" add src/big.ts .claude/config/veto-gate.json
git -C "$R" commit -qm z >/dev/null 2>&1; ok "$?" "1" "T5 size blocks"
git -C "$R" commit -qm z --no-verify >/dev/null 2>&1; ok "$?" "0" "T5b no-verify passes"
rm -rf "$R"

# T6: repo opted out in its OWN prior commit → hook inert (the HEAD state
# governs; disabling takes effect from the NEXT commit on)
R=$(new_repo); inst "$R"; printf '{"enabled":false}' > "$R/.claude/config/veto-gate.json"
git -C "$R" add .claude/config/veto-gate.json
git -C "$R" commit -qm disable >/dev/null 2>&1; ok "$?" "0" "T6a disable-only commit passes"
printf "import { g } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "0" "T6b disabled repo passes"
rm -rf "$R"

# T20: enabled:false STAGED TOGETHER with bad code → still checked (codex
# round 4: a commit must not silence the hook for itself; HEAD state wins)
R=$(new_repo); inst "$R"; printf '{"enabled":false}' > "$R/.claude/config/veto-gate.json"
printf "import { g } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add -A
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T20 same-commit disable ignored"
rm -rf "$R"

# T7: foreign existing pre-commit → installer refuses, never overwrites
R=$(new_repo); printf '#!/bin/sh\nexit 0\n' > "$R/.git/hooks/pre-commit"; chmod +x "$R/.git/hooks/pre-commit"
bash "$LIB/veto-gate-cli.sh" install-precommit "$R" >/dev/null 2>&1; ok "$?" "1" "T7 foreign hook refused"
grep -q veto2 "$R/.git/hooks/pre-commit" && { F=$((F+1)); echo "  FAIL T7 overwrote"; } || P=$((P+1))
rm -rf "$R"

# T7b: own shim → idempotent reinstall succeeds
R=$(new_repo); inst "$R"
bash "$LIB/veto-gate-cli.sh" install-precommit "$R" >/dev/null 2>&1; ok "$?" "0" "T7b reinstall idempotent"
rm -rf "$R"


# T8: existing-but-BROKEN veto2.json (STAGED) → fail-closed (block, loud)
# (codex design finding B6-CONFIG-FAILOPEN in the plan review)
R=$(new_repo); inst "$R"; printf 'kaputt{' > "$R/.claude/config/veto-gate.json"
printf 'export const x = 1;\n' > "$R/src/x.ts"
git -C "$R" add src/x.ts .claude/config/veto-gate.json
E=$(git -C "$R" commit -qm x 2>&1 >/dev/null); RC=$?
ok "$RC" "1" "T8 broken config blocks"
case "$E" in *kaputt*|*JSON*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL T8 message: $E";; esac
rm -rf "$R"

# T9: invalid max_lines → safe default 300 still blocks a big commit
# (codex design finding B6-MAXLINES-INVALID in the plan review)
R=$(new_repo); inst "$R"; printf '{"enabled":true,"max_lines":"kaputt"}' > "$R/.claude/config/veto-gate.json"
for i in $(seq 1 320); do echo "export const v$i = $i;"; done > "$R/src/big.ts"
git -C "$R" add src/big.ts .claude/config/veto-gate.json
git -C "$R" commit -qm z >/dev/null 2>&1; ok "$?" "1" "T9 invalid max_lines still blocks"
rm -rf "$R"

# T10: doc-only commit (auto-sync channel) passes the size gate
R=$(new_repo); inst "$R"
for i in $(seq 1 320); do echo "zeile $i"; done > "$R/notizen.md"
git -C "$R" add notizen.md
git -C "$R" commit -qm docs >/dev/null 2>&1; ok "$?" "0" "T10 big doc commit passes"
rm -rf "$R"

# T11: install source path with SPACES → shim still works (codex: unquoted
# path in the generated hook could break or execute foreign commands)
LDIR=$(mktemp -d)/"l i b"; mkdir -p "$LDIR"
cp "$LIB"/veto-gate-cli.sh "$LIB"/veto-gate-cli.sh "$LIB"/pre-commit.sh "$LIB"/diff-size.sh "$LIB"/generated-files.sh "$LIB"/grounding-check-diff.sh "$LDIR/"
mkdir -p "$LDIR/../watch-stub" 2>/dev/null || true
R=$(new_repo); bash "$LDIR/veto-gate-cli.sh" install-precommit "$R" >/dev/null
printf "import { g } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T11 spaced lib path still blocks"
rm -rf "$R" "$LDIR"

# T12: grounding checker itself crashes → fail-CLOSED in enabled repos
# (codex: a blocker must not silently open when its checker breaks —
# unlike the warn-only pre-write hook)
R=$(new_repo); inst "$R"
printf "import { dep } from './dep';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
VETO_GATE_GROUNDING_BIN=/usr/bin/false git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T12 broken checker blocks"
rm -rf "$R"

# T13: diff-size crashes / non-numeric → fail-CLOSED
R=$(new_repo); inst "$R"
printf "import { dep } from './dep';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
VETO_GATE_DIFFSIZE_BIN=/usr/bin/false git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T13 broken size check blocks"
rm -rf "$R"

# T14: temp file creation fails → fail-CLOSED (codex: GNU mktemp -t breaks)
R=$(new_repo); inst "$R"
printf "import { dep } from './dep';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
TMPDIR=/nope/nix git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T14 mktemp failure blocks"
rm -rf "$R"

# T15: very FIRST commit of a repo (no HEAD yet) → clean passes, ghost blocks
R=$(mktemp -d); mkdir -p "$R/src" "$R/.claude/config"
git -C "$R" init -q; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf '{"enabled":true}' > "$R/.claude/config/veto-gate.json"
bash "$LIB/veto-gate-cli.sh" install-precommit "$R" >/dev/null
printf 'export const dep = 1;\n' > "$R/src/dep.ts"; git -C "$R" add -A
git -C "$R" commit -qm first >/dev/null 2>&1; ok "$?" "0" "T15 first commit clean passes"
printf "import { g } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T15b first-ish ghost blocks"
rm -rf "$R"

# T16: UNSTAGED enabled:false in the working tree must NOT disarm the hook —
# the INDEX state decides (codex: a working-tree edit could silently switch
# off protection for an unrelated commit)
R=$(new_repo); inst "$R"
printf '{"enabled":false}' > "$R/.claude/config/veto-gate.json"   # unstaged!
printf "import { g } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T16 unstaged disable ignored"
rm -rf "$R"

# T17: installer reports failure when it cannot write the hook
R=$(new_repo); chmod -w "$R/.git/hooks" 2>/dev/null
bash "$LIB/veto-gate-cli.sh" install-precommit "$R" >/dev/null 2>&1; ok "$?" "1" "T17 unwritable hooks dir → install fails loudly"
chmod +w "$R/.git/hooks" 2>/dev/null; rm -rf "$R"

# T18: EMPTY existing config = broken → fail-closed (codex round 3: empty
# slipped past the JSON check into silent inert)
R=$(new_repo); inst "$R"; : > "$R/.claude/config/veto-gate.json"
printf 'export const x = 1;\n' > "$R/src/x.ts"
git -C "$R" add src/x.ts .claude/config/veto-gate.json
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T18 empty config blocks"
rm -rf "$R"

# T19: foreign hook that merely CONTAINS the marker text → still refused
# (codex round 3: marker grep alone allowed overwriting a foreign wrapper)
R=$(new_repo)
printf '#!/bin/sh\n# wraps veto2 pre-commit shim and more\necho custom\nexit 0\n' > "$R/.git/hooks/pre-commit"
chmod +x "$R/.git/hooks/pre-commit"
bash "$LIB/veto-gate-cli.sh" install-precommit "$R" >/dev/null 2>&1; ok "$?" "1" "T19 marker-lookalike refused"
grep -q custom "$R/.git/hooks/pre-commit" && P=$((P+1)) || { F=$((F+1)); echo "  FAIL T19 overwrote wrapper"; }
rm -rf "$R"

# T21: absurdly long max_lines must not overflow the shell comparison into
# a silent pass (codex round 5) — falls back to 300 and still blocks
R=$(new_repo); inst "$R"
printf '{"enabled":true,"max_lines":99999999999999999999}' > "$R/.claude/config/veto-gate.json"
for i in $(seq 1 320); do echo "export const v$i = $i;"; done > "$R/src/big.ts"
git -C "$R" add src/big.ts .claude/config/veto-gate.json
git -C "$R" commit -qm z >/dev/null 2>&1; ok "$?" "1" "T21 huge max_lines still blocks"
rm -rf "$R"

# T22: broken HEAD config must be fully ignored — its silent 300 must not
# min() a valid repair commit into a block (codex round 5)
R=$(new_repo); inst "$R"
printf 'kaputt{' > "$R/.claude/config/veto-gate.json"
git -C "$R" add .claude/config/veto-gate.json
git -C "$R" commit -qm broken --no-verify >/dev/null 2>&1
printf '{"enabled":true,"max_lines":500}' > "$R/.claude/config/veto-gate.json"
for i in $(seq 1 320); do echo "export const v$i = $i;"; done > "$R/src/fix.ts"
git -C "$R" add .claude/config/veto-gate.json src/fix.ts
git -C "$R" commit -qm repair >/dev/null 2>&1; ok "$?" "0" "T22 repair commit not min'd by broken HEAD"
rm -rf "$R"

# T23: UNTRACKED config file is not part of any commit → hook inert
# (codex round 5: working-tree files must not govern commits)
R=$(mktemp -d); mkdir -p "$R/src" "$R/.claude/config"
git -C "$R" init -q; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf 'export const dep = 1;\n' > "$R/src/dep.ts"
git -C "$R" add src/dep.ts; git -C "$R" commit -qm base --no-verify
bash "$LIB/veto-gate-cli.sh" install-precommit "$R" >/dev/null
printf '{"enabled":true}' > "$R/.claude/config/veto-gate.json"   # never added
printf "import { g } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "0" "T23 untracked config → inert"
rm -rf "$R"

# T24: jq missing from PATH → fail-closed with a clear message (codex round 6)
R=$(new_repo); inst "$R"
printf "import { dep } from './dep';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
BINDIR=$(mktemp -d)
for t in git bash sh; do ln -s "$(command -v $t)" "$BINDIR/$t"; done
E=$(cd "$R" && env PATH="$BINDIR" git commit -qm x 2>&1 >/dev/null); RC=$?
ok "$RC" "1" "T24 missing jq blocks"
case "$E" in *jq*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL T24 message: $E";; esac
rm -rf "$R" "$BINDIR"

# T25: broken config in HEAD, commit does NOT touch the config → still blocks
# (refutes codex round-6 B1: the index always carries tracked configs, so the
# staged-state check fires even when the commit leaves the config alone)
R=$(new_repo); inst "$R"
printf 'kaputt{' > "$R/.claude/config/veto-gate.json"
git -C "$R" add .claude/config/veto-gate.json
git -C "$R" commit -qm broken --no-verify >/dev/null 2>&1
printf 'export const ok = 1;\n' > "$R/src/ok.ts"; git -C "$R" add src/ok.ts
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T25 broken tracked config blocks any commit"
rm -rf "$R"

# T25: rename transition — a staged veto-gate.json made of TWO concatenated
# JSON objects is UNSOUND and must fail closed (multi-document files slipped
# past a bare type=="object" probe and disarmed the enabled read, codex find)
R=$(new_repo); inst "$R"
printf '{}\n{"enabled":false}\n' > "$R/.claude/config/veto-gate.json"
printf 'x\n' > "$R/f.txt"
git -C "$R" add -A >/dev/null 2>&1
E=$(git -C "$R" commit -qm x 2>&1); RC=$?
ok "$RC" "1" "T25 two-object staged veto-gate.json blocks"
case "$E" in *kaputt*|*JSON*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL T25 message: $E";; esac

# T26: a staged SOUND veto-gate.json governs (new name wins per state) —
# enabled:false in the new file must not be overridden by the old HEAD state
# arming... the STRICTEST state still governs, so HEAD enabled keeps the hook
# armed for THIS commit (same-commit disable rule, T20 analog)
R=$(new_repo); inst "$R"
printf '{"enabled":false}' > "$R/.claude/config/veto-gate.json"
printf 'y\n' > "$R/big.txt"; i=0; while [ $i -lt 350 ]; do printf 'const x%d = 1;\n' "$i" >> "$R/src/big.ts"; i=$((i+1)); done
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -qm x >/dev/null 2>&1; ok "$?" "1" "T26 same-commit disable via new name ignored (HEAD armed)"


# T28: jq MISSING while HEAD carries an armed (new-name) config: deleting
# that config and shipping code in the same commit must BLOCK, not pass —
# presence must be decided on raw git state BEFORE any jq-dependent probe
# (codex find: cfg_sound ran before the jq check and discarded the state)
R=$(new_repo); inst "$R"
git -C "$R" rm -q .claude/config/veto-gate.json
printf 'const x = 1;\n' > "$R/src/n.ts"
git -C "$R" add -A >/dev/null 2>&1
FAKEBIN=$(mktemp -d)
for b in git bash sh env dirname mktemp cat rm cp mv grep sed awk; do
  pth=$(command -v "$b" 2>/dev/null) && ln -s "$pth" "$FAKEBIN/$b"
done
E=$(PATH="$FAKEBIN" git -C "$R" commit -qm x 2>&1); RC=$?
ok "$RC" "1" "T28 missing jq + armed config in HEAD blocks"
rm -rf "$FAKEBIN"

# T29: a dependency commit — manifest + lockfile in ONE commit, because splitting
# them leaves a state where the declared version is not the installed one. The
# lockfile supplies almost every changed line, so the size gate blocked every
# security upgrade and the only way through was --no-verify: no review at all.
R=$(new_repo); inst "$R"
printf '{"enabled":true,"max_lines":10}' > "$R/.claude/config/veto-gate.json"
printf '{"name":"root","dependencies":{"sharp":"0.35.3"}}\n' > "$R/package.json"
{ echo '{'; for i in $(seq 1 200); do echo "  \"pkg$i\": \"1.0.0\","; done; echo '  "end": 1'; echo '}'; } > "$R/package-lock.json"
git -C "$R" add package.json package-lock.json .claude/config/veto-gate.json
git -C "$R" commit -qm "chore(deps): sharp 0.35.3" >/dev/null 2>&1
ok "$?" "0" "T29 dependency commit no longer size-blocks"

# …and the reviewers still run for it. A lockfile-only commit must NOT look like a
# doc commit (CHANGED==0 skips the review stage) — that would wave an unreviewed
# `npm install` through, which is a worse hole than the one we just closed.
DEPD=$(mktemp); git -C "$R" show --format= -U3 HEAD > "$DEPD"
CH=$(bash "$LIB/diff-size.sh" --diff "$DEPD"); rm -f "$DEPD"
ok "$([ "${CH:-0}" -gt 0 ] && echo yes || echo no)" "yes" "T29b lockfile lines keep the commit out of the doc-only skip"

# real code alongside the lockfile still counts and still blocks
for i in $(seq 1 20); do echo "export const v$i = $i;"; done > "$R/src/big.ts"
git -C "$R" add src/big.ts
git -C "$R" commit -qm "feat: big" >/dev/null 2>&1
ok "$?" "1" "T29c real code next to a lockfile still size-blocks"
rm -rf "$R"

echo "precommit: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

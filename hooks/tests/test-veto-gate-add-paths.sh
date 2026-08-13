#!/usr/bin/env bash
# add-paths.sh: extract the file args of every `git add` in a command string,
# quote-aware (F6: the gate narrows its review diff to what is really added).
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/add-paths.sh"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1' want '$2')"; fi; }

# T1: bare path
ok "$(printf 'git add src/a.ts && git commit -m x' | bash "$S")" "src/a.ts" "T1 bare path"

# T2: double-quoted path with space
ok "$(printf 'git add "src/big neu.ts" && git commit -m x' | bash "$S")" "src/big neu.ts" "T2 quoted path with space"

# T3: single-quoted path
ok "$(printf "git add 'x y.ts' && git commit -m x" | bash "$S")" "x y.ts" "T3 single-quoted path"

# T4: multiple paths + options skipped
ok "$(printf 'git add -f a.ts b.ts && git commit -m x' | bash "$S")" "a.ts
b.ts" "T4 options skipped, two paths"

# T5: git -C <repo> add
ok "$(printf 'git -C /tmp/repo add src/c.ts && git commit' | bash "$S")" "src/c.ts" "T5 -C form"

# T6: paths in the commit MESSAGE must not leak in
ok "$(printf 'git add a.ts && git commit -m "fix b.ts handling"' | bash "$S")" "a.ts" "T6 message text ignored"

# T7: -A/--all/. emit the sentinel line ::ALL::
ok "$(printf 'git add -A && git commit -m x' | bash "$S")" "::ALL::" "T7 -A sentinel"
ok "$(printf 'git add . && git commit -m x' | bash "$S")" "::ALL::" "T7b dot sentinel"

# T8: no git add at all → empty
ok "$(printf 'git commit -m x' | bash "$S")" "" "T8 no add"

# T9: add inside a substitution is NOT extracted (undecidable → caller falls back)
ok "$(printf 'echo $(git add x.ts) && git commit -m x' | bash "$S")" "" "T9 substitution ignored"

# T10: -- separator: everything after is a path, even if dash-prefixed
ok "$(printf 'git add -- -weird.ts && git commit' | bash "$S")" "-weird.ts" "T10 dashdash path"

# T11: a $VAR token is not statically resolvable → EMPTY output, the caller
# falls back (grounding superset, size counts only visibly named — F6 rule)
ok "$(printf 'git add $FILES && git commit -m x' | bash "$S")" "::VAR::" "T11 variable token → VAR sentinel"

# T12: single-quoted / escaped dollars are LITERAL paths, never expansion
ok "$(printf "git add '\$FILES' && git commit -m x" | bash "$S")" "\$FILES" "T12 sq dollar literal path"
ok "$(printf 'git add \\$F && git commit -m x' | bash "$S")" "\$F" "T12b escaped dollar literal path"
# double backslash: the shell sees literal '\' then EXPANDS $F → fallback
ok "$(printf 'git add \\\\$F && git commit -m x' | bash "$S")" "::VAR::" "T12c even backslashes → expands → VAR"

# T13: add -u/--update stages tracked changes only → ::TRACKED:: sentinel,
# and its pathspecs are NOT untracked sources either (codex round)
ok "$(printf 'git add -u && git commit -m x' | bash "$S")" "::TRACKED::" "T13 -u → TRACKED sentinel"
ok "$(printf 'git add -u src/ && git commit -m x' | bash "$S")" "::TRACKED::src/" "T13b -u pathspec kept for tracked scope"
# ...but a SECOND plain add in the chain still contributes its path
ok "$(printf 'git add -u && git add neu.ts && git commit' | bash "$S")" "::TRACKED::
neu.ts" "T13c mixed -u + plain add"

# T14: $VAR inside an -u add stays TRACKED (-u never takes untracked)
ok "$(printf 'git add -u $FILES && git commit -m x' | bash "$S")" "::TRACKEDVAR::" "T14 -u with variable → TRACKEDVAR"

# T15: a literal path starting with :: must not be read as a sentinel —
# undecidable → fallback instead of a spoofed marker
ok "$(printf 'git add ::TRACKED::x && git commit' | bash "$S")" "::VAR::" "T15 sentinel-lookalike path → VAR"

# T16: a safe add plus a variable add — the VAR sentinel must survive so the
# caller falls back for the WHOLE chain (a path list would hide the var files)
ok "$(printf 'git add safe.ts && git add $F && git commit' | bash "$S")" "safe.ts
::VAR::" "T16 mixed safe+var adds keep sentinel"

# T17: an unquoted newline separates commands — a $ in the NEXT command's
# message must not drag the add into ::VAR:: fallback (codex round)
ok "$(printf 'git add a.ts\ngit commit -m "$M"' | bash "$S")" "a.ts" "T17 newline ends the add segment"

# T18: safe path and variable in the SAME add — sentinel plus paths, so the
# size gate still counts the named file (codex round)
ok "$(printf 'git add safe.ts $F && git commit' | bash "$S")" "::VAR::
safe.ts" "T18 same-add safe+var keeps path"

# T19: -u with pathspec and variable — TRACKEDVAR plus TRACKED path
ok "$(printf 'git add -u src/ $F && git commit' | bash "$S")" "::TRACKEDVAR::
::TRACKED::src/" "T19 -u pathspec+var keeps tracked path"

# T20: 'git add -u .' is tracked-only — dot must not become ::ALL:: (codex)
ok "$(printf 'git add -u . && git commit' | bash "$S")" "::TRACKED::" "T20 -u dot stays tracked-only"

echo "add-paths: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

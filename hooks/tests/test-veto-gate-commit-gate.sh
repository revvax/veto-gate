#!/usr/bin/env bash
# Integration tests for veto-gate.sh with a mock codex.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
# Never post test findings to the real Discord: the gate calls notify_discord
# on every block, and these fixtures would land on the owner's phone as garbage.
unset DISCORD_VETO_WEBHOOK
HOOK="$(cd "$(dirname "$0")/.." && pwd)/veto-gate.sh"
export VETO_GATE_LOG_DIR="$(mktemp -d)"   # isolate: never touch the real run log
export VETO_GATE_TIMEOUT=5                 # mocks are instant; keep watcher short
# hermetic: the qwen stage must NEVER reach a real LM Studio from tests —
# dead port fails open instantly; the B2 section overrides this per test
export VETO_GATE_HERMES_BIN="/nonexistent/hermes"   # hermetic: never a real paid call
export VETO_GATE_KREISEL_STOP=0   # this suite is a fixture farm, not one correction sequence
TMP=$(mktemp -d); trap 'rm -rf "$TMP" "$VETO_GATE_LOG_DIR"' EXIT
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }

# a real git repo, opted in
R="$TMP/repo"; mkdir -p "$R/src" "$R/.claude/config"
git -C "$R" init -q
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"
printf 'export const b=1;\n' > "$R/src/b.ts"

# mock codex that emits a clean verdict + a thread.started event line
MOCK_CLEAN="$TMP/codex-clean"; cat > "$MOCK_CLEAN" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$MOCK_CLEAN"

# mock codex that emits a BLOCKING verdict
MOCK_BLOCK="$TMP/codex-block"; cat > "$MOCK_BLOCK" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '{"blocking":[{"id":"B1","claim":"drops user table","why":"data loss","fix":"remove"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$MOCK_BLOCK"

# mock codex that FAILS (no thread.started, empty verdict) → fail-open
MOCK_FAIL="$TMP/codex-fail"; cat > "$MOCK_FAIL" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null; exit 1
EOF
chmod +x "$MOCK_FAIL"

run(){ # $1=mock ; prints exit code
  printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
    | CODEX_BIN="$1" bash "$HOOK" >/dev/null 2>&1; echo $?
}

# clean, real import staged → codex clean → allow (0)
printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(run "$MOCK_CLEAN")" "0" "clean diff + clean codex → allow"

# codex blocking → block (2)
ok "$(run "$MOCK_BLOCK")" "2" "codex blocking → block"

# codex infra failure / timeout → BLOCK (fail-closed, not waved through)
ok "$(run "$MOCK_FAIL")" "2" "codex fail → block (fail-closed)"

# hallucinated import → deterministic block (2), codex never consulted
git -C "$R" reset -q; printf "import { ghost } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(run "$MOCK_CLEAN")" "2" "hallucinated import → deterministic block"

# opt-out: remove config → allow (0)
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
rm "$R/.claude/config/veto-gate.json"
ok "$(run "$MOCK_BLOCK")" "0" "no config → gate inert"
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"

# override consumes flag → allow once (0)
mkdir -p "$R/.claude/session-flags"; touch "$R/.claude/session-flags/s1-veto-gate-override"
ok "$(run "$MOCK_BLOCK")" "0" "override → allow once"
ok "$([ -f "$R/.claude/session-flags/s1-veto-gate-override" ] && echo exists || echo gone)" "gone" "override single-use"
# A deliberate wave-through must leave a trace. Without it REIBUNG — the column
# that separates "the gate helped" from "the gate got in the way" — cannot be
# counted at all, and the score card had to print `?` for every hook (E4).
ok "$(tail -1 "$VETO_GATE_LOG_DIR/runs.jsonl" | jq -r '.result')" "override" "override → ledger entry"
ok "$(tail -1 "$VETO_GATE_LOG_DIR/runs.jsonl" | jq -r '.blocking')" "0" "override blocks nothing"
ok "$(tail -1 "$VETO_GATE_LOG_DIR/runs.jsonl" | jq -r '.repo')" "repo" "override names its repo"
ok "$(cat "$VETO_HB_DIR"/*.tsv 2>/dev/null | grep -cF "$(printf '\tveto-gate\toverride\t')")" "1" "override → heartbeat"
# An empty flag file is a bypass that gave no reason. It still gets through —
# blocking it would only move the problem — but the ledger says so, otherwise
# "the gate is too strict" and "we were in a hurry" leave the same trace.
ok "$(tail -1 "$VETO_GATE_LOG_DIR/runs.jsonl" | jq -r '.reason')" "" "override without a reason is recorded as one"

# the WHY: whatever stands in the flag file travels into the ledger
printf 'Lockfile, der Prüfer kann das nicht\n' > "$R/.claude/session-flags/s1-veto-gate-override"
ok "$(run "$MOCK_BLOCK")" "0" "override with a reason → allow once"
ok "$(tail -1 "$VETO_GATE_LOG_DIR/runs.jsonl" | jq -r '.reason')" "Lockfile, der Prüfer kann das nicht" "the reason lands in the ledger"
# free text in a JSON ledger: quotes must not split the line, and a second line
# is not a second reason — the ledger is one entry per run
printf 'er sagte "nein"\nzweite Zeile\n' > "$R/.claude/session-flags/s1-veto-gate-override"
ok "$(run "$MOCK_BLOCK")" "0" "override with quotes → allow once"
ok "$(tail -1 "$VETO_GATE_LOG_DIR/runs.jsonl" | jq -r '.reason')" 'er sagte "nein"' "quotes survive, the second line is dropped"
# a novel is not a reason: the ledger is a stats file, not an archive
python3 -c 'print("x"*400)' > "$R/.claude/session-flags/s1-veto-gate-override"
ok "$(run "$MOCK_BLOCK")" "0" "override with a novel → allow once"
ok "$(tail -1 "$VETO_GATE_LOG_DIR/runs.jsonl" | jq -r '.reason' | wc -c | tr -d ' ')" "201" "an over-long reason is cut at 200 characters"

# --- git -C <repo> from a foreign cwd (E1: gate must follow -C, not cwd) ----
ELSE="$TMP/elsewhere"; mkdir -p "$ELSE"
runc(){ # $1=mock $2=command ; cwd is ELSE, command targets $R via -C
  printf '{"tool_input":{"command":"%s"},"cwd":"%s","session_id":"s1"}' "$2" "$ELSE" \
    | CODEX_BIN="$1" bash "$HOOK" >/dev/null 2>&1; echo $?
}
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "git -C $R commit -m x")" "2" "-C repo resolved: block despite foreign cwd"

# -C target without config → inert, even if cwd repo had one
rm "$R/.claude/config/veto-gate.json"
mkdir -p "$ELSE/.claude/config"; printf '{"enabled":true}\n' > "$ELSE/.claude/config/veto-gate.json"
ok "$(runc "$MOCK_BLOCK" "git -C $R commit -m x")" "0" "-C repo without config → inert"
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"

# -C add-chain: unstaged ghost import in working tree → deterministic block
git -C "$R" reset -q; printf "import { ghost } from './ghost';\n" > "$R/src/a.ts"
ok "$(runc "$MOCK_CLEAN" "git -C $R add src/a.ts && git -C $R commit -m x")" "2" "-C add-chain → grounding block"
printf "import { b } from './b';\n" > "$R/src/a.ts"

# F3: import-like STRINGS in non-JS/TS files (sh fixtures, docs) are literals,
# not imports — grounding must not flag them.
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"
printf 'printf "import { ghost } from %s./nope%s;"\n' "'" "'" > "$R/src/tool.sh"
git -C "$R" add src/a.ts src/tool.sh
ok "$(run "$MOCK_CLEAN")" "0" "sh fixture import-string not flagged"

# .mts/.cts carry import semantics too — ghost import there must still block
git -C "$R" reset -q; rm -f "$R/src/tool.sh"
printf "import { ghost } from './ghost';\n" > "$R/src/m.mts"; git -C "$R" add src/m.mts
ok "$(run "$MOCK_CLEAN")" "2" "mts ghost import blocked"

# unknown-but-import-bearing types (.astro etc.) must stay covered (deny-list, not allow-list)
git -C "$R" reset -q; printf "import { ghost } from './ghost';\n" > "$R/src/c.astro"
git -C "$R" add src/c.astro
ok "$(run "$MOCK_CLEAN")" "2" "astro ghost import blocked"

# --- F19: `cd <repo> && git commit` from a foreign cwd must follow the cd
# target, not the session cwd (live hit 2026-07-10: gate reviewed the session
# repo's untracked docs instead of the committed repo's staged diff) ---------
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "cd $R && git commit -m x")" "2" "cd-chain resolved: block despite foreign cwd"

# cd-chain with add: unstaged ghost import in working tree → deterministic block
git -C "$R" reset -q; printf "import { ghost } from './ghost';\n" > "$R/src/a.ts"
ok "$(runc "$MOCK_CLEAN" "cd $R && git add src/a.ts && git commit -m x")" "2" "cd add-chain → grounding block"
printf "import { b } from './b';\n" > "$R/src/a.ts"

# cd target without config → inert, even if the cwd repo has one enabled
rm "$R/.claude/config/veto-gate.json"
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "cd $R && git commit -m x")" "0" "cd target without config → inert"
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"

# `git -C` beats a cd prefix (the -C target is where the commit lands)
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "cd $ELSE && git -C $R commit -m x")" "2" "-C wins over cd prefix"

# --- F19b: hooks receive the RAW command string — a -C/cd target written as
# $HOME/... or ~/... was never expanded, [ -d ] failed, gate fell back to the
# wrong cwd repo (2nd live hit 2026-07-10). HOME is remapped to $TMP so
# $HOME/repo resolves to $R. -----------------------------------------------
runh(){ # $1=mock $2=command ; cwd is ELSE, HOME remapped to TMP
  printf '{"tool_input":{"command":"%s"},"cwd":"%s","session_id":"s1"}' "$2" "$ELSE" \
    | CODEX_BIN="$1" HOME="$TMP" bash "$HOOK" >/dev/null 2>&1; echo $?
}
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runh "$MOCK_BLOCK" 'git -C $HOME/repo commit -m x')" "2" "-C \$HOME target expanded"
ok "$(runh "$MOCK_BLOCK" 'git -C \"$HOME/repo\" commit -m x')" "2" "-C quoted \$HOME target expanded"
ok "$(runh "$MOCK_BLOCK" 'cd ~/repo && git commit -m x')" "2" "cd tilde target expanded"

# a cd AFTER the commit must not re-target the gate (codex live finding
# 2026-07-10: last-cd-wins let a trailing cd bend the review off the repo)
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "cd $R && git commit -m x; cd $ELSE")" "2" "cd after commit ignored"

# codex live finding #2 (2026-07-10): a conditionally-skipped cd must not
# re-target the gate. Only a pure && chain guarantees the cd ran when the
# commit runs; with ; | & the session cwd stays authoritative.
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "false && cd $R; git commit -m x")" "0" "conditionally-skipped cd not honored"
# codex live finding #6: the FINAL ;-segment is unconditional — a pure &&
# chain there guarantees the cd ran when the commit runs, so honor it
ok "$(runc "$MOCK_BLOCK" "true; cd $R && git commit -m x")" "2" "cd in final ;-segment honored"
ok "$(runc "$MOCK_BLOCK" "false && cd $R && git commit -m x")" "2" "pure && chain still honored"
# a || before the cd can skip it while the chain still succeeds → not honored
ok "$(runc "$MOCK_BLOCK" "true || cd $R && git commit -m x")" "0" "||-conditional cd not honored"

# codex live finding #3 (2026-07-10): a RELATIVE -C (git -C . commit) must
# resolve against the cd target, not the hook process cwd
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "cd $R && git -C . commit -m x")" "2" "relative -C resolved against cd target"

# codex live findings #4+#5 (2026-07-10): quoted targets. (a) quoted paths
# WITH SPACES must parse; (b) quoting decides expansion — '$HOME' single-
# quoted and "~" double-quoted stay literal for the shell, so the gate must
# treat them literally too (else it reviews a repo the commit never touches).
R2="$TMP/mein repo"; mkdir -p "$R2/src" "$R2/.claude/config"
git -C "$R2" init -q; git -C "$R2" config user.email t@t.t; git -C "$R2" config user.name t
printf '{"enabled":true,"effort":"high"}\n' > "$R2/.claude/config/veto-gate.json"
printf 'export const b=1;\n' > "$R2/src/b.ts"
printf "import { b } from './b';\n" > "$R2/src/a.ts"; git -C "$R2" add src/a.ts src/b.ts
ok "$(runc "$MOCK_BLOCK" "cd \\\"$R2\\\" && git commit -m x")" "2" "quoted path with spaces honored"
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runh "$MOCK_BLOCK" "git -C '\$HOME/repo' commit -m x")" "0" "single-quoted \$HOME stays literal"
ok "$(runh "$MOCK_BLOCK" "cd \\\"~/repo\\\" && git commit -m x")" "0" "double-quoted tilde stays literal"

# codex live findings #7+#8 (2026-07-10): (a) '&&' without spaces must still
# join the cd to the commit; (b) cd/git-commit TEXT inside quoted args is
# data, not commands — it must never steer the parser.
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "cd $R&&git commit -m x")" "2" "&& without spaces honored"
ok "$(runc "$MOCK_BLOCK" "cd $R && echo \\\"a && cd $ELSE\\\" && git commit -m x")" "2" "quoted cd text ignored"
ok "$(runc "$MOCK_BLOCK" "echo \\\"git commit\\\"")" "0" "quoted pseudo-commit → gate inert"

# codex live findings #9+#10 (2026-07-10): (a) escaped quotes inside quoted
# text must not break quote pairing (mis-pairing can expose quoted cd text as
# structure); (b) a backslash inside a cd/-C target (cd mein\ repo) is not
# parseable with confidence → conservative fallback, even if a prefix dir
# exists ("$TMP/mein" repo vs "$TMP/mein repo").
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "cd $R && echo \\\"\\\\\\\" && cd $ELSE \\\\\\\"\\\" && git commit -m x")" "2" "escaped quotes lexed correctly"
MEIN="$TMP/mein"; mkdir -p "$MEIN/.claude/config" "$MEIN/src"
git -C "$MEIN" init -q; git -C "$MEIN" config user.email t@t.t; git -C "$MEIN" config user.name t
printf '{"enabled":true,"effort":"high"}\n' > "$MEIN/.claude/config/veto-gate.json"
printf 'export const b=1;\n' > "$MEIN/src/b.ts"
printf "import { b } from './b';\n" > "$MEIN/src/a.ts"; git -C "$MEIN" add src/a.ts src/b.ts
# codex live finding #11: backslash-escaped spaces are shell-valid targets —
# parse them ("$TMP/mein repo" is the real repo, not its "$TMP/mein" prefix)
ok "$(runc "$MOCK_BLOCK" "cd $TMP/mein\\\\ repo && git commit -m x")" "2" "escaped-space cd target parsed"

# codex live finding #12: a commit from a SUBFOLDER commits the whole repo —
# config + diff live at the toplevel; subdir must not make the gate inert
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runc "$MOCK_BLOCK" "cd $R/src && git commit -m x")" "2" "cd into subdir resolves to toplevel"
ok "$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R/src" \
  | CODEX_BIN="$MOCK_BLOCK" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "session cwd in subdir resolves to toplevel"

# codex live findings #13+#14 (2026-07-10): (a) \\\$HOME is a LITERAL dollar
# for the shell — the gate must not expand it; (b) without perl, quoted text
# cannot be lexed — commands containing quotes must fail CLOSED, quote-free
# commands still work (VETO_GATE_NO_PERL is the test seam).
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(runh "$MOCK_BLOCK" 'git -C \\$HOME/repo commit -m x')" "0" "escaped \$HOME stays literal"
ok "$(VETO_GATE_NO_PERL=1 runc "$MOCK_CLEAN" "echo \\\"hi\\\" && git commit -m x")" "2" "no perl + quotes → fail closed"
ok "$(VETO_GATE_NO_PERL=1 runc "$MOCK_BLOCK" "cd $R && git commit -m x")" "2" "no perl, quote-free → still gated"

# codex live findings #15+#16 (2026-07-10): paths CONTAINING 'cd ' or '-C '
# must not confuse the anchored prefix strip (greedy .*cd ate into the path)
XR="$TMP/a cd -C b"; mkdir -p "$XR/src" "$XR/.claude/config"
git -C "$XR" init -q; git -C "$XR" config user.email t@t.t; git -C "$XR" config user.name t
printf '{"enabled":true,"effort":"high"}\n' > "$XR/.claude/config/veto-gate.json"
printf 'export const b=1;\n' > "$XR/src/b.ts"
printf "import { b } from './b';\n" > "$XR/src/a.ts"; git -C "$XR" add src/a.ts src/b.ts
ok "$(runc "$MOCK_BLOCK" "cd \\\"$XR\\\" && git commit -m x")" "2" "path containing 'cd ' parsed"
ok "$(runc "$MOCK_BLOCK" "git -C \\\"$XR\\\" commit -m x")" "2" "path containing '-C ' parsed"

# codex live finding #17 (2026-07-10): $(...) and backticks EXECUTE, also
# inside double quotes — a commit hidden there must fail closed in gated
# repos (and stay inert where veto2 is off; single quotes stay literal)
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(printf '{"tool_input":{"command":"echo \\"$(git commit -m x)\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "commit in dq substitution → fail closed"
ok "$(printf '{"tool_input":{"command":"echo `git commit -m x`"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "commit in backticks → fail closed"
NOCFG="$TMP/nocfg"; mkdir -p "$NOCFG"
ok "$(printf '{"tool_input":{"command":"echo \\"$(git commit -m x)\\""},"cwd":"%s","session_id":"s1"}' "$NOCFG" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "hidden commit where gate is off → inert"
ok "$(printf '{"tool_input":{"command":"echo '\''x $(git commit) y'\''"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "sq substitution text stays literal"

# codex live findings #18+#19 (2026-07-10): (a) a hidden 'git -C <gated>
# commit' from a non-gated cwd must be checked against the -C TARGET's
# config; (b) without perl, substitution-hidden commits must fail closed.
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(printf '{"tool_input":{"command":"echo \\"$(git -C %s commit -m x)\\""},"cwd":"%s","session_id":"s1"}' "$R" "$NOCFG" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "hidden -C into gated repo → fail closed"
ok "$(printf '{"tool_input":{"command":"echo $(git commit -m x)"},"cwd":"%s","session_id":"s1"}' "$R" \
  | VETO_GATE_NO_PERL=1 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "no perl + substitution commit → fail closed"
ok "$(printf '{"tool_input":{"command":"echo $(date)"},"cwd":"%s","session_id":"s1"}' "$R" \
  | VETO_GATE_NO_PERL=1 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "no perl, substitution without commit → inert"

# codex live finding #20 (2026-07-10): the no-perl fail-closed paths must
# still honor the per-repo OPT-IN — projects without veto2 never get blocked
ok "$(printf '{"tool_input":{"command":"git commit -m \\"x\\""},"cwd":"%s","session_id":"s1"}' "$NOCFG" \
  | VETO_GATE_NO_PERL=1 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "no perl + quotes, repo not gated → inert"
ok "$(printf '{"tool_input":{"command":"echo $(git commit -m x)"},"cwd":"%s","session_id":"s1"}' "$NOCFG" \
  | VETO_GATE_NO_PERL=1 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "no perl + substitution, repo not gated → inert"

# codex live finding #21 (2026-07-10): interpreters EXECUTE their string
# argument — bash/sh/zsh -c "git commit", eval "git commit" (single quotes
# too) must fail closed in gated repos, stay inert without opt-in
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(printf '{"tool_input":{"command":"bash -c \\"git commit -m x\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "bash -c hidden commit → fail closed"
ok "$(printf '{"tool_input":{"command":"sh -c '\''git commit -m x'\''"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "sh -c single-quoted commit → fail closed"
ok "$(printf '{"tool_input":{"command":"eval \\"git commit -m x\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "eval hidden commit → fail closed"
ok "$(printf '{"tool_input":{"command":"bash -c \\"git commit -m x\\""},"cwd":"%s","session_id":"s1"}' "$NOCFG" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "bash -c where gate is off → inert"
ok "$(printf '{"tool_input":{"command":"bash -c \\"git commit -m x\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | VETO_GATE_NO_PERL=1 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "no perl + bash -c commit → fail closed"

# codex live findings #22+#23 (2026-07-10): (a) only real -c invocations make
# an interpreter suspicious — 'bash build.sh && echo "git commit"' is prose;
# (b) hidden commits may cd into a gated repo — scan cd candidates too
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(printf '{"tool_input":{"command":"bash build.sh && echo \\"git commit\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "bash without -c + commit prose → inert"
ok "$(printf '{"tool_input":{"command":"bash -c \\"cd %s && git commit -m x\\""},"cwd":"%s","session_id":"s1"}' "$R" "$NOCFG" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "hidden cd into gated repo → fail closed"

# codex live finding #24 (2026-07-10): combined short options (-lc) still
# carry -c — the interpreter check must catch them
ok "$(printf '{"tool_input":{"command":"bash -lc \\"git commit -m x\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "bash -lc hidden commit → fail closed"

# codex live findings #25-#27 (2026-07-10): (a) a structural commit match
# INSIDE an open $(/backtick region is a hidden commit (balanced substitutions
# before a real commit stay normal); (b) multi-option 'bash --noprofile
# --norc -c' is caught (pin — codex #26 was a false alarm, the regex matches);
# (c) gated_anywhere must resolve \$HOME/~ like the normal path
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(printf '{"tool_input":{"command":"echo $(cd %s && git commit -m x)"},"cwd":"%s","session_id":"s1"}' "$R" "$NOCFG" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "commit inside open substitution → fail closed"
ok "$(printf '{"tool_input":{"command":"echo $(date) && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "balanced substitution before commit → normal review"
ok "$(printf '{"tool_input":{"command":"bash --noprofile --norc -c \\"git commit -m x\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "multi-option bash -c → fail closed"
ok "$(printf '{"tool_input":{"command":"git -C \\"$HOME/repo\\" commit -m x"},"cwd":"%s","session_id":"s1"}' "$NOCFG" \
  | HOME="$TMP" VETO_GATE_NO_PERL=1 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "no perl + \$HOME -C into gated repo → fail closed"

# codex live finding #28 (2026-07-10): a benign substitution NEXT TO commit
# prose must not couple into a hidden-commit block — the commit pattern must
# sit INSIDE the executable span itself
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(printf '{"tool_input":{"command":"echo \\"$(date)\\" && echo \\"git commit -m x\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "substitution + commit prose decoupled"

# codex live finding #29 (2026-07-10): the perl-less opt-in approximation
# must also scan cd targets — 'cd <gated> && git commit -m \"x\"' from an
# ungated cwd otherwise slips through the quote fail-close
ok "$(printf '{"tool_input":{"command":"cd %s && git commit -m \\"x\\""},"cwd":"%s","session_id":"s1"}' "$R" "$NOCFG" \
  | VETO_GATE_NO_PERL=1 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "no perl + quoted commit after cd into gated repo → fail closed"

# F4: the override hint must say it needs a SEPARATE command BEFORE the
# commit (chicken-and-egg: the hook runs before the chained touch would)
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
E=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_BLOCK" bash "$HOOK" 2>&1 >/dev/null)
case "$E" in *SEPARAT*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL F4 hint missing: $E";; esac

# --- B4: hard size gate -----------------------------------------------------
# >300 changed CODE lines → size-block with "aufteilen" hint
git -C "$R" reset -q
for i in $(seq 1 320); do echo "export const v$i = $i;"; done > "$R/src/big.ts"
git -C "$R" add src/big.ts
E=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" 2>&1 >/dev/null); RC=$?
ok "$RC" "2" "B4b big code diff → size-block"
case "$E" in *aufteilen*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL B4b message: $E";; esac
git -C "$R" reset -q; rm -f "$R/src/big.ts"

# doc lines are exempt: 320-line .md diff passes the size stage
for i in $(seq 1 320); do echo "zeile $i"; done > "$R/plan.md"
git -C "$R" add plan.md
ok "$(run "$MOCK_CLEAN")" "0" "B4b-2 md-only big diff passes"
git -C "$R" reset -q; rm -f "$R/plan.md"

# custom max_lines from config is honored
printf '{"enabled":true,"max_lines":10}\n' > "$R/.claude/config/veto-gate.json"
for i in $(seq 1 20); do echo "export const v$i = $i;"; done > "$R/src/mid.ts"
git -C "$R" add src/mid.ts
ok "$(run "$MOCK_CLEAN")" "2" "B4b-3 max_lines=10 blocks 20 lines"
git -C "$R" reset -q; rm -f "$R/src/mid.ts"
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"

# invalid max_lines in config must not disarm the gate (codex live finding:
# a non-numeric value made -gt fail silently → default 300 must kick in)
printf '{"enabled":true,"max_lines":"kaputt"}\n' > "$R/.claude/config/veto-gate.json"
for i in $(seq 1 320); do echo "export const v$i = $i;"; done > "$R/src/big.ts"
git -C "$R" add src/big.ts
ok "$(run "$MOCK_CLEAN")" "2" "B4b-4 invalid max_lines → default 300 still blocks"
git -C "$R" reset -q; rm -f "$R/src/big.ts"
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"

# NEW big file via add-chain must count against the size gate (codex round 2:
# measuring only tracked changes let 'git add big && commit' bypass the gate)
rm -f "$R/src/m.mts" "$R/src/c.astro"   # leftover ghost fixtures would grounding-block first
for i in $(seq 1 320); do echo "export const n$i = $i;"; done > "$R/src/new.ts"
runc2(){ printf '{"tool_input":{"command":"%s"},"cwd":"%s","session_id":"s1"}' "$1" "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" 2>"$TMP/err" >/dev/null; echo $?; }
ok "$(runc2 "git add src/new.ts && git commit -m x")" "2" "B4b-5 new big file via add-chain → size-block"
grep -q "zu groß" "$TMP/err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL B4b-5 wrong block reason: $(cat "$TMP/err")"; }
ok "$(runc2 "git add -A && git commit -m x")" "2" "B4b-6 new big file via add -A → size-block"
grep -q "zu groß" "$TMP/err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL B4b-6 wrong block reason: $(cat "$TMP/err")"; }
# a FOREIGN big untracked file not named in the command must NOT size-block (F6)
ok "$(runc2 "git add src/a.ts && git commit -m x")" "0" "B4b-7 foreign big untracked ignored"

# codex round 3: QUOTED path must count too (quote-aware add-paths extractor)
mv "$R/src/new.ts" "$R/src/big neu.ts"
ok "$(runc2 "git add \\\"src/big neu.ts\\\" && git commit -m x")" "2" "B4b-8 quoted big path → size-block"
grep -q "zu groß" "$TMP/err" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL B4b-8 wrong reason: $(cat "$TMP/err")"; }
rm -f "$R/src/big neu.ts"

# codex round 3: foreign big untracked file must not CAP-block a tiny add
for i in $(seq 1 900); do echo "export const q$i = $i;"; done > "$R/src/fremd.ts"
RC=$(printf '{"tool_input":{"command":"git add src/a.ts && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | VETO_GATE_CAP=2000 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)
ok "$RC" "0" "B4b-9 foreign untracked can't cap-block a path add"

# codex round 3: foreign big change to a TRACKED file must not size-block a path add
git -C "$R" add src/fremd.ts && git -C "$R" commit -qm fremd-baseline >/dev/null 2>&1 || true
for i in $(seq 1 900); do echo "export const q$i = $i + 1;"; done > "$R/src/fremd.ts"   # big UNSTAGED tracked change
ok "$(runc2 "git add src/a.ts && git commit -m x")" "0" "B4b-10 foreign tracked change not counted for path add"
git -C "$R" checkout -q -- src/fremd.ts 2>/dev/null || true
rm -f "$R/src/fremd.ts"

# B4c: bundle cap exceeded → cap-block "aufteilen" (was: fail-open)
printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
E=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | VETO_GATE_CAP=1 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" 2>&1 >/dev/null); RC=$?
ok "$RC" "2" "B4c cap exceeded → block"
case "$E" in *aufteilen*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL B4c message: $E";; esac
git -C "$R" reset -q

# --- B2: the MiniMax pre-reviewer stage --------------------------------------
# hermes is mocked as a plain script — no paid model call is ever made from a
# test, and there is no HTTP server to start, wait for and kill.
MMBIN="$TMP/hermes-mock"
minimax_mock(){ # $1 = what the fake hermes prints
  printf '#!/usr/bin/env bash\nprintf %s "$1"\n' "'$1'" > "$MMBIN"
  chmod +x "$MMBIN"; export VETO_GATE_HERMES_BIN="$MMBIN"
}

# B2-1: the pre-reviewer finds a blocking issue → block, codex is never consulted
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
minimax_mock '{"blocking":[{"id":"M1","claim":"kaputt","why":"w","fix":"f"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
E=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_FAIL" bash "$HOOK" 2>&1 >/dev/null); RC=$?
ok "$RC" "2" "B2-1 pre-reviewer blocking → block"
case "$E" in *"Vorprüfer (minimax)"*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL B2-1 message: $E";; esac

# B2-2: pre-reviewer clean → codex still decides
minimax_mock '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
ok "$(run "$MOCK_BLOCK")" "2" "B2-2 pre-reviewer clean → codex still blocks"
ok "$(run "$MOCK_CLEAN")" "0" "B2-2b pre-reviewer clean + codex clean → pass"

# B2-3: hermes missing → fail OPEN to codex, never a block on our own infra
export VETO_GATE_HERMES_BIN="$TMP/gibtsnicht"
ok "$(run "$MOCK_CLEAN")" "0" "B2-3 pre-reviewer unavailable → codex clean passes"

# B2-4: config "qwen": false still means "no pre-reviewer" (legacy switch)
minimax_mock '{"blocking":[{"id":"M1","claim":"kaputt","why":"w","fix":"f"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
printf '{"enabled":true,"effort":"high","qwen":false}\n' > "$R/.claude/config/veto-gate.json"
ok "$(run "$MOCK_CLEAN")" "0" "B2-4 pre-reviewer disabled in config → skipped"
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"
export VETO_GATE_HERMES_BIN="$TMP/gibtsnicht"


# --- E3: selectable prechecker (groq/gemini/none) -----------------------------
# groq and gemini ARE OpenAI-compatible HTTP endpoints, so they keep an HTTP mock
# on localhost; the env keys are the sanctioned localhost-only test seam.
QPORT=4099
http_mock(){ # $1 = message content; serves until killed (incl. /v1/models identity)
  python3 - "$1" "$QPORT" <<'HTTPPY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
content, port = sys.argv[1], int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self._send({"data": [{"id": "mock-model"}]})
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._send({"choices": [{"message": {"content": content}}]})
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
HTTPPY
  QSRV=$!; sleep 0.4
}
# E3-1: prechecker groq + blocking mock → groq-block, codex never consulted
http_mock '{"blocking":[{"id":"G1","claim":"kaputt","why":"w","fix":"f"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
printf '{"enabled":true,"effort":"high","prechecker":"groq"}\n' > "$R/.claude/config/veto-gate.json"
E=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://127.0.0.1:$QPORT/v1/chat/completions" \
    CODEX_BIN="$MOCK_FAIL" bash "$HOOK" 2>&1 >/dev/null); RC=$?
ok "$RC" "2" "E3-1 groq blocking → block"
case "$E" in *"Vorprüfer (groq)"*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL E3-1 message: $E";; esac
ok "$(tail -1 "$VETO_GATE_LOG_DIR/runs.jsonl" | jq -r .result)" "groq-block" "E3-1 result logged as groq-block"
kill "$QSRV" 2>/dev/null; wait "$QSRV" 2>/dev/null

# E3-2: prechecker gemini, adapter infra error (dead port) → fail open to codex
printf '{"enabled":true,"effort":"high","prechecker":"gemini"}\n' > "$R/.claude/config/veto-gate.json"
E=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | GEMINI_API_KEY=k VETO_GATE_GEMINI_URL="http://127.0.0.1:4098/nix" \
    CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1); RC=$?
ok "$RC" "0" "E3-2 gemini down → codex clean passes"

# E3-3: prechecker none → stage skipped entirely (blocking mock would block)
http_mock '{"blocking":[{"id":"G1","claim":"kaputt","why":"w","fix":"f"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
printf '{"enabled":true,"effort":"high","prechecker":"none"}\n' > "$R/.claude/config/veto-gate.json"
RC=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://127.0.0.1:$QPORT/v1/chat/completions" \
    CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)
ok "$RC" "0" "E3-3 prechecker none → skipped"

# E3-4: explicit prechecker beats the legacy qwen flag
printf '{"enabled":true,"effort":"high","prechecker":"qwen","qwen":false}\n' > "$R/.claude/config/veto-gate.json"
ok "$(run "$MOCK_FAIL")" "2" "E3-4 explicit qwen beats legacy qwen:false"
export VETO_GATE_HERMES_BIN="/nonexistent/hermes"   # hermetic: never a real paid call
export VETO_GATE_KREISEL_STOP=0   # this suite is a fixture farm, not one correction sequence
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"
kill "$QSRV" 2>/dev/null; wait "$QSRV" 2>/dev/null

# --- B5: plan review mode for md-only diffs ----------------------------------
# spy mock: records the bundle's REVIEW_PROMPT.md, answers clean
MOCK_SPY="$TMP/codex-spy"; cat > "$MOCK_SPY" <<EOF
#!/usr/bin/env bash
OUT=""; C=""
while [ \$# -gt 0 ]; do
  [ "\$1" = "-o" ] && { OUT="\$2"; shift 2; continue; }
  [ "\$1" = "-C" ] && { C="\$2"; shift 2; continue; }
  shift
done
cat > /dev/null
cp "\$C/REVIEW_PROMPT.md" "$TMP/seen-prompt" 2>/dev/null
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "\$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$MOCK_SPY"

# B5-1: md-only diff under the plan path + plan_review:true → plan prompt
printf '{"enabled":true,"effort":"high","plan_review":true}\n' > "$R/.claude/config/veto-gate.json"
mkdir -p "$R/docs/superpowers/plans"
git -C "$R" reset -q; printf 'Ein Plan.\n' > "$R/docs/superpowers/plans/docs-plan.md"
git -C "$R" add docs/superpowers/plans/docs-plan.md
rm -f "$TMP/seen-prompt"
ok "$(run "$MOCK_SPY")" "0" "B5-1 md-only plan run passes"
ok "$(grep -c 'SKIZZEN' "$TMP/seen-prompt" 2>/dev/null)" "1" "B5-1 plan paragraph in prompt"

# B5-1b: plan diffs NEVER reach the pre-reviewer — a blocking mock must not
# matter (this pins the stage order: PLAN_FLAG is decided before that stage)
minimax_mock '{"blocking":[{"id":"M1","claim":"skizze","why":"w","fix":"f"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
ok "$(run "$MOCK_SPY")" "0" "B5-1b plan diff skips the pre-reviewer entirely"
export VETO_GATE_HERMES_BIN="/nonexistent/hermes"   # hermetic: never a real paid call
export VETO_GATE_KREISEL_STOP=0   # this suite is a fixture farm, not one correction sequence

# B5-1c: md-only OUTSIDE the plan path (binding docs like CONVENTIONS) →
# normal mode (codex round 5: not every .md is a plan)
git -C "$R" reset -q; printf 'Regelwerk.\n' > "$R/CONVENTIONS.md"; git -C "$R" add CONVENTIONS.md
rm -f "$TMP/seen-prompt"
ok "$(run "$MOCK_SPY")" "0" "B5-1c md outside plan path passes"
ok "$(grep -c 'SKIZZEN' "$TMP/seen-prompt" 2>/dev/null)" "0" "B5-1c → normal mode"
git -C "$R" reset -q; rm -f "$R/CONVENTIONS.md"

# B5-1d: binding md PLUS a plan file → still normal mode (codex round 6:
# a small plan file must not downgrade the review of binding docs)
printf 'Regelwerk.\n' > "$R/CONVENTIONS.md"
git -C "$R" add CONVENTIONS.md docs/superpowers/plans/docs-plan.md
rm -f "$TMP/seen-prompt"
ok "$(run "$MOCK_SPY")" "0" "B5-1d mixed md passes"
ok "$(grep -c 'SKIZZEN' "$TMP/seen-prompt" 2>/dev/null)" "0" "B5-1d plan file can't downgrade binding docs"
git -C "$R" reset -q; rm -f "$R/CONVENTIONS.md"

# B5-1e: plan_path is a directory PREFIX, not a regex/pattern (codex round 7:
# 'docs/plans' must not match 'docs/plans-private.md')
printf '{"enabled":true,"effort":"high","plan_review":true,"plan_path":"docs/plans"}\n' > "$R/.claude/config/veto-gate.json"
mkdir -p "$R/docs/plans"
git -C "$R" reset -q; printf 'Privat.\n' > "$R/docs/plans-private.md"; git -C "$R" add docs/plans-private.md
rm -f "$TMP/seen-prompt"
ok "$(run "$MOCK_SPY")" "0" "B5-1e prefix-lookalike passes"
ok "$(grep -c 'SKIZZEN' "$TMP/seen-prompt" 2>/dev/null)" "0" "B5-1e lookalike outside plan dir → normal"
git -C "$R" reset -q; rm -f "$R/docs/plans-private.md"
printf 'Plan.\n' > "$R/docs/plans/x.md"; git -C "$R" add docs/plans/x.md
rm -f "$TMP/seen-prompt"
ok "$(run "$MOCK_SPY")" "0" "B5-1e2 real plan dir passes"
ok "$(grep -c 'SKIZZEN' "$TMP/seen-prompt" 2>/dev/null)" "1" "B5-1e2 slashless plan_path still works"
git -C "$R" reset -q; rm -f "$R/docs/plans/x.md"
printf '{"enabled":true,"effort":"high","plan_review":true}\n' > "$R/.claude/config/veto-gate.json"

# B5-2: plan_review absent → normal prompt even for plan-path md
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"
git -C "$R" add docs/superpowers/plans/docs-plan.md
rm -f "$TMP/seen-prompt"
ok "$(run "$MOCK_SPY")" "0" "B5-2 md-only without plan_review passes"
ok "$(grep -c 'SKIZZEN' "$TMP/seen-prompt" 2>/dev/null)" "0" "B5-2 no plan paragraph"

# B5-3: mixed diff (md + code) + plan_review:true → normal mode
printf '{"enabled":true,"effort":"high","plan_review":true}\n' > "$R/.claude/config/veto-gate.json"
printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
rm -f "$TMP/seen-prompt"
ok "$(run "$MOCK_SPY")" "0" "B5-3 mixed diff passes"
ok "$(grep -c 'SKIZZEN' "$TMP/seen-prompt" 2>/dev/null)" "0" "B5-3 mixed diff → no plan paragraph"
git -C "$R" reset -q; rm -f "$R/docs/superpowers/plans/docs-plan.md"

# B5-4: md change + DELETED code file → normal mode (codex live finding:
# a deletion shows as '+++ /dev/null', only its '--- a/' side names the file)
printf 'export const weg = 1;\n' > "$R/src/weg.ts"
git -C "$R" add src/weg.ts && git -C "$R" commit -qm tmp-baseline --no-verify >/dev/null 2>&1
printf 'Ein Plan.\n' > "$R/docs/superpowers/plans/docs-plan.md"
git -C "$R" rm -q src/weg.ts && git -C "$R" add docs/superpowers/plans/docs-plan.md
rm -f "$TMP/seen-prompt"
ok "$(run "$MOCK_SPY")" "0" "B5-4 md+deletion passes"
ok "$(grep -c 'SKIZZEN' "$TMP/seen-prompt" 2>/dev/null)" "0" "B5-4 deletion forces normal mode"
git -C "$R" reset -q; rm -f "$R/docs/superpowers/plans/docs-plan.md"
git -C "$R" checkout -q -- src/weg.ts 2>/dev/null || true

# B5-5: PURE md deletion under the plan path is still a plan diff (codex round 2)
printf 'Alter Plan.\n' > "$R/docs/superpowers/plans/old-plan.md"
git -C "$R" add docs/superpowers/plans/old-plan.md && git -C "$R" commit -qm tmp-md-baseline --no-verify >/dev/null 2>&1
git -C "$R" rm -q docs/superpowers/plans/old-plan.md
rm -f "$TMP/seen-prompt"
ok "$(run "$MOCK_SPY")" "0" "B5-5 md deletion passes"
ok "$(grep -c 'SKIZZEN' "$TMP/seen-prompt" 2>/dev/null)" "1" "B5-5 md deletion → plan mode"
git -C "$R" reset -q
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"

# commit -a with the flag AFTER other options must still be recognized
# (isolated auditor finding: 'git commit -m x -a' had an empty index at
# PreToolUse time, --cached was empty, the gate waved everything through)
git -C "$R" reset -q
git -C "$R" add src/b.ts 2>/dev/null; git -C "$R" commit -qm seed --no-verify >/dev/null 2>&1 || true
printf "export const b=1;\nimport { ghost } from './ghost';\n" > "$R/src/b.ts"   # unstaged tracked change
ok "$(printf '{"tool_input":{"command":"git commit -m x -a"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-1 commit -m x -a → grounding block"
ok "$(printf '{"tool_input":{"command":"git commit --dry-run --all -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-1b late --all → grounding block"
# control: --author=x must NOT count as -a (no false COMMIT_ALL)
git -C "$R" checkout -q -- src/b.ts 2>/dev/null || true
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(printf '{"tool_input":{"command":"git commit -m x --author=T <t@t.t>"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-1c --author not misread as -a"
# controls (codex round on the fix): unstaged ghost in a tracked file must
# NOT false-block when -a is (1) the VALUE of -m, (2) in the NEXT line's
# command, (3) a path after '--' — none of these are commit-all
printf "export const b=1;\nimport { ghost } from './ghost';\n" > "$R/src/b.ts"   # unstaged ghost
ok "$(printf '{"tool_input":{"command":"git commit -m -a"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-1d -a as -m value ignored"
ok "$(printf '{"tool_input":{"command":"git commit -m x\\nls -a"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-1e -a on next line ignored"
ok "$(printf '{"tool_input":{"command":"git commit -m x -- -a"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-1f -a after dashdash ignored"
ok "$(printf '{"tool_input":{"command":"git commit --amend -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-1g --amend not misread as -a"
ok "$(printf '{"tool_input":{"command":"git commit --allow-empty -mabc"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-1h attached -mabc value ignored"
ok "$(printf '{"tool_input":{"command":"git commit -ma"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-1i -ma is -m with value a"
ok "$(printf '{"tool_input":{"command":"git commit -m x\\\\ -a"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-1j escaped-space message not a flag"
# positive control: combined -am must still count as commit-all
ok "$(printf '{"tool_input":{"command":"git commit -am x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-1k -am still commit-all"
# escaped separator inside the message must not cut the flag scan short
# ('git commit -m x\; -a' IS commit-all — codex round on the fix)
ok "$(printf '{"tool_input":{"command":"git commit -m x\\\\; -a"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-1l escaped semicolon then -a → commit-all"
# line continuation keeps the flag on the same logical command
ok "$(printf '{"tool_input":{"command":"git commit -m x \\\\\\n-a"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-1m line continuation then -a → commit-all"
# a SECOND commit later in the same line may carry the -a (codex round:
# only the first structural match was flag-scanned)
ok "$(printf '{"tool_input":{"command":"git commit -m x; git commit -a -m y"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-1n second commit carries -a → commit-all"
# perl failure must not blind the -a scan (fallback to the raw span)
ok "$(printf '{"tool_input":{"command":"git commit -m x -a"},"cwd":"%s","session_id":"s1"}' "$R" \
  | VETO_GATE_NO_PERL=1 CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-1o -a scan survives missing perl"

# pins auditor-2 refutation: grep scans line-wise, '^' matches after a real
# newline — an add chained by newline IS recognized (grounding must block)
git -C "$R" reset -q; printf "import { ghost } from './ghost';\n" > "$R/src/a.ts"
ok "$(printf '{"tool_input":{"command":"git add src/a.ts\\ngit commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2b newline add-chain still detected"
printf "import { b } from './b';\n" > "$R/src/a.ts"

# auditor-2 finding: 'git add <path> && git commit -am x' must NOT pull a
# foreign untracked file into the review (commit -a never takes untracked;
# the add named one path) — neither size-block nor bundle content
git -C "$R" reset -q
git -C "$R" checkout -q -- . 2>/dev/null || true   # clean tree: -a WOULD take any tracked mod/deletion
printf "import { b } from './b';\n" > "$R/src/a.ts"
for i in $(seq 1 900); do echo "export const q$i = $i;"; done > "$R/src/fremd2.ts"   # untracked, never added
ok "$(printf '{"tool_input":{"command":"git add src/a.ts && git commit -am x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-2a -am + path add: foreign untracked ignored"
rm -f "$R/src/fremd2.ts"
# ...but the file the add DOES name must still reach grounding despite -am
printf "import { ghost } from './ghost';\n" > "$R/src/neu2.ts"
ok "$(printf '{"tool_input":{"command":"git add src/neu2.ts && git commit -am x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2c -am + named new file still grounded"
# directory add with trailing slash must match its children (codex round:
# 'git add src/ && commit' left new files under src/ unchecked)
ok "$(printf '{"tool_input":{"command":"git add src/ && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2d dir add with slash grounds children"
# unparseable add args (substitution) → conservative superset still grounds
# new files (codex round: fallback must behave like all for appending)
ok "$(printf '{"tool_input":{"command":"git add $(echo src/neu2.ts) && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2e substitution add falls back to superset"
# git add -u stages tracked changes only → a foreign untracked ghost file
# must NOT be pulled into the review (codex round)
ok "$(printf '{"tool_input":{"command":"git add -u && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-2f add -u ignores untracked ghost"
ok "$(printf '{"tool_input":{"command":"git add -u src/ && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-2g add -u with pathspec ignores untracked ghost"
rm -f "$R/src/neu2.ts"
# variable add: fallback semantics — foreign untracked code must not COUNT
# against size (F6 rule per CONVENTIONS), while grounding still sees all
for i in $(seq 1 900); do echo "export const q$i = $i;"; done > "$R/src/fremd3.ts"
ok "$(printf '{"tool_input":{"command":"git add $FILES && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-2i var add: foreign untracked not size-counted"
rm -f "$R/src/fremd3.ts"
# ...and the visible-name check is TOKEN-wise: a one-letter foreign file
# named 'a' must not count just because 'add' contains the letter (codex)
for i in $(seq 1 900); do echo "export const q$i = $i;"; done > "$R/a"
ok "$(printf '{"tool_input":{"command":"git add $FILES && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-2j substring letter not size-counted"
rm -f "$R/a"
# ...and foreign TRACKED changes must not size-count in the fallback either
# (codex: size measures the index there, review still sees the superset)
printf 'export const b=1;\n' > "$R/src/b.ts"   # ensure clean baseline
git -C "$R" checkout -q -- . 2>/dev/null || true
for i in $(seq 1 900); do echo "export const w$i = $i;"; done > "$R/src/fremd.ts"   # tracked, unstaged big mod
ok "$(printf '{"tool_input":{"command":"git add $FILES && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-2k fallback: foreign tracked mod not size-counted"
git -C "$R" checkout -q -- src/fremd.ts 2>/dev/null || true
# ...but a big change SAFELY NAMED next to the \$VAR add still counts
# (codex: safe paths survive beside ::VAR:: for the size measurement)
for i in $(seq 1 320); do echo "export const f$i = $i;"; done > "$R/src/fremd.ts"   # tracked big mod, named below
ok "$(printf '{"tool_input":{"command":"git add src/fremd.ts && git add $FILES && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2l named big file beside var add size-counted"
git -C "$R" checkout -q -- src/fremd.ts 2>/dev/null || true
# add -u with a variable: review wide, size narrow — foreign tracked big
# mod must not block (codex round)
for i in $(seq 1 900); do echo "export const w$i = $i;"; done > "$R/src/fremd.ts"
ok "$(printf '{"tool_input":{"command":"git add -u $FILES && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-2m -u var: foreign tracked mod not size-counted"
git -C "$R" checkout -q -- src/fremd.ts 2>/dev/null || true
# -u var + safe add: the REVIEW must stay wide (a $FILES -u can stage any
# tracked file — its ghost must still block), size stays narrow (codex)
printf "export const b=1;\nimport { ghost } from './ghost';\n" > "$R/src/b.ts"
ok "$(printf '{"tool_input":{"command":"git add -u $FILES && git add src/a.ts && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2o -u var + safe add reviews wide"
git -C "$R" checkout -q -- src/b.ts 2>/dev/null || true
# bare -u beside a var add REALLY stages all tracked mods → they size-count
for i in $(seq 1 900); do echo "export const w$i = $i;"; done > "$R/src/fremd.ts"
ok "$(printf '{"tool_input":{"command":"git add -u && git add $FILES && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2p bare -u beside var add size-counts tracked"
git -C "$R" checkout -q -- src/fremd.ts 2>/dev/null || true
# -u pathspec beside a var add: NEW files under the -u path never count
# (add -u takes no untracked; codex round)
mkdir -p "$R/src"; for i in $(seq 1 320); do echo "export const n$i = $i;"; done > "$R/src/neu5.ts"
ok "$(printf '{"tool_input":{"command":"git add -u src/ && git add $FILES && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-2q -u pathspec never counts new files"
rm -f "$R/src/neu5.ts"
# commit -am beside a var add really stages tracked mods → they size-count
# even in the narrow mode (codex round)
for i in $(seq 1 900); do echo "export const w$i = $i;"; done > "$R/src/fremd.ts"
ok "$(printf '{"tool_input":{"command":"git add $FILES && git commit -am x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2r var add + commit -a size-counts tracked"
git -C "$R" checkout -q -- src/fremd.ts 2>/dev/null || true
# no double counting: a STAGED 200-line change that is ALSO safely named
# must count once, not twice (codex round: overlap false-blocked at 300)
printf '{"enabled":true,"max_lines":300}\n' > "$R/.claude/config/veto-gate.json"
printf 'export const d0 = 0;\n' > "$R/src/d200.ts"
git -C "$R" add src/d200.ts && git -C "$R" commit -qm d200-base --no-verify >/dev/null 2>&1
for i in $(seq 1 200); do echo "export const d$i = $i;"; done > "$R/src/d200.ts"
git -C "$R" add src/d200.ts
ok "$(printf '{"tool_input":{"command":"git add src/d200.ts $FILES && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0" "AUDIT-2s staged+named counts once"
git -C "$R" reset -q; git -C "$R" checkout -q -- src/d200.ts 2>/dev/null || true
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"
# QUOTED big new file beside a var add still counts (parsed paths cover
# quoted names — the blanked-command grep could not, codex round)
for i in $(seq 1 320); do echo "export const g$i = $i;"; done > "$R/src/big neu.ts"
ok "$(printf '{"tool_input":{"command":"git add \\\"src/big neu.ts\\\" && git add $F && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2n quoted big file beside var add size-counted"
rm -f "$R/src/big neu.ts"

# -u pathspec changes DO scope the tracked diff: a tracked ghost mod under
# src/ must still block when '-u src/' takes it (codex round)
printf "export const b=1;\nimport { ghost } from './ghost';\n" > "$R/src/b.ts"   # tracked mod, unstaged
ok "$(printf '{"tool_input":{"command":"git add -u src/ && git add docs-x.md && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)" "2" "AUDIT-2h -u pathspec scopes tracked diff"
git -C "$R" checkout -q -- src/b.ts 2>/dev/null || true
git -C "$R" checkout -q -- src/b.ts 2>/dev/null || true

# T-SEP: a commit that ENDS at a shell separator must still be detected. `git commit;`
# and `(git commit)` matched nothing, so the hook exited 0 and the commit was never
# reviewed — the detector, not the reviewer, was the hole.
git -C "$R" reset -q; printf "import { nope } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
printf '{"tool_input":{"command":"git commit -m x;"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_BLOCK" bash "$HOOK" >/dev/null 2>&1
ok "$?" "2" "T-SEP `git commit;` is gated, not waved through"
printf '{"tool_input":{"command":"( git commit -m x )"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_BLOCK" bash "$HOOK" >/dev/null 2>&1
ok "$?" "2" "T-SEP a grouped commit is gated too"
# glued to the bracket, at line start and mid-line — both structural, both gated
printf '{"tool_input":{"command":"(git commit -m x)"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_BLOCK" bash "$HOOK" >/dev/null 2>&1
ok "$?" "2" "T-SEP a glued (git commit is gated"
printf '{"tool_input":{"command":"git add -A && (git commit -m x)"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_BLOCK" bash "$HOOK" >/dev/null 2>&1
ok "$?" "2" "T-SEP a glued (git commit mid-line is gated"
# …but an ESCAPED bracket is text, not a group — that must not become a false block
printf '{"tool_input":{"command":"echo \\\\(git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_BLOCK" bash "$HOOK" >/dev/null 2>&1
ok "$?" "0" "T-SEP an escaped bracket is text, not a commit"
git -C "$R" reset -q; printf 'export const b=1;\n' > "$R/src/a.ts"

# --- B7: quota countdown gate -------------------------------------------------
# future reset → quota-block in seconds, message names the reset time
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
FUT=$(python3 -c 'import time;print(int(time.time())+1800)')
printf '{"reset_epoch":%s,"reset_at":"17:28","msg":"usage limit","ts":"x"}' "$FUT" > "$VETO_GATE_LOG_DIR/quota.json"
T0=$(date +%s)
E=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" 2>&1 >/dev/null); RC=$?
D=$(( $(date +%s) - T0 ))
ok "$RC" "2" "B7-1 closed window → quota-block"
case "$E" in *"Fenster zu bis 17:28"*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL B7-1 message: $E";; esac
[ "$D" -lt 10 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL B7-1 slow (${D}s)"; }
# …and no reading work is booked: the bundle was built, but codex never got it.
# A size here would show a read bundle nobody ever received (codex find).
ok "$(jq -r 'has("bundle_tokens")' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "false" "B7-1 quota-block books no reading work"

# elapsed reset → file cleared, review proceeds normally
printf '{"reset_epoch":1,"reset_at":"00:00","msg":"old","ts":"x"}' > "$VETO_GATE_LOG_DIR/quota.json"
ok "$(run "$MOCK_CLEAN")" "0" "B7-2 elapsed window → normal pass"
[ ! -f "$VETO_GATE_LOG_DIR/quota.json" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL B7-2 stale file not cleared"; }

# malformed quota.json → ignored, review proceeds (never blocks on garbage)
printf 'kaputt{' > "$VETO_GATE_LOG_DIR/quota.json"
ok "$(run "$MOCK_CLEAN")" "0" "B7-3 broken quota.json ignored"
rm -f "$VETO_GATE_LOG_DIR/quota.json"

# --- E3.5: gate mirrors its lifecycle into the repo status bar ---------------
# writes land in the FIXTURE repo's .claude/status/state.json (hermetic)
rm -f "$R/.claude/status/state.json"
run "$MOCK_BLOCK" >/dev/null
ok "$(jq -r '.gate.stage' "$R/.claude/status/state.json" 2>/dev/null)" "block" "E3.5 block mirrored to bar"
ok "$(jq -r '.gate.plan' "$R/.claude/status/state.json" 2>/dev/null)" "false" "E3.5 normal run → plan=false"
run "$MOCK_CLEAN" >/dev/null
ok "$(jq -r '.gate.stage' "$R/.claude/status/state.json" 2>/dev/null)" "pass" "E3.5 pass mirrored to bar"
TS=$(jq -r '.gate.ts' "$R/.claude/status/state.json" 2>/dev/null)
NOW=$(date +%s); [ "$TS" -gt $((NOW-60)) ] 2>/dev/null && [ "$TS" -le "$NOW" ] 2>/dev/null \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: E3.5 gate.ts fresh (got '$TS')"; }

# ── the evidence ledger ────────────────────────────────────────────────────
# T-LEDGER: every gate run leaves notes, and a clean run records the stages it ran.
: > "$VETO_GATE_LOG_DIR/runs.jsonl"
run "$MOCK_CLEAN" >/dev/null
PJ=$(jq -c '.proofs' "$VETO_GATE_LOG_DIR/runs.jsonl" 2>/dev/null | tail -1)
for st in size grounding prechecker codex; do
  ok "$(printf '%s' "$PJ" | jq -e --arg s "$st" 'any(.[]; .stage==$s)' >/dev/null 2>&1; echo $?)" \
     "0" "T-LEDGER stage '$st' left a note"
done
# the dead pre-reviewer (port 4/nix, hermetic) must show up as a GAP — not as silence.
# Before this it could have been down for weeks and nothing would have said so.
ok "$(printf '%s' "$PJ" | jq -r '.[] | select(.stage=="prechecker") | .status')" \
   "unavailable" "T-LEDGER dead pre-reviewer is a visible gap"
ok "$(jq -r '.result' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" "codex-pass" "T-LEDGER a gap still passes the commit"

# a BLOCKED run carries its notes too — otherwise the log shows a block with no reason
: > "$VETO_GATE_LOG_DIR/runs.jsonl"
run "$MOCK_BLOCK" >/dev/null
ok "$(jq -r '.proofs[] | select(.stage=="codex") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "fail" "T-LEDGER a blocked run records WHY it blocked"

# T-LEDGER-BROKEN: if the ledger cannot be written at all, the gate must STOP — not sail
# through. A run with zero recorded checks looks exactly like a run where everything passed,
# and that confusion is the whole disease. Real infra failure, not a stub: a read-only dir.
RO="$TMP/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
ERR="$TMP/broken.err"
RC=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
      | CODEX_BIN="$MOCK_CLEAN" VETO_GATE_LOG_DIR="$RO/nope" bash "$HOOK" >/dev/null 2>"$ERR"; echo $?)
ok "$RC" "2" "T-LEDGER-BROKEN unwritable ledger → commit blocked, not waved through"
# and blocked for THIS reason, not by accident through some other stage: an exit code alone
# would have let a timeout masquerade as the ledger doing its job.
if grep -q 'Beweis-Zettel' "$ERR"; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "FAIL: T-LEDGER-BROKEN must block on the LEDGER, got: $(head -1 "$ERR")"; fi
chmod 700 "$RO"

# the ledger's working file is cleaned up: one file per run, and nobody ever deletes them
ok "$(ls "$VETO_GATE_LOG_DIR"/proofs-*.jsonl 2>/dev/null | wc -l | tr -d ' ')" "0" \
   "T-LEDGER no leftover proof files after the run"

# ── Sorte C: the tests run inside the gate ─────────────────────────────────
# T-TESTS: red tests BLOCK the commit. This is the stage that catches code which compiles, runs,
# and does the wrong thing — the one thing no amount of reading can find.
TR="$TMP/testrepo"; mkdir -p "$TR/.claude/config"
git -C "$TR" init -q; git -C "$TR" config user.email t@t.t; git -C "$TR" config user.name t
printf '{"enabled":true,"prechecker":"none"}\n' > "$TR/.claude/config/veto-gate.json"
echo 'node_modules/' > "$TR/.gitignore"
mkdir -p "$TR/node_modules/.bin"
cat > "$TR/node_modules/.bin/jest" <<'B'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--listTests" ] && { echo "/x/a.test.ts"; exit 0; }; done
exit ${FAKE_JEST_RC:-0}
B
chmod +x "$TR/node_modules/.bin/jest"
cat > "$TR/package.json" <<'J'
{"name":"tr","scripts":{"test:unit":"jest"}}
J
git -C "$TR" add -A >/dev/null 2>&1; git -C "$TR" commit -qm init >/dev/null 2>&1
export VETO_GATE_TEST_ALLOWLIST="$TMP/allowlist"; (cd "$TR" && pwd -P) > "$VETO_GATE_TEST_ALLOWLIST"
echo 'export const a = 1;' > "$TR/a.ts"; git -C "$TR" add a.ts >/dev/null 2>&1

run_tr(){ printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$TR" \
  | CODEX_BIN="$1" FAKE_JEST_RC="${2:-0}" bash "$HOOK" >/dev/null 2>&1; echo $?; }

ok "$(run_tr "$MOCK_CLEAN" 1)" "2" "T-TESTS red tests block the commit"
ok "$(jq -r '.result' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" "tests-block" "T-TESTS the block is logged as such"
ok "$(run_tr "$MOCK_CLEAN" 0)" "0" "T-TESTS green tests let it through"
ok "$(jq -r '.proofs[] | select(.stage=="tests") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "pass" "T-TESTS the ledger records the test run"

# T-TESTS-ADD (codex): `git add x && git commit` runs BEFORE the add — the index still holds the
# OLD content of x. Testing the index would prove nothing about the commit that is about to happen.
# The gate hands run-tests its own file list and says: take the WORKING TREE of these.
cat > "$TR/node_modules/.bin/jest" <<'B'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--listTests" ] && { echo "/x/a.test.ts"; exit 0; }; done
grep -q KAPUTT a.ts && exit 1      # red exactly when the NEW content is the one tested
exit 0
B
chmod +x "$TR/node_modules/.bin/jest"
echo 'export const a = 1;' > "$TR/a.ts"; git -C "$TR" add a.ts >/dev/null 2>&1   # good, in the INDEX
echo 'export const a = "KAPUTT";' > "$TR/a.ts"                                   # broken, only in the tree
RC=$(printf '{"tool_input":{"command":"git add a.ts && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$TR" \
      | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" >/dev/null 2>&1; echo $?)
ok "$RC" "2" "T-TESTS-ADD an add-chain tests what will be committed, not the stale index"
echo 'export const a = 1;' > "$TR/a.ts"; git -C "$TR" add a.ts >/dev/null 2>&1

# T-TESTS-SPOOF (codex): a file's own CONTENT must never be able to switch the tests off. A line
# "++ b/package.json" inside a file shows up in the diff as "+++ b/package.json" — read as a
# filename, it makes the gate believe the test machinery changed, and the whole stage stands down.
cat > "$TR/node_modules/.bin/jest" <<'B'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "--listTests" ] && { echo "/x/a.test.ts"; exit 0; }; done
exit 1
B
chmod +x "$TR/node_modules/.bin/jest"
printf 'export const a = 1;\n// ++ b/package.json\n' > "$TR/a.ts"
git -C "$TR" add a.ts >/dev/null 2>&1
ok "$(run_tr "$MOCK_CLEAN")" "2" "T-TESTS-SPOOF a file cannot disarm the test stage with its own text"
echo 'export const a = 1;' > "$TR/a.ts"; git -C "$TR" add a.ts >/dev/null 2>&1

# a repo that is NOT allowed to run its tests still commits — but the gap is LOUD
: > "$VETO_GATE_TEST_ALLOWLIST"
ok "$(run_tr "$MOCK_CLEAN" 0)" "0" "T-TESTS an unlisted repo still commits"
ok "$(jq -r '.proofs[] | select(.stage=="tests") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "unavailable" "T-TESTS …and the missing permission is a visible gap"
unset VETO_GATE_TEST_ALLOWLIST

# ── effort by size ─────────────────────────────────────────────────────────
# Measured on 2026-07-14: 220 gate runs, average diff 2.7 files, every one of them reviewed in the
# most expensive thinking mode. Four parallel sessions then queued behind the same reviewer and each
# run slowed the others down (96s alone → 167s at four → 488s at six). A small diff does not need
# 'high'; spending it there is what made the queue.
MOCK_ARGS="$TMP/codex-args"; MOCK_SPY="$TMP/codex-spy"
cat > "$MOCK_SPY" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_ARGS_OUT"
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$MOCK_SPY"
spy_effort(){ CODEX_ARGS_OUT="$MOCK_ARGS" run "$MOCK_SPY" >/dev/null
  grep -A1 -- '-c' "$MOCK_ARGS" | grep 'model_reasoning_effort' | sed 's/.*=//'; }

printf 'export const klein = 1;\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts >/dev/null 2>&1
ok "$(spy_effort)" "medium" "T-EFFORT a small diff is reviewed with 'medium', not 'high'"

# a big diff still gets the expensive mode — that is where it earns its keep
: > "$R/src/a.ts"
i=0; while [ $i -lt 120 ]; do echo "export const v$i = $i;" >> "$R/src/a.ts"; i=$((i+1)); done
git -C "$R" add src/a.ts >/dev/null 2>&1
ok "$(spy_effort)" "high" "T-EFFORT a big diff keeps 'high'"

# and it only ever goes DOWN: a repo configured to 'medium' is never silently upgraded
printf '{"enabled":true,"effort":"medium"}\n' > "$R/.claude/config/veto-gate.json"
printf 'export const klein = 1;\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts >/dev/null 2>&1
ok "$(spy_effort)" "medium" "T-EFFORT the configured effort is a ceiling, never raised"
# T-EFFORT-OFF (codex): the off-switch must actually switch it off. `.effort_auto // true` in jq
# hands back TRUE for a stored FALSE — it treats false like "not set" — so a repo that insists on
# 'high' would have been quietly downgraded anyway. A knob that does nothing is worse than no knob.
printf '{"enabled":true,"effort":"high","effort_auto":false}\n' > "$R/.claude/config/veto-gate.json"
printf 'export const klein = 1;\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts >/dev/null 2>&1
ok "$(spy_effort)" "high" "T-EFFORT effort_auto:false really keeps 'high' on a small diff"
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"

# the ledger records WHICH mode was used — otherwise nobody can ever measure whether this helped
ok "$(jq -r '.proofs[] | select(.stage=="codex") | .detail' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1 | grep -c 'effort=')" \
   "1" "T-EFFORT the run log says which thinking mode was spent"

# ── A1: codex asks for a file he needs (context_requests) ──────────────────
# His answer schema has carried the field from day one and the gate ignored it. He said
# "I need db.ts to judge this", nobody listened, and he had to guess about exactly the
# code he could not see. db.ts is COMMITTED here, not touched — so it is not in the
# bundle, and round 1 is genuinely blind.
AR="$TMP/askrepo"; mkdir -p "$AR/src" "$AR/.claude/config"
git -C "$AR" init -q; git -C "$AR" config user.email t@t.t; git -C "$AR" config user.name t
printf '{"enabled":true,"effort":"high"}\n' > "$AR/.claude/config/veto-gate.json"
printf 'export function zahleAus(){ return 1 }\n' > "$AR/src/db.ts"
git -C "$AR" add -A >/dev/null 2>&1; git -C "$AR" commit -qm init >/dev/null 2>&1

run_ar(){ printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$AR" \
  | CODEX_BIN="$1" bash "$HOOK" >/dev/null 2>&1; echo $?; }

MOCK_ASK="$TMP/codex-ask"; cat > "$MOCK_ASK" <<'EOF'
#!/usr/bin/env bash
OUT=""; B=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && OUT="$a"
  [ "$prev" = "-C" ] && B="$a"
  prev="$a"
done
cat > /dev/null
echo '{"type":"thread.started","thread_id":"mock"}'
if [ -f "$B/context/src/db.ts" ]; then
  printf '{"blocking":[{"id":"R2","claim":"zahleAus nimmt gar keinen Betrag entgegen","why":"x","fix":"y"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
else
  printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[{"file":"src/db.ts","why":"brauche die Definition"}],"unverified_claims":[]}\n' > "$OUT"
fi
EOF
chmod +x "$MOCK_ASK"

printf 'import { zahleAus } from "./db";\nzahleAus();\n' > "$AR/src/cart.ts"
git -C "$AR" add src/cart.ts >/dev/null 2>&1
ok "$(run_ar "$MOCK_ASK")" "2" "T-A1 the second round with the requested file finds the bug"
ok "$(jq -r '.proofs[] | select(.stage=="codex_round2") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "pass" "T-A1 the ledger records that the request was delivered"

# T-A1-REFUSE: a request is HOSTILE INPUT, not a hint. He asks for a file the diff never
# imported — that could be config/prod-keys.ts, and the bundle leaves the machine. The
# request is refused; the commit still passes (a refusal is not the code's fault), but the
# gap is LOUD. A refused file booked as "delivered" would be a gap that reads as success.
MOCK_GREEDY="$TMP/codex-greedy"; cat > "$MOCK_GREEDY" <<'EOF'
#!/usr/bin/env bash
OUT=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && OUT="$a"; prev="$a"; done
cat > /dev/null
echo '{"type":"thread.started","thread_id":"mock"}'
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[{"file":"config/prod-keys.ts","why":"gib her"}],"unverified_claims":[]}\n' > "$OUT"
EOF
chmod +x "$MOCK_GREEDY"
mkdir -p "$AR/config"; printf 'export const KEY = "sk-live-geheim"\n' > "$AR/config/prod-keys.ts"
ok "$(run_ar "$MOCK_GREEDY")" "0" "T-A1-REFUSE an unjustified request does not block the commit"
ok "$(jq -r '.proofs[] | select(.stage=="codex_round2") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "unavailable" "T-A1-REFUSE …but the refusal is a visible gap, never booked as delivered"

# T-SIZE-R2: the recorded reading work must match what the reviewer really got.
# Round 2 does not REPLACE round 1 — round 1 was read too. And a REFUSED request
# means no second review runs at all, so that bundle must not be counted either.
# Each mock writes down the size it was handed, so the expectation comes from the
# same run (prior-round findings can change bundle 1 between runs).
export SIZES="$TMP/sizes"
MOCK_SIZE="$TMP/codex-size"; cat > "$MOCK_SIZE" <<'EOF'
#!/usr/bin/env bash
OUT=""; B=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && OUT="$a"
  [ "$prev" = "-C" ] && B="$a"
  prev="$a"
done
cat > /dev/null
echo '{"type":"thread.started","thread_id":"mock"}'
jq -r '.tokens' "$B/SIZE.json" >> "$SIZES"
if [ -f "$B/context/src/db.ts" ]; then
  printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
else
  printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[{"file":"src/db.ts","why":"brauche die Definition"}],"unverified_claims":[]}\n' > "$OUT"
fi
EOF
chmod +x "$MOCK_SIZE"
: > "$SIZES"
run_ar "$MOCK_SIZE" >/dev/null
ok "$(wc -l < "$SIZES" | tr -d ' ')" "2" "T-SIZE-R2 the reviewer really saw two rounds"
ok "$(jq -r '.bundle_tokens' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "$(awk '{s+=$1} END{print s}' "$SIZES")" "T-SIZE-R2 both rounds counted, round 1 not dropped"

# …and a refused request adds nothing: no second review took place
MOCK_SIZE_GREEDY="$TMP/codex-size-greedy"; cat > "$MOCK_SIZE_GREEDY" <<'EOF'
#!/usr/bin/env bash
OUT=""; B=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && OUT="$a"
  [ "$prev" = "-C" ] && B="$a"
  prev="$a"
done
cat > /dev/null
echo '{"type":"thread.started","thread_id":"mock"}'
jq -r '.tokens' "$B/SIZE.json" >> "$SIZES"
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[{"file":"config/prod-keys.ts","why":"gib her"}],"unverified_claims":[]}\n' > "$OUT"
EOF
chmod +x "$MOCK_SIZE_GREEDY"
: > "$SIZES"
run_ar "$MOCK_SIZE_GREEDY" >/dev/null
ok "$(wc -l < "$SIZES" | tr -d ' ')" "1" "T-SIZE-R2b only one round ran"
ok "$(jq -r '.bundle_tokens' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "$(awk '{s+=$1} END{print s}' "$SIZES")" "T-SIZE-R2b a refused request adds nothing"
# …and if ONE round's size is missing, the field is dropped entirely. An
# incomplete sum would report less reading than happened and could explain a
# timeout away — absent is honest, too small is not.
: > "$SIZES"
export VETO_GATE_NO_SIZE=round2
run_ar "$MOCK_SIZE" >/dev/null
unset VETO_GATE_NO_SIZE
# the mock cannot count this round via $SIZES — its own size note is the one
# missing — so the ledger's own round-2 note proves the second review happened
ok "$(jq -r '.proofs[] | select(.stage=="codex_round2") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "pass" "T-SIZE-R2c the second round really ran"
ok "$(jq -r 'has("bundle_tokens")' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "false" "T-SIZE-R2c one missing round size drops the field, never an understated sum"

# T-SIZE-R2d: a MALFORMED size must not be fed to arithmetic. Measured: `$(( 0 + 1.5 ))`
# does not just fail, it kills the shell — the gate would die before writing its entry.
: > "$SIZES"
export VETO_GATE_NO_SIZE=bad2
run_ar "$MOCK_SIZE" >/dev/null
unset VETO_GATE_NO_SIZE
ok "$(jq -r '.proofs[] | select(.stage=="codex_round2") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "pass" "T-SIZE-R2d the run survives a malformed size and still logs"
ok "$(jq -r 'has("bundle_tokens")' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "false" "T-SIZE-R2d …and books no size at all"
unset SIZES

# T-A1-DEAD (codex): round 1 said itself that it lacked the file — its "no findings" was
# given under reservation. If round 2 then dies (quota, timeout), NOBODY has judged this
# diff. Codex is the one stage that is fail-closed, so this blocks; a gap note would wave
# through code that was never reviewed.
MOCK_DEAD="$TMP/codex-dead"; cat > "$MOCK_DEAD" <<'EOF'
#!/usr/bin/env bash
OUT=""; B=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && OUT="$a"
  [ "$prev" = "-C" ] && B="$a"
  prev="$a"
done
cat > /dev/null
[ -f "$B/context/src/db.ts" ] && exit 1          # round 2: dead
echo '{"type":"thread.started","thread_id":"mock"}'
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[{"file":"src/db.ts","why":"brauche die Definition"}],"unverified_claims":[]}\n' > "$OUT"
EOF
chmod +x "$MOCK_DEAD"
rm -f "$AR/config/prod-keys.ts"
ok "$(run_ar "$MOCK_DEAD")" "2" "T-A1-DEAD a dead second round blocks — nobody judged this diff"
ok "$(jq -r '.proofs[] | select(.stage=="codex_round2") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "fail" "T-A1-DEAD …and it is a failure, not a mere gap"

# T-A1-PACKFAIL (codex): if the SECOND bundle cannot even be built (here: it blows the
# cap), that is the same class as a dead round 2 — round 1 judged incompletely by its own
# admission, so nobody fully reviewed this diff. Block, do not wave through with a gap.
# db2.ts has a huge interface (many long export names); the tiny first bundle fits the
# cap, the second one does not.
printf 'import { a0 } from "./db2";\n' > "$AR/src/main2.ts"
: > "$AR/src/db2.ts"
i=0; while [ $i -lt 400 ]; do
  printf 'export const a%s%s = 1;\n' "$i" "$(printf 'x%.0s' $(seq 1 400))" >> "$AR/src/db2.ts"
  i=$((i+1))
done
git -C "$AR" add -A >/dev/null 2>&1
MOCK_ASK2="$TMP/codex-ask2"; cat > "$MOCK_ASK2" <<'EOF'
#!/usr/bin/env bash
OUT=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && OUT="$a"; prev="$a"; done
cat > /dev/null
echo '{"type":"thread.started","thread_id":"mock"}'
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[{"file":"src/db2.ts","why":"brauche die Definition"}],"unverified_claims":[]}\n' > "$OUT"
EOF
chmod +x "$MOCK_ASK2"
RC=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$AR" \
      | VETO_GATE_CAP=20000 CODEX_BIN="$MOCK_ASK2" bash "$HOOK" >/dev/null 2>&1; echo $?)
ok "$RC" "2" "T-A1-PACKFAIL a second bundle that cannot be packed blocks"
ok "$(jq -r '.proofs[] | select(.stage=="codex_round2") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "fail" "T-A1-PACKFAIL …as a failure, not a gap"
git -C "$AR" rm -q --cached src/main2.ts src/db2.ts >/dev/null 2>&1; rm -f "$AR/src/main2.ts" "$AR/src/db2.ts"

# T-A1-ADDCHAIN (codex): the real B1 case. `git add cart.ts && git commit` builds the diff
# from the WORKING TREE, and db.ts is a brand-new file cart.ts imports but that is not
# itself added — on disk, not in the index. Reading the index would leave codex blind about
# exactly that new dependency; the working tree is the commit candidate here.
AR2="$TMP/addchain"; mkdir -p "$AR2/src" "$AR2/.claude/config"
git -C "$AR2" init -q; git -C "$AR2" config user.email t@t.t; git -C "$AR2" config user.name t
printf '{"enabled":true,"effort":"high"}\n' > "$AR2/.claude/config/veto-gate.json"
printf 'export const seed = 1\n' > "$AR2/seed.ts"
git -C "$AR2" add -A >/dev/null 2>&1; git -C "$AR2" commit -qm init >/dev/null 2>&1
printf 'export function zahleAus(){ return 1 }\n' > "$AR2/src/db.ts"          # NEW, deliberately NOT added
printf 'import { zahleAus } from "./db";\nzahleAus();\n' > "$AR2/src/cart.ts"  # NEW, WILL be added
run_ac(){ printf '{"tool_input":{"command":"git add src/cart.ts && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$AR2" \
  | CODEX_BIN="$1" bash "$HOOK" >/dev/null 2>&1; echo $?; }
ok "$(run_ac "$MOCK_ASK")" "2" "T-A1-ADDCHAIN a new imported-but-unadded file is delivered from the working tree"
ok "$(jq -r '.proofs[] | select(.stage=="codex_round2") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "pass" "T-A1-ADDCHAIN …and the round-2 delivery is booked as a pass"

# ── D: real library docs in the bundle ──────────────────────────────────────
# an external import whose version-exact docs are NOT cached → the commit still passes (a
# missing Context7 lookup is not the code's fault), but the gap is LOUD in the ledger.
printf '{"packages":{"node_modules/zod":{"version":"3.22.4"}}}\n' > "$R/package-lock.json"
printf "import { z } from 'zod';\n" > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1
ok "$(VETO_GATE_DOC_CACHE="$TMP/emptycache" run "$MOCK_CLEAN")" "0" "T-DOCS external import + no cached docs → commit passes"
ok "$(jq -r '.proofs[] | select(.stage=="docs") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "unavailable" "T-DOCS …and the missing docs are a visible gap"
# and when the version-exact docs ARE cached, the stage passes and the doc rides in the bundle
mkdir -p "$TMP/doccache"; echo '# zod docs' > "$TMP/doccache/zod@3.22.4.md"
VETO_GATE_DOC_CACHE="$TMP/doccache" run "$MOCK_CLEAN" >/dev/null
ok "$(jq -r '.proofs[] | select(.stage=="docs") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "pass" "T-DOCS cached version-exact docs → pass"
rm -f "$R/package-lock.json"; printf 'export const b=1;\n' > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1

# B1 (codex): a NEW file added in an add-chain must appear in the bundle as a VALID diff hunk
# (diff --git / --- /dev/null / @@), so codex reviews it as a real change, not a loose blob.
MOCK_DIFFCHECK="$TMP/codex-diffcheck"; cat > "$MOCK_DIFFCHECK" <<'EOF'
#!/usr/bin/env bash
OUT=""; B=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && OUT="$a"; [ "$prev" = "-C" ] && B="$a"; prev="$a"; done
cat > /dev/null
echo '{"type":"thread.started","thread_id":"mock"}'
if grep -q '^diff --git a/src/neu.ts b/src/neu.ts$' "$B/DIFF.patch" \
   && grep -q '^--- /dev/null$' "$B/DIFF.patch" && grep -qE '^@@ ' "$B/DIFF.patch"; then
  printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
else
  printf '{"blocking":[{"id":"X","claim":"kein gueltiger Hunk fuer die neue Datei","why":"x","fix":"y"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
fi
EOF
chmod +x "$MOCK_DIFFCHECK"
printf 'export const neu = 1;\n' > "$R/src/neu.ts"   # NEW untracked file
RC=$(printf '{"tool_input":{"command":"git add src/neu.ts && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
      | CODEX_BIN="$MOCK_DIFFCHECK" bash "$HOOK" >/dev/null 2>&1; echo $?)
ok "$RC" "0" "T-NEWFILE-HUNK a new file appears as a valid diff hunk in the bundle"
rm -f "$R/src/neu.ts"

# B1 (codex): an EMPTY new file gets a well-formed `@@ -0,0 +1,0 @@` header — `grep -c ''` on
# an empty file printed 0 AND exited 1, so `|| echo 0` doubled the count into `+1,0\n0`.
MOCK_EMPTYCHECK="$TMP/codex-emptycheck"; cat > "$MOCK_EMPTYCHECK" <<'EOF'
#!/usr/bin/env bash
OUT=""; B=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && OUT="$a"; [ "$prev" = "-C" ] && B="$a"; prev="$a"; done
cat > /dev/null
echo '{"type":"thread.started","thread_id":"mock"}'
if grep -qxE '@@ -0,0 \+1,0 @@' "$B/DIFF.patch"; then
  printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
else
  printf '{"blocking":[{"id":"X","claim":"kaputte Kopfzeile bei leerer Datei","why":"x","fix":"y"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
fi
EOF
chmod +x "$MOCK_EMPTYCHECK"
: > "$R/src/leer.ts"   # NEW empty untracked file
RC=$(printf '{"tool_input":{"command":"git add src/leer.ts && git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
      | CODEX_BIN="$MOCK_EMPTYCHECK" bash "$HOOK" >/dev/null 2>&1; echo $?)
ok "$RC" "0" "T-EMPTY-HUNK an empty new file gets a valid '@@ -0,0 +1,0 @@' header"
rm -f "$R/src/leer.ts"

# ── E: a claim needs a receipt ───────────────────────────────────────────────
# "Tests grün" in the message with no green test run is a LIE — and a lie about the work is
# worse than a bug: it poisons every other claim in the message. R is not on the test
# allow-list, so the tests stage is not `pass` and the claim has no backing.
: > "$TMP/emptyallow"
printf 'export const claimtest = 1;\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts >/dev/null 2>&1
claim_gate(){ # $1 = mock codex, $2 = commit message
  jq -cn --arg cmd "git commit -m \"$2\"" --arg cwd "$R" '{tool_input:{command:$cmd},cwd:$cwd,session_id:"s1"}' \
    | VETO_GATE_TEST_ALLOWLIST="$TMP/emptyallow" CODEX_BIN="$1" bash "$HOOK" >/dev/null 2>&1; echo $?
}
claim_gate_cmd(){ # $1 = mock codex, $2 = full git command
  jq -cn --arg cmd "$2" --arg cwd "$R" '{tool_input:{command:$cmd},cwd:$cwd,session_id:"s1"}' \
    | VETO_GATE_TEST_ALLOWLIST="$TMP/emptyallow" CODEX_BIN="$1" bash "$HOOK" >/dev/null 2>&1; echo $?
}
ok "$(claim_gate "$MOCK_CLEAN" "feat: x — Tests grün")" "2" "T-CLAIM 'Tests grün' without a test run → blocked"
ok "$(claim_gate "$MOCK_CLEAN" "feat: x")"              "0" "T-CLAIM no claim → passes"
ok "$(claim_gate "$MOCK_CLEAN" "feat: verifiziert")"    "2" "T-CLAIM 'verifiziert' without proof → blocked"
ok "$(jq -r '.proofs[] | select(.stage=="claim") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "fail" "T-CLAIM the unbacked claim is recorded on the ledger"
# codex B1: the message is parsed quote-aware — `--message` and an unquoted `-m` count too
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit --message "Tests grün"')" "2" "T-CLAIM --message form is parsed"
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m Getestet')"             "2" "T-CLAIM an unquoted -m is parsed"
# codex B2: an explicit NEGATION is not a claim and must not false-block
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "feat: noch ungetestet"')"    "0" "T-CLAIM 'ungetestet' is not a claim"
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "feat: nicht verifiziert"')"  "0" "T-CLAIM 'nicht verifiziert' is not a claim"
# codex B1: with several -m, a negation in one part must not hide a real claim in another
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "nicht verifiziert" -m "Tests grün"')" "2" "T-CLAIM a claim in a second -m is not hidden by a negation in the first"
# codex B2: a -m belonging to ANOTHER command must not be read as the commit message
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'grep -m1 "Tests grün" /dev/null; git commit -m "feat: x"')" "0" "T-CLAIM a -m from another command is ignored"
# codex round 2 B1: the combined short option -am is a message option too
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -am "Tests grün"')" "2" "T-CLAIM -am carries the message"
# codex round 2 B2: a separator glued to a word (no space) still splits the commit off
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "feat: x"; echo -m "Tests grün"')" "0" "T-CLAIM a glued ';' before another -m does not leak in"
# codex CLAIM-1: common phrasings "Tests sind grün" and the ASCII "gruen"
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "Tests sind grün"')" "2" "T-CLAIM 'Tests sind grün' is caught"
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "Tests gruen"')"     "2" "T-CLAIM the ASCII 'gruen' is caught"
# codex CLAIM-2: text in a shell comment after the command is NOT the commit message
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "feat: x"  # -m "Tests grün"')" "0" "T-CLAIM a shell comment does not leak a claim"
# codex round 3 B1: a `-m` AFTER `--` is a pathspec, not a message
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "feat: x" -- -m "Tests grün"')" "0" "T-CLAIM a -m after -- is a pathspec, not a message"
# codex round 3 B2: a backslash line continuation still carries the message
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m \
"Tests grün"')" "2" "T-CLAIM a line-continued message is still read"
# codex round 3 B3: -F/--file reads the message from a file
printf 'feat: x — Tests grün\n' > "$R/msg.txt"
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -F msg.txt')" "2" "T-CLAIM -F reads the message file"
rm -f "$R/msg.txt"
# codex round 4 P1: the command must ACTUALLY be git — `echo git commit -m "…"` does not count
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "feat: x"; echo git commit -m "Tests grün"')" "0" "T-CLAIM an echoed 'git commit' is not a real commit"
# codex round 4 P2: a backslash-escaped space keeps the message as one value
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m Tests\ grün')" "2" "T-CLAIM a backslash-escaped space keeps 'Tests grün' together"
# codex round 5 B1: `commit` as an argument to ANOTHER git subcommand is not a commit
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -m "feat: x"; git log commit -m "Tests grün" >/dev/null 2>&1 || true')" "0" "T-CLAIM 'commit' as an arg to git log is not the commit subcommand"
# The gate only BLOCKS these commits (never actually commits), so one staged change persists
# across all of them. HEAD gets the reused claim message FIRST — the index is cleared so the
# --allow-empty commit is truly empty, THEN a real change is staged against that HEAD.
git -C "$R" reset -q >/dev/null 2>&1
git -C "$R" commit -q --allow-empty -m "alt: Tests grün" >/dev/null 2>&1
printf 'export const claimtest = 1;\n' > "$R/src/a.ts"; git -C "$R" add src/a.ts >/dev/null 2>&1
# codex round 5 B2: a reused message (--reuse-message) is read and must still be backed
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit --reuse-message HEAD')" "2" "T-CLAIM --reuse-message reuses a message that must still be backed"
# codex round 6 B1: an exec wrapper (env/sudo) before git is still a real commit
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'env git commit -m "Tests grün"')" "2" "T-CLAIM an env-wrapped git commit is caught"
# a shell keyword prefix (if/while) before git is still a real commit
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'if git commit -m "Tests grün"; then :; fi')" "2" "T-CLAIM an 'if git commit' is caught"
# codex round 6 B3: git follows a symlinked -F message file, so the check must too
printf 'feat: x — Tests grün\n' > "$R/realmsg.txt"; ln -sf realmsg.txt "$R/msglink.txt"
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'git commit -F msglink.txt')" "2" "T-CLAIM a symlinked -F message file is followed and checked"
rm -f "$R/realmsg.txt" "$R/msglink.txt"
# a value hidden in a shell variable is NOT chased (documented override) — no false-block
ok "$(claim_gate_cmd "$MOCK_CLEAN" 'MSG="Tests grün"; git commit -m "$MSG"')" "0" "T-CLAIM a variable message is skipped, not false-blocked"
git -C "$R" reset -q >/dev/null 2>&1; printf 'export const b=1;\n' > "$R/src/a.ts"

# a repo with docs:false in its config → the docs stage is skipped, note says so
printf '{"enabled":true,"effort":"high","docs":false}\n' > "$R/.claude/config/veto-gate.json"
printf "import { z } from 'zod';\n" > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1
run "$MOCK_CLEAN" >/dev/null
ok "$(jq -r '.proofs[] | select(.stage=="docs") | .status' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" \
   "skipped" "T-DOCS-CFG docs:false → stage skipped"
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"
printf 'export const b=1;\n' > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1

# T-SIZE: the bundle size reaches the run log. A note nobody can read is worth
# nothing — the dashboard and every statistic read runs.jsonl, and this is the
# number that says how much reading a review actually was.
printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1
run "$MOCK_CLEAN" >/dev/null
ok "$(jq -r 'has("bundle_tokens")' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" "true" "T-SIZE bundle size in the run log"
ok "$(jq -r '.bundle_tokens > 0' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" "true" "T-SIZE the size is a real number"
printf 'export const b=1;\n' > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1

# T-INTENT: the order the change was built for reaches the reviewer, so drift and
# omission become checkable at all. The mock reports what it was handed.
MOCK_INTENT="$TMP/codex-intent"; cat > "$MOCK_INTENT" <<'EOF'
#!/usr/bin/env bash
OUT=""; B=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && OUT="$a"
  [ "$prev" = "-C" ] && B="$a"
  prev="$a"
done
cat > /dev/null
echo '{"type":"thread.started","thread_id":"mock"}'
{ [ -f "$B/INTENT.md" ] && cat "$B/INTENT.md"; } > "$SEEN_INTENT"
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
EOF
chmod +x "$MOCK_INTENT"
export SEEN_INTENT="$TMP/seen-intent"
printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1
printf '{"tool_input":{"command":"git commit -m \\"Zaehler einbauen\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "Zaehler einbauen" "T-INTENT the order reaches the reviewer"
# a -m from an UNRELATED command must never become the order — a non-git segment makes
# the whole line ineligible, so nothing is sent at all
printf '{"tool_input":{"command":"echo -m \\"falscher Auftrag\\" && git commit --message \\"echter Auftrag\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a foreign -m never becomes the order"
# --message counts, and every message part travels, not just the first
printf '{"tool_input":{"command":"git commit --message \\"Titel\\" -m \\"Rumpf\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "$(printf 'Titel\n\nRumpf')" "T-INTENT every message part travels"
# no extractable message → no order, and nothing invented
printf '{"tool_input":{"command":"git commit -m \\"$(cat msg.txt)\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT an unreadable message ships no order at all"
# a -F file is read with git semantics (symlinks followed, path outside the repo) — fine
# for a LOCAL claim scan, never for a bundle that leaves the machine
printf 'Auftrag aus Datei\n' > "$TMP/auftrag.txt"
printf '{"tool_input":{"command":"git commit -F %s"},"cwd":"%s","session_id":"s1"}' "$TMP/auftrag.txt" "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a -F file never leaves the machine as the order"
# two commits in one chain: their goals must not be blended into one order
printf '{"tool_input":{"command":"git commit -m \\"erster\\" && git commit -m \\"zweiter\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT several commits in one chain ship no order"
# all or nothing: one unreadable part must not leave a FRAGMENT posing as the whole order
printf '{"tool_input":{"command":"git commit -m \\"Titel\\" -m \\"$(cat rumpf.txt)\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT one unreadable part drops the whole order"
# a SECOND commit carries no message option at all — counting messages would miss it and
# ship the first commit's goal as this diff's order, so the commits themselves are counted
printf '{"tool_input":{"command":"git commit -m \\"erster\\" && git commit --amend"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a messageless second commit still drops the order"
# grouped commands: `( git commit … ; git commit … )` is still two commits
printf '{"tool_input":{"command":"( git commit -m \\"erster\\" ; git commit -m \\"zweiter\\" )"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT commits inside ( … ) are counted too"
# …and a single grouped commit still ships its order
printf '{"tool_input":{"command":"( git commit -m \\"gruppiert\\" )"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a grouped command is not a plain git chain → no order"
# an interpreter can run a commit no count will ever see, so it is not eligible either
printf '{"tool_input":{"command":"bash -c \\"git commit -m innen\\" && git commit -m \\"aussen\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT an interpreter in the chain drops the order"
# the everyday shape stays eligible: a chain of plain git invocations
printf '{"tool_input":{"command":"git add -A && git commit -m \\"kette\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "kette" "T-INTENT a plain git chain still ships its order"
# a git ALIAS is an arbitrary word and can run another commit first
printf '{"tool_input":{"command":"git schnell && git commit -m \\"aussen\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT an unknown git subcommand drops the order"
# an UNQUOTED tilde is expanded before git sees it, so the text read here is not the message
printf '{"tool_input":{"command":"git commit -m ~x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT an unquoted expansion drops the order"
# the same for every other rewriting form — one positive character set covers them all
for X in 'git commit -m ~x' 'git add [D]IFF && git commit -m ok' 'git commit -m Ziel{A,B}' 'git commit -m x <(cat)'; do
  printf '{"tool_input":{"command":"%s"},"cwd":"%s","session_id":"s1"}' "$X" "$R" \
    | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
  ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT rewriting form drops the order: $X"
done
# -t takes a FILE as its value; the next token is a template name, not a message
printf '{"tool_input":{"command":"git commit -t -mZiel"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a template name is not read as the order"
# an option value that LOOKS like a message must not become one either
printf '{"tool_input":{"command":"git commit --author \\"-m falsch\\" -m \\"echt\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "echt" "T-INTENT an option value is not read as the order"
# a short cluster carrying F/C/c/t takes text from a file or history — the remaining -m
# would be a fragment posing as the whole order
printf '{"tool_input":{"command":"git commit -aF auftrag.txt -m \\"Zusatz\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a clustered -F drops the whole order"
# -C <dir> is modelled by the gate itself, so such a commit keeps its order
printf '{"tool_input":{"command":"git -C %s commit -m \\"mit-C\\""},"cwd":"%s","session_id":"s1"}' "$R" "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "mit-C" "T-INTENT git -C keeps its order"
# a shape the message parser documents as out of scope (`env -u FOO git commit`) is still
# counted, because the AUTHORITATIVE detector does the counting
printf '{"tool_input":{"command":"git commit -m \\"erster\\" && env -u FOO git commit"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a commit behind a valued wrapper option still counts"
# a second commit glued to a grouping char — no pattern enumerates these shapes, the
# word count does not have to
printf '{"tool_input":{"command":"git commit -m \\"erster\\" && (git commit -m \\"zweiter\\")"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a glued grouped second commit still counts"
# the word inside a quoted message is blanked, so it cannot fake a second commit
printf '{"tool_input":{"command":"git commit -m \\"commit und commit\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "commit und commit" "T-INTENT the word in a message is not a second commit"
# quote-splicing hides the WORD from the blanked line, but not from shlex — the second
# detector catches what the first cannot, which is why both must agree
printf '{"tool_input":{"command":"git com\\"mit\\" -m \\"erster\\" && git commit -m \\"zweiter\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a quote-spliced second commit still drops the order"
# a commit inside a substitution runs FIRST and no count over the written text can see
# it — so no order leaves a command that carries a substitution at all
printf '{"tool_input":{"command":"git commit -m \\"aussen\\" \\"$(git commit -m innen)\\""},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN="$MOCK_INTENT" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$SEEN_INTENT" 2>/dev/null)" "" "T-INTENT a substitution anywhere drops the order"
unset SEEN_INTENT
printf 'export const b=1;\n' > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1

# T-TIMEOUT-CFG: the per-repo timeout/timeout2 must actually REACH the reviewer.
# Nothing pinned this before, and it is the one knob that decides whether a run
# ends with a verdict or with "nobody reviewed this" — measured 2026-07-28, the
# repo `testbau-repo` carried no timeout at all and 19 of 62 runs ended in a timeout.
# The mock records what it was handed; the env seam is unset for this one call,
# because an explicit env value deliberately wins over the config.
MOCK_ENV="$TMP/codex-env"; cat > "$MOCK_ENV" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '%s %s\n' "${VETO_GATE_TIMEOUT:-unset}" "${VETO_GATE_TIMEOUT2:-unset}" > "$SEEN"
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$MOCK_ENV"
printf '{"enabled":true,"effort":"high","timeout":500,"timeout2":654}\n' > "$R/.claude/config/veto-gate.json"
printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | env -u VETO_GATE_TIMEOUT -u VETO_GATE_TIMEOUT -u VETO_GATE_TIMEOUT2 -u VETO_GATE_TIMEOUT2 \
        SEEN="$TMP/seen-timeout" CODEX_BIN="$MOCK_ENV" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$TMP/seen-timeout" 2>/dev/null)" "500 654" "T-TIMEOUT-CFG a raised config timeout reaches the reviewer"
# …and a value BELOW the central minimum is lifted, not honoured: more time cannot
# lower review depth, so a repo may only ever give more (measured spread across ten
# repo configs on 2026-07-29: 60, 100, 100, 240, 360 — every copy froze a template)
printf '{"enabled":true,"effort":"high","timeout":60}\n' > "$R/.claude/config/veto-gate.json"
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | env -u VETO_GATE_TIMEOUT -u VETO_GATE_TIMEOUT2 \
        SEEN="$TMP/seen-timeout" CODEX_BIN="$MOCK_ENV" bash "$HOOK" >/dev/null 2>&1
ok "$(cat "$TMP/seen-timeout" 2>/dev/null)" "360 420" "T-TIMEOUT-CFG a too-low timeout is lifted to the central minimum"
printf '{"enabled":true,"effort":"high"}\n' > "$R/.claude/config/veto-gate.json"
printf 'export const b=1;\n' > "$R/src/a.ts"; git -C "$R" add -A >/dev/null 2>&1

# T-KREISEL-STOP: at round N the gate stops BEFORE any reviewer runs. Measured
# twice (7 rounds on a markdown parser, 19 on a shell parser): the detection was
# never the problem, the next review was. A spy reviewer proves it is not called.
MOCK_SPY2="$TMP/codex-spy2"; cat > "$MOCK_SPY2" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
echo gerufen >> "$SPY_MARK"
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}\n' > "$OUT"
echo '{"type":"thread.started","thread_id":"mock"}'
EOF
chmod +x "$MOCK_SPY2"
export SPY_MARK="$TMP/spy-mark"; : > "$SPY_MARK"
git -C "$R" reset -q; printf "import { b } from './b';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
# force the spiral: threshold 1 means "already at round 1" counts as spinning
E=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | VETO_GATE_KREISEL_STOP=1 CODEX_BIN="$MOCK_SPY2" bash "$HOOK" 2>&1 >/dev/null); RC=$?
ok "$RC" "2" "T-KREISEL-STOP the spiral blocks"
ok "$(wc -l < "$SPY_MARK" | tr -d ' ')" "0" "T-KREISEL-STOP …and no reviewer was called at all"
case "$E" in *BAUFORM*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL T-KREISEL-STOP asks the form question: $E";; esac
ok "$(jq -r '.result' "$VETO_GATE_LOG_DIR/runs.jsonl" | tail -1)" "kreisel-stop" "T-KREISEL-STOP the ledger records it"
# the override still gets through — the stop is a hard block, not a dead end
mkdir -p "$R/.claude/session-flags"; touch "$R/.claude/session-flags/s1-veto-gate-override"
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | VETO_GATE_KREISEL_STOP=1 CODEX_BIN="$MOCK_SPY2" bash "$HOOK" >/dev/null 2>&1
ok "$?" "0" "T-KREISEL-STOP a deliberate override still passes"
# threshold 0 switches the stop off entirely
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$R" \
  | VETO_GATE_KREISEL_STOP=0 CODEX_BIN="$MOCK_SPY2" bash "$HOOK" >/dev/null 2>&1
ok "$(wc -l < "$SPY_MARK" | tr -d ' ')" "1" "T-KREISEL-STOP threshold 0 → reviewer runs again"
unset SPY_MARK
git -C "$R" reset -q; printf 'export const b=1;\n' > "$R/src/a.ts"

# T-GUARD: no stage may exist without writing a note of its own name.
#
# Counting `mark` against `proof_add` would prove nothing — two notes in one stage would
# mask a stage with none. So every stage is checked BY NAME, and then again against a REAL
# run: a source-level grep can be fooled, a run cannot.
GATE="$(cd "$(dirname "$0")/.." && pwd)/veto-gate.sh"
MISSING=""
for st in $(grep -oE '^mark [a-z_]+' "$GATE" | awk '{print $2}' | sort -u); do
  grep -qE "proof_add[[:space:]]+\"?${st}\"?[[:space:]]" "$GATE" || MISSING="${MISSING}${st} "
done
ok "$MISSING" "" "T-GUARD every marked stage writes a note of its own name"

# ── the beat on the COMMON path ──────────────────────────────────────────────
# The gate fires on every Bash call, and almost none of them are commits. Until
# the bench caught it, it beat only on the commit path — so on a day without a
# commit a live gate and a dead one left exactly the same trace: none.
export VETO_HB_SESSION=vgq; rm -f "$VETO_HB_DIR"/*.tsv
printf '{"tool_input":{"command":"ls -la"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN=/nonexistent/codex bash "$HOOK" >/dev/null 2>&1
ok "$(awk -F'\t' '$2=="veto-gate"{print $3}' "$VETO_HB_DIR/vgq.tsv" 2>/dev/null | sort -u | tr '\n' ' ')" \
   "skipped " "a non-commit command reports skipped instead of nothing"
printf '{"tool_input":{"command":"echo hallo"},"cwd":"%s","session_id":"s1"}' "$R" \
  | CODEX_BIN=/nonexistent/codex bash "$HOOK" >/dev/null 2>&1
ok "$(grep -c . "$VETO_HB_DIR/vgq.tsv")" "1" "…once a day, not once per Bash call"

# ── the size stage and the lockfile it must not count ────────────────────────
# A dependency commit is manifest + lockfile in ONE commit; the lockfile supplies
# almost every changed line. Counting them blocked every security upgrade behind
# an advice ("split it up") that cannot be followed, so the only way through was
# the override — no review at all.
LR="$TMP/lockrepo"; mkdir -p "$LR/src" "$LR/.claude/config"
git -C "$LR" init -q; git -C "$LR" config user.email t@t.t; git -C "$LR" config user.name t
printf '{"enabled":true,"effort":"high","max_lines":10}\n' > "$LR/.claude/config/veto-gate.json"
printf 'export const a=1;\n' > "$LR/src/a.ts"
git -C "$LR" add -A >/dev/null 2>&1; git -C "$LR" commit -qm base --no-verify >/dev/null 2>&1
printf '{"name":"root","dependencies":{"sharp":"0.35.3"}}\n' > "$LR/package.json"
{ echo '{'; for i in $(seq 1 200); do echo "  \"pkg$i\": \"1.0.0\","; done; echo '  "end": 1'; echo '}'; } > "$LR/package-lock.json"
git -C "$LR" add package.json package-lock.json >/dev/null 2>&1
LRC=$(printf '{"tool_input":{"command":"git commit -m deps"},"cwd":"%s","session_id":"s1"}' "$LR" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" 2>&1 >/dev/null; echo "rc=$?")
ok "$(printf '%s' "$LRC" | grep -c 'Diff zu groß')" "0" "T-LOCK1 a dependency commit does not size-block"

# the exemption is SAID, not silent: an unseen exemption is a hole, not a rule
ok "$(jq -r '[.proofs[]|select(.stage=="size")|.detail]|join("")' "$VETO_GATE_LOG_DIR/runs.jsonl" 2>/dev/null | tail -1 | grep -c 'Lockfile-Zeilen')" \
   "1" "T-LOCK2 the size proof names the exempted lines"

# real code next to the lockfile still counts and still blocks
for i in $(seq 1 20); do echo "export const v$i = $i;"; done > "$LR/src/big.ts"
git -C "$LR" add src/big.ts >/dev/null 2>&1
LRC2=$(printf '{"tool_input":{"command":"git commit -m big"},"cwd":"%s","session_id":"s1"}' "$LR" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$HOOK" 2>&1 >/dev/null)
ok "$(printf '%s' "$LRC2" | grep -c 'Diff zu groß')" "1" "T-LOCK3 real code next to a lockfile still blocks"

# ── a broken size checker blocks, it never passes ────────────────────────────
# diff-size.sh now depends on a shared file. If that goes missing the count is
# gone — and an empty count used to become "0 Code-Zeilen: pass", i.e. the size
# stage waving through a diff nobody measured (UL-006).
BROK="$TMP/brokenhooks"; mkdir -p "$BROK"
cp -R "$(dirname "$HOOK")"/. "$BROK/" 2>/dev/null
rm -f "$BROK/lib/veto-gate/generated-files.sh"
BRC=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"s1"}' "$LR" \
  | CODEX_BIN="$MOCK_CLEAN" bash "$BROK/veto-gate.sh" 2>&1 >/dev/null; echo "rc=$?")
ok "$(printf '%s' "$BRC" | grep -c 'Größenprüfung selbst fehlgeschlagen')" "1" "T-LOCK4 missing shared list blocks"
ok "$(printf '%s' "$BRC" | grep -c 'rc=2')" "1" "T-LOCK5 …with the block exit code, never a pass"

echo "veto-gate: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

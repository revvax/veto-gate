#!/usr/bin/env bash
# testbench-veto-gate.sh — repeatable test environment for the veto2 commit gate.
# Spins up throwaway repos, drives the hook through every scenario with a mock
# codex, and asserts the DESIRED behaviour. No real codex, no real repo touched.
#   Scenarios: clean-pass, hallucinated-import-block, codex-block, fail-open,
#   and the BYPASS cases (git commit -a / git add && commit).
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
# Never post test findings to the real Discord: the gate calls notify_discord
# on every block, and these fixtures would land on the owner's phone as garbage.
unset DISCORD_VETO_WEBHOOK
HOOK="$(cd "$(dirname "$0")/.." && pwd)/veto-gate.sh"
export VETO_GATE_TIMEOUT=5
# hermetic: qwen stage fails open instantly (dead port), never a real LM Studio
export VETO_GATE_HERMES_BIN="/nonexistent/hermes"   # hermetic: never a real paid call
export VETO_GATE_QWEN_TIMEOUT=2
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 (exit $1, want $2)"; fi; }

# --- mocks -----------------------------------------------------------------
MDIR=$(mktemp -d); trap 'rm -rf "$MDIR"' EXIT
cat > "$MDIR/clean" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}' > "$OUT"
echo '{"type":"thread.started","thread_id":"tb"}'
EOF
cat > "$MDIR/block" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '{"blocking":[{"id":"B1","claim":"x","why":"y","fix":"z"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}' > "$OUT"
echo '{"type":"thread.started","thread_id":"tb"}'
EOF
cat > "$MDIR/fail" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null; exit 1
EOF
chmod +x "$MDIR"/clean "$MDIR"/block "$MDIR"/fail
# 'clean' variant that records the reasoning effort it was called with, so a test can
# prove WHICH depth the triage handed to codex (codex-diff-review.sh passes it as
# `-c model_reasoning_effort=<v>`).
cat > "$MDIR/clean-rec" <<'EOF'
#!/usr/bin/env bash
OUT=""; PREV=""
for a in "$@"; do
  case "$a" in model_reasoning_effort=*) echo "${a#model_reasoning_effort=}" > "$EFFORT_REC";; esac
  [ "$PREV" = "-o" ] && OUT="$a"
  PREV="$a"
done
cat > /dev/null
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}' > "$OUT"
echo '{"type":"thread.started","thread_id":"tb"}'
EOF
chmod +x "$MDIR/clean-rec"
export EFFORT_REC="$MDIR/effort.rec"
# block mock with a steerable quote (KQUOTE) — the spiral scenario needs findings
# that provably hit lines added between rounds. Also records whether the prompt
# carried the prior-findings memory (MEM_REC, used by the memory scenario).
cat > "$MDIR/block-q" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
IN=$(cat)
printf '%s' "$IN" | grep -q 'PRIOR_FINDINGS' && echo mem >> "${MEM_REC:-/dev/null}"
printf '{"blocking":[{"id":"K1","claim":"x","why":"y","fix":"z","quote":"%s"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}' "${KQUOTE:-}" > "$OUT"
echo '{"type":"thread.started","thread_id":"tb"}'
EOF
chmod +x "$MDIR/block-q"

# fresh repo with a committed baseline tracked file + a real import target
new_repo(){
  local R; R=$(mktemp -d)
  mkdir -p "$R/src" "$R/.claude/config"
  git -C "$R" init -q; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
  printf '{"enabled":true,"effort":"high"}' > "$R/.claude/config/veto-gate.json"
  printf 'export const dep = 1;\n' > "$R/src/dep.ts"
  printf 'export const base = 1;\n' > "$R/src/base.ts"
  git -C "$R" add -A; git -C "$R" commit -qm baseline
  echo "$R"
}
run(){ # $1 mock  $2 cmd  $3 cwd
  # TB_LOG_DIR lets a test read the ledger a run wrote; unset → fresh temp dir per run,
  # exactly as before
  printf '{"tool_input":{"command":"%s"},"cwd":"%s","session_id":"tb"}' "$2" "$3" \
    | VETO_GATE_LOG_DIR="${TB_LOG_DIR:-$(mktemp -d)}" CODEX_BIN="$1" bash "$HOOK" >/dev/null 2>&1; echo $?
}
run_err(){ # like run(), but keeps stderr so a test can read the block text
  printf '{"tool_input":{"command":"%s"},"cwd":"%s","session_id":"tb"}' "$2" "$3" \
    | VETO_GATE_LOG_DIR="${TB_LOG_DIR:-$(mktemp -d)}" CODEX_BIN="$1" bash "$HOOK" >/dev/null 2>"$MDIR/err.log"; echo $?
}

echo "=== veto-gate testbench ==="

# S1 clean staged import → allow
R=$(new_repo); printf "import { dep } from './dep';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(run "$MDIR/clean" "git commit -m x" "$R")" "0" "S1 clean staged → allow"; rm -rf "$R"

# S2 hallucinated import staged → block (grounding)
R=$(new_repo); printf "import { ghost } from './ghost';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(run "$MDIR/clean" "git commit -m x" "$R")" "2" "S2 hallucinated staged → block"; rm -rf "$R"

# S3 codex-block staged → block
R=$(new_repo); printf "import { dep } from './dep';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(run "$MDIR/block" "git commit -m x" "$R")" "2" "S3 codex-block → block"; rm -rf "$R"

# S4 codex fail/timeout → BLOCK (fail-closed, not waved through)
R=$(new_repo); printf "import { dep } from './dep';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
ok "$(run "$MDIR/fail" "git commit -m x" "$R")" "2" "S4 codex fail → block (fail-closed)"; rm -rf "$R"

# S5 BYPASS: git commit -a on a MODIFIED tracked file (hallucinated), unstaged
R=$(new_repo); printf "export const base = 1;\nimport { ghost } from './ghost';\n" > "$R/src/base.ts"
ok "$(run "$MDIR/clean" "git commit -am x" "$R")" "2" "S5 commit -a (mod tracked) → block"; rm -rf "$R"

# S6 BYPASS: git add f && git commit on a MODIFIED tracked file (hallucinated)
R=$(new_repo); printf "export const base = 1;\nimport { ghost } from './ghost';\n" > "$R/src/base.ts"
ok "$(run "$MDIR/clean" "git add src/base.ts && git commit -m x" "$R")" "2" "S6 add && commit (mod tracked) → block"; rm -rf "$R"

# S7 BYPASS: NEW untracked file (hallucinated) via git add && commit
R=$(new_repo); printf "import { ghost } from './ghost';\n" > "$R/src/new.ts"
ok "$(run "$MDIR/clean" "git add src/new.ts && git commit -m x" "$R")" "2" "S7 new untracked add && commit → block"; rm -rf "$R"

# S8 control: clean NEW untracked via git add && commit → allow (no false positive)
R=$(new_repo); printf "import { dep } from './dep';\nexport const n = 1;\n" > "$R/src/new.ts"
ok "$(run "$MDIR/clean" "git add src/new.ts && git commit -m x" "$R")" "0" "S8 clean new untracked add && commit → allow"; rm -rf "$R"

# S9: review prompt demands plain language (Task 3, Mission Control E1)
LIB="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)"
ok "$(grep -c 'einfacher deutscher Sprache' "$LIB/pack-diff.sh")" "1" "S9 prompt fordert einfache Sprache"

# S10 (B4): >300 changed CODE lines staged → size-block
R=$(new_repo); for i in $(seq 1 320); do echo "export const v$i = $i;"; done > "$R/src/big.ts"
git -C "$R" add src/big.ts
ok "$(run "$MDIR/clean" "git commit -m x" "$R")" "2" "S10 big code diff → size-block"; rm -rf "$R"

# S11 (B4): >300 DOC lines staged → passes (docs exempt from size gate)
R=$(new_repo); for i in $(seq 1 320); do echo "zeile $i"; done > "$R/plan.md"
git -C "$R" add plan.md
ok "$(run "$MDIR/clean" "git commit -m x" "$R")" "0" "S11 big doc diff → allow"; rm -rf "$R"

# S12 (B2): local qwen finds a blocking issue → qwen-block, codex not needed
QPORT=4096
python3 - "$QPORT" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self._send({"data": [{"id": "qwen3.6-35b-a3b-mlx"}]})
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._send({"choices": [{"message": {"content":
            '{"blocking":[{"id":"Q1","claim":"kaputt","why":"w","fix":"f"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'}}]})
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
QSRV=$!; sleep 0.4
R=$(new_repo); printf "import { dep } from './dep';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
RC=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"tb"}' "$R" \
  | VETO_GATE_LOG_DIR="$(mktemp -d)" VETO_GATE_QWEN_URL="http://127.0.0.1:$QPORT/v1/chat/completions" \
    CODEX_BIN="$MDIR/fail" bash "$HOOK" >/dev/null 2>&1; echo $?)
ok "$RC" "2" "S12 qwen blocking → block (codex fail irrelevant)"
kill "$QSRV" 2>/dev/null; wait "$QSRV" 2>/dev/null; rm -rf "$R"

# S13 (B7): known-closed codex window → quota-block in seconds, no codex run
R=$(new_repo); printf "import { dep } from './dep';\n" > "$R/src/a.ts"; git -C "$R" add src/a.ts
QLOG=$(mktemp -d)
python3 -c 'import time,json;print(json.dumps({"reset_epoch":int(time.time())+1800,"reset_at":"17:28","msg":"usage limit","ts":"x"}))' > "$QLOG/quota.json"
T0=$(date +%s)
RC=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"tb"}' "$R" \
  | VETO_GATE_LOG_DIR="$QLOG" CODEX_BIN="$MDIR/clean" bash "$HOOK" >/dev/null 2>&1; echo $?)
D=$(( $(date +%s) - T0 ))
ok "$RC" "2" "S13 closed window → quota-block"
[ "$D" -lt 10 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: S13 slow (${D}s)"; }
rm -rf "$R" "$QLOG"

# --- triage (Stufe 1) ------------------------------------------------------
# The depth handed to codex follows the FACTS of the diff, not the line count alone.
trg(){ # $1 = path to change, $2 = code lines (0 = prose only) → prints recorded effort
  local R i; R=$(new_repo); : > "$EFFORT_REC"
  mkdir -p "$(dirname "$R/$1")"
  if [ "$2" -eq 0 ]; then
    echo "nur Prosa, keine einzige Code-Zeile" > "$R/$1"
  else
    i=0; while [ "$i" -lt "$2" ]; do echo "export const x$i = $i;" >> "$R/$1"; i=$((i+1)); done
  fi
  git -C "$R" add -A >/dev/null 2>&1
  run "$MDIR/clean-rec" "git commit -m x" "$R" >/dev/null
  cat "$EFFORT_REC" 2>/dev/null; rm -rf "$R"
}
ok "$(trg docs/note.md 0)"       "low"    "S14 doc-only diff → low effort"
ok "$(trg src/auth/login.ts 10)" "high"   "S15 small auth diff NOT lowered (old gap closed)"
ok "$(trg src/util.ts 10)"       "medium" "S16 small plain code → medium (unchanged vs today)"

# --- triage mismatch ledger (Stufe 1) --------------------------------------
# A run sized 'light' that a reviewer blocks anyway was mis-sized — it must leave
# evidence (UL-006), or the calibration can never learn.
mm(){ # $1 = mock, $2 = path to change, $3 = code lines → prints ledger line count
  local R i; R=$(new_repo)
  export TB_LOG_DIR="$MDIR/ledger"; rm -rf "$TB_LOG_DIR"; mkdir -p "$TB_LOG_DIR"
  mkdir -p "$(dirname "$R/$2")"
  if [ "$3" -eq 0 ]; then
    echo "nur Prosa, keine einzige Code-Zeile" > "$R/$2"
  else
    i=0; while [ "$i" -lt "$3" ]; do echo "export const x$i = $i;" >> "$R/$2"; i=$((i+1)); done
  fi
  git -C "$R" add -A >/dev/null 2>&1
  run "$1" "git commit -m x" "$R" >/dev/null
  # explicit branch, not `wc -l ... || echo 0`: on a missing file the redirect fails and
  # the fallback would print 0 too — "no ledger" and "empty ledger" must not read alike
  if [ -s "$TB_LOG_DIR/triage-mismatch.jsonl" ]; then
    wc -l < "$TB_LOG_DIR/triage-mismatch.jsonl" | tr -d ' '
  else
    echo 0
  fi
  rm -rf "$R"
}
ok "$(mm "$MDIR/block" docs/note.md 0)" "1" "S17 light doc diff + block → one ledger entry"
ok "$(mm "$MDIR/clean" docs/note.md 0)" "0" "S18 clean light run → no entry"
ok "$(mm "$MDIR/block" src/util.ts 10)" "0" "S19 normal-profile block → no entry"

# --- kreisel (Stufe 2): sequence identity in the ledger, HEAD move ends it ---
export TB_LOG_DIR="$MDIR/kled"; rm -rf "$TB_LOG_DIR"; mkdir -p "$TB_LOG_DIR"
R=$(new_repo)
printf "export const k1 = 1;\n" > "$R/src/k.ts"; git -C "$R" add src/k.ts
run "$MDIR/block" "git commit -m x" "$R" >/dev/null
run "$MDIR/block" "git commit -m x" "$R" >/dev/null
ok "$(jq -rs '.[0].seq == .[1].seq' "$TB_LOG_DIR/runs.jsonl")" "true" "S20 both rounds share one sequence id"
ok "$(jq -rs '.[0].seq_round,"/",.[1].seq_round' "$TB_LOG_DIR/runs.jsonl" | tr -d '\n')" "1/2" "S20b rounds count up"
ok "$(tail -1 "$TB_LOG_DIR/runs.jsonl" | jq -r '.names[0]')" "src/k.ts" "S20c file names in the ledger"
git -C "$R" commit -qm moved >/dev/null 2>&1   # a REAL commit moves HEAD — the sequence ends by itself
printf "export const k2 = 2;\n" >> "$R/src/k.ts"; git -C "$R" add src/k.ts
run "$MDIR/block" "git commit -m x" "$R" >/dev/null
ok "$(tail -1 "$TB_LOG_DIR/runs.jsonl" | jq -r .seq_round)" "1" "S20d new HEAD → fresh sequence"
ok "$(jq -rs '.[0].seq != .[-1].seq' "$TB_LOG_DIR/runs.jsonl")" "true" "S20e …with its own id"
unset TB_LOG_DIR; rm -rf "$R"

# --- spiral end-to-end (Stufe 2): warning fires on the real gate, no false alarm
export TB_LOG_DIR="$MDIR/spiral"; rm -rf "$TB_LOG_DIR"; mkdir -p "$TB_LOG_DIR"
R=$(new_repo)
i=0; while [ "$i" -lt 10 ]; do echo "export const a$i = $i;" >> "$R/src/k.ts"; i=$((i+1)); done
git -C "$R" add src/k.ts; export KQUOTE="egal erste Runde"
run "$MDIR/block-q" "git commit -m x" "$R" >/dev/null
i=0; while [ "$i" -lt 10 ]; do echo "export const b$i = $i;" >> "$R/src/k.ts"; i=$((i+1)); done
git -C "$R" add src/k.ts; export KQUOTE="export const b3 = 3;"
run "$MDIR/block-q" "git commit -m x" "$R" >/dev/null
ok "$(tail -1 "$TB_LOG_DIR/runs.jsonl" | jq -r .kreisel)" "false" "S21 round 2 → below threshold, no alarm"
i=0; while [ "$i" -lt 10 ]; do echo "export const c$i = $i;" >> "$R/src/k.ts"; i=$((i+1)); done
git -C "$R" add src/k.ts; export KQUOTE="export const c3 = 3;"
ok "$(run_err "$MDIR/block-q" "git commit -m x" "$R")" "2" "S21b spiral round still blocks"
ok "$(tail -1 "$TB_LOG_DIR/runs.jsonl" | jq -r .kreisel)"   "true" "S21c spiral flag in the ledger"
ok "$(tail -1 "$TB_LOG_DIR/runs.jsonl" | jq -r .seq_round)" "3"    "S21d third round of one sequence"
ok "$(grep -c 'KREISEL' "$MDIR/err.log")" "1" "S21e churn warning in the block text"
unset KQUOTE TB_LOG_DIR; rm -rf "$R"

# S22: a normal single block stays silent — the false-alarm anchor from the spec
export TB_LOG_DIR="$MDIR/single"; rm -rf "$TB_LOG_DIR"; mkdir -p "$TB_LOG_DIR"
R=$(new_repo); printf "export const s = 1;\n" > "$R/src/s.ts"; git -C "$R" add src/s.ts
run_err "$MDIR/block" "git commit -m x" "$R" >/dev/null
ok "$(tail -1 "$TB_LOG_DIR/runs.jsonl" | jq -r .kreisel)" "false" "S22 one-round block → no spiral"
ok "$(grep -c 'KREISEL' "$MDIR/err.log")" "0" "S22b no churn warning"
unset TB_LOG_DIR; rm -rf "$R"

# S24: from round 2 the review prompt carries the prior findings (codex's memory)
export TB_LOG_DIR="$MDIR/mem"; rm -rf "$TB_LOG_DIR"; mkdir -p "$TB_LOG_DIR"
export MEM_REC="$MDIR/mem.rec"; : > "$MEM_REC"
R=$(new_repo)
printf "export const m1 = 1;\n" > "$R/src/m.ts"; git -C "$R" add src/m.ts
export KQUOTE="egal"
run "$MDIR/block-q" "git commit -m x" "$R" >/dev/null
ok "$([ -s "$MEM_REC" ] || echo leer)" "leer" "S24 round 1 → no memory"
printf "export const m2 = 2;\n" >> "$R/src/m.ts"; git -C "$R" add src/m.ts
run "$MDIR/block-q" "git commit -m x" "$R" >/dev/null
ok "$([ -s "$MEM_REC" ] && echo mem)" "mem" "S24b round 2 → prior findings in the prompt"
unset KQUOTE TB_LOG_DIR MEM_REC; rm -rf "$R"

echo "=== testbench: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]

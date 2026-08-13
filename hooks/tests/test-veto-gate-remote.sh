#!/usr/bin/env bash
# test-veto-gate-remote.sh — hermetic tests for remote-diff-review.sh (groq/gemini
# free-tier pre-reviewers) and the `veto-gate key` subcommand. NEVER touches a
# real provider: URLs are either dead ports, foreign hosts (must be refused
# before any network contact) or a local python3 mock.
set -uo pipefail
LIB="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)"
# a failed mktemp would leave VETO_GATE_LOG_DIR empty and every path below would
# hit / — abort instead (codex find)
VETO_GATE_LOG_DIR="$(mktemp -d)" && [ -d "$VETO_GATE_LOG_DIR" ] || { echo "mktemp failed" >&2; exit 1; }
export VETO_GATE_LOG_DIR
trap '[ -n "$VETO_GATE_LOG_DIR" ] && rm -rf "$VETO_GATE_LOG_DIR"; [ -n "${MOCK:-}" ] && kill "$MOCK" 2>/dev/null' EXIT
P=0; F=0; ok(){ case "$1" in *"$2"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL $3: got '$1'";; esac; }
# portable permission check (stat -f is BSD-only, stat -c is GNU-only — F15)
perm(){ python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777)[-3:])' "$1"; }
DIFF="$VETO_GATE_LOG_DIR/d.diff"; printf 'diff --git a/x b/x\n+++ b/x\n+code\n' > "$DIFF"

# bad args
bash "$LIB/remote-diff-review.sh" --provider ftp --diff "$DIFF" 2>/dev/null; ok "$?" "64" "unknown provider"
bash "$LIB/remote-diff-review.sh" --provider groq --diff /nope 2>/dev/null; ok "$?" "64" "missing diff"
bash "$LIB/remote-diff-review.sh" --diff "$DIFF" 2>/dev/null; ok "$?" "64" "provider required"
bash "$LIB/remote-diff-review.sh" --provider 2>/dev/null; ok "$?" "64" "dangling flag → 64, no hang"

# no key anywhere → infra (3), fail-open to codex — and NEVER a network call
env -u GROQ_API_KEY VETO_GATE_GROQ_URL="http://127.0.0.1:1/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "no key → 3"

# oversized diff → 4
python3 -c 'print("x"*20000)' > "$VETO_GATE_LOG_DIR/big.diff"
GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://127.0.0.1:1/v1/chat/completions" VETO_GATE_GROQ_MAXBYTES=16000 \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$VETO_GATE_LOG_DIR/big.diff" 2>/dev/null; ok "$?" "4" "oversize → 4"

# dead port → 3
GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://127.0.0.1:1/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "dead port → 3"

# broken size cap must fail open (3), never send the diff anyway
GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://127.0.0.1:1/v1/chat/completions" VETO_GATE_GROQ_MAXBYTES=abc \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "non-numeric cap → 3"
GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://127.0.0.1:1/v1/chat/completions" VETO_GATE_GROQ_MAXBYTES=0 \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "zero cap → 3"

# R2-B2: URL override outside provider-host/localhost → 3, NOTHING is sent
GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://evil.example/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "foreign http url refused"
GROQ_API_KEY=k VETO_GATE_GROQ_URL="https://evil.example/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "foreign https url refused"
# R4-B2: userinfo trick — looks like localhost, curl would hit evil.example
GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://127.0.0.1:4094@evil.example/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "userinfo@ url refused"
# R5-B2: cross-provider host binding — a groq key never goes to gemini's host
GROQ_API_KEY=k VETO_GATE_GROQ_URL="https://generativelanguage.googleapis.com/v1beta/openai/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "groq key never sent to gemini host"
# R5-B1: env key is a localhost-only test seam — for the REAL provider host
# it must not count (no key file → exit 3 BEFORE any network contact)
GROQ_API_KEY=k bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null
ok "$?" "3" "env key ignored for production host"

# R2-B1/R1-B2: neither diff body nor key may travel via argv — pin the shape
grep -q -- '--data-binary @-' "$LIB/remote-diff-review.sh"; ok "$?" "0" "body via stdin pinned"
grep -q -- '-H @' "$LIB/remote-diff-review.sh"; ok "$?" "0" "auth header via file pinned"
grep -cE 'curl[^|]*Bearer' "$LIB/remote-diff-review.sh" >/dev/null; ok "$?" "1" "no bearer in curl argv"

# mock server: returns one blocking finding; records the Authorization header
python3 - "$VETO_GATE_LOG_DIR" <<'PY' & MOCK=$!
import http.server, json, socketserver, sys
seen = sys.argv[1] + "/auth.txt"
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        open(seen, "w").write(self.headers.get("Authorization", ""))
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        v = {"blocking": [{"id": "R1", "claim": "Mock-Fund", "why": "w", "fix": "f"}],
             "non_blocking": [], "questions": [], "context_requests": [], "unverified_claims": []}
        b = json.dumps({"choices": [{"message": {"content": json.dumps(v)}}]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 4094), H) as s: s.serve_forever()
PY
sleep 1
V=$(GROQ_API_KEY=sekret VETO_GATE_GROQ_URL="http://127.0.0.1:4094/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null); RC=$?
ok "$RC" "0" "mock verdict rc=0"
ok "$(printf '%s' "$V" | jq -r '.blocking[0].claim')" "Mock-Fund" "verdict passthrough"
ok "$(cat "$VETO_GATE_LOG_DIR/auth.txt")" "Bearer sekret" "bearer header sent"
# key file fallback (env unset) — the shared file the panel reports
mkdir -p "$VETO_GATE_LOG_DIR/keys"; printf 'filekey' > "$VETO_GATE_LOG_DIR/keys/groq.key"
V=$(env -u GROQ_API_KEY VETO_GATE_GROQ_URL="http://127.0.0.1:4094/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null)
ok "$(cat "$VETO_GATE_LOG_DIR/auth.txt")" "Bearer filekey" "key file fallback"
rm -rf "$VETO_GATE_LOG_DIR/keys"
# gemini uses the same adapter (mock URL override)
V=$(GEMINI_API_KEY=g VETO_GATE_GEMINI_URL="http://127.0.0.1:4094/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider gemini --diff "$DIFF" 2>/dev/null); RC=$?
ok "$RC" "0" "gemini via same adapter"
# no tmp header files left behind
ok "$(ls "${TMPDIR:-/tmp}" | grep -c veto-gate-hdr)" "0" "no header temp remnant"

# garbage response body → 3 (fail open), never a block
python3 - <<'PY' & MOCK2=$!
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        b = b'kaputt nicht json'
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 4095), H) as s: s.serve_forever()
PY
sleep 1
GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://127.0.0.1:4095/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "garbage body → 3"
kill "$MOCK2" 2>/dev/null

# shape-valid garbage: claim as NUMBER must fall open (jq length trap), not block
python3 - <<'PY' & MOCK3=$!
import http.server, json, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        v = {"blocking": [{"id": "X", "claim": 5}], "non_blocking": []}
        b = json.dumps({"choices": [{"message": {"content": json.dumps(v)}}]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 4096), H) as s: s.serve_forever()
PY
sleep 1
GROQ_API_KEY=k VETO_GATE_GROQ_URL="http://127.0.0.1:4096/v1/chat/completions" \
  bash "$LIB/remote-diff-review.sh" --provider groq --diff "$DIFF" 2>/dev/null; ok "$?" "3" "numeric claim → 3 (never a block)"
kill "$MOCK3" 2>/dev/null

# veto-gate key: stores from stdin, chmod 600, never echoes the key
OUT=$(printf 'mykey\n' | bash "$LIB/veto-gate-cli.sh" key groq 2>&1)
ok "$(cat "$VETO_GATE_LOG_DIR/keys/groq.key")" "mykey" "key stored"
ok "$(perm "$VETO_GATE_LOG_DIR/keys/groq.key")" "600" "key chmod 600"
case "$OUT" in *mykey*) F=$((F+1)); echo "FAIL key echoed";; *) P=$((P+1));; esac
ok "$OUT" "§10" "free-tier warning printed (R1-B5)"
# R2-B3: an existing too-open key file must end up 0600 after re-store
chmod 644 "$VETO_GATE_LOG_DIR/keys/groq.key"
printf 'mykey2\n' | bash "$LIB/veto-gate-cli.sh" key groq >/dev/null 2>&1
ok "$(perm "$VETO_GATE_LOG_DIR/keys/groq.key")" "600" "pre-existing 0644 tightened to 600"
ok "$(cat "$VETO_GATE_LOG_DIR/keys/groq.key")" "mykey2" "key replaced atomically"
bash "$LIB/veto-gate-cli.sh" key ftp 2>/dev/null; ok "$?" "64" "key: unknown provider rejected"
printf '\n' | bash "$LIB/veto-gate-cli.sh" key gemini >/dev/null 2>&1; ok "$?" "1" "empty key rejected"
ok "$([ -f "$VETO_GATE_LOG_DIR/keys/gemini.key" ] && echo created || echo absent)" "absent" "empty key stores nothing"

echo "remote: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

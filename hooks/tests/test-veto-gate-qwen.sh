#!/usr/bin/env bash
# qwen-diff-review.sh: local pre-reviewer. Mocked LM Studio via a python3
# HTTP server on a test port (VETO2_QWEN_URL seam, real curl).
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/qwen-diff-review.sh"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1' want '$2')"; fi; }
D=$(mktemp); PORT=4097
trap 'rm -f "$D"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null' EXIT
printf '+++ b/src/a.ts\n+const x = 1;\n' > "$D"

serve_reply(){ # $1 = chat content; $2 = model id served on /v1/models
  python3 - "$1" "$PORT" "${2:-qwen3.6-35b-a3b-mlx}" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
content, port, model = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(BaseHTTPRequestHandler):
    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if model == "::NOMODELS::":
            self.send_response(404); self.end_headers(); return
        self._send({"data": [{"id": model}]})
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._send({"choices": [{"message": {"content": content}}]})
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  SRV=$!; sleep 0.4
}

export VETO2_QWEN_URL="http://127.0.0.1:$PORT/v1/chat/completions"
export VETO2_QWEN_TIMEOUT=5

# T1: clean verdict passes through (with a <think> block to strip)
serve_reply '<think>hm</think>{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
OUT=$(bash "$S" --diff "$D"); RC=$?
ok "$RC" "0" "T1 clean rc=0"
ok "$(printf '%s' "$OUT" | jq -r '.blocking|length')" "0" "T1 verdict parsed"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

# T2: blocking verdict passes through
serve_reply '{"blocking":[{"id":"Q1","claim":"c","why":"w","fix":"f"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
OUT=$(bash "$S" --diff "$D"); RC=$?
ok "$RC" "0" "T2 rc=0"
ok "$(printf '%s' "$OUT" | jq -r '.blocking|length')" "1" "T2 blocking found"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

# T3: garbage reply → exit 3 (infra, caller fails open to codex)
serve_reply 'ich bin kein json'
bash "$S" --diff "$D" >/dev/null 2>&1; ok "$?" "3" "T3 garbage → 3"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

# T4: server down → exit 3 fast
export VETO2_QWEN_URL="http://127.0.0.1:4098/nix"
T0=$(date +%s); bash "$S" --diff "$D" >/dev/null 2>&1; RC=$?
ok "$RC" "3" "T4 down → 3"
[ $(( $(date +%s) - T0 )) -lt 5 ] && P=$((P+1)) || { F=$((F+1)); echo "  FAIL: T4 slow"; }

# T5: oversized diff → exit 4 (skip local, caller goes straight to codex)
BIG=$(mktemp); head -c 70000 /dev/zero | tr '\0' 'x' > "$BIG"
VETO2_QWEN_MAXBYTES=60000 bash "$S" --diff "$BIG" >/dev/null 2>&1; ok "$?" "4" "T5 too big → 4"
rm -f "$BIG"

# T6: malformed blocking entries (no claim / non-object) → exit 3, never a
# block on garbage (codex live finding on B2)
export VETO2_QWEN_URL="http://127.0.0.1:$PORT/v1/chat/completions"
serve_reply '{"blocking":[{"id":"Q1"}],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
bash "$S" --diff "$D" >/dev/null 2>&1; ok "$?" "3" "T6 claimless finding → 3"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
serve_reply '{"blocking":["nur text"],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}'
bash "$S" --diff "$D" >/dev/null 2>&1; ok "$?" "3" "T6b non-object finding → 3"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

# T7: prompt pins — diff-only findings, no missing-reference claims (context
# lives with codex, codex live finding on B2)
ok "$(grep -c 'Repo-Kontext' "$S")" "1" "T7 prompt forbids missing-ref claims"

# T8: identity check — the diff is only sent to a server that lists the
# configured model on /v1/models (codex live finding: never ship a diff to
# an unknown listener on the port)
serve_reply '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}' '::NOMODELS::'
bash "$S" --diff "$D" >/dev/null 2>&1; ok "$?" "3" "T8 no /v1/models → 3 (no diff sent)"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
serve_reply '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}' 'anderes-modell'
bash "$S" --diff "$D" >/dev/null 2>&1; ok "$?" "3" "T8b wrong model listed → 3"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

echo "qwen-review: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

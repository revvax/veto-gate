#!/usr/bin/env bash
# discord-codex-findings.sh: post gate blocks to Discord as WAS/WARUM/WIE fields.
# Mocked webhook via a python3 HTTP server (real curl, DISCORD_VETO_WEBHOOK seam).
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/discord-codex-findings.sh"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1' want '$2')"; fi; }
has(){ if printf '%s' "$1" | grep -qF "$2"; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (missing '$2')"; fi; }
PORT=4098; RX=$(mktemp)
trap 'rm -f "$RX"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null' EXIT

# field <payload> <index> <key> — read one embed field out of the payload
field(){ printf '%s' "$1" | jq -r ".embeds[0].fields[$2].$3 // \"\"" 2>/dev/null; }

V_ONE='{"blocking":[{"id":"B1","claim":"Passwort steht im Klartext im Code","why":"Wer den Code liest, kann sich anmelden","fix":"Passwort in eine Umgebungsvariable (env var) auslagern"}],"non_blocking":[],"questions":[]}'
V_TWO='{"blocking":[{"id":"B1","claim":"Erstes Problem","why":"Grund eins","fix":"Loesung eins"},{"id":"B2","claim":"Zweites Problem","why":"Grund zwei","fix":"Loesung zwei"}]}'
V_NONE='{"blocking":[],"non_blocking":[{"id":"N1","note":"egal"}]}'

export VETO_GATE_DISCORD_DRY_RUN=1
unset DISCORD_VETO_WEBHOOK

# ── T1: one finding → exactly the three fixed headings, in order ─────────
OUT=$(printf '%s' "$V_ONE" | bash "$S" --repo Alpha --branch main \
        --commit-msg "feat: login einbauen" --files "src/auth.ts, src/db.ts"); RC=$?
ok "$RC" "0" "T1 rc=0"
ok "$(printf '%s' "$OUT" | jq -r '.embeds[0].fields|length')" "3" "T1 exactly 3 fields"
has "$(field "$OUT" 0 name)"  "WAS"               "T1 field 1 = WAS"
has "$(field "$OUT" 1 name)"  "WARUM"             "T1 field 2 = WARUM"
has "$(field "$OUT" 2 name)"  "WIE WIRD ES GELÖST" "T1 field 3 = WIE"
has "$(field "$OUT" 0 value)" "Passwort steht im Klartext"  "T1 WAS holds the claim"
has "$(field "$OUT" 1 value)" "Wer den Code liest"          "T1 WARUM holds the why"
has "$(field "$OUT" 2 value)" "Umgebungsvariable"           "T1 WIE holds the fix"
has "$(printf '%s' "$OUT" | jq -r '.embeds[0].title')" "1 Problem" "T1 title counts findings"

# T1b: noise (files, commit msg, repo) is demoted to the footer — not the body
FOOT=$(printf '%s' "$OUT" | jq -r '.embeds[0].footer.text')
has "$FOOT" "Alpha"                "T1b repo in footer"
has "$FOOT" "main"                  "T1b branch in footer"
has "$FOOT" "2 Datei(en)"           "T1b file COUNT, not the path wall"
has "$FOOT" "feat: login einbauen"  "T1b commit message in footer"
ok "$(printf '%s' "$OUT" | grep -c 'src/auth.ts' || true)" "0" "T1b file paths do NOT bloat the body"

# ── T2: two findings → one field each, heading carries the WAS ───────────
OUT=$(printf '%s' "$V_TWO" | bash "$S" --repo Alpha)
ok "$(printf '%s' "$OUT" | jq -r '.embeds[0].fields|length')" "2" "T2 one field per finding"
has "$(printf '%s' "$OUT" | jq -r '.embeds[0].title')" "2 Probleme" "T2 title counts"
has "$(field "$OUT" 0 name)"  "Erstes Problem" "T2 heading = claim"
has "$(field "$OUT" 0 value)" "Warum"          "T2 body labels the why"
has "$(field "$OUT" 0 value)" "Lösung"         "T2 body labels the fix"

# T2b: more than 5 findings → 5 shown + one honest "there are more" field
MANY=$(python3 -c '
import json
print(json.dumps({"blocking":[{"id":"B%d"%i,"claim":"c%d"%i,"why":"w","fix":"f"} for i in range(9)]}))')
OUT=$(printf '%s' "$MANY" | bash "$S" --repo Alpha)
ok "$(printf '%s' "$OUT" | jq -r '.embeds[0].fields|length')" "6" "T2b 5 findings + 1 overflow note"
has "$(field "$OUT" 5 value)" "+ 4 weitere" "T2b overflow states the count (no silent drop)"

# ── T3: invented code → same three headings ─────────────────────────────
G='{"count":1,"violations":[{"file":"src/a.ts","import":"./nope","symbol":"doThing"}]}'
OUT=$(printf '%s' "$G" | bash "$S" --kind grounding --repo Alpha)
has "$(printf '%s' "$OUT" | jq -r '.embeds[0].title')" "Erfundener Code" "T3 title"
ok "$(printf '%s' "$OUT" | jq -r '.embeds[0].fields|length')" "3" "T3 same 3-field shape"
has "$(field "$OUT" 0 value)" "src/a.ts"  "T3 WAS names the file"
has "$(field "$OUT" 0 value)" "doThing"   "T3 WAS names the symbol"
has "$(field "$OUT" 2 value)" "anlegen"   "T3 WIE gives a way out"

# ── T4: no review happened → orange, and says so plainly ────────────────
OUT=$(printf '' | bash "$S" --kind quota --repo Alpha --detail "wieder frei ab 17:30")
has "$(printf '%s' "$OUT" | jq -r '.embeds[0].title')" "Nicht geprüft" "T4 quota title"
ok "$(printf '%s' "$OUT" | jq -r '.embeds[0].color')" "16753920" "T4 orange, not red"
has "$(field "$OUT" 0 value)" "17:30"       "T4 WAS shows the reset time"
has "$(field "$OUT" 1 value)" "Niemand hat" "T4 WARUM spells out the gap"
OUT=$(printf '' | bash "$S" --kind timeout --repo Alpha)
has "$(field "$OUT" 0 value)" "nicht rechtzeitig geantwortet" "T4 timeout WAS"
has "$(field "$OUT" 1 value)" "Niemand hat"                   "T4 timeout WARUM"

# T4b: real findings are red, not orange
OUT=$(printf '%s' "$V_ONE" | bash "$S" --repo Alpha)
ok "$(printf '%s' "$OUT" | jq -r '.embeds[0].color')" "15548997" "T4b findings are red"

# ── T5: silence where it belongs ────────────────────────────────────────
for c in "$V_NONE|--repo Alpha|clean verdict" "not json|--repo Alpha|garbage" "|--repo Alpha|empty"; do
  IFS='|' read -r payload args label <<< "$c"
  OUT=$(printf '%s' "$payload" | bash "$S" $args); RC=$?
  ok "$RC" "0" "T5 $label rc=0"
  ok "$OUT" ""  "T5 $label posts nothing"
done
OUT=$(printf '' | bash "$S" --kind bogus --repo Alpha); RC=$?
ok "$RC" "0" "T5 unknown kind rc=0"
ok "$OUT" ""  "T5 unknown kind posts nothing"

# T6: long text stays inside Discord's per-field limit (1024)
LONG=$(python3 -c '
import json
print(json.dumps({"blocking":[{"id":"B1","claim":"x"*2000,"why":"y"*2000,"fix":"z"*2000}]}))')
OUT=$(printf '%s' "$LONG" | bash "$S" --repo Alpha)
MAXLEN=$(printf '%s' "$OUT" | jq -r '[.embeds[0].fields[].value | length] | max')
ok "$(( MAXLEN <= 1024 ? 1 : 0 ))" "1" "T6 field values <= 1024 chars (max was $MAXLEN)"

# ── real POST against a mock webhook ────────────────────────────────────
unset VETO_GATE_DISCORD_DRY_RUN
python3 - "$PORT" "$RX" <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, rx = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        open(rx, "wb").write(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
SRV=$!; sleep 0.4

export DISCORD_VETO_WEBHOOK="http://127.0.0.1:$PORT/hook"
printf '%s' "$V_ONE" | bash "$S" --repo Alpha --branch main; RC=$?
sleep 0.2
ok "$RC" "0" "T7 post rc=0"
has "$(cat "$RX")" "Passwort steht im Klartext" "T7 webhook received the finding"

: > "$RX"
printf '%s' "$V_NONE" | bash "$S" --repo Alpha
sleep 0.2
ok "$(wc -c < "$RX" | tr -d ' ')" "0" "T7 clean verdict sends no request"

# T8: dead webhook → still exit 0 (the gate must never break)
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
printf '%s' "$V_ONE" | bash "$S" --repo Alpha; RC=$?
ok "$RC" "0" "T8 dead webhook still rc=0"

unset DISCORD_VETO_WEBHOOK
OUT=$(printf '%s' "$V_ONE" | bash "$S" --repo Alpha); RC=$?
ok "$RC" "0" "T9 no webhook rc=0"
ok "$OUT" ""  "T9 no webhook prints nothing"

# ── T-GAP: a missing check reaches the phone ────────────────────────────
# Orange, not red: nobody got it wrong — nobody LOOKED. It says which stages did not run
# and, plainly, that the commit went through unchecked. Without this the ledger is a file
# nobody reads.
export VETO_GATE_DISCORD_DRY_RUN=1
unset DISCORD_VETO_WEBHOOK
OUT=$(printf '' | bash "$S" --kind gap --repo Alpha --detail "typecheck, tests")
has "$(printf '%s' "$OUT" | jq -r '.embeds[0].title')" "Nicht gepr" "T-GAP title"
ok "$(printf '%s' "$OUT" | jq -r '.embeds[0].color')" "16753920" "T-GAP orange, not red"
has "$(field "$OUT" 0 value)" "typecheck"    "T-GAP names the missing stages"
has "$(field "$OUT" 1 value)" "Niemand hat"  "T-GAP spells out the gap"
has "$(field "$OUT" 2 value)" "durch"        "T-GAP says the commit went through anyway"
# no detail → still a message, never a crash and never a silent no-op
OUT=$(printf '' | bash "$S" --kind gap --repo Alpha); RC=$?
ok "$RC" "0" "T-GAP without detail still exits 0"
has "$(printf '%s' "$OUT" | jq -r '.embeds[0].title')" "Nicht gepr" "T-GAP without detail still reports"

# ── T10: no test may post to the REAL webhook ───────────────────────────
# The gate calls notify_discord on every block. A test that drives the gate
# inherits DISCORD_VETO_WEBHOOK from the shell and posts its fixtures to the
# owner's phone — that happened on 2026-07-14 ("drops user table", repo tmp.xxx).
# Every test touching the gate must unset the webhook. This guards the rule.
# The pattern must find the gate script itself: since the rename (veto2-commit-gate.sh is
# now a symlink to veto-gate.sh) a suite driving the new name would have slipped past this
# guard — a watchman looking for a man who changed his coat.
TDIR="$(cd "$(dirname "$0")" && pwd)"
for t in "$TDIR"/*.sh; do
  grep -lq 'veto-gate\.sh\|notify_discord' "$t" 2>/dev/null || continue
  [ "$(basename "$t")" = "$(basename "$0")" ] && continue
  if grep -q 'unset DISCORD_VETO_WEBHOOK' "$t"; then P=$((P+1)); else
    F=$((F+1)); echo "  FAIL: $(basename "$t") drives the gate but never unsets DISCORD_VETO_WEBHOOK"
  fi
done

echo "test-veto-gate-discord-findings: $P passed, $F failed"
[ "$F" -eq 0 ]

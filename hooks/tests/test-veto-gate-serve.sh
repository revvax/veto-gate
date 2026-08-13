#!/usr/bin/env bash
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/serve.py"
export VETO_GATE_LOG_DIR="$(mktemp -d)"; export VETO_GATE_PORT=4093
trap 'rm -rf "$VETO_GATE_LOG_DIR"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null' EXIT
# Task 5: read_repos() now scans ~/Desktop and calls gh — isolate BOTH from
# the very first invocation on, or every /data assertion below counts the
# real Desktop (dozens of real repos) and hits the real GitHub account.
export VETO_GATE_GH_BIN=/nonexistent/gh   # never touch the real GitHub account
FAKEHOME="$VETO_GATE_LOG_DIR/fakehome"; mkdir -p "$FAKEHOME/Desktop"
export HOME="$FAKEHOME"                    # isolate Path.home()/Desktop from the real one
P=0; F=0; ok(){ case "$1" in *"$2"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL $3: got '$1'";; esac; }
LOG="$VETO_GATE_LOG_DIR/runs.jsonl"
printf '%s\n' \
  '{"ts":"2026-07-10T20:00:00Z","repo":"cb","branch":"main","files":1,"result":"codex-pass","blocking":0,"dur":10,"thread":"t1"}' \
  '{"ts":"2026-07-10T20:01:00Z","repo":"cb","branch":"main","files":2,"result":"codex-block","blocking":2,"dur":20,"thread":"t2","verdict":{"blocking":[{"id":"B1","claim":"Import erfunden","why":"Datei gibt es nicht","fix":"Pfad korrigieren"},{"id":"B2","claim":"x","why":"y","fix":"z"}],"non_blocking":[]}}' \
  '{"ts":"2026-07-10T20:02:00Z","repo":"cb","branch":"main","files":2,"result":"codex-pass","blocking":0,"dur":12,"thread":"t3"}' \
  > "$LOG"

# data-once
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r .n)" "3" "n=3"
ok "$(printf '%s' "$D" | jq -r .blocked_pct)" "33" "blocked 33"
ok "$(printf '%s' "$D" | jq -r '.runs|length')" "3" "3 runs"

# /data v2 (Task 5): live marker, engine, details, resolved, totals, codex state
mkdir -p "$VETO_GATE_LOG_DIR/running"
printf '{"ts":"%s","repo":"cb","branch":"main","files":1,"stage":"codex"}' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VETO_GATE_LOG_DIR/running/gate-999.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.live[0].stage')" "codex" "live marker sichtbar"
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.result=="codex-block")|.engine')" "codex" "engine codex"
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.result=="codex-block")|.resolved')" "true" "block later resolved"
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.result=="codex-block")|.details[0].claim')" "Import erfunden" "claim im detail"
ok "$(printf '%s' "$D" | jq -r '.found_total')" "2" "found counted"
ok "$(printf '%s' "$D" | jq -r '.resolved_total')" "2" "resolved counted"
ok "$(printf '%s' "$D" | jq -r '.codex.ok')" "true" "codex ok (kein fail zuletzt)"
rm -f "$VETO_GATE_LOG_DIR/running/gate-999.json"
# stale marker (>10min) must be ignored — relative timestamp (B4: no wall-clock
# dependency); computed in python3 for portability (F15: date -v is BSD-only)
printf '{"ts":"%s","repo":"cb","branch":"main","files":1,"stage":"codex"}' \
  "$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=11)).strftime("%Y-%m-%dT%H:%M:%SZ"))')" > "$VETO_GATE_LOG_DIR/running/gate-998.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.live|length')" "0" "stale marker ignoriert"
rm -f "$VETO_GATE_LOG_DIR/running/gate-998.json"

# B3: marker fields are whitelisted — unknown keys must not reach the browser
printf '{"ts":"%s","repo":"cb","branch":"main","files":1,"stage":"codex","cmd":"geheim"}' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$VETO_GATE_LOG_DIR/running/gate-997.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.live[0]|has("cmd")')" "false" "marker fields whitelisted"
rm -f "$VETO_GATE_LOG_DIR/running/gate-997.json"

# B1/B2: malformed run entries (blocking/dur/ts wrong-typed or missing) must not crash
cp "$LOG" "$LOG.bak"
printf '%s\n' \
  '{"ts":"2026-07-10T20:03:00Z","repo":"cb","branch":"main","result":"codex-block","blocking":"zwei","dur":null}' \
  '{"repo":"cb","result":"timeout-block","blocking":null}' >> "$LOG"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.n')" "5" "malformed entries tolerated"
ok "$(printf '%s' "$D" | jq -r '.codex.ok')" "false" "codex fail state despite missing ts"
mv "$LOG.bak" "$LOG"

# B4 (veto3): size-block / cap-block count as blocks, engine "gate"
cp "$LOG" "$LOG.bak"
printf '%s\n' \
  '{"ts":"2026-07-10T20:04:00Z","repo":"cb","branch":"main","files":1,"result":"size-block","blocking":1,"dur":1,"thread":""}' \
  '{"ts":"2026-07-10T20:05:00Z","repo":"cb","branch":"main","files":1,"result":"cap-block","blocking":1,"dur":1,"thread":""}' >> "$LOG"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.blocked_pct')" "60" "size/cap count as blocks (3/5)"
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.result=="size-block")|.engine')" "gate" "engine gate (size)"
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.result=="cap-block")|.engine')" "gate" "engine gate (cap)"
mv "$LOG.bak" "$LOG"

# B2 (veto3): a pre-reviewer block counts as a block, engine "minimax", details flatten
cp "$LOG" "$LOG.bak"
printf '%s\n' \
  '{"ts":"2026-07-10T20:06:00Z","repo":"cb","branch":"main","files":1,"result":"minimax-block","blocking":1,"dur":25,"thread":"","verdict":{"blocking":[{"id":"Q1","claim":"lokal gefunden","why":"w","fix":"f"}],"non_blocking":[]}}' >> "$LOG"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.result=="minimax-block")|.engine')" "minimax" "engine minimax"
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.result=="minimax-block")|.details[0].claim')" "lokal gefunden" "minimax claim im detail"
ok "$(printf '%s' "$D" | jq -r '.blocked_pct')" "50" "qwen-block counted (2/4)"
mv "$LOG.bak" "$LOG"

# E3: groq-/gemini-block count as blocks, engine mapping
cp "$LOG" "$LOG.bak"
printf '%s\n' \
  '{"ts":"2026-07-10T20:08:00Z","repo":"cb","branch":"main","files":1,"result":"groq-block","blocking":1,"dur":9,"thread":""}' \
  '{"ts":"2026-07-10T20:09:00Z","repo":"cb","branch":"main","files":1,"result":"gemini-block","blocking":1,"dur":9,"thread":""}' >> "$LOG"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.result=="groq-block")|.engine')" "groq" "engine groq"
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.result=="gemini-block")|.engine')" "gemini" "engine gemini"
ok "$(printf '%s' "$D" | jq -r '.blocked_pct')" "60" "remote blocks counted (3/5)"
mv "$LOG.bak" "$LOG"

# B3 (veto3): grounding violation with symbol → claim names the symbol
cp "$LOG" "$LOG.bak"
printf '%s\n' \
  '{"ts":"2026-07-10T20:07:00Z","repo":"cb","branch":"main","files":1,"result":"grounding-block","blocking":1,"dur":1,"thread":"","violations":[{"file":"src/a.ts","import":"./dep","symbol":"ghostSym"}]}' >> "$LOG"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.runs[]|select(.ts=="2026-07-10T20:07:00Z")|.details[0].claim')" "Erfundenes Symbol: ghostSym aus ./dep" "symbol claim"
mv "$LOG.bak" "$LOG"

# B7 (veto3): quota countdown in /data
python3 -c 'import time,json;print(json.dumps({"reset_epoch":int(time.time())+900,"reset_at":"17:28","msg":"usage limit","ts":"x"}))' > "$VETO_GATE_LOG_DIR/quota.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.codex.quota.reset_at')" "17:28" "quota reset_at exposed"
REM=$(printf '%s' "$D" | jq -r '.codex.quota.remaining_s')
[ "$REM" -gt 0 ] && [ "$REM" -le 900 ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL quota remaining_s ($REM)"; }
printf '{"reset_epoch":1,"reset_at":"00:00"}' > "$VETO_GATE_LOG_DIR/quota.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.codex.quota')" "null" "elapsed quota → null"
printf 'kaputt{' > "$VETO_GATE_LOG_DIR/quota.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.codex.quota')" "null" "broken quota.json tolerated"
rm -f "$VETO_GATE_LOG_DIR/quota.json"

# repo registry (Task 4)
FAKE="$VETO_GATE_LOG_DIR/fakerepo"; mkdir -p "$FAKE/.claude/config"
printf '{ "enabled": true, "effort": "high", "timeout": 100, "timeout2": 150 }' \
  > "$FAKE/.claude/config/veto-gate.json"
printf '{"repos":["%s"]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].name')" "fakerepo" "repo listed"
ok "$(printf '%s' "$D" | jq -r '.repos[0].enabled')" "true" "repo enabled read"
ok "$(printf '%s' "$D" | jq -r '.repos[0].effort')" "high" "repo effort read"

# defensive: valid-but-wrong-shaped registry/config must not crash /data
printf '[1,2]' > "$VETO_GATE_LOG_DIR/repos.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos|length')" "0" "non-dict registry tolerated"
printf '{"repos":["%s", 42]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"
printf '"kaputt"' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos|length')" "1" "non-string path skipped"
ok "$(printf '%s' "$D" | jq -r '.repos[0].enabled')" "false" "non-dict config tolerated"
# restore fixtures for later sections
printf '{ "enabled": true, "effort": "high", "timeout": 100, "timeout2": 150 }' \
  > "$FAKE/.claude/config/veto-gate.json"
printf '{"repos":["%s"]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"

# B1 hardening: absolute paths must NOT leave the server (LAN exposure)
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0]|has("path")')" "false" "abs path not exposed"

# global module state (E2 Task 1)
export VETO_GATE_CLAUDE_DIR="$VETO_GATE_LOG_DIR/claudehome"
mkdir -p "$VETO_GATE_CLAUDE_DIR/skills/a" "$VETO_GATE_CLAUDE_DIR/skills/b"
printf '{"answer_style":{"default":"friese","gate":{"enabled":true}}}' > "$VETO_GATE_CLAUDE_DIR/triggers.json"
printf '{"model":"fable","outputStyle":"friese"}' > "$VETO_GATE_CLAUDE_DIR/settings.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.global.style')" "friese" "global style"
ok "$(printf '%s' "$D" | jq -r '.global.model')" "fable" "global model"
ok "$(printf '%s' "$D" | jq -r '.global.skills_global')" "2" "global skills count"
# defensiv: kaputte triggers.json → Defaults, kein Crash
printf 'kaputt{' > "$VETO_GATE_CLAUDE_DIR/triggers.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.global.style')" "-" "broken triggers tolerated"
printf '{"answer_style":{"default":"friese","gate":{"enabled":true}}}' > "$VETO_GATE_CLAUDE_DIR/triggers.json"

# per-repo module info (E2 Task 2)
mkdir -p "$FAKE/.claude/skills/x" "$FAKE/.claude/session-flags"
printf '{"outputStyle":"klartext"}' > "$FAKE/.claude/settings.json"
printf 'friese' > "$FAKE/.claude/session-flags/s1-answer-style"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].output_style')" "klartext" "repo outputStyle"
ok "$(printf '%s' "$D" | jq -r '.repos[0].skills_repo')" "1" "repo skills count"
ok "$(printf '%s' "$D" | jq -r '.repos[0].session_style')" "friese" "session style flag"
# defensiv: kaputte repo-settings → "-", kein Crash
printf 'kaputt{' > "$FAKE/.claude/settings.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].output_style')" "-" "broken repo settings tolerated"
printf '{"outputStyle":"klartext"}' > "$FAKE/.claude/settings.json"

# E3 Task 2: /data v3 — settings fields per repo + key presence
printf '{ "enabled": true, "effort": "high", "timeout": 100, "timeout2": 150, "max_lines": 400, "plan_review": true, "qwen": false }' \
  > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].max_lines')" "400" "max_lines exposed"
ok "$(printf '%s' "$D" | jq -r '.repos[0].plan_review')" "true" "plan_review exposed"
ok "$(printf '%s' "$D" | jq -r '.repos[0].prechecker')" "none" "legacy qwen:false → none"
printf '{ "enabled": true, "prechecker": "groq" }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].prechecker')" "groq" "explicit prechecker wins"
ok "$(printf '%s' "$D" | jq -r '.repos[0].max_lines')" "300" "max_lines default 300 (same as gate)"
ok "$(printf '%s' "$D" | jq -r '.repos[0].plan_review')" "false" "plan_review default false"
printf '{ "enabled": true, "prechecker": "quatsch" }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].prechecker')" "minimax" "invalid prechecker → default minimax"
# max_lines wrong-typed → default, no crash
printf '{ "enabled": true, "max_lines": "vierhundert" }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].max_lines')" "300" "non-int max_lines → default"
ok "$(printf '%s' "$D" | jq -r '.keys.groq')" "false" "no groq key"
ok "$(printf '%s' "$D" | jq -r '.keys.gemini')" "false" "no gemini key"
mkdir -p "$VETO_GATE_LOG_DIR/keys"; printf 'k' > "$VETO_GATE_LOG_DIR/keys/gemini.key"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.keys.gemini')" "true" "gemini key presence (bool only)"
ok "$(printf '%s' "$D" | jq -r '.keys|keys|length')" "2" "keys carries presence flags only"
rm -rf "$VETO_GATE_LOG_DIR/keys"
# R3-B1 (Plan-Review): ONLY the shared key FILE counts — a key in the server
# env is invisible to the gate process and must not report "vorhanden"
D=$(GROQ_API_KEY=k python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.keys.groq')" "false" "server env key does NOT count"
# restore fixture for the sections below
printf '{ "enabled": true, "effort": "high", "timeout": 100, "timeout2": 150 }' \
  > "$FAKE/.claude/config/veto-gate.json"

# server smoke
python3 "$S" >/dev/null 2>&1 & SRV=$!
sleep 1
ok "$(curl -s "http://127.0.0.1:4093/data" | jq -r .n)" "3" "server /data n=3"
ok "$(curl -s "http://127.0.0.1:4093/")" "Veto-Gate" "server / has html"

# toggle (Task 6): per-start token, addressed by NAME, flips repo config
H=$(curl -s "http://127.0.0.1:4093/")
TOK=$(printf '%s' "$H" | grep -o 'VETO_GATE_TOKEN="[a-f0-9]*"' | head -1 | cut -d'"' -f2)
ok "$([ -n "$TOK" ] && echo yes || echo no)" "yes" "token embedded in html"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/toggle" -d '{"name":"fakerepo"}')
ok "$C" "403" "toggle without token rejected"
T=$(curl -s -X POST "http://127.0.0.1:4093/toggle" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo"}')
ok "$(printf '%s' "$T" | jq -r '.enabled')" "false" "toggle flips true->false"
ok "$(jq -r '.enabled' "$FAKE/.claude/config/veto-gate.json")" "false" "config file written"
T=$(curl -s -X POST "http://127.0.0.1:4093/toggle" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo"}')
ok "$(printf '%s' "$T" | jq -r '.enabled')" "true" "toggle flips back"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/toggle" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"nix"}')
ok "$C" "403" "unregistered name rejected"

# valid JSON that is not an object → clean 400, no crash
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/toggle" -H "X-Veto-Gate-Token: $TOK" -d '[1,2]')
ok "$C" "400" "non-object body rejected"

# existing-but-broken config must never be clobbered by a toggle
printf 'kaputt{' > "$FAKE/.claude/config/veto-gate.json"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/toggle" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo"}')
ok "$C" "409" "broken config → 409"
ok "$(cat "$FAKE/.claude/config/veto-gate.json")" "kaputt{" "broken config untouched"
printf '{ "enabled": true, "effort": "high", "timeout": 100, "timeout2": 150 }' \
  > "$FAKE/.claude/config/veto-gate.json"

# B1: ambiguous repo names must be rejected, nothing toggled
AMB="$VETO_GATE_LOG_DIR/amb"; mkdir -p "$AMB/fakerepo"
printf '{"repos":["%s","%s/fakerepo"]}' "$FAKE" "$AMB" > "$VETO_GATE_LOG_DIR/repos.json"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/toggle" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo"}')
ok "$C" "409" "ambiguous name rejected"
# B2: registered-but-missing dir must not be created by a toggle
printf '{"repos":["%s","%s/ghostrepo"]}' "$FAKE" "$VETO_GATE_LOG_DIR" > "$VETO_GATE_LOG_DIR/repos.json"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/toggle" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"ghostrepo"}')
ok "$C" "403" "missing repo dir rejected"
ok "$([ -d "$VETO_GATE_LOG_DIR/ghostrepo" ] && echo created || echo absent)" "absent" "ghost dir not created"
printf '{"repos":["%s"]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"

# style switch (E2 Task 3)
T=$(curl -s -X POST "http://127.0.0.1:4093/style" -H "X-Veto-Gate-Token: $TOK" -d '{"style":"klartext"}')
ok "$(printf '%s' "$T" | jq -r '.style')" "klartext" "style switched"
ok "$(jq -r '.answer_style.default' "$VETO_GATE_CLAUDE_DIR/triggers.json")" "klartext" "triggers.json written"
ok "$(jq -r '.answer_style.gate.enabled' "$VETO_GATE_CLAUDE_DIR/triggers.json")" "true" "other trigger fields preserved"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/style" -d '{"style":"friese"}')
ok "$C" "403" "style without token rejected"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/style" -H "X-Veto-Gate-Token: $TOK" -d '{"style":"emoji"}')
ok "$C" "400" "unknown style rejected"
printf 'kaputt{' > "$VETO_GATE_CLAUDE_DIR/triggers.json"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/style" -H "X-Veto-Gate-Token: $TOK" -d '{"style":"friese"}')
ok "$C" "409" "broken triggers not clobbered"
ok "$(cat "$VETO_GATE_CLAUDE_DIR/triggers.json")" "kaputt{" "broken triggers untouched"
# existing-but-wrong-shaped answer_style must not be silently replaced (codex
# find, conventions-based: broken config stays untouched → 409)
printf '{"answer_style":"kaputt-als-string"}' > "$VETO_GATE_CLAUDE_DIR/triggers.json"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/style" -H "X-Veto-Gate-Token: $TOK" -d '{"style":"friese"}')
ok "$C" "409" "non-dict answer_style rejected"
ok "$(cat "$VETO_GATE_CLAUDE_DIR/triggers.json")" '{"answer_style":"kaputt-als-string"}' "non-dict answer_style untouched"
rm "$VETO_GATE_CLAUDE_DIR/triggers.json"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/style" -H "X-Veto-Gate-Token: $TOK" -d '{"style":"friese"}')
ok "$C" "409" "missing triggers.json not created"
ok "$([ -f "$VETO_GATE_CLAUDE_DIR/triggers.json" ] && echo created || echo absent)" "absent" "style system not set up → no file"
printf '{"answer_style":{"default":"friese","gate":{"enabled":true}}}' > "$VETO_GATE_CLAUDE_DIR/triggers.json"

# E3 Task 3: POST /config — whitelisted settings writes
printf '{ "enabled": true, "effort": "high", "timeout": 100, "timeout2": 150 }' \
  > "$FAKE/.claude/config/veto-gate.json"
T=$(curl -s -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" \
  -d '{"name":"fakerepo","key":"effort","value":"medium"}')
ok "$(printf '%s' "$T" | jq -r '.value')" "medium" "effort set"
ok "$(jq -r '.effort' "$FAKE/.claude/config/veto-gate.json")" "medium" "effort written"
ok "$(jq -r '.timeout' "$FAKE/.claude/config/veto-gate.json")" "100" "other fields preserved"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"effort","value":"turbo"}')
ok "$C" "400" "bad effort value rejected"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"timeout","value":5}')
ok "$C" "400" "non-whitelisted key rejected"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"enabled","value":true}')
ok "$C" "400" "enabled not writable via /config (toggle only)"
T=$(curl -s -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"max_lines","value":500}')
ok "$(jq -r '.max_lines' "$FAKE/.claude/config/veto-gate.json")" "500" "max_lines written"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"max_lines","value":10}')
ok "$C" "400" "max_lines below floor rejected"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"max_lines","value":true}')
ok "$C" "400" "bool masquerading as int rejected"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"max_lines","value":"500"}')
ok "$C" "400" "string number rejected"
T=$(curl -s -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"plan_review","value":false}')
ok "$(jq -r '.plan_review' "$FAKE/.claude/config/veto-gate.json")" "false" "plan_review false written (falsy value ok)"
printf '{ "enabled": true, "qwen": false }' > "$FAKE/.claude/config/veto-gate.json"
T=$(curl -s -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"prechecker","value":"gemini"}')
ok "$(jq -r '.prechecker' "$FAKE/.claude/config/veto-gate.json")" "gemini" "prechecker written"
ok "$(jq -r 'has("qwen")' "$FAKE/.claude/config/veto-gate.json")" "false" "legacy qwen key dropped"
ok "$(jq -r '.enabled' "$FAKE/.claude/config/veto-gate.json")" "true" "enabled untouched by prechecker write"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" -d '{"name":"fakerepo","key":"effort","value":"high"}')
ok "$C" "403" "config without token rejected"
printf 'kaputt{' > "$FAKE/.claude/config/veto-gate.json"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"effort","value":"high"}')
ok "$C" "409" "broken config → 409"
ok "$(cat "$FAKE/.claude/config/veto-gate.json")" "kaputt{" "broken config untouched"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"nix","key":"effort","value":"high"}')
ok "$C" "403" "unregistered repo rejected"
# atomic write: no .tmp remnant next to the config after a write
printf '{ "enabled": true }' > "$FAKE/.claude/config/veto-gate.json"
curl -s -o /dev/null -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"effort","value":"low"}'
ok "$(ls "$FAKE/.claude/config/" | grep -c tmp)" "0" "no tmp remnant (atomic write)"
printf '{ "enabled": true, "effort": "high", "timeout": 100, "timeout2": 150 }' \
  > "$FAKE/.claude/config/veto-gate.json"

# Task 6: kreisel_stop + plan_path werden schaltbar. timeout/timeout2 bleiben
# reine Anzeige (WIRKSAMER Wert, nicht der rohe Konfig-Wert — das Gate hebt
# einen zu kleinen Wert ohnehin an). sensitive_paths bekommt gar keinen
# Schreibweg: die Standardliste ist abgenommen, ein Panel darf sie nicht senken.
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"timeout","value":60}')
ok "$C" "400" "timeout ist nicht schaltbar"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"timeout2","value":60}')
ok "$C" "400" "timeout2 ist nicht schaltbar"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"sensitive_paths","value":["x"]}')
ok "$C" "400" "sensitive_paths hat keinen Schreibweg (nur ERGÄNZEN, nie per Panel ersetzbar)"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"kreisel_stop","value":3}')
ok "$C" "200" "kreisel_stop ist schaltbar"
ok "$(jq -r '.kreisel_stop' "$FAKE/.claude/config/veto-gate.json")" "3" "kreisel_stop geschrieben"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"kreisel_stop","value":21}')
ok "$C" "400" "kreisel_stop über 20 abgelehnt"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"kreisel_stop","value":-1}')
ok "$C" "400" "kreisel_stop unter 0 abgelehnt"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"kreisel_stop","value":true}')
ok "$C" "400" "bool als kreisel_stop abgelehnt (bool ist int-Subklasse)"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"plan_path","value":"../../etc/"}')
ok "$C" "400" "plan_path darf nicht aus dem Repo zeigen"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"plan_path","value":"/etc/"}')
ok "$C" "400" "plan_path muss relativ bleiben (kein führender /)"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:4093/config" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"fakerepo","key":"plan_path","value":"docs/plans"}')
ok "$C" "400" "plan_path ohne abschließenden / abgelehnt"
T=$(curl -s -X POST "http://127.0.0.1:4093/config" -H "X-Veto-Gate-Token: $TOK" \
  -d '{"name":"fakerepo","key":"plan_path","value":"docs/plans/"}')
ok "$(printf '%s' "$T" | jq -r '.value')" "docs/plans/" "plan_path gesetzt"
ok "$(jq -r '.plan_path' "$FAKE/.claude/config/veto-gate.json")" "docs/plans/" "plan_path geschrieben"

# /data: timeout/timeout2 sind sichtbar, aber der WIRKSAME Wert — 100/150 liegen
# unter den kalibrierten Mindestwerten (VG_TIMEOUT_MIN=360/VG_TIMEOUT2_MIN=420,
# im Gate-Skript definiert) und werden angehoben, exakt wie beim echten Gate-Lauf.
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0]|has("timeout")')" "true" "Zeitlimit wird ANGEZEIGT"
ok "$(printf '%s' "$D" | jq -r '.repos[0].timeout')" "360" "timeout unter dem Mindestwert wird angehoben (100 -> 360)"
ok "$(printf '%s' "$D" | jq -r '.repos[0].timeout2')" "420" "timeout2 ebenso angehoben (150 -> 420)"
ok "$(printf '%s' "$D" | jq -r '.repos[0].kreisel_stop')" "3" "kreisel_stop im /data sichtbar"
ok "$(printf '%s' "$D" | jq -r '.repos[0].plan_path')" "docs/plans/" "plan_path im /data sichtbar"

# ein Repo, das schon MEHR Zeit gibt, wird nicht gekappt — nur ein zu kleiner
# Wert wird angehoben, ein bewusst größerer bleibt unangetastet
printf '{ "enabled": true, "timeout": 500, "timeout2": 600 }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].timeout')" "500" "timeout über dem Mindestwert bleibt unverändert"
ok "$(printf '%s' "$D" | jq -r '.repos[0].timeout2')" "600" "timeout2 ebenso unverändert"

# nicht-numerischer timeout ist kein Fakt (kaputte Konfig) und darf /data nicht
# crashen — er fällt auf den Mindestwert zurück, wie ein fehlender Wert
printf '{ "enabled": true, "timeout": "kaputt" }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].timeout')" "360" "nicht-numerischer timeout crasht /data nicht, fällt auf den Mindestwert"

# ohne gesetzte Werte gelten dieselben Defaults wie im Gate-Skript selbst
# (.kreisel_stop // 4, .plan_path // "docs/superpowers/plans/")
printf '{ "enabled": true }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].kreisel_stop')" "4" "kreisel_stop default 4, wie das Gate-Skript"
ok "$(printf '%s' "$D" | jq -r '.repos[0].plan_path')" "docs/superpowers/plans/" "plan_path default wie das Gate-Skript"

# nicht-numerischer kreisel_stop ist kein Fakt und fällt auf den Default zurück
printf '{ "enabled": true, "kreisel_stop": "viel" }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].kreisel_stop')" "4" "nicht-numerischer kreisel_stop fällt auf den Default zurück"

# sensitive_extra: der Konfig-Wert ist sichtbar, aber nur als Anzeige (siehe
# oben: kein Schreibweg über /config) — leer/kaputt zählt als "nichts extra"
printf '{ "enabled": true, "sensitive_paths": ["billing", "geo"] }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].sensitive_extra|join(",")')" "billing,geo" "sensitive_extra im /data sichtbar"
printf '{ "enabled": true }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].sensitive_extra|length')" "0" "kein sensitive_paths konfiguriert -> leere Zusatzliste"
printf '{ "enabled": true, "sensitive_paths": "billing" }' > "$FAKE/.claude/config/veto-gate.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].sensitive_extra|length')" "0" "falsch geformtes sensitive_paths crasht nicht, gilt als leer"

# die servierte HTML trägt die neuen Felder auch wirklich (nicht nur /data)
H=$(curl -s "http://127.0.0.1:4093/")
ok "$H" "kreisel_stop" "kreisel_stop-Feld im Panel"
ok "$H" "plan_path" "plan_path-Feld im Panel"
ok "$H" "heikle Pfade" "sensitive_extra-Anzeige im Panel"
ok "$H" "nicht schaltbar" "Zeitlimit-Anzeige nennt sich bewusst nicht schaltbar"

# Fixture für die nachfolgenden Abschnitte wiederherstellen
printf '{ "enabled": true, "effort": "high", "timeout": 100, "timeout2": 150 }' \
  > "$FAKE/.claude/config/veto-gate.json"

# Task 7: UI sections + safe rendering markers
H=$(curl -s "http://127.0.0.1:4093/")
ok "$H" 'id="live"' "live section"
ok "$H" 'id="repos"' "repos section"
ok "$H" 'id="stats"' "stats section"
ok "$H" "gelöst" "resolved wording"
ok "$H" "textContent" "safe rendering (no data innerHTML)"

# F16: resolved is an approximation — the UI must say so
ok "$H" "Näherung" "resolved approximation hint"

# E3 Task 4: ovals + lock-in + settings zone + responsive (replaces E2 matrix)
ok "$H" 'id="settings"' "settings section"
ok "$H" 'id="msg"' "write-error message zone (R1-B4)"
ok "$H" "renderOvals" "ovals renderer wired"
ok "$H" "renderSettings" "settings renderer wired"
ok "$H" "postCfg" "config write wired"
ok "$H" ".oval.locked" "lock-in style present"
ok "$H" "@media" "responsive breakpoint present"
ok "$H" "GLOBAL" "global oval"
ok "$H" "styleSwitch" "style switch still wired"
ok "$H" "styleSwitch(v)" "style saves clicked value, never a blind toggle"
ok "$H" "Schl\\u00fcssel fehlt" "missing-key hint (R1-B1)"
ok "$H" "resp.ok" "http status checked before refresh (R1-B4)"
ok "$H" "function send(" "shared write path (R3-B3)"
ok "$H" "toggle(name){send(" "toggle on shared error path (R3-B3)"
ok "$H" "verl\\u00e4sst den Rechner" "privacy hint at prechecker choice (R3-B2)"
# Der Prüfer heißt seit dem Umbau minimax. Das Panel bot weiter 'qwen' an —
# ein Klick darauf schrieb einen Wert, den das Gate-Skript nicht kennt (es
# fällt dann auf minimax zurück), und das Panel zeigte ab da etwas anderes,
# als lief. Die Liste kommt jetzt aus /data, damit sie an EINER Stelle steht.
ok "$(printf '%s' "$D" | jq -r '.prechecker_options|join(",")')" "minimax,groq,gemini,none" \
   "prechecker-Liste kommt aus /data"
case "$H" in *"'qwen'"*) F=$((F+1)); echo "FAIL: das Panel bietet weiter qwen an";; *) P=$((P+1));; esac
# der Datenschutz-Hinweis unter der Prüfer-Auswahl nannte noch den alten Namen
# 'qwen' statt 'minimax' — derselbe Alt-Name, den die Zeile darüber schon nicht
# mehr anbietet, hier aber als Erklärtext übersehen wurde (widersprüchlicher Text)
ok "$H" "minimax: bleibt lokal" "Datenschutz-Hinweis nennt minimax statt des alten Namens"
case "$H" in *"qwen: bleibt lokal"*) F=$((F+1)); echo "FAIL: Datenschutz-Hinweis nennt noch qwen";; *) P=$((P+1));; esac

# Task 3: jedes Ergebnis, das die Gate-Läufe protokollieren, braucht einen Klartext. Und ein
# Ergebnis, das NICHT in der Tabelle steht, muss sich melden — sonst veraltet
# sie wieder unbemerkt, so wie sie bei sechs von siebzehn stehen geblieben ist.
for r in size-block grounding-block tests-block kreisel-stop minimax-block cap-block \
         quota-block timeout-block claim-block proof-block override; do
  case "$H" in *"'$r':"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL: kein Klartext für $r";; esac
done
case "$H" in *"unbekanntes Ergebnis"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL: unbekanntes Ergebnis wird nicht benannt";; esac
# Fünf Hex-Ziffern hinter \u gibt es in JavaScript nicht: gelesen werden vier,
# die fünfte wird ein literales Zeichen. Das fällt niemandem auf, weil trotzdem
# etwas erscheint — nur eben das Falsche. $H ist die ROHE, nicht ausgewertete
# Quelle (curl führt kein JS aus) — deshalb hier gegen den Escape-TEXT prüfen,
# nicht gegen ein bereits ausgewertetes Zeichen, das in dieser Rohquelle nie vorkommt.
# Geprüft wird nur die RESULT_DE-Zeile (Newlines dafür geglättet, das Objekt steht
# im Quelltext über mehrere Zeilen): im übrigen Text kollidiert die 5-Stellen-Regel
# mit echten 4-stelligen Escapes, denen zufällig ein Hex-ähnlicher Buchstabe folgt
# (z.B. ü + "fung" in "Prüfung" — vier Hex-Ziffern plus ein 'f', das nur
# Textzufall ist, keine fünfte Escape-Ziffer).
RD=$(printf '%s' "$H" | tr '\n' ' ' | grep -o "var RESULT_DE={[^}]*}[^;]*;")
if printf '%s' "$RD" | grep -qE '\\u[0-9A-Fa-f]{5}'; then
  F=$((F+1)); echo "FAIL: ungueltiges 5-stelliges \\u-Escape in RESULT_DE"
else
  P=$((P+1))
fi
# ── Doku-Schalter + Status ──────────────────────────────────────────────────
# a registered repo with a docs-off config and a last run that carries a docs proof.
# registry is $VETO_GATE_LOG_DIR/repos.json {"repos":[paths]} (see serve.py _registry_paths).
RP="$VETO_GATE_LOG_DIR/proj"; mkdir -p "$RP/.claude/config"
printf '{"enabled":true,"docs":false}\n' > "$RP/.claude/config/veto-gate.json"
jq -cn --arg p "$RP" '{repos:[$p]}' > "$VETO_GATE_LOG_DIR/repos.json"
printf '%s\n' \
  '{"ts":"2026-07-11T10:00:00Z","repo":"proj","branch":"main","result":"codex-pass","dur":9,"proofs":[{"stage":"docs","status":"unavailable","detail":"keine echte Doku für: zod@3.22.4"}]}' \
  >> "$LOG"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="proj")|.docs')" "false" "docs toggle in /data"
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="proj")|.docs_status.status')" "unavailable" "docs status from last run"
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="proj")|.docs_status.detail')" "zod@3.22.4" "docs status detail"
# a NEWER run for the same repo with no docs proof must win over the older
# one's proof — an old status must never look current (codex find)
printf '%s\n' \
  '{"ts":"2026-07-11T10:05:00Z","repo":"proj","branch":"main","result":"codex-pass","dur":3}' \
  >> "$LOG"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="proj")|.docs_status.status')" "-" "no stale docs status from an older run"
# runs.jsonl is external input — a non-list "proofs" (here a number) must not
# crash /data; docs_status falls back to "-" (same defensive contract as _details)
printf '%s\n' \
  '{"ts":"2026-07-11T10:06:00Z","repo":"proj","branch":"main","result":"codex-pass","dur":2,"proofs":42}' \
  >> "$LOG"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="proj")|.docs_status.status')" "-" "non-list proofs tolerated"
# remove the malformed line so the HTML server (still serving $LOG) stays clean
sed -i.bak '$d' "$LOG" && rm -f "$LOG.bak"
# the served HTML (GET /) carries the docs toggle control + its status line, so
# the new /data fields are actually operable, not just present in the payload
H=$(curl -s "http://127.0.0.1:4093/")
ok "$(printf '%s' "$H" | grep -c 'doku-stufe')" "1" "docs toggle label in UI"
ok "$H" "doku (letzter Lauf)" "docs status line in UI"

# ── Test-Freigabe-Schalter (globale allowlist unter flock) ───────────────────
export VETO_GATE_TEST_ALLOWLIST="$VETO_GATE_LOG_DIR/allow"
printf '/ein/fremdes/repo\n' > "$VETO_GATE_TEST_ALLOWLIST"   # a foreign line that must survive
# the smoke-test server above forked BEFORE VETO_GATE_TEST_ALLOWLIST existed — env is
# captured at fork, so it never saw the var. restart_srv (re-)forks the server so
# a just-exported env var actually takes effect, and pulls a fresh per-start token
# for the new instance (a token from a killed process would 403 against this one).
restart_srv(){ kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
  python3 "$S" >/dev/null 2>&1 & SRV=$!; sleep 1
  H=$(curl -s "http://127.0.0.1:$VETO_GATE_PORT/")
  TOK=$(printf '%s' "$H" | grep -o 'VETO_GATE_TOKEN="[a-f0-9]*"' | head -1 | cut -d'"' -f2); }
restart_srv
post(){ curl -s -o /dev/null -w '%{http_code}' -H "X-Veto-Gate-Token: $TOK" -H 'Content-Type: application/json' \
        -d "$1" "http://127.0.0.1:$VETO_GATE_PORT/config"; }
RPREAL=$(cd "$RP" && pwd -P)
# ON: adds exactly the repo's canonical path, keeps the foreign line
ok "$(post '{"name":"proj","key":"tests","value":true}')" "200" "tests ON -> 200"
ok "$(grep -qxF "$RPREAL" "$VETO_GATE_TEST_ALLOWLIST" && echo ja || echo nein)" "ja" "repo path added"
ok "$(grep -qxF '/ein/fremdes/repo' "$VETO_GATE_TEST_ALLOWLIST" && echo ja || echo nein)" "ja" "foreign line kept"
ok "$(grep -c . "$VETO_GATE_TEST_ALLOWLIST")" "2" "exactly two lines"
# /data reflects it
ok "$(python3 "$S" --data-once | jq -r '.repos[]|select(.name=="proj")|.tests_allowed')" "true" "tests_allowed true"
# OFF: removes only the repo's line
ok "$(post '{"name":"proj","key":"tests","value":false}')" "200" "tests OFF -> 200"
ok "$(grep -qxF "$RPREAL" "$VETO_GATE_TEST_ALLOWLIST" && echo ja || echo nein)" "nein" "repo path removed"
ok "$(grep -qxF '/ein/fremdes/repo' "$VETO_GATE_TEST_ALLOWLIST" && echo ja || echo nein)" "ja" "foreign line still kept"
# same bool-only contract as the other /config keys
C=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Veto-Gate-Token: $TOK" -H 'Content-Type: application/json' \
  -d '{"name":"proj","key":"tests","value":"x"}' "http://127.0.0.1:$VETO_GATE_PORT/config")
ok "$C" "400" "tests: non-bool value rejected"
# the served HTML actually carries the new toggle (not just a /data field)
H=$(curl -s "http://127.0.0.1:$VETO_GATE_PORT/")
ok "$(printf '%s' "$H" | grep -c 'tests laufen lassen')" "1" "tests toggle label in UI"
# codex B1: an existing-but-unreadable allowlist must NEVER be silently replaced —
# only a MISSING file may count as an empty list. A read error (permission, disk)
# must abort with 409, or the write-back would wipe every other project's grant.
printf '/ein/fremdes/repo\n' > "$VETO_GATE_TEST_ALLOWLIST"
chmod 000 "$VETO_GATE_TEST_ALLOWLIST"
C=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Veto-Gate-Token: $TOK" -H 'Content-Type: application/json' \
  -d '{"name":"proj","key":"tests","value":true}' "http://127.0.0.1:$VETO_GATE_PORT/config")
ok "$C" "409" "unreadable allowlist -> 409, not clobbered"
chmod 644 "$VETO_GATE_TEST_ALLOWLIST"
ok "$(grep -qxF '/ein/fremdes/repo' "$VETO_GATE_TEST_ALLOWLIST" && echo ja || echo nein)" "ja" "unreadable allowlist left untouched"
# codex B2: bytes that are not valid UTF-8 make read_text() raise ValueError, not
# OSError — must be tolerated exactly like every other external-input read here,
# both in /data (read-only) and in the write path (abort, don't clobber)
printf '\xff\xfe\x00bad' > "$VETO_GATE_TEST_ALLOWLIST"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos|length')" "1" "data-once survives undecodable allowlist"
C=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Veto-Gate-Token: $TOK" -H 'Content-Type: application/json' \
  -d '{"name":"proj","key":"tests","value":true}' "http://127.0.0.1:$VETO_GATE_PORT/config")
ok "$C" "409" "undecodable allowlist -> 409, not clobbered"
printf '/ein/fremdes/repo\n' > "$VETO_GATE_TEST_ALLOWLIST"

# codex B1: mkdir for the allowlist's parent ran BEFORE the try/except, so a
# broken parent path (permission, or a path component that is a plain file)
# raised uncaught — the client got a dropped connection, not a clean JSON error.
BLOCKER="$VETO_GATE_LOG_DIR/blocker"; printf 'x' > "$BLOCKER"   # a FILE blocking the path
export VETO_GATE_TEST_ALLOWLIST="$BLOCKER/sub/allow"
restart_srv
C=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Veto-Gate-Token: $TOK" -H 'Content-Type: application/json' \
  -d '{"name":"proj","key":"tests","value":true}' "http://127.0.0.1:$VETO_GATE_PORT/config")
ok "$C" "409" "broken allowlist parent path -> clean 409, no crash"
export VETO_GATE_TEST_ALLOWLIST="$VETO_GATE_LOG_DIR/allow"
restart_srv

# qwen find: the write lock is NON-BLOCKING with a bounded retry (~1s). A held lock must
# return a clean 409 WITHIN the timeout, never hang the request forever. A blocking LOCK_EX
# would instead wait out the 4s holder and then answer 200 — so both status and timing prove it.
printf '/ein/fremdes/repo\n' > "$VETO_GATE_TEST_ALLOWLIST"
python3 -c "import fcntl,time; f=open('$VETO_GATE_TEST_ALLOWLIST.lock','w'); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(4)" & HOLDER=$!
sleep 0.5
T0=$(date +%s)
C=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Veto-Gate-Token: $TOK" -H 'Content-Type: application/json' \
  -d '{"name":"proj","key":"tests","value":true}' "http://127.0.0.1:$VETO_GATE_PORT/config")
T1=$(date +%s)
ok "$C" "409" "held lock -> clean 409, never an infinite hang"
ok "$([ $((T1-T0)) -le 3 ] && echo ja || echo nein)" "ja" "held lock returns within the bounded wait, not after the holder"
ok "$(grep -qxF '/ein/fremdes/repo' "$VETO_GATE_TEST_ALLOWLIST" && echo ja || echo nein)" "ja" "held lock left the list untouched"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# codex final review: the .lock sidecar is never deleted after a write — deliberate
# (see serve.py docstring), not a leak. Unlinking it would open a TOCTOU race between
# the process that just unlocked+deleted and a process that raced in on the freshly
# recreated path. Proof: the lock file's inode stays IDENTICAL across two separate
# writes — if anything ever unlinked+recreated it, the inode would change.
printf '/ein/fremdes/repo\n' > "$VETO_GATE_TEST_ALLOWLIST"
rm -f "$VETO_GATE_TEST_ALLOWLIST.lock"
env PYTHONPATH="$(dirname "$S")" python3 -c "
import os
os.environ['VETO_GATE_TEST_ALLOWLIST'] = '$VETO_GATE_TEST_ALLOWLIST'
import serve
serve._write_allowlist('/inode/repo-a', True)
"
INO1=$(stat -f%i "$VETO_GATE_TEST_ALLOWLIST.lock" 2>/dev/null || stat -c%i "$VETO_GATE_TEST_ALLOWLIST.lock")
env PYTHONPATH="$(dirname "$S")" python3 -c "
import os
os.environ['VETO_GATE_TEST_ALLOWLIST'] = '$VETO_GATE_TEST_ALLOWLIST'
import serve
serve._write_allowlist('/inode/repo-b', True)
"
INO2=$(stat -f%i "$VETO_GATE_TEST_ALLOWLIST.lock" 2>/dev/null || stat -c%i "$VETO_GATE_TEST_ALLOWLIST.lock")
ok "$([ "$INO1" = "$INO2" ] && echo ja || echo nein)" "ja" "lock file never unlinked+recreated (same inode)"
ok "$(stat -f%z "$VETO_GATE_TEST_ALLOWLIST.lock" 2>/dev/null || stat -c%s "$VETO_GATE_TEST_ALLOWLIST.lock")" "0" "lock file stays empty (no secret content)"
printf '/ein/fremdes/repo\n' > "$VETO_GATE_TEST_ALLOWLIST"

# codex final review: no concurrency stress test existed for the allowlist write path —
# only a single ARTIFICIALLY held lock was ever tested. This spawns N genuinely
# independent OS processes (real cross-process race, the thing the flock docstring
# warns about — "a second serve instance, a hand-edit or the gate"), each granting a
# DISTINCT repo, and proves none of the concurrent grants are lost. Sanity-checked
# against a lock-free variant of _write_allowlist: without the flock, 15 concurrent
# writers dropped 14 of 15 grants (2 of 16 lines survived) — so this test is not vacuous.
N=15
STRESS_PIDS=()
for i in $(seq 1 "$N"); do
  ( env PYTHONPATH="$(dirname "$S")" python3 -c "
import os
os.environ['VETO_GATE_TEST_ALLOWLIST'] = '$VETO_GATE_TEST_ALLOWLIST'
import serve
serve._write_allowlist('/stress/repo-$i', True)
" ) &
  STRESS_PIDS+=("$!")
done
# wait on the CAPTURED worker PIDs only — a bare `wait` blocks on every background
# job of this shell, including the long-running dashboard server ($SRV), which never
# exits on its own and hung the whole suite the first time this test was added.
wait "${STRESS_PIDS[@]}"
ok "$(grep -c . "$VETO_GATE_TEST_ALLOWLIST")" "$((N+1))" "parallel writers: no lost grant ($N concurrent + 1 foreign)"
LOST=0
for i in $(seq 1 "$N"); do
  grep -qxF "/stress/repo-$i" "$VETO_GATE_TEST_ALLOWLIST" || LOST=$((LOST+1))
done
ok "$LOST" "0" "every concurrent writer's repo present"
ok "$(sort "$VETO_GATE_TEST_ALLOWLIST" | uniq -d | wc -l | tr -d ' ')" "0" "no duplicate lines from the race"
printf '/ein/fremdes/repo\n' > "$VETO_GATE_TEST_ALLOWLIST"

# ── Nachtrag Task 1: POST /config roundtrip for key "docs" (same server+token) ─
printf '{"enabled":true,"docs":true}\n' > "$RP/.claude/config/veto-gate.json"
T=$(curl -s -X POST "http://127.0.0.1:$VETO_GATE_PORT/config" -H "X-Veto-Gate-Token: $TOK" \
  -d '{"name":"proj","key":"docs","value":false}')
ok "$(printf '%s' "$T" | jq -r '.value')" "false" "docs set via /config"
ok "$(jq -r '.docs' "$RP/.claude/config/veto-gate.json")" "false" "docs written"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$VETO_GATE_PORT/config" -H "X-Veto-Gate-Token: $TOK" \
  -d '{"name":"proj","key":"docs","value":"x"}')
ok "$C" "400" "docs: non-bool value rejected"
kill "$SRV" 2>/dev/null; SRV=""

# ── Browser-Tab nur auf Wunsch (VETO_GATE_OPEN=1), sonst NIE (owner 2026-07-16) ─────
# Der Serve-Test startet den Server oft; ein unbedingtes `open` spülte dutzende
# Tabs auf. Beweis über einen PATH-Stub `open`, der bei Aufruf einen Merker schreibt.
OPENSTUB=$(mktemp -d); OPENMARK="$VETO_GATE_LOG_DIR/open-called"
cat > "$OPENSTUB/open" <<EOF
#!/usr/bin/env bash
echo called >> "$OPENMARK"
EOF
chmod +x "$OPENSTUB/open"
# Default (kein VETO_GATE_OPEN) → Stub darf NICHT gerufen werden.
# VETO_GATE_OPEN ausdrücklich LEEREN — sonst schlägt der Test fehl, wenn die Umgebung
# ihn schon auf 1 hat (hermetisch, codex-Fund).
rm -f "$OPENMARK"
PATH="$OPENSTUB:$PATH" VETO_GATE_OPEN= python3 "$S" >/dev/null 2>&1 & SRV=$!; sleep 1
ok "$(test -f "$OPENMARK" && echo ja || echo nein)" "nein" "Default: kein Browser-Tab geöffnet"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
# VETO_GATE_OPEN=1 → Stub MUSS gerufen werden (Opt-in bleibt möglich)
rm -f "$OPENMARK"
PATH="$OPENSTUB:$PATH" VETO_GATE_OPEN=1 python3 "$S" >/dev/null 2>&1 & SRV=$!; sleep 1
ok "$(test -f "$OPENMARK" && echo ja || echo nein)" "ja" "VETO_GATE_OPEN=1: Tab wird geöffnet"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
rm -rf "$OPENSTUB"

# favorites: field + sort order
printf '{"repos":["%s"]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"
printf '{"favorites":["fakerepo"]}' > "$VETO_GATE_LOG_DIR/favorites.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].name')" "fakerepo" "Favorit steht zuerst"
ok "$(printf '%s' "$D" | jq -r '.repos[0].favorite')" "true" "favorite-Flag gesetzt"
rm -f "$VETO_GATE_LOG_DIR/favorites.json"
D=$(python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[0].favorite')" "false" "ohne favorites.json: false, kein Crash"

# POST /favorite
python3 "$S" >/dev/null 2>&1 & SRV=$!; sleep 1
RESP=$(python3 -c "
import json, urllib.request, re
html = urllib.request.urlopen('http://127.0.0.1:$VETO_GATE_PORT/').read().decode()
token = re.search(r'VETO_GATE_TOKEN=\"([0-9a-f]+)\"', html).group(1)
req = urllib.request.Request('http://127.0.0.1:$VETO_GATE_PORT/favorite',
    data=json.dumps({'name': 'fakerepo', 'on': True}).encode(),
    headers={'X-Veto-Gate-Token': token, 'Content-Type': 'application/json'})
print(urllib.request.urlopen(req).read().decode())
")
ok "$RESP" '"favorite": true' "POST /favorite antwortet favorite:true"
ok "$(cat "$VETO_GATE_LOG_DIR/favorites.json")" '"fakerepo"' "favorites.json persistiert den Namen"
# 'on' als String (nicht Bool) muss 400 geben, nie truthy durchgehen
RESP2=$(python3 -c "
import json, urllib.request, re, urllib.error
html = urllib.request.urlopen('http://127.0.0.1:$VETO_GATE_PORT/').read().decode()
token = re.search(r'VETO_GATE_TOKEN=\"([0-9a-f]+)\"', html).group(1)
req = urllib.request.Request('http://127.0.0.1:$VETO_GATE_PORT/favorite',
    data=json.dumps({'name': 'x', 'on': 'false'}).encode(),
    headers={'X-Veto-Gate-Token': token, 'Content-Type': 'application/json'})
try:
    urllib.request.urlopen(req); print('NO_ERROR')
except urllib.error.HTTPError as e:
    print(e.code)
")
ok "$RESP2" "400" "'on' als String wird abgelehnt statt truthy interpretiert"

# kaputte favorites.json darf NICHT stillschweigend überschrieben werden
printf 'kaputt{' > "$VETO_GATE_LOG_DIR/favorites.json"
RESP3=$(python3 -c "
import json, urllib.request, re, urllib.error
html = urllib.request.urlopen('http://127.0.0.1:$VETO_GATE_PORT/').read().decode()
token = re.search(r'VETO_GATE_TOKEN=\"([0-9a-f]+)\"', html).group(1)
req = urllib.request.Request('http://127.0.0.1:$VETO_GATE_PORT/favorite',
    data=json.dumps({'name': 'fakerepo', 'on': True}).encode(),
    headers={'X-Veto-Gate-Token': token, 'Content-Type': 'application/json'})
try:
    urllib.request.urlopen(req); print('NO_ERROR')
except urllib.error.HTTPError as e:
    print(e.code)
")
ok "$RESP3" "409" "kaputte favorites.json wird abgelehnt statt ueberschrieben"
ok "$(cat "$VETO_GATE_LOG_DIR/favorites.json")" "kaputt{" "Datei bleibt unveraendert (kein Datenverlust)"
rm -f "$VETO_GATE_LOG_DIR/favorites.json"

# mehrdeutiger Name (zwei registrierte Pfade, gleicher Ordnername) wird abgelehnt
AMB2="$VETO_GATE_LOG_DIR/amb2"; mkdir -p "$AMB2/fakerepo"
printf '{"repos":["%s","%s/fakerepo"]}' "$FAKE" "$AMB2" > "$VETO_GATE_LOG_DIR/repos.json"
RESP4=$(python3 -c "
import json, urllib.request, re, urllib.error
html = urllib.request.urlopen('http://127.0.0.1:$VETO_GATE_PORT/').read().decode()
token = re.search(r'VETO_GATE_TOKEN=\"([0-9a-f]+)\"', html).group(1)
req = urllib.request.Request('http://127.0.0.1:$VETO_GATE_PORT/favorite',
    data=json.dumps({'name': 'fakerepo', 'on': True}).encode(),
    headers={'X-Veto-Gate-Token': token, 'Content-Type': 'application/json'})
try:
    urllib.request.urlopen(req); print('NO_ERROR')
except urllib.error.HTTPError as e:
    print(e.code)
")
ok "$RESP4" "409" "mehrdeutiger Name wird abgelehnt, nicht beiden Repos zugewiesen"
# Ausschalten muss trotz Mehrdeutigkeit erlaubt bleiben (sonst nie mehr entfernbar)
RESP5=$(python3 -c "
import json, urllib.request, re
html = urllib.request.urlopen('http://127.0.0.1:$VETO_GATE_PORT/').read().decode()
token = re.search(r'VETO_GATE_TOKEN=\"([0-9a-f]+)\"', html).group(1)
req = urllib.request.Request('http://127.0.0.1:$VETO_GATE_PORT/favorite',
    data=json.dumps({'name': 'fakerepo', 'on': False}).encode(),
    headers={'X-Veto-Gate-Token': token, 'Content-Type': 'application/json'})
print(urllib.request.urlopen(req).read().decode())
")
ok "$RESP5" '"favorite": false' "Ausschalten funktioniert trotz mehrdeutigem Namen"
printf '{"repos":["%s"]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"

kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
rm -f "$VETO_GATE_LOG_DIR/favorites.json"

# ── Task 5: GitHub-Repos zusammengeführt — über die Remote-URL, nie den
# Ordnernamen (UL-002) — und ein Fehlschlag beim Zusammenführen nennt seinen
# GRUND, statt "0 Repos" zu behaupten (UL-008). Eigenes, leeres HOME/Desktop
# je Aufruf (inline, nicht exportiert) — die restliche Suite bleibt auf dem
# HOME/GH_BIN aus dem Datei-Kopf isoliert.
printf '{"repos":[]}' > "$VETO_GATE_LOG_DIR/repos.json"   # nur die Desktop-Funde sollen hier zählen
GHHOME="$VETO_GATE_LOG_DIR/ghhome"; mkdir -p "$GHHOME/Desktop/lokalername" "$GHHOME/Desktop/nurlokal"
git -C "$GHHOME/Desktop/lokalername" init -q
git -C "$GHHOME/Desktop/lokalername" config user.email t@t; git -C "$GHHOME/Desktop/lokalername" config user.name t
git -C "$GHHOME/Desktop/lokalername" remote add origin https://github.com/x/matched.git
git -C "$GHHOME/Desktop/nurlokal" init -q
GHSTUB="$VETO_GATE_LOG_DIR/ghstub"
cat > "$GHSTUB" <<'SH'
#!/bin/sh
printf '[{"name":"matched","url":"https://github.com/x/matched"},{"name":"nurgithub","url":"https://github.com/x/nurgithub"}]'
SH
chmod +x "$GHSTUB"

D=$(HOME="$GHHOME" VETO_GATE_GH_BIN="$GHSTUB" python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.github_error')" "null" "T5.1 github_error null bei Erfolg"
ok "$(printf '%s' "$D" | jq -r '[.repos[].name]|sort|join(",")')" "lokalername,nurgithub,nurlokal" "T5.2 Desktop-Funde + reines GitHub-Repo in einer Liste"
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="lokalername")|.github')" "true" "T5.3 Match über die Remote-URL, der Ordner heißt anders als das GitHub-Repo"
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="lokalername")|.cloned')" "true" "T5.4 lokal geklont"
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="nurlokal")|.github')" "false" "T5.5 kein GitHub-Treffer -> github:false"
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="nurgithub")|.cloned')" "false" "T5.6 nur auf GitHub — nicht geklont, nicht schaltbar"
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="nurgithub")|has("path")')" "false" "T5.7 kein Pfad auch bei ungeklonten Einträgen"
ok "$(printf '%s' "$D" | jq -r '[.repos[]|has("path")]|any')" "false" "T5.8 absoluter Pfad verlässt den Server nie, auch nicht nach dem Merge"
rm -f "$VETO_GATE_LOG_DIR/github.json"   # Puffer nicht über dieses Testende hinaus stehen lassen

# GitHub nicht erreichbar (kein gh): der Grund steht in der Antwort — nie
# "0 Repos", das wäre eine Behauptung über etwas, das nie geprüft wurde.
D=$(HOME="$GHHOME" VETO_GATE_GH_BIN=/nonexistent/gh python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.github_error != null')" "true" "T5.9 github_error nennt den Grund"
ok "$(printf '%s' "$D" | jq -r '[.repos[].name]|sort|join(",")')" "lokalername,nurlokal" "T5.10 lokale Repos bleiben sichtbar, auch wenn GitHub ausfällt"

# Registrierter Pfad, der ZUGLEICH unter Desktop liegt: einmal, nicht doppelt
printf '{"repos":["%s"]}' "$GHHOME/Desktop/nurlokal" > "$VETO_GATE_LOG_DIR/repos.json"
D=$(HOME="$GHHOME" VETO_GATE_GH_BIN=/nonexistent/gh python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '[.repos[]|select(.name=="nurlokal")]|length')" "1" "T5.11 Registry-Pfad + Desktop-Fund dedupliziert"
printf '{"repos":["%s"]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"   # Fixture wiederherstellen

# ── Fix-Runde 1 (Koordinator-Befund, serve.py:707): ein cloned:false-Eintrag
# hat kein timeout/timeout2 (repolist.py merge() liefert für ihn absichtlich
# nur 5 Felder — keine lokale Konfig, kein Wert). Die Behauptung, die geprüft
# werden muss, ist über das GERENDERTE Panel ("zeigt im Panel wörtlich
# 'timeout undefineds/undefineds'") — ein Grep im rohen, nicht ausgewerteten
# JS-Quelltext würde nur pruefen, ob mein eigener Fix-Text irgendwo steht,
# nicht ob er WIRKT (Task 5 Falle 2). Deshalb wird das tatsächlich
# ausgelieferte Skript hier mit Node wirklich ausgeführt — Node ist auf
# diesem Rechner vorhanden, `vm` ist Node-Kern, kein zusätzliches Paket —
# mit einem minimalen DOM-Stub, gegen echte /data-Daten aus einem
# cloned:false-Fund. Wirksamkeit belegt: Fix-Zeile zurückgesetzt (r.timeout
# ohne Fallback) → dieser Test schlägt fehl (siehe task-5-report.md).
FR1HOME="$VETO_GATE_LOG_DIR/fr1home"; mkdir -p "$FR1HOME/Desktop"
FR1STUB="$VETO_GATE_LOG_DIR/fr1stub"
cat > "$FR1STUB" <<'SH'
#!/bin/sh
printf '[{"name":"nurgithub","url":"https://github.com/x/nurgithub"}]'
SH
chmod +x "$FR1STUB"
printf '{"repos":[]}' > "$VETO_GATE_LOG_DIR/repos.json"
D=$(HOME="$FR1HOME" VETO_GATE_GH_BIN="$FR1STUB" python3 "$S" --data-once)
rm -f "$VETO_GATE_LOG_DIR/github.json"
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="nurgithub")|.cloned')" "false" "FR1.0 Testvoraussetzung: nurgithub ist cloned:false"

python3 "$S" >/dev/null 2>&1 & SRV=$!; sleep 1
H=$(curl -s "http://127.0.0.1:$VETO_GATE_PORT/")
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

SCRIPT=$(printf '%s' "$H" | python3 -c "
import sys
html = sys.stdin.read()
i = html.index('function el(tag')   # Anfang des grossen Render-Skripts
j = html.index('</script>', i)
print(html[i:j])
")

NODEOUT=$(D="$D" SCRIPT="$SCRIPT" node -e '
const vm = require("vm");
function makeEl(){
  const e = {className:"",children:[],attrs:{},
    appendChild(c){this.children.push(c);return c;},
    addEventListener(){}, contains(){return false;},
    replaceChildren(){this.children=[];this._t="";},
    set textContent(v){ this._t = String(v); },
    get textContent(){ return (this._t||"") + this.children.map(c=>c.textContent||"").join(""); }};
  return e;
}
const settingsBox = makeEl();
const sandbox = {
  document: { getElementById: id => id === "settings" ? settingsBox : makeEl(),
              activeElement: null, createElement: makeEl },
  localStorage: { getItem: () => null, setItem: () => {} },
  setInterval: () => {}, console,
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(process.env.SCRIPT, sandbox);
const data = JSON.parse(process.env.D);
sandbox.SEL = "nurgithub";
sandbox.renderSettings(data);
const text = settingsBox.textContent;
if (text.indexOf("undefined") !== -1) {
  console.log("FAIL-UNDEFINED:" + text);
} else if (text.indexOf("nicht hier") === -1) {
  console.log("FAIL-NO-HONEST-LABEL:" + text);
} else {
  console.log("OK");
}
' 2>&1)
ok "$NODEOUT" "OK" "FR1.1 gerendertes Panel für cloned:false zeigt nirgends 'undefined', sondern 'nicht hier'"
printf '{"repos":["%s"]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"   # Fixture wiederherstellen

# ── Task 8: Zeitstrahl — ein Kästchen je Zug, rot ist eine Lücke in einer
# sonst grünen Reihe. /data trägt "trail" nur für das EINGELOCKTE Repo, per
# Query-Parameter ?repo=NAME übertragen (Repos werden über den Namen
# adressiert, nie über einen Pfad, s.o.). Die CLI-Form --data-once hat keinen
# Query-String, deshalb liest sie denselben Namen aus einer VETO_GATE_*-
# Variable — dasselbe Muster wie jede andere Server-Einstellung hier.
TRAILREPO="$VETO_GATE_LOG_DIR/repo"
mkdir -p "$TRAILREPO/.claude/session-trace" "$TRAILREPO/.claude/session-flags"
printf '{"ts":"2026-07-30T10:00:00Z","turn":1,"tool":"Skill","skill_name":"brainstorming"}\n' \
  > "$TRAILREPO/.claude/session-trace/sX.jsonl"
printf 'critical\tbrainstorming\n' > "$TRAILREPO/.claude/session-flags/sX-expected-skills-1"
printf 'critical\twriting-plans\n' > "$TRAILREPO/.claude/session-flags/sX-expected-skills-2"
# Ergänzung zum Auftragszettel, keine Abweichung: Zug 1 soll GRÜN sein (alles
# deckungsgleich), aber seit Baustein 4 zieht session_trail() auch die dritte
# Quelle heran — die Behauptungs-Datei. Fehlt sie, ist der Zug "nicht erfasst",
# nicht grün (geprüft per direktem session_trail()-Aufruf gegen exakt die
# Zettel-Fixture, siehe task-8-report.md). Ohne diese Zeile wären Zug 1 und
# Zug 2 identisch "nicht erfasst" und der Test prüfte keine echte Ampel mehr.
printf 'brainstorming\n' > "$TRAILREPO/.claude/session-flags/sX-claimed-skills-1"
printf '{"repos":["%s","%s"]}' "$FAKE" "$TRAILREPO" > "$VETO_GATE_LOG_DIR/repos.json"

D=$(VETO_GATE_TRAIL_REPO=repo python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.trail[0].turns[0].light')" "gruen" "Zug 1 gruen"
ok "$(printf '%s' "$D" | jq -r '.trail[0].turns[1].light')" "nicht erfasst" "Zug 2 hat keine Spur"

python3 "$S" >/dev/null 2>&1 & SRV=$!; sleep 1
H=$(curl -s "http://127.0.0.1:$VETO_GATE_PORT/")
case "$H" in *"Zeitstrahl"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL: kein Zeitstrahl im Panel";; esac
ok "$H" 'id="trail"' "Task8.2 Zeitstrahl-Container im Panel"
ok "$H" 'id="trail-detail"' "Task8.3 Klick-Detailbereich im Panel"
ok "$H" "renderTrail" "Task8.4 Zeitstrahl-Renderer verdrahtet"

# GET /data?repo= liefert über HTTP denselben Zeitstrahl wie --data-once, und
# ohne den Parameter (kein Repo eingelockt) bleibt trail leer statt zu raten
DH=$(curl -s "http://127.0.0.1:$VETO_GATE_PORT/data?repo=repo")
ok "$(printf '%s' "$DH" | jq -r '.trail[0].turns[0].light')" "gruen" "Task8.5 HTTP /data?repo= liefert denselben Zeitstrahl"
DH0=$(curl -s "http://127.0.0.1:$VETO_GATE_PORT/data")
ok "$(printf '%s' "$DH0" | jq -r '.trail|length')" "0" "Task8.6 ohne ?repo= kein Zeitstrahl (kein Repo gewählt)"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

# ── das gerenderte Panel wirklich ausführen (Falle 2 vom Zettel: eine Prüfung
# im rohen Quelltext beweist nichts). Vier Züge, vier Farben, vier
# UNTERSCHEIDBARE Zeichen (nicht nur Farbe — schlecht sehende Nutzer), und ein
# Klick öffnet die drei Listen + Gründe.
python3 "$S" >/dev/null 2>&1 & SRV=$!; sleep 1
H=$(curl -s "http://127.0.0.1:$VETO_GATE_PORT/")
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

SCRIPT=$(printf '%s' "$H" | python3 -c "
import sys
html = sys.stdin.read()
i = html.index('function el(tag')   # Anfang des grossen Render-Skripts
j = html.index('</script>', i)
print(html[i:j])
")

TRAILOUT=$(SCRIPT="$SCRIPT" node -e '
const vm = require("vm");
function makeEl(){
  const e = {className:"",children:[],attrs:{},_listeners:{},
    appendChild(c){this.children.push(c);return c;},
    addEventListener(t,cb){this._listeners[t]=cb;},
    contains(){return false;},
    replaceChildren(){this.children=[];this._t="";},
    set textContent(v){ this._t = String(v); },
    get textContent(){ return (this._t||"") + this.children.map(c=>c.textContent||"").join(""); }};
  return e;
}
const trailBox = makeEl(), detailBox = makeEl();
const ids = {trail: trailBox, "trail-detail": detailBox};
const sandbox = {
  document: { getElementById: id => ids[id] || makeEl(),
              activeElement: null, createElement: makeEl },
  localStorage: { getItem: () => null, setItem: () => {} },
  setInterval: () => {}, console,
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(process.env.SCRIPT, sandbox);
const data = { repos: [{name:"demo", cloned:true}],
  trail: [{session:"sX", turns: [
    {turn:1, light:"gruen", reasons:[], demanded:[["critical","brainstorming"]], ran:["brainstorming"], claimed:["brainstorming"]},
    {turn:2, light:"rot", reasons:["Pflicht-Skill 'writing-plans' war gefordert und lief nie"], demanded:[["critical","writing-plans"]], ran:[], claimed:[]},
    {turn:3, light:"grau", reasons:[], demanded:[], ran:[], claimed:[]},
    {turn:4, light:"nicht erfasst", reasons:["keine Spur-Datei fuer diesen Zug"], demanded:[], ran:[], claimed:[]}
  ]}] };
sandbox.SEL = "demo";
sandbox.renderTrail(data);
// eine Zeile (eine Sitzung): erst das Sitzungs-Label, dann vier Kästchen — die
// Kästchen tragen alle die Klasse "tbox …", das Label nicht
const boxes = trailBox.children[0].children.filter(c => c.className.indexOf("tbox") === 0);
if (boxes.length !== 4) { console.log("FAIL-COUNT:" + boxes.length); process.exit(0); }
const classes = boxes.map(b => b.className);
const symbols = boxes.map(b => b.textContent);
const wantClasses = ["tbox gruen","tbox rot","tbox grau","tbox fehlt"];
if (JSON.stringify(classes) !== JSON.stringify(wantClasses)) {
  console.log("FAIL-CLASS:" + classes.join("|")); process.exit(0);
}
if (new Set(symbols).size !== 4) { console.log("FAIL-SYMBOLS-NOT-DISTINCT:" + symbols.join("|")); process.exit(0); }
// Klick auf das rote Kästchen (Zug 2) öffnet die drei Listen + Gründe
boxes[1]._listeners.click();
const dt = detailBox.textContent;
if (dt.indexOf("writing-plans") === -1) { console.log("FAIL-DETAIL-DEMANDED:" + dt); process.exit(0); }
if (dt.indexOf("gefordert und lief nie") === -1) { console.log("FAIL-DETAIL-REASON:" + dt); process.exit(0); }
console.log("OK");
' 2>&1)
ok "$TRAILOUT" "OK" "Task8.7 vier Züge, vier unterscheidbare Kästchen, Klick zeigt Gründe"

# nicht eingelockt: ehrlicher Hinweis statt leerer Fläche
NOSEL=$(SCRIPT="$SCRIPT" node -e '
const vm = require("vm");
function makeEl(){ const e = {className:"",children:[],attrs:{},_listeners:{},
  appendChild(c){this.children.push(c);return c;}, addEventListener(t,cb){this._listeners[t]=cb;},
  contains(){return false;}, replaceChildren(){this.children=[];this._t="";},
  set textContent(v){ this._t=String(v); }, get textContent(){ return (this._t||"")+this.children.map(c=>c.textContent||"").join(""); }};
  return e; }
const trailBox = makeEl(), detailBox = makeEl();
const ids = {trail: trailBox, "trail-detail": detailBox};
const sandbox = { document:{getElementById:id=>ids[id]||makeEl(), activeElement:null, createElement:makeEl},
  localStorage:{getItem:()=>null,setItem:()=>{}}, setInterval:()=>{}, console };
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(process.env.SCRIPT, sandbox);
sandbox.SEL = null;
sandbox.renderTrail({repos:[], trail:[]});
console.log(trailBox.textContent);
' 2>&1)
case "$NOSEL" in *"einlocken"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL: kein Hinweis ohne eingelocktes Repo: $NOSEL";; esac

# cloned:false (Task 5, GitHub-Repo ohne lokalen Klon): kein leeres Feld,
# sondern ein ehrlicher Satz — genau die Vorgabe aus dem Auftrag.
NOCLONE=$(SCRIPT="$SCRIPT" node -e '
const vm = require("vm");
function makeEl(){ const e = {className:"",children:[],attrs:{},_listeners:{},
  appendChild(c){this.children.push(c);return c;}, addEventListener(t,cb){this._listeners[t]=cb;},
  contains(){return false;}, replaceChildren(){this.children=[];this._t="";},
  set textContent(v){ this._t=String(v); }, get textContent(){ return (this._t||"")+this.children.map(c=>c.textContent||"").join(""); }};
  return e; }
const trailBox = makeEl(), detailBox = makeEl();
const ids = {trail: trailBox, "trail-detail": detailBox};
const sandbox = { document:{getElementById:id=>ids[id]||makeEl(), activeElement:null, createElement:makeEl},
  localStorage:{getItem:()=>null,setItem:()=>{}}, setInterval:()=>{}, console };
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(process.env.SCRIPT, sandbox);
sandbox.SEL = "nurgithub";
sandbox.renderTrail({repos:[{name:"nurgithub", cloned:false}], trail:[]});
console.log(trailBox.textContent);
' 2>&1)
case "$NOCLONE" in *"nicht lokal geklont"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL: cloned:false zeigt keinen ehrlichen Hinweis: $NOCLONE";; esac
case "$NOCLONE" in "") F=$((F+1)); echo "FAIL: cloned:false Feld bleibt leer statt einen Hinweis zu zeigen";; *) P=$((P+1));; esac

printf '{"repos":["%s"]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"   # Fixture wiederherstellen

# ── Schluss-Review K1/W4: Repo-LISTE und Repo-AUFLOESUNG kommen aus DERSELBEN
# Quelle. Vorher kam die Liste aus Registry + Desktop-Fund, die Aufloesung nur
# aus der Registry. Gemessen am echten Rechner: 9 Registry-Eintraege gegen
# 30 Desktop-Repos, 22 nicht registriert, 21 davon MIT eigenen Spur-Dateien —
# fuer die lieferte der Zeitstrahl eine leere Liste und das Panel schrieb
# "noch keine Sitzungen aufgezeichnet", ohne je nachgesehen zu haben. Und jeder
# Klick auf so ein Repo antwortete "nicht registriert".
DESK="$FAKEHOME/Desktop/desktoprepo"
mkdir -p "$DESK/.git" "$DESK/.claude/session-trace" "$DESK/.claude/session-flags"
printf '{"ts":"2026-07-31T10:00:00Z","turn":1,"tool":"Skill","skill_name":"brainstorming"}\n' \
  > "$DESK/.claude/session-trace/sD.jsonl"
printf 'critical\tbrainstorming\n' > "$DESK/.claude/session-flags/sD-expected-skills-1"
printf 'brainstorming\n' > "$DESK/.claude/session-flags/sD-claimed-skills-1"
# bewusst NICHT in repos.json eingetragen — genau der Fall aus dem Befund
D=$(VETO_GATE_TRAIL_REPO=desktoprepo python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.repos[]|select(.name=="desktoprepo")|.cloned')" "true" \
   "K1.0 Testvoraussetzung: unregistriertes Desktop-Repo steht in der Liste"
ok "$(printf '%s' "$D" | jq -r '.trail|length')" "1" "K1.1 und hat einen Zeitstrahl"
ok "$(printf '%s' "$D" | jq -r '.trail[0].turns[0].light')" "gruen" "K1.2 dessen Ampel ausgewertet wird"
ok "$(printf '%s' "$D" | jq -r '.trail_error')" "null" "K1.3 kein Grund noetig — es wurde nachgesehen"

D=$(VETO_GATE_TRAIL_REPO=gibtsnicht python3 "$S" --data-once)
ok "$(printf '%s' "$D" | jq -r '.trail|length')" "0" "K1.4 unbekannter Name: kein Zeitstrahl"
ok "$(printf '%s' "$D" | jq -r '.trail_error')" "weder in der Registry" \
   "K1.5 und der Grund steht da, statt zu schweigen"
ok "$(printf '%s' "$D" | jq -r '.trail_error')" "UNGEPR" "K1.5b und sagt ausdruecklich ungeprueft"

# W4: derselbe Fund auf den SCHREIBwegen — ein Klick auf ein unregistriertes
# Desktop-Repo antwortete "nicht registriert" statt zu schalten.
python3 "$S" >/dev/null 2>&1 & SRV=$!; sleep 1
H=$(curl -s "http://127.0.0.1:$VETO_GATE_PORT/")
TOK=$(printf '%s' "$H" | grep -o 'VETO_GATE_TOKEN="[a-f0-9]*"' | head -1 | cut -d'"' -f2)
T=$(curl -s -X POST "http://127.0.0.1:$VETO_GATE_PORT/toggle" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"desktoprepo"}')
ok "$(printf '%s' "$T" | jq -r '.enabled')" "true" "W4.1 /toggle schaltet ein unregistriertes Desktop-Repo"
ok "$(jq -r '.enabled' "$DESK/.claude/config/veto-gate.json")" "true" "W4.2 und schreibt dessen Konfig"
T=$(curl -s -X POST "http://127.0.0.1:$VETO_GATE_PORT/config" -H "X-Veto-Gate-Token: $TOK" \
     -d '{"name":"desktoprepo","key":"effort","value":"low"}')
ok "$(printf '%s' "$T" | jq -r '.value')" "low" "W4.3 /config ebenso"
ok "$(jq -r '.effort' "$DESK/.claude/config/veto-gate.json")" "low" "W4.4 und der Wert steht in der Datei"
C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$VETO_GATE_PORT/toggle" \
     -H "X-Veto-Gate-Token: $TOK" -d '{"name":"gibtsnicht"}')
ok "$C" "403" "W4.5 ein wirklich unbekannter Name wird weiter abgelehnt"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""

# und das PANEL zeigt den Grund — im ausgefuehrten Skript, nicht im Rohtext
TERR=$(SCRIPT="$SCRIPT" node -e '
const vm = require("vm");
function makeEl(){ const e = {className:"",children:[],attrs:{},_listeners:{},
  appendChild(c){this.children.push(c);return c;}, addEventListener(t,cb){this._listeners[t]=cb;},
  contains(){return false;}, replaceChildren(){this.children=[];this._t="";},
  set textContent(v){ this._t=String(v); }, get textContent(){ return (this._t||"")+this.children.map(c=>c.textContent||"").join(""); }};
  return e; }
const trailBox = makeEl(), detailBox = makeEl();
const ids = {trail: trailBox, "trail-detail": detailBox};
const sandbox = { document:{getElementById:id=>ids[id]||makeEl(), activeElement:null, createElement:makeEl},
  localStorage:{getItem:()=>null,setItem:()=>{}}, setInterval:()=>{}, console };
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(process.env.SCRIPT, sandbox);
sandbox.SEL = "irgendwas";
sandbox.renderTrail({repos:[{name:"irgendwas", cloned:true}], trail:[],
  trail_error:"TESTGRUND: nicht aufloesbar, UNGEPRUEFT"});
console.log(trailBox.textContent);
' 2>&1)
case "$TERR" in *"TESTGRUND"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL: Panel zeigt trail_error nicht: $TERR";; esac
case "$TERR" in *"noch keine Sitzungen"*) F=$((F+1)); echo "FAIL: Panel behauptet trotz Fehlergrund 'keine Sitzungen'";; *) P=$((P+1));; esac

rm -rf "$DESK"
printf '{"repos":["%s"]}' "$FAKE" > "$VETO_GATE_LOG_DIR/repos.json"   # Fixture wiederherstellen

# ── Schluss-Review K6 (Entscheid: BAUEN): worktree_of wurde berechnet und
# von keinem Skript gelesen — 20 von 30 lokalen Repos sind Ableger, die Liste
# war also genau die flache, unlesbare, die der Entwurf ausschliesst. Ableger
# erscheinen eingeklappt unter ihrem Hauptordner, jeder mit EIGENEM Zustand.
WTOUT=$(SCRIPT="$SCRIPT" node -e '
const vm = require("vm");
function makeEl(){ const e = {className:"",children:[],attrs:{},_listeners:{},style:{},title:"",
  appendChild(c){this.children.push(c);return c;}, addEventListener(t,cb){this._listeners[t]=cb;},
  contains(){return false;}, replaceChildren(){this.children=[];this._t="";},
  set textContent(v){ this._t=String(v); }, get textContent(){ return (this._t||"")+this.children.map(c=>c.textContent||"").join(""); }};
  return e; }
const favBox = makeEl(), restBox = makeEl(), btn = makeEl();
const ids = {repos: favBox, "repos-rest": restBox, "repos-toggle": btn};
const sandbox = { document:{getElementById:id=>ids[id]||makeEl(), activeElement:null, createElement:makeEl},
  localStorage:{getItem:()=>"1",setItem:()=>{}}, setInterval:()=>{}, console };
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(process.env.SCRIPT, sandbox);
const data = {repos:[
  {name:"Alpha", worktree_of:null, enabled:true,  cloned:true, exists:true, favorite:false},
  {name:"alpha-e7", worktree_of:"Alpha", enabled:false, cloned:true, exists:true, favorite:false},
  {name:"alpha-dash", worktree_of:"Alpha", enabled:false, cloned:true, exists:true, favorite:false},
  {name:"solo", worktree_of:null, enabled:false, cloned:true, exists:true, favorite:false}
]};
sandbox.SEL = null;
sandbox.renderOvals(data);
const ovals = () => restBox.children.filter(c => c.className.indexOf("oval") === 0).map(o => o.textContent);
// eingeklappt: nur Hauptordner + solo, KEIN Ableger
const flat = ovals().join("|");
if (flat.indexOf("alpha-e7") !== -1) { console.log("FAIL-NOT-COLLAPSED:"+flat); process.exit(0); }
if (flat.indexOf("Alpha") === -1 || flat.indexOf("solo") === -1) { console.log("FAIL-MISSING-TOP:"+flat); process.exit(0); }
const exp = restBox.children.filter(c => c.className === "opt");
if (exp.length !== 1) { console.log("FAIL-EXPANDER-COUNT:"+exp.length); process.exit(0); }
if (exp[0].textContent.indexOf("2 Ableger") === -1) { console.log("FAIL-EXPANDER-TEXT:"+exp[0].textContent); process.exit(0); }
// und die Zahl im Knopf verschweigt die eingeklappten nicht
if (btn.textContent.indexOf("(4)") === -1) { console.log("FAIL-COUNT:"+btn.textContent); process.exit(0); }
// aufklappen
exp[0]._listeners.click();
const grp = restBox.children.filter(c => c.className === "wtgrp");
if (grp.length !== 1) { console.log("FAIL-NO-GROUP:"+grp.length); process.exit(0); }
const kids = grp[0].children;
if (kids.length !== 2) { console.log("FAIL-KID-COUNT:"+kids.length); process.exit(0); }
const names = kids.map(k => k.textContent).join("|");
if (names.indexOf("alpha-e7") === -1 || names.indexOf("alpha-dash") === -1) { console.log("FAIL-KID-NAMES:"+names); process.exit(0); }
// jeder Ableger traegt SEINEN EIGENEN Zustand: Hauptordner scharf, Ableger aus
const parent = restBox.children.filter(c => c.className.indexOf("oval") === 0)
  .find(o => o.textContent.indexOf("Alpha") !== -1);   // Ableger heissen klein: alpha-e7
const dot = e => e.children.filter(c => c.className === "dot-on" || c.className === "dot-off").map(c => c.className)[0];
if (dot(parent) !== "dot-on") { console.log("FAIL-PARENT-STATE:"+dot(parent)); process.exit(0); }
if (dot(kids[0]) !== "dot-off" || dot(kids[1]) !== "dot-off") { console.log("FAIL-KID-STATE:"+dot(kids[0])+"/"+dot(kids[1])); process.exit(0); }
console.log("OK");
' 2>&1)
ok "$WTOUT" "OK" "K6.1 Ableger eingeklappt unter ihrem Hauptordner, jeder mit eigenem Zustand"

# ein selbst angehefteter Ableger bleibt oben stehen — eine Anheftung darf nicht
# durch die Gruppierung verschwinden
WTFAV=$(SCRIPT="$SCRIPT" node -e '
const vm = require("vm");
function makeEl(){ const e = {className:"",children:[],attrs:{},_listeners:{},style:{},title:"",
  appendChild(c){this.children.push(c);return c;}, addEventListener(t,cb){this._listeners[t]=cb;},
  contains(){return false;}, replaceChildren(){this.children=[];this._t="";},
  set textContent(v){ this._t=String(v); }, get textContent(){ return (this._t||"")+this.children.map(c=>c.textContent||"").join(""); }};
  return e; }
const favBox = makeEl(), restBox = makeEl(), btn = makeEl();
const ids = {repos: favBox, "repos-rest": restBox, "repos-toggle": btn};
const sandbox = { document:{getElementById:id=>ids[id]||makeEl(), activeElement:null, createElement:makeEl},
  localStorage:{getItem:()=>"1",setItem:()=>{}}, setInterval:()=>{}, console };
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(process.env.SCRIPT, sandbox);
sandbox.SEL = null;
sandbox.renderOvals({repos:[
  {name:"Alpha", worktree_of:null, enabled:true, cloned:true, exists:true, favorite:false},
  {name:"alpha-e7", worktree_of:"Alpha", enabled:false, cloned:true, exists:true, favorite:true}
]});
console.log(favBox.textContent);
' 2>&1)
case "$WTFAV" in *"alpha-e7"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL: angehefteter Ableger verschwindet in der Gruppe: $WTFAV";; esac

# ── Schluss-Review K8: der Standard-Block schrieb fuer ein Repo OHNE Konfig
# timeout=100/timeout2=150 — beide UNTER den kalibrierten Mindestwerten
# (VG_TIMEOUT_MIN=360 / VG_TIMEOUT2_MIN=420 im Gate-Skript) und im Widerspruch
# zur Zusage des Panels, das Zeitlimit sei nicht schaltbar. Wirkungslos nur,
# weil das Gate wieder anhebt.
K8="$FAKEHOME/Desktop/k8repo"; mkdir -p "$K8/.git"
python3 "$S" >/dev/null 2>&1 & SRV=$!; sleep 1
H=$(curl -s "http://127.0.0.1:$VETO_GATE_PORT/")
TOK=$(printf '%s' "$H" | grep -o 'VETO_GATE_TOKEN="[a-f0-9]*"' | head -1 | cut -d'"' -f2)
curl -s -o /dev/null -X POST "http://127.0.0.1:$VETO_GATE_PORT/toggle" -H "X-Veto-Gate-Token: $TOK" -d '{"name":"k8repo"}'
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
ok "$(jq -r 'has("timeout")' "$K8/.claude/config/veto-gate.json")" "false" "K8.1 kein timeout in eine frische Konfig geschrieben"
ok "$(jq -r 'has("timeout2")' "$K8/.claude/config/veto-gate.json")" "false" "K8.2 auch kein timeout2"
ok "$(jq -r '.enabled' "$K8/.claude/config/veto-gate.json")" "true" "K8.3 der Schalter selbst wirkt weiter"
rm -rf "$K8"

# ── Schluss-Review K2: github_error wurde berechnet, ausgeliefert und geprueft,
# aber KEIN Skript las ihn. Im Panel war "gh fehlt / nicht angemeldet /
# Zeitablauf" damit ununterscheidbar von "GitHub hat nichts". Geprueft wird am
# AUSGEFUEHRTEN Skript — ein Grep im Rohtext beweist nichts ueber das Angezeigte.
ok "$(printf '%s' "$D" | jq -r '.github_error')" "gh" "K2.0 Testvoraussetzung: /data traegt einen Grund"
GHOUT=$(SCRIPT="$SCRIPT" node -e '
const vm = require("vm");
function makeEl(){ const e = {className:"",children:[],attrs:{},_listeners:{},
  appendChild(c){this.children.push(c);return c;}, addEventListener(t,cb){this._listeners[t]=cb;},
  contains(){return false;}, replaceChildren(){this.children=[];this._t="";},
  set textContent(v){ this._t=String(v); }, get textContent(){ return (this._t||"")+this.children.map(c=>c.textContent||"").join(""); }};
  return e; }
const ghBox = makeEl();
const sandbox = { document:{getElementById:id=>id==="ghinfo"?ghBox:makeEl(), activeElement:null, createElement:makeEl},
  localStorage:{getItem:()=>null,setItem:()=>{}}, setInterval:()=>{}, console };
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(process.env.SCRIPT, sandbox);
sandbox.renderGithub({github_error:"TESTGRUND-gh-nicht-angemeldet"});
const withReason = ghBox.textContent;
sandbox.renderGithub({github_error:null});
const withoutReason = ghBox.textContent;
if (withReason.indexOf("TESTGRUND-gh-nicht-angemeldet") === -1) { console.log("FAIL-NO-REASON:"+withReason); }
else if (withoutReason !== "") { console.log("FAIL-NOISE-WHEN-OK:"+withoutReason); }
else { console.log("OK"); }
' 2>&1)
ok "$GHOUT" "OK" "K2.1 gerendertes Panel nennt den GitHub-Grund, und schweigt wenn alles ging"

# und der 2s-Takt ruft ihn wirklich auf: tick() wird HIER ausgefuehrt, mit
# gestubbtem fetch. Ein Renderer, den niemand aufruft, war ja der ganze Befund.
TICKOUT=$(SCRIPT="$SCRIPT" node -e '
const vm = require("vm");
function makeEl(){ const e = {className:"",children:[],attrs:{},_listeners:{},style:{},
  appendChild(c){this.children.push(c);return c;}, addEventListener(t,cb){this._listeners[t]=cb;},
  contains(){return false;}, replaceChildren(){this.children=[];this._t="";},
  set textContent(v){ this._t=String(v); }, get textContent(){ return (this._t||"")+this.children.map(c=>c.textContent||"").join(""); }};
  return e; }
const ghBox = makeEl();
const data = {n:0, blocked_pct:0, avg:0, last_ts:"", last_thread:"", found_total:0, resolved_total:0,
  live:[], repos:[], github_error:"TESTGRUND-tick", global:{}, keys:{},
  codex:{ok:true, hint:"", quota:null}, prechecker_options:["minimax","none"], runs:[],
  trail:[], trail_error:null};
const sandbox = { document:{getElementById:id=>id==="ghinfo"?ghBox:makeEl(), activeElement:null, createElement:makeEl},
  localStorage:{getItem:()=>null,setItem:()=>{}}, setInterval:()=>{},
  encodeURIComponent:encodeURIComponent, console,
  fetch:()=>Promise.resolve({json:()=>Promise.resolve(data)}) };
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(process.env.SCRIPT, sandbox);
sandbox.SEL = null;
sandbox.tick().then(function(){ console.log(ghBox.textContent || "LEER"); });
' 2>&1)
case "$TICKOUT" in *"TESTGRUND-tick"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL: tick() zeigt den GitHub-Grund nicht: $TICKOUT";; esac

echo "serve: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

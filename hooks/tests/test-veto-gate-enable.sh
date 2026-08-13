#!/usr/bin/env bash
# `veto-gate enable|disable` — the per-repo switch that replaced the hand-written
# mkdir+echo from the README. What is tested here is mostly what the echo GOT WRONG:
# it clobbered an existing config and it happily wrote into a subdirectory.
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/veto-gate-cli.sh"
P=0; F=0; ok(){ [ "$1" = "$2" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL $3: '$1'≠'$2'"; }; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
CFG="$REPO/.claude/config/veto-gate.json"

# ── fresh repo: the file does not exist yet ────────────────────────────────
bash "$S" enable "$REPO" >/dev/null 2>&1
ok "$([ -f "$CFG" ] && echo yes || echo no)" "yes"  "T1 config created"
ok "$(jq -r .enabled "$CFG")"                "true" "T1 enabled=true"

bash "$S" disable "$REPO" >/dev/null 2>&1
ok "$(jq -r .enabled "$CFG")" "false" "T2 disable flips it back"

# ── the clobber the README's `echo >` caused: other fields must survive ────
printf '%s' '{"enabled":false,"max_lines":600,"effort":"high","prechecker":"groq"}' > "$CFG"
bash "$S" enable "$REPO" >/dev/null 2>&1
ok "$(jq -r .enabled    "$CFG")" "true" "T3 enabled set"
ok "$(jq -r .max_lines  "$CFG")" "600"  "T3 max_lines survives"
ok "$(jq -r .effort     "$CFG")" "high" "T3 effort survives"
ok "$(jq -r .prechecker "$CFG")" "groq" "T3 prechecker survives"

# ── broken JSON is never overwritten: repairing it is the author's call ────
printf '%s' '{kaputt' > "$CFG"
bash "$S" enable "$REPO" >/dev/null 2>&1
ok "$?" "1" "T4 exits non-zero on invalid JSON"
ok "$(cat "$CFG")" '{kaputt' "T4 file left untouched"
printf '%s' '{}' > "$CFG"

# ── called from a subdirectory, the switch belongs at the repo ROOT ────────
# The gate reads <cwd>/.claude/config/veto-gate.json — a config parked in
# src/ looks flipped and does nothing.
SUB="$REPO/src/deep"; mkdir -p "$SUB"
bash "$S" enable "$SUB" >/dev/null 2>&1
ok "$(jq -r .enabled "$CFG")"                             "true" "T5 root config written"
ok "$([ -e "$SUB/.claude" ] && echo yes || echo no)"      "no"   "T5 nothing written in subdir"

# ── a .claude symlink must not route the write out of the repo ─────────────
# Otherwise `veto-gate enable` in repo A silently flips repo B's config.
OTHER="$TMP/elsewhere"; mkdir -p "$OTHER"
LREPO="$TMP/linked"; mkdir -p "$LREPO"; git -C "$LREPO" init -q
ln -s "$OTHER" "$LREPO/.claude"
bash "$S" enable "$LREPO" >/dev/null 2>&1
ok "$?" "1" "T7 refuses a .claude that points outside the repo"
ok "$([ -e "$OTHER/config/veto-gate.json" ] && echo yes || echo no)" "no" "T7 foreign config not written"
# Refusing is not enough — the check has to happen BEFORE mkdir, or the foreign
# directory exists by the time the refusal prints.
ok "$([ -e "$OTHER/config" ] && echo yes || echo no)" "no" "T7 foreign directory not even created"

# ── concurrent writers must not shred the file or lose a neighbouring field ─
# 12 switches at once. Without a lock held across read-merge-replace this ends
# as truncated JSON or with someone's field gone.
R1="$TMP/racy"; mkdir -p "$R1"; git -C "$R1" init -q
export VETO_GATE_LOG_DIR="$TMP/logs"
C1="$R1/.claude/config/veto-gate.json"
bash "$S" enable "$R1" >/dev/null 2>&1
python3 - "$C1" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["max_lines"] = 600
json.dump(d, open(p, "w"))
PY
for i in 1 2 3 4 5 6; do
  bash "$S" enable "$R1" >/dev/null 2>&1 &
  bash "$S" disable "$R1" >/dev/null 2>&1 &
done
wait
ok "$(jq -e '.' "$C1" >/dev/null 2>&1 && echo valid || echo broken)" "valid"  "T8 still valid JSON after 12 parallel writers"
ok "$(jq -r .max_lines "$C1")"                                       "600"    "T8 neighbouring field survived every one of them"
ok "$(jq -r '.enabled|type' "$C1")"                                  "boolean" "T8 the switch holds a real value"
ok "$(ls "$R1/.claude/config" | grep -c 'lock\|tmp')"                "0"      "T8 no lock or temp litter left in the repo"

# ── no repo, no switch: a config outside git would never be read ───────────
NOGIT="$TMP/plain"; mkdir -p "$NOGIT"
bash "$S" enable "$NOGIT" >/dev/null 2>&1
ok "$?" "1" "T6 exits non-zero outside a git repo"
ok "$([ -e "$NOGIT/.claude" ] && echo yes || echo no)" "no" "T6 nothing created outside a repo"

echo "veto-gate-enable: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

#!/usr/bin/env bash
# triage.sh: deterministic effort floor from diff FACTS (paths + code lines).
# Floor, never ceiling: the configured effort stays the maximum.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
# triage.sh itself never posts anywhere, but this suite names gate files as
# fixture data, which trips the (deliberately rough) T10 webhook guard in
# test-veto-gate-discord-findings.sh — and should this suite ever grow a real
# gate call, the unset is already standing.
unset DISCORD_VETO_WEBHOOK
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/triage.sh"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1', want '$2')"; fi; }
N=$(mktemp); C=$(mktemp); trap 'rm -f "$N" "$C"' EXIT
printf '{"effort":"high"}' > "$C"
field(){ printf '%s' "$1" | jq -r ".$2"; }

# T1: pure doc diff (0 code lines), no sensitive path → light profile, low effort
printf 'docs/plan.md\n' > "$N"
R=$(bash "$S" --names "$N" --changed 0 --cfg "$C")
ok "$(field "$R" effort)" "low"     "T1 0 code lines → low"
ok "$(field "$R" profile)" "light"  "T1 0 code lines → light profile"
ok "$(field "$R" sensitive)" "false" "T1 not sensitive"

# T2: THE CLOSED GAP — a small diff touching auth is NOT lowered
printf 'src/auth/login.ts\n' > "$N"
R=$(bash "$S" --names "$N" --changed 10 --cfg "$C")
ok "$(field "$R" effort)" "high"    "T2 sensitive small diff stays at ceiling"
ok "$(field "$R" sensitive)" "true" "T2 auth flagged sensitive"

# T3: a 0-code diff on a sensitive path is NOT light either
printf '.env.example\n' > "$N"
R=$(bash "$S" --names "$N" --changed 0 --cfg "$C")
ok "$(field "$R" effort)" "high"    "T3 sensitive doc-only stays at ceiling"
ok "$(field "$R" profile)" "normal" "T3 sensitive → never light"

# T4: REGRESSION — plain code under the threshold behaves as today (high→medium)
printf 'src/util.ts\n' > "$N"
R=$(bash "$S" --names "$N" --changed 10 --cfg "$C")
ok "$(field "$R" effort)" "medium"  "T4 small plain code → medium (unchanged)"
ok "$(field "$R" profile)" "normal" "T4 code is never light"

# T5: REGRESSION — code over the threshold keeps the ceiling
R=$(bash "$S" --names "$N" --changed 200 --cfg "$C")
ok "$(field "$R" effort)" "high"    "T5 big code diff → ceiling (unchanged)"

# T6: the config value is the CEILING — a 'medium' repo is never raised
printf '{"effort":"medium"}' > "$C"
printf 'docs/x.md\n' > "$N"
ok "$(field "$(bash "$S" --names "$N" --changed 0 --cfg "$C")" effort)" "low" "T6 medium ceiling, 0 lines → low"
printf 'src/util.ts\n' > "$N"
ok "$(field "$(bash "$S" --names "$N" --changed 10 --cfg "$C")" effort)" "medium" "T6b medium ceiling never raised to high"

# T7: effort_auto:false disables every lowering (jq's // would turn false into true — ask has())
printf '{"effort":"high","effort_auto":false}' > "$C"
printf 'docs/x.md\n' > "$N"
R=$(bash "$S" --names "$N" --changed 0 --cfg "$C")
ok "$(field "$R" effort)" "high"    "T7 effort_auto:false → no lowering"
ok "$(field "$R" profile)" "normal" "T7 effort_auto:false → not light"

# T8: repo-configured sensitive_paths EXTEND the defaults, they don't replace them
printf '{"effort":"high","sensitive_paths":["billing"]}' > "$C"
printf 'src/billing/rate.ts\n' > "$N"
ok "$(field "$(bash "$S" --names "$N" --changed 5 --cfg "$C")" sensitive)" "true" "T8 configured path is sensitive"
printf 'src/auth/x.ts\n' > "$N"
ok "$(field "$(bash "$S" --names "$N" --changed 5 --cfg "$C")" sensitive)" "true" "T8b default still applies alongside config"

# T9: sensitive matching is a literal substring, case-insensitive, never a regex
printf '{"effort":"high","sensitive_paths":["a.c"]}' > "$C"
printf 'src/abc.ts\n' > "$N"
ok "$(field "$(bash "$S" --names "$N" --changed 5 --cfg "$C")" sensitive)" "false" "T9 dot is literal, not a regex wildcard"
printf '{"effort":"high"}' > "$C"
printf 'src/AUTH/Login.ts\n' > "$N"
ok "$(field "$(bash "$S" --names "$N" --changed 5 --cfg "$C")" sensitive)" "true" "T9b matching is case-insensitive"

# T10: the gate's own code is sensitive (a gate that lowers its own review is absurd)
printf 'claude-config/hooks/veto-gate.sh\n' > "$N"
ok "$(field "$(bash "$S" --names "$N" --changed 5 --cfg "$C")" sensitive)" "true" "T10 gate code is sensitive"

# T10b: CI workflows are sensitive too — they can change what runs and read stored
# secrets, and a workflow diff is often 0 code lines (codex find)
printf '.github/workflows/deploy.yml\n' > "$N"
ok "$(field "$(bash "$S" --names "$N" --changed 0 --cfg "$C")" sensitive)" "true" "T10b CI workflow is sensitive"

# T11: never crash a caller — missing names file / missing cfg → valid JSON, rc 0.
# And: a fact we could not READ is not a fact. Without the names file we cannot know
# whether a sensitive path is involved, so nothing may be lowered (codex find).
R=$(bash "$S" --names /nope/nix --changed 0 --cfg /nope/nix 2>/dev/null); RC=$?
ok "$RC" "0" "T11 missing files → rc 0"
ok "$(printf '%s' "$R" | jq -e 'type=="object"' >/dev/null 2>&1 && echo yes)" "yes" "T11b still valid JSON"
ok "$(field "$R" effort)" "high"    "T11c unreadable facts → no lowering"
ok "$(field "$R" profile)" "normal" "T11d unreadable facts → never light"

# T12: garbage --changed is treated as 'unknown', never as 0 (0 would mean 'light')
printf 'src/util.ts\n' > "$N"
ok "$(field "$(bash "$S" --names "$N" --changed xx --cfg "$C")" profile)" "normal" "T12 garbage size → never light"

# T13: a config that is not valid JSON is not a fact either — the ceiling and the
# effort_auto off-switch would both be unreadable, so never lower on it
printf 'kein json {{{' > "$C"
printf 'docs/x.md\n' > "$N"
R=$(bash "$S" --names "$N" --changed 0 --cfg "$C")
ok "$(field "$R" effort)" "high"    "T13 broken config → no lowering"
ok "$(field "$R" profile)" "normal" "T13b broken config → never light"

# T14: valid JSON of the WRONG SHAPE is not a readable config (codex find). An array
# has no .effort_auto — every field lookup would quietly yield "not set" and the
# off-switch would be ignored while we still lower.
printf '[1,2]' > "$C"
R=$(bash "$S" --names "$N" --changed 0 --cfg "$C")
ok "$(field "$R" effort)" "high"    "T14 non-object config → no lowering"
ok "$(field "$R" profile)" "normal" "T14b non-object config → never light"

# T15: a names file that EXISTS but cannot be read is not a fact either (codex find):
# a read error must never read as "no sensitive path in this diff".
printf '{"effort":"high"}' > "$C"
if [ "$(id -u)" != 0 ]; then   # root reads anything — the fixture cannot fail there
  printf 'docs/x.md\n' > "$N"; chmod 000 "$N"
  R=$(bash "$S" --names "$N" --changed 0 --cfg "$C"); chmod 644 "$N"
  ok "$(field "$R" effort)" "high"    "T15 unreadable names file → no lowering"
  ok "$(field "$R" profile)" "normal" "T15b unreadable names file → never light"
fi

# T16: an EMPTY names list answers nothing (codex find). With no file names at all we
# cannot tell whether a sensitive path is in play — that is not "nothing sensitive".
: > "$N"
R=$(bash "$S" --names "$N" --changed 0 --cfg "$C")
ok "$(field "$R" effort)" "high"    "T16 empty names list → no lowering"
ok "$(field "$R" profile)" "normal" "T16b empty names list → never light"

# T17: a malformed sensitive_paths is not a fact (codex find). Every other field falls
# back STRICTLY when unusable (bad effort → high, bad small_lines → 80); this one's
# empty fallback would fall the WRONG way — silently meaning "nothing is sensitive".
printf 'docs/x.md\n' > "$N"
printf '{"effort":"high","sensitive_paths":"billing"}' > "$C"
R=$(bash "$S" --names "$N" --changed 0 --cfg "$C")
ok "$(field "$R" effort)" "high"    "T17 string instead of list → no lowering"
ok "$(field "$R" profile)" "normal" "T17b string instead of list → never light"
printf '{"effort":"high","sensitive_paths":["ok",5]}' > "$C"
ok "$(field "$(bash "$S" --names "$N" --changed 0 --cfg "$C")" profile)" "normal" "T17c non-string entry → never light"
# control: a well-formed list must still allow the normal lowering
printf '{"effort":"high","sensitive_paths":["billing"]}' > "$C"
ok "$(field "$(bash "$S" --names "$N" --changed 0 --cfg "$C")" profile)" "light" "T17d valid list → lowering still works"

# T18: a BIG names list with an EARLY hit (codex find). grep -m1 stops at the first
# match; feeding the list through a PIPE would then kill the writer with SIGPIPE, and
# pipefail would report the whole pipeline as failed — losing the hit and reporting a
# sensitive path as not sensitive. Needs a list bigger than the pipe buffer (~64K).
printf '{"effort":"high"}' > "$C"
{ echo "src/auth/login.ts"; i=0; while [ "$i" -lt 20000 ]; do echo "src/plain/f$i.ts"; i=$((i+1)); done; } > "$N"
R=$(bash "$S" --names "$N" --changed 10 --cfg "$C")
ok "$(field "$R" sensitive)" "true" "T18 big list, early hit → still sensitive"
ok "$(field "$R" effort)" "high"    "T18b big list, early hit → no lowering"

echo "triage: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

#!/usr/bin/env bash
# test-veto-gate-perl-required.sh — perl is a HARD requirement, not a timeout fallback.
#
# grounding's A2 stage (invented method calls on an imported namespace, e.g.
# `db.ghostMethod()`) runs entirely through perl: build_nsmap strips comments
# with `perl -0777 -pe`, is_shadowed matches with perl. Without perl that pipe
# yields nothing, the namespace map stays empty and A2 silently checks NOTHING
# and exits 0 — while `veto-gate doctor` still reported "Pflicht-Abhängigkeiten:
# alle da" because it only ever demanded `timeout` OR perl. A slim Linux/WSL
# image with GNU timeout and no perl got a gate that looks healthy and has one
# of its three grounding checks switched off.
#
# The path check and the named-symbol check are grep-based and DO survive
# without perl — this test pins the A2 stage specifically, plus doctor's report.
set -uo pipefail
export VETO_HB_DIR="$(mktemp -d)"   # isolate: never touch the real heartbeat
# Never post test findings to the real Discord: the gate notifies on every block
# and section 3 below drives a real block, which would land on the owner's phone.
unset DISCORD_VETO_WEBHOOK
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1', want '$2')"; fi; }
has(){ case "$1" in *"$2"*) P=$((P+1));; *) F=$((F+1)); echo "  FAIL: $3 (got '$1')";; esac; }

LIB="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)"
command -v perl >/dev/null 2>&1 || { echo "SKIP: no perl on this machine to hide"; exit 0; }

# A PATH holding every real tool EXCEPT perl, plus a working `timeout` — so the
# old "timeout OR perl" rule would have called this system fine.
# Built by linking whole bin dirs: resolving each tool via `command -v` picks up
# shell FUNCTIONS (grep is one here) and silently creates self-referential dead
# symlinks — a broken stub that fakes failures the gate does not actually have.
STUB=$(mktemp -d)
for d in /usr/bin /bin /usr/sbin /sbin /opt/homebrew/bin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=$(basename "$f")
    case "$b" in perl*) continue;; esac
    [ -e "$STUB/$b" ] || ln -sf "$f" "$STUB/$b" 2>/dev/null
  done
done
# drop the symlink first: on Linux the loop above linked the REAL timeout, and
# writing through that link would corrupt the system binary (codex find)
rm -f "$STUB/timeout"
printf '#!/bin/sh\nshift; exec "$@"\n' > "$STUB/timeout"; chmod +x "$STUB/timeout"
# guard: the stub must be usable, or every assertion below is meaningless
[ -x "$STUB/grep" ] && "$STUB/grep" --version >/dev/null 2>&1 \
  || { echo "  FAIL: stub PATH is broken (grep unusable) — test cannot judge anything"; exit 1; }
PATH="$STUB" command -v perl >/dev/null 2>&1 && { echo "  FAIL: stub still exposes perl"; exit 1; }

# --- 1. doctor must not hand out an all-clear without perl ------------------
OUT=$(PATH="$STUB" bash "$LIB/veto-gate-cli.sh" doctor 2>&1); RC=$?
ok "$RC" "1" "doctor exits 1 when perl is missing (timeout present)"
has "$OUT" "perl FEHLT" "doctor names perl as missing"
case "$OUT" in
  *"alle da"*) F=$((F+1)); echo "  FAIL: doctor still claims 'alle da' without perl";;
  *) P=$((P+1));;
esac

# --- 2. A2 must not silently pass an invented method call ------------------
R=$(mktemp -d); mkdir -p "$R/src"
printf 'export function zahleAus(){ return 1; }\n' > "$R/src/db.ts"
printf "import * as db from './db';\nexport const x = db.ghostMethod();\n" > "$R/src/a.ts"
D=$(mktemp)
cat > "$D" <<'EOF'
diff --git a/src/a.ts b/src/a.ts
--- /dev/null
+++ b/src/a.ts
+import * as db from './db';
+export const x = db.ghostMethod();
EOF

# control: with perl this is a violation — proves the fixture really is invalid
OUT=$(bash "$LIB/grounding-check-diff.sh" --diff "$D" --repo "$R" 2>/dev/null); RC=$?
ok "$RC" "1" "control: with perl, db.ghostMethod() is caught"
has "$OUT" "ghostMethod" "control: the invented method is named"

# without perl the check cannot run — it must say so and fail closed (65),
# never exit 0 and let the call through unchecked
ERR=$(mktemp)
OUT=$(PATH="$STUB" bash "$LIB/grounding-check-diff.sh" --diff "$D" --repo "$R" 2>"$ERR"); RC=$?
ok "$RC" "65" "without perl, grounding fails closed with the infra code"
has "$(cat "$ERR")" "perl" "the error names perl as the cause"

# --- 3. the gate turns that infra code into a real, explained block ---------
# End-to-end, because exit 65 is only worth anything if the hook acts on it: a
# caller that reads "non-zero" as "hallucinated imports found" would report a
# wrong reason, and one that reads it as 0 would wave the commit through.
HOOK="$(cd "$(dirname "$0")/.." && pwd)/veto-gate.sh"
MDIR=$(mktemp -d)
cat > "$MDIR/clean" <<'EOF'
#!/usr/bin/env bash
OUT=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { OUT="$2"; shift 2; continue; }; shift; done
cat > /dev/null
printf '{"blocking":[],"non_blocking":[],"questions":[],"context_requests":[],"unverified_claims":[]}' > "$OUT"
echo '{"type":"thread.started","thread_id":"tb"}'
EOF
chmod +x "$MDIR/clean"

G=$(mktemp -d); mkdir -p "$G/src" "$G/.claude/config"
git -C "$G" init -q; git -C "$G" config user.email t@t.t; git -C "$G" config user.name t
printf '{"enabled":true}' > "$G/.claude/config/veto-gate.json"
printf 'export const dep = 1;\n' > "$G/src/dep.ts"
git -C "$G" add -A; git -C "$G" commit -qm baseline
# a perfectly CLEAN diff: nothing to find, yet an unrunnable checker must still
# stop the commit rather than pass it off as reviewed
printf "import { dep } from './dep';\n" > "$G/src/a.ts"; git -C "$G" add src/a.ts

GERR=$(mktemp)
RC=$(printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"tb"}' "$G" \
  | PATH="$STUB" VETO_GATE_LOG_DIR="$(mktemp -d)" VETO_GATE_QWEN_URL="http://127.0.0.1:4/nix" \
    CODEX_BIN="$MDIR/clean" bash "$HOOK" >/dev/null 2>"$GERR"; echo $?)
ok "$RC" "2" "gate blocks a clean commit when grounding cannot run at all"
has "$(cat "$GERR")" "perl fehlt" "block message gives perl as the real reason"
case "$(cat "$GERR")" in
  *halluzinierte*) F=$((F+1)); echo "  FAIL: block blames hallucinated imports, but none were found";;
  *) P=$((P+1));;
esac

rm -rf "$STUB" "$R" "$D" "$ERR" "$MDIR" "$G" "$GERR"
echo "perl-required: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

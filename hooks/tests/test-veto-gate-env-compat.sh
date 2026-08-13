#!/usr/bin/env bash
# env-compat.sh: transitional mapping VETO2_* -> VETO_GATE_* (rename 2026-07-17).
# Every OLD name must keep working, the NEW name must always win (even when set
# empty), and the list must stay complete — the test derives all pairs from the
# file under test and checks the frozen inventory count (33), so a forgotten
# variable is a red test, not a silent gap (design-review find B3).
set -uo pipefail
LIB="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)"
S="$LIB/env-compat.sh"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1', want '$2')"; fi; }

[ -f "$S" ] || { echo "  FAIL: env-compat.sh missing"; echo "PASS=0 FAIL=1"; exit 1; }

# The file path is passed to bash -c as a POSITIONAL parameter, never spliced
# into the command string — a quote in the path must stay data (find B4).

# T1: the mapping list is complete — 34 pairs, the frozen 2026-07-17 inventory:
# grep -rhoE 'VETO2_[A-Z0-9_]+' over the repo (digits INCLUDED — a [A-Z_]-only
# pattern silently missed VETO2_TIMEOUT2), minus two artifacts: __VETO2_TOKEN__
# (HTML placeholder in serve.py) and VETO2_X (docs placeholder).
PAIRS=$(grep -Eo '^_vg_env_compat +VETO_GATE_[A-Z0-9_]+ +VETO2_[A-Z0-9_]+$' "$S" | awk '{print $2":"$3}')
ok "$(printf '%s\n' "$PAIRS" | grep -c .)" "34" "T1 mapping list complete (frozen inventory)"

# T2: names must correspond (VETO_GATE_X pairs with VETO2_X, never a mixup)
BAD=0
for p in $PAIRS; do
  new=${p%%:*}; old=${p##*:}
  [ "veto_gate_${new#VETO_GATE_}" = "veto_gate_${old#VETO2_}" ] || { BAD=$((BAD+1)); echo "  mismatched pair: $new <- $old"; }
done
ok "$BAD" "0" "T2 every pair maps X to X"

# T3/T3b/T4/T4b: for EVERY pair — old-only carries over; an old value that is
# SET but empty carries over as empty; when both are set the new wins; a
# deliberately EMPTY new value also wins (set-but-empty is a decision, not a
# gap — design-review finds B2/B3)
for p in $PAIRS; do
  new=${p%%:*}; old=${p##*:}
  out=$(env -i HOME="$HOME" "$old=/tmp/old" /bin/bash -c ". \"\$1\"; printf %s \"\${$new:-}\"" _ "$S")
  ok "$out" "/tmp/old" "T3 $old carries into $new"
  out=$(env -i HOME="$HOME" "$old=" /bin/bash -c ". \"\$1\"; printf %s \"\${$new-unset}\"" _ "$S")
  ok "$out" "" "T3b empty-but-set $old carries as empty $new"
  out=$(env -i HOME="$HOME" "$old=/tmp/old" "$new=/tmp/new" /bin/bash -c ". \"\$1\"; printf %s \"\${$new:-}\"" _ "$S")
  ok "$out" "/tmp/new" "T4 $new wins over $old"
  out=$(env -i HOME="$HOME" "$old=/tmp/old" "$new=" /bin/bash -c ". \"\$1\"; printf %s \"\${$new-unset}\"" _ "$S")
  ok "$out" "" "T4b empty $new stays empty (not replaced by $old)"
done

# T5: neither set -> stays truly unset (no invented defaults, no empty
# export). Fresh temp HOME: on a real legacy install the deliberate old-dir
# fallback would fire and fail this check falsely (codex find)
FH5=$(mktemp -d)
out=$(env -i HOME="$FH5" /bin/bash -c ". \"\$1\"; printf %s \"\${VETO_GATE_LOG_DIR-unset}\"" _ "$S")
ok "$out" "unset" "T5 neither set: stays unset"
rm -rf "$FH5"

# T6: a value full of shell metacharacters stays DATA (design-review find B1:
# the value must never pass through eval)
TRICKY='$(touch /tmp/pwned);"; `id`; $HOME'
out=$(env -i HOME="$HOME" VETO2_TOKEN="$TRICKY" /bin/bash -c ". \"\$1\"; printf %s \"\${VETO_GATE_TOKEN:-}\"" _ "$S")
ok "$out" "$TRICKY" "T6 metacharacter value survives verbatim, never executed"
ok "$(ls /tmp/pwned 2>/dev/null || echo none)" "none" "T6b no side-effect file was created"

# T7: sourcing under set -eu must not kill the caller
out=$(env -i HOME="$HOME" /bin/bash -c "set -eu; . \"\$1\"; echo alive" _ "$S")
ok "$out" "alive" "T7 safe under set -eu"

# T8: helper does not leak into the caller's namespace
out=$(env -i HOME="$HOME" /bin/bash -c ". \"\$1\"; type _vg_env_compat 2>/dev/null | head -1" _ "$S")
ok "$out" "" "T8 no helper function left after sourcing"

# T8b: the caller's OWN variables survive sourcing untouched (design-review
# find B1 round 2: the compat layer must not clobber or unset foreign names)
out=$(env -i HOME="$HOME" /bin/bash -c "nv=keep; ov=keep; . \"\$1\"; printf %s \"\$nv\$ov\"" _ "$S")
ok "$out" "keepkeep" "T8b caller's nv/ov survive sourcing"

# T9: legacy data fallback — an existing install has its data in
# ~/.claude/veto2 and no new dir yet: with LOG_DIR unset, the mapping must
# point at the OLD dir so runs/keys/quota stay findable until the real
# migration runs (codex find B3)
FH=$(mktemp -d); mkdir -p "$FH/.claude/veto2"
out=$(env -i HOME="$FH" /bin/bash -c ". \"\$1\"; printf %s \"\${VETO_GATE_LOG_DIR-unset}\"" _ "$S")
ok "$out" "$FH/.claude/veto2" "T9 legacy dir wins while new dir is absent"
out=$(env -i HOME="$FH" VETO_GATE_LOG_DIR= /bin/bash -c ". \"\$1\"; printf %s \"\${VETO_GATE_LOG_DIR-unset}\"" _ "$S")
ok "$out" "$FH/.claude/veto2" "T9d empty counts as unset for the dir fallback (server parity)"
mkdir -p "$FH/.claude/veto-gate"
out=$(env -i HOME="$FH" /bin/bash -c ". \"\$1\"; printf %s \"\${VETO_GATE_LOG_DIR-unset}\"" _ "$S")
ok "$out" "unset" "T9b new dir present: stays unset (defaults apply)"
out=$(env -i HOME="$FH" VETO_GATE_LOG_DIR=/tmp/explicit /bin/bash -c ". \"\$1\"; printf %s \"\${VETO_GATE_LOG_DIR-unset}\"" _ "$S")
ok "$out" "/tmp/explicit" "T9c explicit value never overridden"
rm -rf "$FH"

# T10: the CLI invoked THROUGH A SYMLINK must still find env-compat.sh —
# dirname of the symlink is the wrong place (codex find B2)
LNK=$(mktemp -d); ln -s "$LIB/veto-gate-cli.sh" "$LNK/veto-gate"
errs=$(env -i HOME="$HOME" PATH=/usr/bin:/bin "$LNK/veto-gate" doctor 2>&1 >/dev/null | grep -c env-compat)
ok "$errs" "0" "T10 symlink invocation finds env-compat"
rm -rf "$LNK"

echo "PASS=$P FAIL=$F"
[ "$F" = 0 ]

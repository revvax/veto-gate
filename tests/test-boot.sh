#!/usr/bin/env bash
# boot.sh — the one-command setup. Tested against a LOCAL source repo with a
# stub install.sh: what matters here is boot's own behaviour (fetch, update,
# refuse), not a second run of the installer, which has its own checks.
#
#   bash tests/test-boot.sh
set -uo pipefail
BOOT="$(cd "$(dirname "$0")/.." && pwd)/boot.sh"
P=0; F=0; ok(){ [ "$1" = "$2" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL $3: '$1'≠'$2'"; }; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A source repo standing in for GitHub. The stub records that it ran, so a
# silent no-op cannot pass as a successful install.
SRC="$TMP/src"; mkdir -p "$SRC"
cat > "$SRC/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub-installer ran"
EOF
chmod +x "$SRC/install.sh"
git -C "$SRC" init -q
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm init

# HOME is redirected on purpose: boot.sh offers to append a PATH line to the
# user's shell startup file, and a test must never be one wrong answer away from
# editing the real ~/.zshrc.
FAKEHOME="$TMP/home"; mkdir -p "$FAKEHOME"
run() {
  HOME="$FAKEHOME" VETO_GATE_BOOT_SRC="$SRC" VETO_GATE_HOME="$1" \
  VETO_GATE_BOOT_NONINTERACTIVE=1 bash "$BOOT" 2>&1
}

# ── first run: clone, then hand over to the installer ──────────────────────
H="$TMP/h1"
OUT=$(run "$H"); RC=$?
ok "$RC" "0" "T1 exits clean"
ok "$([ -d "$H/.git" ] && echo yes || echo no)" "yes" "T1 checkout created"
case "$OUT" in *"stub-installer ran"*) ok yes yes "T1 installer was called";; *) ok no yes "T1 installer was called";; esac
case "$OUT" in *"veto-gate enable"*) ok yes yes "T1 tells the user the next step";; *) ok no yes "T1 tells the user the next step";; esac

# ── second run: update in place, never a second clone ──────────────────────
touch "$H/marker"
OUT=$(run "$H"); RC=$?
ok "$RC" "0" "T2 second run exits clean"
ok "$([ -f "$H/marker" ] && echo yes || echo no)" "yes" "T2 existing checkout kept, not re-cloned"

# ── a foreign directory in the way is never taken over ─────────────────────
H2="$TMP/h2"; mkdir -p "$H2"; echo "someone else's work" > "$H2/important.txt"
OUT=$(run "$H2"); RC=$?
ok "$RC" "1" "T3 refuses a non-checkout directory"
ok "$(cat "$H2/important.txt")" "someone else's work" "T3 leaves it untouched"

# ── an incomplete checkout fails loudly instead of reporting success ───────
H3="$TMP/h3"
SRC2="$TMP/src2"; mkdir -p "$SRC2"; echo hi > "$SRC2/README.md"
git -C "$SRC2" init -q
git -C "$SRC2" -c user.email=t@t -c user.name=t add -A
git -C "$SRC2" -c user.email=t@t -c user.name=t commit -qm init
OUT=$(VETO_GATE_BOOT_SRC="$SRC2" VETO_GATE_HOME="$H3" VETO_GATE_BOOT_NONINTERACTIVE=1 bash "$BOOT" 2>&1); RC=$?
ok "$RC" "1" "T4 aborts when install.sh is missing"
case "$OUT" in *"install.sh missing"*) ok yes yes "T4 says why";; *) ok no yes "T4 says why";; esac

# ── unattended: no prompt may ever block the run ───────────────────────────
# T1–T4 all ran with VETO_GATE_BOOT_NONINTERACTIVE=1 and returned, which is the
# proof; this asserts the skip is announced rather than silently assumed.
OUT=$(PATH="/usr/bin:/bin" run "$TMP/h4")
ok "$([ -d "$TMP/h4/.git" ] && echo yes || echo no)" "yes" "T5 works on a minimal PATH"

# ── the PATH line: warned about, never written without a yes ───────────────
# Without ~/.local/bin on PATH the final instruction ("veto-gate enable") fails
# with "command not found" — the one step the whole rewrite exists to remove.
printf 'original\n' > "$FAKEHOME/.zshrc"
OUT=$(SHELL=/bin/zsh run "$TMP/h5")
case "$OUT" in *"not on your PATH"*) ok yes yes "T6 warns about the missing PATH entry";; *) ok no yes "T6 warns about the missing PATH entry";; esac
ok "$(cat "$FAKEHOME/.zshrc")" "original" "T6 shell startup file untouched without a yes"

# ── one closing block, not two ─────────────────────────────────────────────
# install.sh prints its own "Next:" when run on its own; under boot it must stay
# quiet, or the output reads as if the install ran twice.
ok "$(printf '%s\n' "$OUT" | grep -c '^Next:')" "1" "T7 exactly one Next block"

echo "boot: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

#!/usr/bin/env bash
set -uo pipefail
P=0; F=0; ok(){ case "$1" in *"$2"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL $3: got '$1'";; esac; }
V="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/veto-gate-cli.sh"

# Success case on a CONTROLLED PATH, not the real machine's: the test rig may
# itself lack codex (or anything else), and doctor correctly reporting that
# must not read as a test failure. codex is a stub — existence is what doctor
# checks. dirname is real: veto-gate-cli.sh's own header needs it before dispatching.
FULL=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
for bin in git python3 bash perl jq dirname; do
  real=$(command -v "$bin") || continue
  ln -s "$real" "$FULL/$bin"
done
printf '#!/bin/sh\nexit 0\n' > "$FULL/codex"; chmod +x "$FULL/codex"
OUT=$(PATH="$FULL" bash "$V" doctor 2>&1); RC=$?
ok "$RC" "0" "doctor exits 0 when all required deps present"
ok "$OUT" "git gefunden" "doctor reports git"
ok "$OUT" "python3 gefunden" "doctor reports python3"
ok "$OUT" "jq gefunden" "doctor reports jq"
rm -rf "$FULL"

# Simulate a missing REQUIRED dependency (jq) via a restricted PATH stub dir
# that has everything except jq — must fail loudly, exit 1.
STUB=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
for bin in git python3 bash perl dirname; do
  real=$(command -v "$bin") || continue
  ln -s "$real" "$STUB/$bin"
done
OUT=$(PATH="$STUB" bash "$V" doctor 2>&1); RC=$?
ok "$RC" "1" "doctor exits 1 when jq is missing"
ok "$OUT" "jq FEHLT" "doctor names the missing dependency"
rm -rf "$STUB"

# `perl` missing -> doctor must fail. perl is REQUIRED (grounding's A2 stage is
# written in it); a present `timeout` does not substitute for it. The dedicated
# proof that A2 really goes blind without perl lives in test-veto-gate-perl-required.sh.
STUB2=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
for bin in git python3 bash jq dirname; do
  real=$(command -v "$bin") || continue
  ln -s "$real" "$STUB2/$bin"
done
OUT=$(PATH="$STUB2" bash "$V" doctor 2>&1); RC=$?
ok "$RC" "1" "doctor exits 1 when perl is missing"
ok "$OUT" "perl FEHLT" "doctor names perl as required"
rm -rf "$STUB2"

# `codex` missing -> doctor must fail too. The main reviewer is always codex
# (codex-diff-review.sh, CODEX_BIN); the qwen/groq/gemini choice only covers the
# PRE-checker. Without codex the gate fail-closes on EVERY commit — an install
# in that state is not 'alle da', it is unusable until codex is set up.
STUB3=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
for bin in git python3 bash jq perl dirname; do
  real=$(command -v "$bin") || continue
  ln -s "$real" "$STUB3/$bin"
done
OUT=$(PATH="$STUB3" bash "$V" doctor 2>&1); RC=$?
ok "$RC" "1" "doctor exits 1 when codex is missing"
ok "$OUT" "codex-CLI FEHLT" "doctor names codex as missing"
case "$OUT" in
  *"alle da"*) F=$((F+1)); echo "FAIL doctor still claims 'alle da' without codex: got '$OUT'";;
  *) P=$((P+1));;
esac
rm -rf "$STUB3"

echo "doctor: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

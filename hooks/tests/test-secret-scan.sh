#!/usr/bin/env bash
set -uo pipefail
P=0; F=0; ok(){ case "$1" in *"$2"*) P=$((P+1));; *) F=$((F+1)); echo "FAIL $3: got '$1'";; esac; }
SCAN="$(cd "$(dirname "$0")/../.." && pwd)/secret-scan.sh"

# A clean fixture tree — must pass.
CLEAN=$(mktemp -d)
mkdir -p "$CLEAN/hooks"
printf '#!/usr/bin/env bash\necho "hello, no secrets here"\n' > "$CLEAN/hooks/x.sh"
OUT=$(bash "$SCAN" "$CLEAN" 2>&1); RC=$?
ok "$([ "$RC" = "0" ] && echo ja || echo nein)" "ja" "clean tree exits exactly 0"
ok "$OUT" "sauber" "clean tree reports sauber"
rm -rf "$CLEAN"

# A fixture tree with an injected fake OpenAI-shaped key — must fail. The fake
# key is assembled at RUNTIME from two concatenated literals, not written as
# one contiguous literal in THIS file — this test file itself lives
# permanently in the repo, and Task 7 runs secret-scan.sh against the whole
# finished tree; a literal match here would make that scan perpetually dirty
# on its own fixture.
FAKE_KEY="sk-test""FAKE1234567890abcdef"
DIRTY=$(mktemp -d)
mkdir -p "$DIRTY/hooks"
printf '#!/usr/bin/env bash\nexport FAKE=%s\n' "$FAKE_KEY" > "$DIRTY/hooks/leaky.sh"
OUT=$(bash "$SCAN" "$DIRTY" 2>&1); RC=$?
# Exact match, not the shared ok()'s substring match: "1" is a substring of 127
# ("No such file" from a missing script), which would falsely pass this
# assertion even with no secret-scan.sh at all.
ok "$([ "$RC" = "1" ] && echo ja || echo nein)" "ja" "dirty tree (fake sk- key) exits exactly 1"
ok "$OUT" "leaky.sh" "dirty tree names the offending file"
rm -rf "$DIRTY"

# A fixture with a hardcoded personal path — must also fail. Same
# runtime-assembly reasoning as above. The name is a placeholder on purpose:
# this file ships publicly, and a real username or internal repo name would be
# pointless to leak here — the scanner matches the /Users/<name>/ SHAPE, so any
# name exercises it identically.
FAKE_PATH="/Users/""beispielnutzer/Desktop/beispielprojekt"
DIRTY2=$(mktemp -d)
mkdir -p "$DIRTY2/hooks"
printf '#!/usr/bin/env bash\nSRC="%s"\n' "$FAKE_PATH" > "$DIRTY2/hooks/path.sh"
OUT=$(bash "$SCAN" "$DIRTY2" 2>&1); RC=$?
ok "$([ "$RC" = "1" ] && echo ja || echo nein)" "ja" "dirty tree (hardcoded personal path) exits exactly 1"
ok "$OUT" "path.sh" "dirty tree names the offending file"
rm -rf "$DIRTY2"

echo "secret-scan: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

#!/usr/bin/env bash
# diff-size.sh: counts changed (+/-) lines per diff, excluding doc files
# (.md/.txt/.log) and diff headers. Doc lines are exempt BY DESIGN: the
# auto-sync doc channel and >300-line plans must never size-block (F18c).
set -uo pipefail
S="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/diff-size.sh"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got $1, want $2)"; fi; }
D=$(mktemp); trap 'rm -f "$D"' EXIT

# T1: 3 added + 1 removed code lines, headers not counted
cat > "$D" <<'EOF'
diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
+one
+two
-gone
+three
EOF
ok "$(bash "$S" --diff "$D")" "4" "T1 code lines counted"

# T2: doc file lines are exempt
cat > "$D" <<'EOF'
+++ b/docs/plan.md
+alpha
+beta
+++ b/src/a.ts
+one
EOF
ok "$(bash "$S" --diff "$D")" "1" "T2 .md exempt, code counted"

# T3: empty diff → 0
: > "$D"
ok "$(bash "$S" --diff "$D")" "0" "T3 empty → 0"

# T4: .txt and .log exempt too
cat > "$D" <<'EOF'
+++ b/notes.txt
+x
+++ b/out.log
+y
EOF
ok "$(bash "$S" --diff "$D")" "0" "T4 txt/log exempt"

# T5: missing diff file → 0, exit 0 (never crashes a caller)
ok "$(bash "$S" --diff /nope/nix 2>/dev/null; echo ":$?")" "0
:0" "T5 missing file → 0 rc 0"

# T6: DELETED code file right after a doc file — its '-' lines must count
# (codex live finding: '+++ /dev/null' kept the previous file's doc flag)
cat > "$D" <<'EOF'
+++ b/readme.md
+doc line
diff --git a/src/gone.ts b/src/gone.ts
--- a/src/gone.ts
+++ /dev/null
-old1
-old2
EOF
ok "$(bash "$S" --diff "$D")" "2" "T6 deleted code file counted after doc"

# T7: deleted DOC file stays exempt
cat > "$D" <<'EOF'
+++ b/src/a.ts
+code
diff --git a/notes.md b/notes.md
--- a/notes.md
+++ /dev/null
-line
EOF
ok "$(bash "$S" --diff "$D")" "1" "T7 deleted doc file exempt"

# ── lockfiles: countable on their own, never missing from the total ────────
# A dependency commit is manifest + lockfile in ONE commit (splitting them
# leaves a state where the declared version is not the installed one). The
# lockfile supplies almost every changed line, so the size gate blocked every
# security upgrade and "split it up" was impossible to follow.
#
# The fix is a SEPARATE count, not an exemption inside the total: pre-commit.sh
# treats CHANGED==0 as "docs only" and skips the reviewers entirely. If lockfile
# lines vanished from the total, a lockfile-only commit — an unreviewed
# `npm install` — would look exactly like a doc commit.
cat > "$D" <<'EOF'
+++ b/package-lock.json
+      "version": "0.35.3",
-      "version": "0.34.5",
+++ b/package.json
+    "sharp": "0.35.3"
EOF
ok "$(bash "$S" --diff "$D")" "3" "T8 lockfile lines stay in the honest total"
ok "$(bash "$S" --diff "$D" --lockfile-lines)" "2" "T9 …and are countable on their own"

# every package manager's lockfile, not just npm's — the same argument holds
# for yarn, pnpm, Cargo, poetry, go.sum: machine output, not hand-written
cat > "$D" <<'EOF'
+++ b/yarn.lock
+a
+++ b/services/api/pnpm-lock.yaml
+b
+++ b/Cargo.lock
+c
+++ b/go.sum
+d
+++ b/src/a.ts
+code
EOF
ok "$(bash "$S" --diff "$D" --lockfile-lines)" "4" "T10 all lockfile flavours recognised"
ok "$(bash "$S" --diff "$D")" "5" "T10b …total unchanged by the new flag"

# a DELETED lockfile is classified from the '--- a/' side, like a deleted doc
cat > "$D" <<'EOF'
diff --git a/package-lock.json b/package-lock.json
--- a/package-lock.json
+++ /dev/null
-x
-y
EOF
ok "$(bash "$S" --diff "$D" --lockfile-lines)" "2" "T11 deleted lockfile recognised"

# a file that merely LOOKS like one must not slip through: the name has to be
# the whole basename, never a suffix of a longer one
cat > "$D" <<'EOF'
+++ b/src/my-package-lock.json
+x
+++ b/src/notgo.sum
+y
EOF
ok "$(bash "$S" --diff "$D" --lockfile-lines)" "0" "T12 lookalike names are not lockfiles"
ok "$(bash "$S" --diff "$D")" "2" "T12b …and still count as code"

echo "diff-size: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

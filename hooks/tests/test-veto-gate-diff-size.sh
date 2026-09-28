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

# ── whitespace-only share: a re-indent is not a big change to judge ────────
# Measured on a real product commit that wrapped a component in one more element —
# 1081 changed lines, 15 with `git diff -w`. The size gate blocked it, and
# "split it up" cannot be followed for an indent.
cat > "$D" <<'EOF'
diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
@@ -1,4 +1,5 @@
-const a = 1;
-  if (x) { y(); }
+    const a = 1;
+	if (x) {   y(); }
+const b = 2;
EOF
ok "$(bash "$S" --diff "$D")" "5" "T13 re-indent stays in the honest total"
ok "$(bash "$S" --diff "$D" --ws-lines)" "4" "T14 …two re-indented pairs are countable on their own"

# pairing is per HUNK: the same text removed in one hunk and added in another
# is a move, not an indent, and keeps counting (same as git -w)
cat > "$D" <<'EOF'
diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
@@ -1,1 +1,0 @@
-const moved = 1;
@@ -9,0 +9,1 @@
+  const moved = 1;
EOF
ok "$(bash "$S" --diff "$D" --ws-lines)" "0" "T15 a move across hunks is not whitespace"

# a changed WORD is never whitespace, however the spacing looks
cat > "$D" <<'EOF'
+++ b/src/a.ts
@@ -1 +1 @@
-const a = 1;
+const a = 2;
EOF
ok "$(bash "$S" --diff "$D" --ws-lines)" "0" "T16 a real edit is not whitespace"

# doc and lockfile lines never enter the share: they are not counted as code
# in the first place, and a lockfile line must not be subtracted twice
cat > "$D" <<'EOF'
+++ b/docs/a.md
@@ -1 +1 @@
-x y
+xy
+++ b/package-lock.json
@@ -1 +1 @@
-  "a": 1
+"a": 1
EOF
ok "$(bash "$S" --diff "$D" --ws-lines)" "0" "T17 doc and lockfile lines are not in the share"

# a hunk-less diff (old fixtures, the gate's own synthetic new-file hunks) is
# one section per file, and the file boundary still separates pairs
cat > "$D" <<'EOF'
+++ b/src/a.ts
-  x = 1
+x = 1
+++ b/src/b.ts
-  y = 1
+++ b/src/c.ts
+y = 1
EOF
ok "$(bash "$S" --diff "$D" --ws-lines)" "2" "T18 without @@ each file is one section, never two"
cat > "$D" <<'EOF'
diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
-  x = 1
diff --git a/src/b.ts b/src/b.ts
--- a/src/b.ts
+++ b/src/b.ts
+x = 1
EOF
ok "$(bash "$S" --diff "$D" --ws-lines)" "0" "T19 a pair never spans two files"

echo "diff-size: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

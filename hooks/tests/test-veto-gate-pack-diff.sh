#!/usr/bin/env bash
# Tests for pack-diff.sh — bundle contents incl. CONVENTIONS.md (F17).
set -uo pipefail
P="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/pack-diff.sh"
TMP=$(mktemp -d) || exit 1; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3 (got '$1' want '$2')"; fi; }

R="$TMP/repo"; mkdir -p "$R/src"
printf 'export const x=1;\n' > "$R/src/a.ts"
printf '+++ b/src/a.ts\n+export const x=1;\n' > "$TMP/d.patch"

# baseline: touched file lands in context/
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/b0")
ok "$([ -f "$OUT/context/src/a.ts" ] && echo yes || echo no)" "yes" "touched file in bundle"

# F17: CONVENTIONS.md (if present) travels into the bundle and the prompt
# tells codex that documented design decisions are not blocking findings
printf '# Konventionen\n- /data ist bewusst LAN-lesbar\n' > "$R/CONVENTIONS.md"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/b1")
ok "$([ -f "$OUT/context/CONVENTIONS.md" ] && echo yes || echo no)" "yes" "conventions file in bundle"
ok "$(grep -q 'CONVENTIONS' "$OUT/REVIEW_PROMPT.md" && echo yes || echo no)" "yes" "prompt references conventions"

# without CONVENTIONS.md the prompt must not promise one
rm "$R/CONVENTIONS.md"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/b2")
ok "$([ -f "$OUT/context/CONVENTIONS.md" ] && echo yes || echo no)" "no" "no conventions file, none bundled"
ok "$(grep -q 'CONVENTIONS' "$OUT/REVIEW_PROMPT.md" && echo yes || echo no)" "no" "prompt silent without conventions"

# conventions count toward the cap (no free lunch)
printf '%060000d' 0 > "$R/CONVENTIONS.md"
C=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/b3" --cap 10000 >/dev/null 2>&1; echo $?)
ok "$C" "2" "oversized conventions trip the cap"

# codex live findings on F17 itself (2026-07-10): (a) a diff that TOUCHES
# CONVENTIONS.md must not have its new rules bind this very review
# (self-silencing); (b) a symlinked CONVENTIONS.md must never be bundled
# (could exfiltrate files from outside the repo); it lands once via the
# touched-files loop, never double-counted.
printf '# Konventionen\n- alles erlaubt\n' > "$R/CONVENTIONS.md"
printf '+++ b/src/a.ts\n+export const x=1;\n+++ b/CONVENTIONS.md\n+- alles erlaubt\n' > "$TMP/d2.patch"
OUT=$(bash "$P" --diff "$TMP/d2.patch" --repo "$R" --out "$TMP/b4")
ok "$(grep -q 'KEIN blocking-Fund' "$OUT/REVIEW_PROMPT.md" && echo yes || echo no)" "no" "touched conventions do not bind the review"
ok "$([ -f "$OUT/context/CONVENTIONS.md" ] && echo yes || echo no)" "yes" "touched conventions still visible as context"
# …and the prompt must SAY so explicitly — the file's own text could claim
# to be binding (codex find: self-silencing via content)
ok "$(grep -q 'NICHT als Regel' "$OUT/REVIEW_PROMPT.md" && echo yes || echo no)" "yes" "touched conventions flagged as non-binding"
rm "$R/CONVENTIONS.md"
printf 'geheim\n' > "$TMP/outside.txt"
ln -s "$TMP/outside.txt" "$R/CONVENTIONS.md"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/b5")
ok "$([ -f "$OUT/context/CONVENTIONS.md" ] && echo yes || echo no)" "no" "symlinked conventions not bundled"
ok "$(grep -q 'CONVENTIONS' "$OUT/REVIEW_PROMPT.md" && echo yes || echo no)" "no" "symlinked conventions not referenced"
rm "$R/CONVENTIONS.md"

# codex find: without python3 the conventions copy must degrade LOUDLY
# (stderr warning, bundle still built), never silently (VETO_GATE_NO_PY seam)
printf '# Konventionen\n- x\n' > "$R/CONVENTIONS.md"
E=$(VETO_GATE_NO_PY=1 bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/b6" 2>&1 >/dev/null); RC=$?
ok "$RC" "0" "no python3 → bundle still built"
case "$E" in *python3*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL: no-python3 warning missing: $E";; esac
ok "$([ -f "$TMP/b6/context/CONVENTIONS.md" ] && echo yes || echo no)" "no" "no python3 → conventions skipped"
rm "$R/CONVENTIONS.md"

# B5 (veto3): --plan appends the plan-mode paragraph; without it, prompt unchanged
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/b7" --plan)
ok "$(grep -c 'SKIZZEN' "$OUT/REVIEW_PROMPT.md")" "1" "--plan appends plan paragraph"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/b8")
ok "$(grep -c 'SKIZZEN' "$OUT/REVIEW_PROMPT.md")" "0" "no --plan → no plan paragraph"

# ── A1: the files codex asked for (context_requests) ───────────────────────
# The bundle is shipped to an EXTERNAL service, so a file request is HOSTILE
# INPUT, not a hint. Two independent locks:
#   1. JUSTIFIED — only a file the staged diff actually imports may be asked for
#      (resolved like the module loader would, never by basename).
#   2. INTERFACE ONLY — what travels is the list of exported signatures, values
#      cut off at the '='. A secret has no fixed shape, so no scanner can be
#      trusted; a list of names cannot carry one at all.
AR="$TMP/askrepo"; mkdir -p "$AR/src"
git -C "$AR" init -q; git -C "$AR" config user.email t@t.t; git -C "$AR" config user.name t
printf 'export function zahleAus(){ return 1 }\n' > "$AR/src/db.ts"
printf 'import { zahleAus } from "./db";\n' > "$AR/src/cart.ts"
git -C "$AR" add -A >/dev/null 2>&1
printf '+++ b/src/cart.ts\n+import { zahleAus } from "./db";\n' > "$TMP/ask.patch"

B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/a1" --add-files "src/db.ts")
ok "$([ -f "$B/context/src/db.ts" ] && echo yes || echo no)" "yes" "T-ADD requested file is bundled"
ok "$(jq -r '.delivered[0]' "$B/ADDED.json")" "src/db.ts" "T-ADD delivery is booked honestly"
ok "$(grep -c 'Nur die Schnittstelle' "$B/context/src/db.ts")" "1" "T-ADD only the interface travels, not the file"

# a path leaving the repo is refused — codex must not read /etc/passwd because he asked nicely
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/a2" --add-files "../../../etc/passwd")
ok "$(find "$B/context" -name passwd | wc -l | tr -d ' ')" "0" "T-ADD-ESC path traversal refused"

# .env has no business in a bundle that leaves the machine — extension allow-list, not deny-list
printf 'API_KEY=supergeheim\n' > "$AR/.env"
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/a3" --add-files ".env")
ok "$(find "$B/context" -name '.env' | wc -l | tr -d ' ')" "0" "T-ADD-SECRET .env is never bundled"

# an unimported source file has no justification — a hardcoded key in a .ts file is still a key
mkdir -p "$AR/config"; printf 'export const KEY = "sk-live-geheim"\n' > "$AR/config/prod-keys.ts"
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/a4" --add-files "config/prod-keys.ts")
ok "$(find "$B/context" -name 'prod-keys.ts' | wc -l | tr -d ' ')" "0" "T-ADD-JUST unimported source file is refused"
ok "$(jq -r '.delivered | length' "$B/ADDED.json")" "0" "T-ADD-JUST nothing booked as delivered"

# basename matching would be a truck-sized hole: an import of "./db" must NOT
# justify handing over "secrets/db.ts". Imports are resolved, never guessed.
mkdir -p "$AR/secrets"; printf 'export const pw = "geheim"\n' > "$AR/secrets/db.ts"
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/a5" --add-files "secrets/db.ts")
ok "$(find "$B/context" -name 'db.ts' -path '*secrets*' | wc -l | tr -d ' ')" "0" "T-ADD-CANON same-name file elsewhere is refused"

# being imported proves the file is RELEVANT, not that it is HARMLESS. So the body
# stays home: the signature codex needs travels, the key value does not.
cat > "$AR/src/db.ts" <<'F'
export const KEY = "sk-live-abcdefghij0123456789";
export function zahleAus(){ return 1 }
F
git -C "$AR" add -A >/dev/null 2>&1
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/a6" --add-files "src/db.ts")
ok "$(grep -c 'sk-live-abcdefghij0123456789' "$B/context/src/db.ts")" "0" "T-ADD-SIG the key value never leaves the machine"
ok "$(grep -c 'zahleAus' "$B/context/src/db.ts")" "1" "T-ADD-SIG the signature codex needs does travel"

# an imported file that is a SYMLINK is refused — it can point out of the repo,
# and the resolved import would follow it happily
LR="$TMP/linkrepo"; mkdir -p "$LR/src"
git -C "$LR" init -q; git -C "$LR" config user.email t@t.t; git -C "$LR" config user.name t
printf 'export const geheim = 1\n' > "$TMP/aussen.ts"
ln -s "$TMP/aussen.ts" "$LR/src/db.ts"
printf 'import { geheim } from "./db";\n' > "$LR/src/cart.ts"
git -C "$LR" add -A >/dev/null 2>&1
printf '+++ b/src/cart.ts\n+import { geheim } from "./db";\n' > "$TMP/link.patch"
B=$(bash "$P" --diff "$TMP/link.patch" --repo "$LR" --out "$TMP/a7" --add-files "src/db.ts")
ok "$(find "$B/context" -name 'db.ts' | wc -l | tr -d ' ')" "0" "T-ADD-LINK an imported symlink is still refused"

# an EMPTY interface must not be booked as delivered: codex would have no evidence,
# and a gap recorded as success is the exact failure this whole plan exists to kill
printf 'const intern = 1\n' > "$AR/src/util.ts"
printf 'import { intern } from "./util";\n' >> "$AR/src/cart.ts"
git -C "$AR" add -A >/dev/null 2>&1
printf '+++ b/src/cart.ts\n+import { intern } from "./util";\n' > "$TMP/ask2.patch"
B=$(bash "$P" --diff "$TMP/ask2.patch" --repo "$AR" --out "$TMP/a8" --add-files "src/util.ts")
ok "$(jq -r '.delivered | length' "$B/ADDED.json")" "0" "T-ADD-EMPTY no readable exports → not booked as delivered"
case "$(jq -r '.refused' "$B/ADDED.json")" in
  *Export-Signaturen*) PASS=$((PASS+1));;
  *) FAIL=$((FAIL+1)); echo "FAIL: T-ADD-EMPTY must say WHY nothing was delivered";;
esac

# T-ADD-NEWFILE (codex B1): pack-diff reads the WORKING TREE, like the context copy. The
# gate builds an add-chain diff from the working tree, so a file created in this very
# `git add && commit` — on disk but not yet tracked — must still be deliverable. Reading
# the index would leave codex blind about exactly that new dependency.
printf 'export function neu(){ return 1 }\n' > "$AR/src/db3.ts"   # on disk, deliberately NOT git-added
printf 'import { neu } from "./db3";\n' > "$AR/src/cart3.ts"
git -C "$AR" add src/cart3.ts >/dev/null 2>&1                     # the importing file is staged; db3 is not
printf '+++ b/src/cart3.ts\n+import { neu } from "./db3";\n' > "$TMP/new.patch"
B=$(bash "$P" --diff "$TMP/new.patch" --repo "$AR" --out "$TMP/a9" --add-files "src/db3.ts")
ok "$(jq -r '.delivered[0]' "$B/ADDED.json")" "src/db3.ts" "T-ADD-NEWFILE a not-yet-tracked file is deliverable from the working tree"
ok "$(grep -c 'neu' "$B/context/src/db3.ts")" "1" "T-ADD-NEWFILE its interface travels"

# T-ADD-COMMENT (codex B2): a comment on an export line that has no '=' to trigger the
# value cut must not ride along to the external service.
cat > "$AR/src/db.ts" <<'F'
export function zahleAus(){ return 1 } // TODO real key sk-live-COMMENTLEAK
export const K = "sk-live-VALUELEAK"
F
git -C "$AR" add -A >/dev/null 2>&1
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/acom" --add-files "src/db.ts")
ok "$(grep -c 'COMMENTLEAK' "$B/context/src/db.ts")" "0" "T-ADD-COMMENT a trailing comment is stripped"
ok "$(grep -c 'VALUELEAK' "$B/context/src/db.ts")" "0" "T-ADD-COMMENT the value is blanked"
ok "$(grep -c 'zahleAus' "$B/context/src/db.ts")" "1" "T-ADD-COMMENT the signature still travels"

# T-ADD-BODY (codex B1): a one-line exported function keeps its body when only a trailing
# `{` is cut. The body can hold a secret, and the bundle leaves the machine — cut at the
# FIRST `{`, not just one at end of line.
printf 'export function zahleAus(){ return "sk-live-BODYLEAK" }\n' > "$AR/src/db.ts"
git -C "$AR" add -A >/dev/null 2>&1
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/abody" --add-files "src/db.ts")
ok "$(grep -c 'BODYLEAK' "$B/context/src/db.ts")" "0" "T-ADD-BODY a one-line function body is cut off"
ok "$(grep -c 'zahleAus' "$B/context/src/db.ts")" "1" "T-ADD-BODY the signature still travels"

# T-ADD-SPACE (codex B3): a touched file whose path has a space must stay ONE path. Word
# splitting would turn `src/my file.ts` into two bogus paths, its import would go unseen,
# and the requested file would be wrongly refused.
printf 'export function raum(){ return 1 }\n' > "$AR/src/raum.ts"
printf 'import { raum } from "./raum";\n' > "$AR/src/mit raum.ts"
git -C "$AR" add -A >/dev/null 2>&1
printf '+++ b/src/mit raum.ts\n+import { raum } from "./raum";\n' > "$TMP/space.patch"
B=$(bash "$P" --diff "$TMP/space.patch" --repo "$AR" --out "$TMP/aspace" --add-files "src/raum.ts")
ok "$(jq -r '.delivered[0]' "$B/ADDED.json")" "src/raum.ts" "T-ADD-SPACE a space in a touched path does not break the import scan"

# T-ADD-MLCOMMENT (codex B1/B2): a block comment spanning lines must neither whitelist a
# file the code never imports, nor be shipped as a fake export signature. Single-line seds
# cannot see a `/* … */` that runs over several lines.
printf 'export const echt = 1\n' > "$AR/src/geheim.ts"     # exists, but only MENTIONED in a comment
cat > "$AR/src/withcomment.ts" <<'F'
/*
 import { x } from "./geheim"
*/
import { neu } from "./db3";
F
git -C "$AR" add -A >/dev/null 2>&1
printf '+++ b/src/withcomment.ts\n+import { neu } from "./db3";\n' > "$TMP/mlc.patch"
B=$(bash "$P" --diff "$TMP/mlc.patch" --repo "$AR" --out "$TMP/amlc" --add-files "src/geheim.ts")
ok "$(find "$B/context" -name geheim.ts | wc -l | tr -d ' ')" "0" "T-ADD-MLCOMMENT a multi-line comment does not whitelist a file"
cat > "$AR/src/db3.ts" <<'F'
/*
export const MLSECRET = "sk-live-MLLEAK"
*/
export function neu(){ return 1 }
F
git -C "$AR" add -A >/dev/null 2>&1
B=$(bash "$P" --diff "$TMP/mlc.patch" --repo "$AR" --out "$TMP/amlc2" --add-files "src/db3.ts")
ok "$(grep -c 'MLSECRET' "$B/context/src/db3.ts")" "0" "T-ADD-MLCOMMENT a commented-out export is not shipped"
ok "$(grep -c 'neu' "$B/context/src/db3.ts")" "1" "T-ADD-MLCOMMENT the real export still travels"

# T-ADD-COMMA (codex B3): a comma is legal in a filename. Requests arrive one per line, so
# `src/a,b.ts` stays one path instead of being split into "src/a" and "b.ts".
printf 'export const komma = 1\n' > "$AR/src/a,b.ts"
printf 'import { komma } from "./a,b";\n' > "$AR/src/usecomma.ts"
git -C "$AR" add -A >/dev/null 2>&1
printf '+++ b/src/usecomma.ts\n+import { komma } from "./a,b";\n' > "$TMP/comma.patch"
B=$(bash "$P" --diff "$TMP/comma.patch" --repo "$AR" --out "$TMP/acomma" --add-files "src/a,b.ts")
ok "$(jq -r '.delivered[0]' "$B/ADDED.json")" "src/a,b.ts" "T-ADD-COMMA a comma in a requested path is one path, not two"

# T-ADD-ESCAPE (codex B1): an import that climbs ABOVE the repo root with `..` must resolve
# to NOTHING, not clamp to a same-named file at the root. `../../secret` from src/climb.ts
# points outside the repo; it must never justify handing over the repo's own secret.ts.
printf 'export const wurzelgeheim = 1\n' > "$AR/secret.ts"           # exists at the repo ROOT
printf 'import { x } from "../../secret";\n' > "$AR/src/climb.ts"     # climbs above the root
git -C "$AR" add -A >/dev/null 2>&1
printf '+++ b/src/climb.ts\n+import { x } from "../../secret";\n' > "$TMP/climb.patch"
B=$(bash "$P" --diff "$TMP/climb.patch" --repo "$AR" --out "$TMP/aesc" --add-files "secret.ts")
ok "$(find "$B/context" -name secret.ts | wc -l | tr -d ' ')" "0" "T-ADD-ESCAPE climbing above the repo root does not whitelist a root file"

# T-ADD-BACKTICK (codex B2): a template literal with no '=' or '{' before it (here a
# template-literal TYPE in a parameter) survives the value and body cuts — its backticks
# must be blanked too.
printf 'export function f(x: `sk-live-TICKLEAK`): void\n' > "$AR/src/db.ts"
git -C "$AR" add -A >/dev/null 2>&1
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/atick" --add-files "src/db.ts")
ok "$(grep -c 'TICKLEAK' "$B/context/src/db.ts")" "0" "T-ADD-BACKTICK a template literal is blanked"
ok "$(grep -c 'export function f' "$B/context/src/db.ts")" "1" "T-ADD-BACKTICK the signature head still travels"

# T-ADD-ESCQUOTE (codex B1): a backslash-escaped quote inside a string must not end the
# blanking early. `"a\"sk-live-ESCLEAK\"b"` on an export line with no '=' before it would
# otherwise leave the secret standing after the first quote.
printf 'export default "a\\"sk-live-ESCLEAK\\"b"\n' > "$AR/src/db.ts"
git -C "$AR" add -A >/dev/null 2>&1
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/aescq" --add-files "src/db.ts")
ok "$(grep -c 'ESCLEAK' "$B/context/src/db.ts")" "0" "T-ADD-ESCQUOTE an escaped quote does not end blanking early"

# T-ADD-DEFAULT (codex B1): `export default EXPR` carries a value with no '=', quote or
# '{' — a bare regex literal would ride along. The whole expression is cut; a NAMED default
# (function/class) keeps its name, its body cut by the '{' rule.
printf 'export default /sk-live-REGEXLEAK/\n' > "$AR/src/db.ts"
git -C "$AR" add -A >/dev/null 2>&1
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/adef" --add-files "src/db.ts")
ok "$(grep -c 'REGEXLEAK' "$B/context/src/db.ts")" "0" "T-ADD-DEFAULT a bare default-export value is cut"
printf 'export default function bleibt(){ return "sk-live-BODY2" }\n' > "$AR/src/db.ts"
git -C "$AR" add -A >/dev/null 2>&1
B=$(bash "$P" --diff "$TMP/ask.patch" --repo "$AR" --out "$TMP/adef2" --add-files "src/db.ts")
ok "$(grep -c 'BODY2' "$B/context/src/db.ts")" "0" "T-ADD-DEFAULT a named default's body is still cut"
ok "$(grep -c 'bleibt' "$B/context/src/db.ts")" "1" "T-ADD-DEFAULT a named default keeps its name"

# T-ADD-MTS (codex B3): .mts/.cts modules carry imports and must be resolvable AND allowed.
printf 'export function mod(){ return 1 }\n' > "$AR/src/mod.mts"
printf 'import { mod } from "./mod";\n' > "$AR/src/usemts.ts"
git -C "$AR" add -A >/dev/null 2>&1
printf '+++ b/src/usemts.ts\n+import { mod } from "./mod";\n' > "$TMP/mts.patch"
B=$(bash "$P" --diff "$TMP/mts.patch" --repo "$AR" --out "$TMP/amts" --add-files "src/mod.mts")
ok "$(jq -r '.delivered[0]' "$B/ADDED.json")" "src/mod.mts" "T-ADD-MTS an .mts dependency is resolved and delivered"

# T-ADD-LANG (codex B2): the allow-list advertises only types this stage can resolve and
# read as an interface (JS/TS). A .py file is refused, never silently half-supported.
printf 'def x():\n  return 1\n' > "$AR/src/helper.py"
printf 'import { neu } from "./db3";\n' > "$AR/src/uselang.ts"
git -C "$AR" add -A >/dev/null 2>&1
printf '+++ b/src/uselang.ts\n+import { neu } from "./db3";\n' > "$TMP/lang.patch"
B=$(bash "$P" --diff "$TMP/lang.patch" --repo "$AR" --out "$TMP/alang" --add-files "src/helper.py")
ok "$(jq -r '.delivered | length' "$B/ADDED.json")" "0" "T-ADD-LANG a .py request is refused (JS/TS only)"

# T-ADD-SIDE (codex): `import "./boot";` is a real import — it just has no `from`.
# The old parser only knew from/require(/import(, so a file imported for its side effects
# alone could never be handed over, and codex would stay blind while the commit passed.
printf 'export function starte(){ return 1 }\n' > "$AR/src/boot.ts"
printf 'import "./boot";\n' > "$AR/src/main.ts"
git -C "$AR" add -A >/dev/null 2>&1
printf '+++ b/src/main.ts\n+import "./boot";\n' > "$TMP/side.patch"
B=$(bash "$P" --diff "$TMP/side.patch" --repo "$AR" --out "$TMP/a10" --add-files "src/boot.ts")
ok "$(jq -r '.delivered[0]' "$B/ADDED.json")" "src/boot.ts" "T-ADD-SIDE a side-effect import justifies the request too"

# D (codex): docs are BEST-EFFORT — an oversized doc must NEVER block the commit. The CODE
# bundle fits the cap, so it builds; the huge doc would push it over, so it is DROPPED (the
# code review still runs) and DOCS.json says so. A false import from a string can thus never
# cap-block a valid commit.
printf 'import { z } from "zod";\n' > "$R/src/a.ts"
cat > "$R/package-lock.json" <<'J'
{"packages":{"node_modules/zod":{"version":"1.0.0"}}}
J
printf '+++ b/src/a.ts\n+import { z } from "zod";\n' > "$TMP/dz.patch"
DC="$TMP/doccache"; mkdir -p "$DC"; printf '%080000d' 0 > "$DC/zod@1.0.0.md"   # ~20000 tokens
OUT=$(VETO_GATE_DOC_CACHE="$DC" bash "$P" --diff "$TMP/dz.patch" --repo "$R" --out "$TMP/bd" --cap 5000); RC=$?
ok "$RC" "0" "T-DOCS-CAP an oversized doc does NOT block — the code review still runs"
ok "$([ -f "$OUT/context/docs/zod.md" ] && echo yes || echo no)" "no" "T-DOCS-CAP the oversized doc is dropped, not bundled"
ok "$(jq -r '.status' "$OUT/DOCS.json")" "unavailable" "T-DOCS-CAP DOCS.json says the doc was dropped"
# a small doc that FITS rides along and lands in context/docs
printf '# zod docs\n' > "$DC/zod@1.0.0.md"
OUT=$(VETO_GATE_DOC_CACHE="$DC" bash "$P" --diff "$TMP/dz.patch" --repo "$R" --out "$TMP/bd2")
ok "$([ -f "$OUT/context/docs/zod.md" ] && echo yes || echo no)" "yes" "T-DOCS-CAP a small doc is bundled"
ok "$(jq -r '.status' "$OUT/DOCS.json")" "pass" "T-DOCS-CAP DOCS.json records the pass"
rm -f "$R/package-lock.json"; printf 'export const x=1;\n' > "$R/src/a.ts"

# --docs off: the docs stage is skipped and DOCS.json says so (Dashboard toggle)
printf 'import { z } from "zod";\n' > "$R/src/a.ts"
cat > "$R/package-lock.json" <<'J'
{"packages":{"node_modules/zod":{"version":"1.0.0"}}}
J
printf '+++ b/src/a.ts\n+import { z } from "zod";\n' > "$TMP/doff.patch"
DC2="$TMP/dc2"; mkdir -p "$DC2"; printf '# zod docs\n' > "$DC2/zod@1.0.0.md"
OUT=$(VETO_GATE_DOC_CACHE="$DC2" bash "$P" --diff "$TMP/doff.patch" --repo "$R" --out "$TMP/boff" --docs off)
ok "$([ -f "$OUT/context/docs/zod.md" ] && echo yes || echo no)" "no" "T-DOCS-OFF the docs stage did not run"
ok "$(jq -r '.status' "$OUT/DOCS.json")" "skipped" "T-DOCS-OFF DOCS.json says skipped"
# default (no --docs) still runs
OUT=$(VETO_GATE_DOC_CACHE="$DC2" bash "$P" --diff "$TMP/doff.patch" --repo "$R" --out "$TMP/bon")
ok "$([ -f "$OUT/context/docs/zod.md" ] && echo yes || echo no)" "yes" "T-DOCS-OFF default still fetches"
rm -f "$R/package-lock.json"; printf 'export const x=1;\n' > "$R/src/a.ts"

# --- Stufe 2: the verdict schema anchors findings by CONTENT (quote), not line numbers
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bq")
ok "$(grep -c '"quote":""' "$OUT/REVIEW_PROMPT.md")" "1" "P-Q1 schema carries a quote field"
ok "$(grep -c 'WÖRTLICH' "$OUT/REVIEW_PROMPT.md")"   "1" "P-Q2 prompt demands a literal quote"

# --- Stufe 2: prior-round findings ride into the bundle (codex's memory) -----
PR=$(mktemp)
printf '{"runde":2,"vorrunden":[{"round":1,"result":"codex-block","changed":10,"findings":[{"id":"B1","claim":"alt","fix":"f","quote":"q"}]}]}' > "$PR"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bp" --prior "$PR")
ok "$([ -f "$OUT/PRIOR_FINDINGS.json" ] && echo yes)" "yes" "P-M1 prior findings in the bundle"
ok "$(grep -c 'RESTLICHEN Punkte' "$OUT/REVIEW_PROMPT.md")" "1" "P-M2 convergence question in the prompt"
# P-M3: without --prior neither file nor paragraph appears (round 1 stays cold)
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bp0")
ok "$([ -f "$OUT/PRIOR_FINDINGS.json" ] || echo no)" "no" "P-M3 no prior → no memory file"
ok "$(grep -c 'RESTLICHEN Punkte' "$OUT/REVIEW_PROMPT.md")" "0" "P-M3b no prior → no paragraph"
# P-M4: unreadable prior → ignored, never a crash, no half-truth in the prompt
printf 'kein json' > "$PR"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bp1" --prior "$PR")
ok "$?" "0" "P-M4 broken prior → rc 0"
ok "$([ -f "$OUT/PRIOR_FINDINGS.json" ] || echo no)" "no" "P-M4b broken prior → not shipped"
# P-M5: memory is best-effort like docs — over the cap it stays home, the prompt says so
python3 -c 'import json;print(json.dumps({"runde":2,"vorrunden":[{"round":1,"result":"codex-block","changed":1,"findings":[{"id":"B","claim":"x"*400000,"fix":"f","quote":"q"}]}]}))' > "$PR"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bp2" --cap 5000 --prior "$PR")
ok "$([ -f "$OUT/PRIOR_FINDINGS.json" ] || echo no)" "no" "P-M5 oversized prior stays home"
ok "$(grep -c 'Vorrunden-Kontext' "$OUT/REVIEW_PROMPT.md")" "1" "P-M5b …and the prompt says so"
rm -f "$PR"

# --- the bundle records its own SIZE ---------------------------------------
# pack-diff copies every touched file WHOLE, so the reading work grows with the
# FILE size, not with the diff size. Without that number every timeout theory
# stays a guess (testbau-repo 2026-07-28: four runs of 94 changed lines each, three
# timed out, one produced a verdict — same diff size, different outcome).
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bs")
ok "$([ -f "$OUT/SIZE.json" ] && echo yes || echo no)" "yes" "P-S1 bundle size recorded"
ok "$(jq -r '.tokens > 0' "$OUT/SIZE.json")" "true" "P-S2 token total counted"
ok "$(jq -r '.cap' "$OUT/SIZE.json")" "120000" "P-S3 cap recorded next to it"
ok "$(jq -r '.context_files' "$OUT/SIZE.json")" "1" "P-S4 whole files copied is counted"
# a big touched FILE dwarfs a tiny diff — that is the whole point of the number
printf '%040000d' 0 > "$R/src/big.ts"
printf '+++ b/src/big.ts\n+x\n' > "$TMP/big.patch"
OUT=$(bash "$P" --diff "$TMP/big.patch" --repo "$R" --out "$TMP/bs2")
ok "$(jq -r '.tokens > (.diff_tokens * 100)' "$OUT/SIZE.json")" "true" "P-S5 file size, not diff size, drives the bundle"
rm -f "$R/src/big.ts"

# --- the bundle carries the ORDER, not just the diff -----------------------
# Today the bundle says WHAT changed and never WHY. The prompt says "report only
# what the diff really introduces" — so something FORGOTTEN introduces nothing and
# is invisible by construction. With the order present, drift, omission and
# invention become checkable.
IN="$TMP/intent.md"; printf 'Ziel: Zaehler einbauen.\nWeg: neues Feld.\nErgebnis: Zahl im Log.\n' > "$IN"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bi" --intent "$IN")
ok "$([ -f "$OUT/INTENT.md" ] && echo yes || echo no)" "yes" "P-I1 the order travels in the bundle"
ok "$(grep -c 'AUFTRAG' "$OUT/REVIEW_PROMPT.md")" "1" "P-I2 the prompt asks for the check against it"
# the order is the AUTHOR's claim, never a licence: it must not be able to
# neutralise a finding, the way a touched CONVENTIONS.md must not
ok "$(grep -c 'entkräften' "$OUT/REVIEW_PROMPT.md")" "1" "P-I3 the order can never disarm a finding"
# …and it must not steer attention either: a wrong order could otherwise point the
# review at the wrong risk and let a real one pass unexamined
ok "$(grep -c 'verengt ihn NIE' "$OUT/REVIEW_PROMPT.md")" "1" "P-I3b the order widens the scope, never narrows it"
# without an order the prompt SAYS so — a missing check is visible, not silent
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bi2")
ok "$([ -f "$OUT/INTENT.md" ] && echo yes || echo no)" "no" "P-I4 no order → nothing bundled"
ok "$(grep -c 'kein Auftrag' "$OUT/REVIEW_PROMPT.md")" "1" "P-I5 …and the prompt names the gap"
# an oversized order is best-effort like the docs: dropped, never a block —
# a long commit message must not stop a commit
printf '%060000d' 0 > "$IN"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bi3" --cap 10000 --intent "$IN"); RC=$?
ok "$RC" "0" "P-I6 an oversized order does not block"
ok "$([ -f "$OUT/INTENT.md" ] && echo yes || echo no)" "no" "P-I6 …it stays home"
ok "$(grep -c 'kein Auftrag' "$OUT/REVIEW_PROMPT.md")" "1" "P-I6 …and the gap is named"

# --- the bundle says what already happened to the TESTS ---------------------
# The reviewer's rule "a green run must be documented in the bundle" had nothing to
# read: the verdict existed, in the gate's own ledger, and was never handed over.
# Measured 2026-08-13 — six consecutive rounds blocked on a missing receipt while
# that ledger said `tests: pass — pytest-Suite grün`.
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bt" --tests "pass: pytest-Suite grün")
ok "$([ -f "$OUT/TESTS.md" ] && echo yes || echo no)" "yes" "P-T1 the test verdict travels along"
ok "$(grep -c 'pytest-Suite grün' "$OUT/TESTS.md")" "1" "P-T2 …with the detail, not just the word"
ok "$(grep -c 'TESTS:' "$OUT/REVIEW_PROMPT.md")" "1" "P-T3 the prompt tells the reviewer to read it"
# it must not become a licence: a missing TEST stays a finding, only the missing RUN goes
ok "$(grep -c 'zwei verschiedene Dinge' "$OUT/REVIEW_PROMPT.md")" "1" "P-T4 missing test ≠ missing run"
# no verdict handed over → no file and no paragraph, rather than a blank claim
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bt2")
ok "$([ -f "$OUT/TESTS.md" ] && echo yes || echo no)" "no" "P-T5 no verdict → nothing claimed"
ok "$(grep -c 'TESTS:' "$OUT/REVIEW_PROMPT.md")" "0" "P-T6 …and the prompt stays silent about it"
# a flag without a value is a caller mistake, not a silent empty bundle
bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/bt3" --tests >/dev/null 2>&1
ok "$?" "64" "P-T7 --tests without a value is refused, not swallowed"

# --- the RULES travel with every bundle ------------------------------------
# Prose conventions drifted: after the hook move, CONVENTIONS.md still claimed the
# hooks lived in another repo. Rules as DATA cannot drift that way — every rule
# names its stage, and a rule pointing at a stage that does not exist is refused
# before it ever reaches a reviewer.
RJ="$TMP/rules.json"
printf '{"rules":[{"id":"R05","was":"Erfundene Bezuege blocken","checked_by":"grounding","effect":"block"}]}' > "$RJ"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/br" --rules "$RJ")
ok "$([ -f "$OUT/RULES.json" ] && echo yes || echo no)" "yes" "P-R1 the rules travel in the bundle"
ok "$(grep -c 'REGELN' "$OUT/REVIEW_PROMPT.md")" "1" "P-R2 the prompt asks for a check against them"
ok "$(grep -c 'ERWEITERN' "$OUT/REVIEW_PROMPT.md")" "1" "P-R3 rules widen the task, never narrow it"
# without rules the prompt says nothing about them — no phantom authority
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/br2")
ok "$([ -f "$OUT/RULES.json" ] && echo yes || echo no)" "no" "P-R4 no rules → nothing bundled"
ok "$(grep -c 'REGELN' "$OUT/REVIEW_PROMPT.md")" "0" "P-R5 …and the prompt stays silent"
# oversized rules are best-effort like the docs: dropped, never a block
printf '%060000d' 0 > "$RJ"
OUT=$(bash "$P" --diff "$TMP/d.patch" --repo "$R" --out "$TMP/br3" --cap 10000 --rules "$RJ"); RC=$?
ok "$RC" "0" "P-R6 oversized rules do not block"
ok "$([ -f "$OUT/RULES.json" ] && echo yes || echo no)" "no" "P-R6b …they stay home"

# --- what is too big or machine-made never rides along WHOLE ---------------
# The touched-files loop copied EVERY touched file whole. A 1.6 MB
# package-lock.json is then 97.8 % of the bundle and blows the cap, while the
# real change is three lines in two package.json — and "split it up" is
# impossible to follow: manifest and lockfile are ONE statement, and between
# two commits the declared version would not be the installed one.
#
# What is dropped is only the AFTER-STATE full text. The file's diff hunks stay
# in DIFF.patch, so a swapped `resolved` URL is still reviewed — the reviewer
# loses the 40 000 unchanged checksum lines, nothing else.
LK="$TMP/lockrepo"; mkdir -p "$LK/src"
printf 'export const x=1;\n' > "$LK/src/a.ts"
printf '{"name":"root"}\n' > "$LK/package.json"
python3 -c "
import json,sys
d={'name':'root','lockfileVersion':3,'packages':{}}
for i in range(9000):
    d['packages']['node_modules/pkg%d'%i]={'version':'1.0.0','integrity':'sha512-'+('A'*88)}
open(sys.argv[1],'w').write(json.dumps(d,indent=2))
" "$LK/package-lock.json"
cat > "$TMP/lock.patch" <<'EOF'
diff --git a/package.json b/package.json
--- a/package.json
+++ b/package.json
-    "sharp": "0.34.5"
+    "sharp": "0.35.3"
diff --git a/package-lock.json b/package-lock.json
--- a/package-lock.json
+++ b/package-lock.json
-      "version": "0.34.5",
+      "version": "0.35.3",
EOF
OUT=$(bash "$P" --diff "$TMP/lock.patch" --repo "$LK" --out "$TMP/bl" --docs off); RC=$?
ok "$RC" "0" "P-L1 a dependency commit passes the cap"
ok "$([ -f "$OUT/context/package-lock.json" ] && echo yes || echo no)" "no" "P-L2 lockfile not bundled whole"
ok "$([ -f "$OUT/context/package.json" ] && echo yes || echo no)" "yes" "P-L3 the manifest still is"
ok "$(grep -c '^+++ b/package-lock.json' "$OUT/DIFF.patch")" "1" "P-L4 its change is still in the diff"
ok "$(grep -c 'package-lock.json' "$OUT/REVIEW_PROMPT.md")" "1" "P-L5 the prompt names what was left out"
ok "$(jq -r '.omitted_full_text | length' "$OUT/SIZE.json")" "1" "P-L6 …and the bundle records it"

# a small lockfile is left out too: its content is machine output, fully derived
# from the manifest, and no reviewer reads 40 000 lines of checksums
printf '{"name":"root","lockfileVersion":3}\n' > "$LK/package-lock.json"
OUT=$(bash "$P" --diff "$TMP/lock.patch" --repo "$LK" --out "$TMP/bl2" --docs off)
ok "$([ -f "$OUT/context/package-lock.json" ] && echo yes || echo no)" "no" "P-L7 small lockfile left out as well"

# the generic brake: ANY touched file over the size limit ships as diff only,
# lockfile or not. Same limit as the --add path uses to refuse a file.
BR="$TMP/bigrepo"; mkdir -p "$BR"
printf '%0250000d' 0 > "$BR/huge.ts"
printf 'export const y=1;\n' > "$BR/small.ts"
printf '+++ b/huge.ts\n+x\n+++ b/small.ts\n+y\n' > "$TMP/huge.patch"
OUT=$(bash "$P" --diff "$TMP/huge.patch" --repo "$BR" --out "$TMP/bh" --docs off); RC=$?
ok "$RC" "0" "P-L8 an oversized source file no longer bursts the bundle"
ok "$([ -f "$OUT/context/huge.ts" ] && echo yes || echo no)" "no" "P-L9 …it ships as diff only"
ok "$([ -f "$OUT/context/small.ts" ] && echo yes || echo no)" "yes" "P-L10 …and normal files are untouched"
ok "$(grep -c 'huge.ts' "$OUT/REVIEW_PROMPT.md")" "1" "P-L11 …with the gap named in the prompt"

# a genuinely oversized CHANGE still blocks — the cap is right, only what was
# counted into it was wrong. And the block now SAYS which item burst it, so a
# reader can tell whether splitting up would help at all.
printf '%0600000d' 0 > "$TMP/fat.patch"
E=$(bash "$P" --diff "$TMP/fat.patch" --repo "$BR" --out "$TMP/bf" --cap 120000 --docs off 2>&1 >/dev/null); RC=$?
ok "$RC" "2" "P-L12 a really oversized change still blocks"
case "$E" in *"CAP EXCEEDED"*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL: P-L13 numbers missing: $E";; esac
case "$E" in *"· DIFF.patch"*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); echo "FAIL: P-L14 top contributor not named: $E";; esac

# a path with a SPACE must survive the report: with the path anywhere but last, the
# reader would parse a number out of the filename and pick the wrong culprit — or none
SP="$TMP/spacerepo"; mkdir -p "$SP"
printf '%0190000d' 0 > "$SP/my notes.ts"     # under the 200 KB brake → ships whole → dominates
printf '+++ b/my notes.ts\n+x\n' > "$TMP/space.patch"
E=$(bash "$P" --diff "$TMP/space.patch" --repo "$SP" --out "$TMP/bsp" --cap 1000 --docs off 2>&1 >/dev/null)
TOPP=$(printf '%s' "$E" | awk -F' · ' '/^TOP: /{split($1,a," "); if (a[2]+0 >= 50) print $3; exit}')
ok "$TOPP" "context/my notes.ts" "P-L15 a spaced path does not derail the top-contributor line"

echo "pack-diff: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

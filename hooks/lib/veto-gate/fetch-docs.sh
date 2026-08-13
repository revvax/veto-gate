#!/usr/bin/env bash
# fetch-docs.sh — put the REAL library docs into the review bundle.
#
# Sorte D (Spec 2026-07-14): an API field that does not exist in that version, a config key
# the library never had. Codex answers from training, and training is old. CLAUDE.md §3 has
# demanded a Context7 lookup for months — no gate ever enforced it, so it happened when
# someone remembered.
#
# It does NOT call Context7 itself: MCP servers live in the Claude process, not in a shell
# hook. It reads a CACHE that Claude fills and reports `unavailable` when the lookup was
# skipped — the omission becomes visible instead of silent.
#
# Reports, judges nothing: {"status":"pass|skipped|unavailable","detail":"…"}. Always exit 0.
set -uo pipefail

# --repo is REQUIRED. Guessing it from `dirname "$DIFF"` fails: the diff lives in a temp dir,
# not in the repo, so every version lookup would find nothing and read as "unknown". A checker
# that always says "cannot check" is not a checker.
DIFF=""; OUT=""; REPO_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --diff) DIFF="$2"; shift 2;;
    --out)  OUT="$2"; shift 2;;
    --repo) REPO_DIR="$2"; shift 2;;
    *) shift;;
  esac
done
out(){ jq -cn --arg s "$1" --arg d "$2" '{status:$s,detail:$d}'; exit 0; }
[ -f "$DIFF" ] || out unavailable "Diff nicht gefunden"
[ -d "${REPO_DIR:-}" ] || out unavailable "--repo fehlt oder existiert nicht"

CACHE="${VETO_GATE_DOC_CACHE:-$HOME/.claude/veto-gate/doccache}"
mkdir -p "$OUT" 2>/dev/null || true

# Read ANY repo file (source, lockfile) safely to stdout — never with a bare cat/jq/grep
# (codex): a symlinked lockfile pointing at a FIFO would hang the read forever, and pack-diff
# waits on this script without a timeout. O_NOFOLLOW refuses the symlink, O_NONBLOCK means a
# FIFO returns instead of blocking, fstat refuses non-regular files, and the size is bounded.
# On any failure it prints nothing (rc 1) → the caller treats the file as absent.
safe_cat(){ # $1 = file → content to stdout iff a regular file within a sane size
  python3 - "$1" 2>/dev/null <<'PY'
import os, shutil, stat, sys
MAX = 5_000_000
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    sys.exit(1)
try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX:
        sys.exit(1)
    with os.fdopen(fd, "rb") as f:
        shutil.copyfileobj(f, sys.stdout.buffer)
except OSError:
    sys.exit(1)
finally:
    try: os.close(fd)
    except OSError: pass
PY
}

# The cache is filled by Claude, but the bundle leaves the machine — so a cache entry that is
# a SYMLINK must never copy the file it points at (codex): a link to a secret would be shipped
# verbatim. A single open with O_NOFOLLOW refuses the link atomically (no TOCTOU), O_NONBLOCK
# means a FIFO returns instead of hanging the hook forever, and fstat checks TYPE and SIZE
# BEFORE any bytes are copied — a non-regular file, or one larger than a sane doc, is refused
# outright (codex). python3 is an allowed dependency.
safe_copy(){ # $1 = cache src, $2 = bundle dst → 0 iff a plausible REGULAR doc was copied
  python3 - "$1" "$2" 2>/dev/null <<'PY'
import os, shutil, stat, sys
MAX = 1_000_000  # bound the copy; pack-diff's bundle cap is the real limit
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    sys.exit(1)
try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_size > MAX:
        sys.exit(1)
    with os.fdopen(fd, "rb") as f, open(sys.argv[2], "wb") as g:
        shutil.copyfileobj(f, g)
except OSError:
    sys.exit(1)
finally:
    try: os.close(fd)
    except OSError: pass
PY
}

# Every external package the TOUCHED FILES import, not just the newly ADDED lines: a new CALL
# can use an import already at the top of the file, and codex would judge it from old training
# anyway (spec Sorte D). Read the WHOLE working-tree file — consistent with the grounding
# check and with the gate's add-chain diff (which is built from the working tree). Comments are
# stripped first so a commented-out import does not load docs or trip the cap (codex); a
# side-effect `import "paket"` (no `from`) is matched too (codex); node builtins (`fs`,
# `node:fs`, …) are not packages and must not read as a missing dependency.
TOUCHED=$(grep -E '^\+\+\+ b/' "$DIFF" | sed 's|^+++ b/||' | sort -u)
PKGS=$(
  printf '%s\n' "$TOUCHED" | while IFS= read -r f; do
    [ -n "$f" ] && safe_cat "$REPO_DIR/$f"
  done \
  | perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' 2>/dev/null \
  | grep -oE "(from|require\(|import\(|(^|[^A-Za-z_])import)[[:space:]]*['\"][^'\"]+['\"]" \
  | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" \
  | grep -vE '^[./]|^node:' \
  | sed -E 's|^(@[^/]+/[^/]+).*|\1|; s|^([^@][^/]*)/.*|\1|' \
  | grep -vxE 'fs|path|os|http|https|http2|crypto|util|events|stream|child_process|url|querystring|zlib|net|tls|dns|assert|buffer|process|cluster|readline|repl|vm|module|timers|string_decoder|punycode|perf_hooks|async_hooks|worker_threads|inspector|v8|tty|dgram|constants|fs/promises|dns/promises' \
  | sort -u
)

[ -n "$PKGS" ] || out skipped "keine externen Bibliotheken in den geänderten Dateien"

# The version comes from the LOCKFILE. NOT node_modules: that folder is not in git, can belong
# to another branch, be stale, or be half-installed. Docs for the wrong version read as
# authoritative and are therefore WORSE than no docs.
#
# Read from the WORKING TREE, not the git index (documented override — codex asked for the
# index on plain commits). Same reasons as the grounding check: the gate builds an add-chain
# diff from the working tree, and for the common `npm install X && git add -A && commit` the
# index still holds the OLD lockfile, so the index would ship docs for the version being
# REPLACED — the working tree is in fact more correct there. The only case it gets wrong is an
# unstaged lockfile edit in a plain commit, and the stakes are minimal: docs are advisory and
# best-effort (they never block), so a slightly-off version is noise, not a false result. If
# the lockfile does not name the package, the version is unknown → `unavailable`, never a guess.
pkg_version(){ # $1 = package name → version for this commit, or empty
  local v esc
  # lockfiles are read through safe_cat (never opened directly by jq/grep): a symlinked
  # lockfile pointing at a FIFO would otherwise hang the hook (codex).
  # npm v7+ lockfile — jq treats the name as a literal key, no escaping needed
  v=$(safe_cat "$REPO_DIR/package-lock.json" | jq -r --arg p "node_modules/$1" '.packages[$p].version // empty' 2>/dev/null)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  # the grep/yaml lockfiles use the name as a PATTERN — escape regex metacharacters so
  # `lodash.merge` matches only itself and not `lodashXmerge` → docs for the wrong version
  # (codex). The version tail is peeled with `.*@` (no name), so it needs no escaping.
  esc=$(printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')
  # pnpm lockfile (yaml — a plain grep is enough for "  /<pkg>@<ver>:")
  v=$(safe_cat "$REPO_DIR/pnpm-lock.yaml" | grep -oE "^[[:space:]]+/?${esc}@[0-9][^:( ]*" | head -1 | sed -E 's|.*@||')
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  # yarn.lock
  v=$(safe_cat "$REPO_DIR/yarn.lock" \
      | grep -A2 -E "^\"?${esc}@" | grep -oE '^[[:space:]]+version "[^"]+"' | head -1 | sed -E 's/.*version "([^"]+)".*/\1/')
  printf '%s' "$v"
}

MISS=""; GOT=0
for p in $PKGS; do
  safe=$(printf '%s' "$p" | tr '/' '_')
  ver=$(pkg_version "$p")
  if [ -z "$ver" ]; then
    MISS="${MISS}${p}(Version unbekannt) "
    continue
  fi
  # The version goes straight into the cache filename `$CACHE/$safe@$ver.md`. A lockfile is not
  # trusted input — a version like `../../../etc/secret` would let O_NOFOLLOW (which stops only
  # symlinks, never `..` traversal) copy a foreign .md into a bundle that leaves the machine
  # (codex). Only a real version string is allowed; anything else is treated as no docs.
  case "$ver" in *[!A-Za-z0-9._+-]*|*..*) MISS="${MISS}${p}(ungültige Version) "; continue;; esac
  if safe_copy "$CACHE/$safe@$ver.md" "$OUT/$safe.md"; then
    GOT=$((GOT+1))
  else
    MISS="${MISS}${p}@${ver} "
  fi
done

[ -z "$MISS" ] || out unavailable "keine echte Doku für: $MISS (Claude muss sie per Context7 für GENAU diese Version holen)"
out pass "$GOT Paket-Doku(s) im Bündel (versionsgenau)"

#!/usr/bin/env bash
# grounding-check-diff.sh — deterministic anti-hallucination check on a diff.
# For every ADDED relative import/require, verify the target resolves to a real
# file. Conservative: only ./ and ../ paths are checked. Alias (@/…) and bare
# module names are recorded as "skipped" and NEVER cause a violation. 0 tokens.
set -uo pipefail

DIFF=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --diff) DIFF="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 64;;
  esac
done
[ -f "$DIFF" ] || { echo "diff not found: $DIFF" >&2; exit 64; }
[ -d "$REPO" ] || { echo "repo not found: $REPO" >&2; exit 64; }

# The A2 namespace-call stage lives entirely in perl (build_nsmap's comment
# stripper, is_shadowed). With perl gone those pipes yield nothing, the map
# stays empty and A2 checks NOTHING while still exiting 0 — an invented
# `db.ghostMethod()` sails through a gate that looks healthy. Refuse to run
# instead: 65 = infra error, the caller turns it into a block (fail-closed).
command -v perl >/dev/null 2>&1 \
  || { echo "perl fehlt — die Grounding-Prüfung kann nicht laufen" >&2; exit 65; }

SKIP="[]"
# Violations go to a FILE, not a variable: the A2 call-check below appends from inside a
# `grep | while` pipe, which bash 3.2 runs in a SUBSHELL — a variable written there is lost
# on exit (this is exactly the trap that bit the import check's early drafts). adds() stays
# variable-based: it is only ever called from the main loop, never a subshell.
VIOLTMP=$(mktemp -t veto-gate-grounding-viol)
addv(){ jq -cn --arg f "$1" --arg s "$2" --arg y "${3:-}" \
  '{file:$f,import:$s} + (if $y != "" then {symbol:$y} else {} end)' >> "$VIOLTMP"; }
adds(){ SKIP=$(jq -c --arg f "$1" --arg s "$2" '. + [{file:$f,import:$s}]' <<<"$SKIP"); }

resolve_file(){ # $1 = base path (may contain ..); prints first existing FILE
  # directories never count as a hit themselves (codex live finding: grep on
  # a directory made real symbols look missing) — their index.* candidates
  # further down the list resolve them
  local b="$1" c
  for c in "$b" "$b".ts "$b".tsx "$b".mts "$b".cts "$b".js "$b".jsx "$b".mjs "$b".cjs "$b".json "$b".d.ts \
           "$b"/index.ts "$b"/index.tsx "$b"/index.js "$b"/index.jsx; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# One small lexer for everything that needs to see CODE without strings or comments (codex
# kept finding regex/sed corner cases: `//` inside a URL, a comma inside a string, an escaped
# quote, a call inside a template expression). It removes line and block comments and the
# BODIES of '…' / "…" / `…` strings, but KEEPS the code inside a template's `${ … }` — that
# is real code and may hold a real call. Reads stdin, writes the code skeleton to stdout.
codeskel(){
  perl -0777 -e '
    my $s = do { local $/; <STDIN> }; my $o = ""; my $i = 0; my $L = length $s;
    while ($i < $L) {
      my $two = substr($s,$i,2);
      if ($two eq "//") { $i+=2; $i++ while $i<$L && substr($s,$i,1) ne "\n"; next; }
      if ($two eq "/*") { $i+=2; $i++ while $i<$L && substr($s,$i,2) ne "*/"; $i+=2; next; }
      my $c = substr($s,$i,1);
      if ($c eq "\x27" || $c eq "\x22") {                 # single/double quoted string
        my $q=$c; $i++;
        while ($i<$L) { my $d=substr($s,$i,1);
          if ($d eq "\\") { $i+=2; next; } if ($d eq $q) { $i++; last; } $i++; }
        $o.=" "; next;
      }
      if ($c eq "\x60") {                                 # template literal
        $i++;
        while ($i<$L) {
          my $d=substr($s,$i,1);
          if ($d eq "\\") { $i+=2; next; }
          if ($d eq "\x60") { $i++; last; }
          if (substr($s,$i,2) eq "\${") {                 # expression: keep its code
            $i+=2; $o.=" "; my $depth=1;
            while ($i<$L && $depth>0) {
              my $e=substr($s,$i,1); $i++;
              if ($e eq "{") { $depth++; $o.="{"; next; }
              if ($e eq "}") { $depth--; $o.=($depth==0?" ":"}"); next; }
              $o.=$e;
            }
            next;
          }
          $i++;                                           # ordinary template char dropped
        }
        $o.=" "; next;
      }
      $o.=$c; $i++;
    }
    print $o;
  ' 2>/dev/null
}

# Is a namespace name ALSO bound locally in the file (codex B3)? `import * as db` at the top
# plus a `function f(db)` param or a `const db` means a `db.x()` in that scope is on the LOCAL
# value, not the module — checking it against db.ts would false-block valid code. Precise scope
# needs a parser; we err safe and DROP the whole namespace when its name is bound anywhere in
# the file. That over-skips (a false negative), never false-blocks. Name via env → quotemeta,
# so a `$` in it is data, never a regex.
is_shadowed(){ # $1 = file, $2 = namespace name → exit 0 if the name is bound locally
  NSNAME="$2" perl -0777 -ne '
    my $n = quotemeta($ENV{NSNAME});
    exit 0 if /\b(?:const|let|var)\s+$n\b/;                 # local declaration
    exit 0 if /\bfunction\b[^({]*\([^)]*\b$n\b[^)]*\)/;     # function parameter
    # method-shorthand parameter: NAME(… n …) { … } or NAME(… n …): T { … }. Not preceded by
    # a dot (that would be a call arr.forEach(n)), not a control keyword (if/for/while/…),
    # and a real body brace must follow — so a ternary call `x ? f(n) : y` is not matched.
    exit 0 if /(?<![.\w\$])(?!(?:if|for|while|switch|catch|return|function|await|typeof|in|of|new|delete|void|yield)\b)[A-Za-z0-9_\$]+\s*\([^()]*\b$n\b[^()]*\)\s*(?::[^{;=]*)?\{/;
    exit 0 if /\([^()]*\b$n\b[^()]*\)\s*=>/;                # arrow parameter list
    exit 0 if /(?:^|[^.\w\$])$n\s*=>/;                      # single arrow parameter
    exit 0 if /\bcatch\s*\(\s*$n\b/;                        # catch binding
    exit 1
  ' "$1" 2>/dev/null
}

# A2: map every `import * as NS from "./x"` in a file to its resolved target, PER FILE
# (file → ns → target). Per file, not global: two files may both import `db` from different
# places, and a call in file A must resolve against A's import. Read from the WORKING TREE,
# like resolve_file and the gate's add-chain diff — a call added in a `git add && commit` can
# reference an import in a file that is not yet staged, and an old import stays absent from
# the diff (codex B2).
build_nsmap(){ # $1 = repo-relative file
  [ -f "$REPO/$1" ] || return 0
  local dir imp ns p t; dir=$(dirname "$1")
  # strip comments so a commented-out `import * as` cannot create a phantom namespace, and
  # anchor to the start of the line so the same text inside a string is ignored too (codex B2)
  perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$REPO/$1" 2>/dev/null \
    | grep -oE "^[[:space:]]*import[[:space:]]+\*[[:space:]]+as[[:space:]]+[A-Za-z0-9_\$]+[[:space:]]+from[[:space:]]*['\"][^'\"]+['\"]" \
    | while IFS= read -r imp; do
        ns=$(printf '%s' "$imp" | awk '{print $4}')
        p=$(printf '%s' "$imp" | grep -oE "['\"][^'\"]+['\"]$" | tr -d "'\"")
        case "$p" in ./*|../*) ;; *) continue;; esac
        is_shadowed "$REPO/$1" "$ns" && continue
        if t=$(resolve_file "$REPO/$dir/$p"); then printf '%s\t%s\t%s\n' "$1" "$ns" "$t" >> "$NSMAP"; fi
      done
}

# The set of names a target file really EXPORTS (codex B1/B2). Matching a name "anywhere on
# an export line" was wrong twice: a PARAMETER or a comment word counted as an export (a
# false pass), and a multi-line `export { … }` block was invisible to a per-line grep, so a
# real method read as invented (a false BLOCK — the worse of the two). This reads real
# export FORMS, multi-line brace blocks included.
#
# If the file uses a form this cannot resolve, the set is UNKNOWN and the call-check SKIPS
# that target — never block on a set we could not read. Undecidable forms:
#   - `export *` / `export =` / a destructured `export const { … }`
#   - CommonJS: `module.exports` / `exports.x` — no ES `export` at all (codex)
#   - anything using `declare` — an ambient declaration produces no runtime value we can
#     verify, so its export shape is uncertain (codex)
exports_undecidable(){
  grep -qE 'export[[:space:]]*\*|export[[:space:]]*=|export[[:space:]]+(default[[:space:]]+)?(const|let|var)[[:space:]]*[{[]|module\.exports|(^|[^.[:alnum:]_])exports[.[]|(^|[^.[:alnum:]_])declare[[:space:]]' "$1" 2>/dev/null
}
# RUNTIME exports only (codex). A namespace call `ns.method()` resolves at runtime, so:
#   - `type` and `interface` are excluded — they do not exist at runtime, calling one is a bug.
#   - `export default function foo` is visible on the namespace as `default`, NOT `foo`.
#   - `export type { … }` (type-only re-export) is skipped; plain `export { … }` counts.
# Files using `declare` never reach here — exports_undecidable skips them.
exported_names(){ # $1 = target file → one runtime-exported name per line
  # through the lexer first: comments and string BODIES gone, so a comma or a `//` inside a
  # string cannot split a declarator list or hide a real export (codex).
  codeskel < "$1" | perl -0777 -ne '
    while (/\bexport\s+(type\s+)?\{([^}]*)\}/g) {  # named / re-exported, multi-line ok
      unless (defined $1) {                        # `export type { … }` is type-only → skip
        for my $part (split /,/, $2) {
          $part =~ s/^\s+|\s+$//g; next unless length $part;
          next if $part =~ /^type\s+(?!as\b)/;                         # inline `type Foo [as Bar]` is type-only (codex)
          if ($part =~ /\bas\s+([A-Za-z0-9_\$]+)/) { print "$1\n"; }   # x as y → exports y
          elsif ($part =~ /^([A-Za-z0-9_\$]+)$/)    { print "$1\n"; }  # plain x
        }
      }
    }
    # single-name declarations
    while (/\bexport\s+(?:async\s+|abstract\s+)*(?:function\*?|class|enum|namespace)\s+([A-Za-z0-9_\$]+)/g) { print "$1\n"; }
    # const/let/var may declare SEVERAL names in one statement, ACROSS lines up to the `;`
    # (codex): `export const a = 1,\n b = 2;`. Split the declarator list on TOP-LEVEL commas
    # only — a comma inside a value like `export const a = f(1,2), b = 3` must not split it.
    while (/\bexport\s+(?:const|let|var)\s+([^;]*)/g) {
      my $decl = $1; my $depth = 0; my $cur = ""; my @parts;
      for my $ch (split //, $decl) {
        if    ($ch =~ /[([{]/) { $depth++; $cur .= $ch; }
        elsif ($ch =~ /[)\]}]/) { $depth--; $cur .= $ch; }
        elsif ($ch eq "," && $depth == 0) { push @parts, $cur; $cur = ""; }
        else  { $cur .= $ch; }
      }
      push @parts, $cur;
      for my $p (@parts) { if ($p =~ /^\s*([A-Za-z0-9_\$]+)/) { print "$1\n"; } }
    }
    while (/\bexport\s+default\b/g) { print "default\n"; }
  ' 2>/dev/null
}

SYMTMP=$(mktemp -t veto-gate-grounding-syms)
NSMAP=$(mktemp -t veto-gate-grounding-nsmap)
trap 'rm -f "$SYMTMP" "$VIOLTMP" "$NSMAP"' EXIT

# Python relative imports. The only two repos where this gate is armed are
# Python repos (~335 .py each, measured 2026-07-29), and until now this stage
# read JS/TS syntax only — an invented module reached codex instead of being
# caught here for free, and reached NOTHING when codex was unreachable.
#
# Only relative imports are judged. `import foo` depends on the interpreter's
# search path (site-packages, PYTHONPATH, the working directory), which this
# cannot know — a false block on `import os` would be worse than the gap.
#
# `.a.b` from a file in dir D means D/a/b; each dot BEYOND the first goes one
# level up. A package resolves through its __init__.py — that is what makes the
# directory importable in the first place.
resolve_py(){ # $1 = dir of the importing file (repo-relative), $2 = dotted spec
  local dir="$1" spec="$2" base="$2" n=0
  while [ "${spec#.}" != "$spec" ]; do spec="${spec#.}"; n=$((n+1)); done
  base="$dir"
  while [ "$n" -gt 1 ]; do base="$base/.."; n=$((n-1)); done
  [ -n "$spec" ] || return 1          # `from . import x` — handled by the caller
  base="$base/$(printf '%s' "$spec" | tr '.' '/')"
  [ -f "$REPO/$base.py" ] && { printf '%s' "$REPO/$base.py"; return 0; }
  [ -f "$REPO/$base/__init__.py" ] && { printf '%s' "$REPO/$base/__init__.py"; return 0; }
  return 1
}

# An ABSOLUTE import can still be decidable — when its top-level name is a
# package this repo itself ships. Measured 2026-07-29 in testbau-repo
# (one of the two armed repos): 0 relative imports, ~1250 absolute ones onto its
# own packages (`from orchestrator…`, `from learning…`, `from gates…`). Checking
# relative imports alone would have left it completely uncovered.
#
# "Its own" means a real package — __init__.py present — at the repo root or
# under src/, the two layouts in use here. A bare directory does not count: that
# is what keeps a local folder from being mistaken for the library it shadows.
# Everything else stays unjudged; the interpreter's search path is not knowable
# from here.
py_root(){ # $1 = top-level name; prints the root dir holding it, or fails
  local t="$1" r
  for r in "" src; do
    [ -f "$REPO${r:+/$r}/$t/__init__.py" ] && { printf '%s' "${r:+$r/}"; return 0; }
    [ -f "$REPO${r:+/$r}/$t.py" ] && { printf '%s' "${r:+$r/}"; return 0; }
  done
  return 1
}
resolve_py_abs(){ # $1 = dotted spec, e.g. orchestrator.runner
  local spec="$1" top="${1%%.*}" root p
  case "$spec" in *.*) ;; *) return 0;; esac   # bare package: it exists, nothing to say
  root=$(py_root "$top") || return 0           # not ours → not our judgement
  p="$REPO/$root$(printf '%s' "$spec" | tr '.' '/')"
  { [ -f "$p.py" ] || [ -f "$p/__init__.py" ]; } && return 0
  return 1
}

curfile=""
pytq=0     # inside a triple-quoted run? reset per file, see below
while IFS= read -r line; do
  case "$line" in
    "+++ b/"*) curfile="${line#+++ b/}"; pytq=0; continue;;
    "diff --git"*|"--- "*|"+++ "*) continue;;
  esac
  [ "${line:0:1}" = "+" ] || continue          # added lines only
  # deny-list, fail-closed: only known literal-only file types are exempt from
  # import grounding — an "import …" in .sh/.md is a string, not an import (F3).
  # Everything else (incl. .astro/.mdx and future types) stays checked; an
  # allow-list here would silently exempt unknown import-bearing types (veto2
  # live-review finding).
  case "$curfile" in
    *.sh|*.bash|*.zsh|*.md|*.txt|*.yml|*.yaml|*.toml|*.ini|*.conf) continue;;
    *) ;;
  esac
  content="${line:1}"
  case "$curfile" in
    *.py)
      # A docstring showing example imports is the one shape that would false-
      # block: unlike a JS comment it sits at column 0, exactly like real code.
      # So triple-quote runs are tracked across the added lines of this file —
      # documentation must never block a commit. State is read BEFORE the line
      # is counted, so the opening line itself already counts as inside.
      WASQ=$pytq
      TQ=$(printf '%s' "$content" | grep -oE '"""|'"'''" | grep -c '')
      [ $(( TQ % 2 )) -eq 1 ] && pytq=$(( 1 - pytq ))
      [ "$WASQ" = 1 ] && continue
      # column 0 only, and `from .x import` only: an indented line is far more
      # likely prose than a module import, and `from . import x` is ambiguous
      # (x may be a submodule OR a name bound in __init__.py) — undecidable
      # cases are skipped, never blocked, as everywhere else here.
      PYSPEC=$(printf '%s' "$content" | grep -oE '^(from|import)[[:space:]]+\.?[A-Za-z0-9_.]*[[:space:]]*' \
               | awk '{print $2}')
      [ -z "$PYSPEC" ] && continue
      case "$PYSPEC" in
        .*)
          # `from . import x` is ambiguous — x may be a submodule OR a name
          # bound in __init__.py. Undecidable is skipped, never blocked.
          case "$PYSPEC" in *[!.]*) ;; *) continue;; esac
          printf '%s' "$content" | grep -qE '^from[[:space:]]' || continue
          resolve_py "$(dirname "$curfile")" "$PYSPEC" >/dev/null && continue;;
        *)
          resolve_py_abs "$PYSPEC" && continue;;
      esac
      addv "$curfile" "$PYSPEC"
      continue;;
  esac
  path=$(printf '%s' "$content" \
    | grep -oE "(from|require\(|import\()[[:space:]]*['\"][^'\"]+['\"]" \
    | grep -oE "['\"][^'\"]+['\"]" | head -1 | tr -d "'\"")
  [ -z "$path" ] && continue
  case "$path" in
    ./*|../*)
      # dirname of a real staged file exists, so -e follows ".." correctly without normalization
      base="$REPO/$(dirname "$curfile")/$path"
      if tgt=$(resolve_file "$base"); then
        # B3: symbol grounding — every ORIGINAL name of a named import/re-export
        # must appear as a word in the resolved file. Undecidable cases are
        # skipped, never blocked: re-export barrels (export *), .json/.d.ts
        # targets, default/namespace imports. 0 tokens, pure grep.
        case "$tgt" in *.json|*.d.ts) continue;; esac
        grep -q 'export[[:space:]]*\*' "$tgt" 2>/dev/null && continue
        # symbols are only decidable when the line holds exactly ONE
        # module reference — with several (from/require()/import() in any
        # mix), names and paths can't be paired line-wise (codex live
        # findings rounds 2+4: statement 2's names were checked against
        # statement 1's file → false block). Same pattern as the path
        # extraction above, so both counts always agree.
        NREF=$(printf '%s' "$content" \
          | grep -oE "(from|require\(|import\()[[:space:]]*['\"][^'\"]+['\"]" | grep -c '' )
        [ "${NREF:-0}" -gt 1 ] && continue
        # only a line that IS an import/export statement carries checkable
        # names — import-looking text in comments or strings must not block
        # (codex live finding round 5)
        printf '%s' "$content" | grep -qE '^[[:space:]]*(import|export)[[:space:]]' || continue
        # named part may follow a default import: import def, { a } from …
        printf '%s' "$content" \
          | grep -oE '(import|export)[[:space:]]+(type[[:space:]]+)?([A-Za-z0-9_$]+[[:space:]]*,[[:space:]]*)?\{[^}]*\}' \
          | sed -E 's|/\*[^*]*\*/||g; s/^[^{]*\{//; s/\}.*$//' | tr ',' '\n' \
          | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^type[[:space:]]+//; s/[[:space:]]+as[[:space:]]+.*$//' \
          > "$SYMTMP"
        while IFS= read -r sym; do
          [ -z "$sym" ] && continue
          # only clean identifiers are decidable — comment remnants or exotic
          # tokens skip instead of blocking; -F matches $-names literally
          # (codex live findings: '$foo' read as regex, 'dep /* x */' as one
          # literal — both false-blocked real imports)
          case "$sym" in *[!A-Za-z0-9_\$]*) continue;; esac
          grep -qFw -- "$sym" "$tgt" 2>/dev/null || addv "$curfile" "$path" "$sym"
        done < "$SYMTMP"
      elif [ -d "$base" ]; then
        # existing directory without an index file: bundler/package magic may
        # still resolve it — path passes, symbols are undecidable → skip
        :
      else
        addv "$curfile" "$path"
      fi
      ;;
    *) adds "$curfile" "$path";;               # alias/bare → skipped, never blocked
  esac
done < "$DIFF"

# ── A2: calls on imported namespaces (Sorte A, second half) ─────────────────
# `db.zahleAus()` where db.ts was never touched: the import passes (the file exists), the
# method does not exist, and until now nobody looked — codex cannot see it either (db.ts is
# not in his bundle). Build the per-file namespace map from every touched file's WORKING-TREE
# state (build_nsmap); an old import unchanged by the diff is still seen there (codex B2).
grep -E '^\+\+\+ b/' "$DIFF" | sed 's|^+++ b/||' | sort -u \
  | while IFS= read -r f; do build_nsmap "$f"; done

if [ -s "$NSMAP" ]; then
  curfile=""
  while IFS= read -r line; do
    case "$line" in "+++ b/"*) curfile="${line#+++ b/}"; continue;; esac
    [ "${line:0:1}" = "+" ] || continue
    # only checkable in real code files — an import-looking token in shell/docs is text
    case "$curfile" in *.sh|*.bash|*.zsh|*.md|*.txt|*.yml|*.yaml|*.toml|*.ini|*.conf) continue;; esac
    # drop comments and string literals FIRST so a call sitting in either does not
    # false-block. A false block trains people to reach for --no-verify, and then NOTHING
    # is checked at all — worse than missing one invented call. The lexer removes comments and
    # string bodies but KEEPS code inside a template's `${ … }`, so a call there is still seen
    # (codex) and a `//` inside a URL string cannot swallow a real call after it.
    csan=$(printf '%s\n' "${line:1}" | codeskel)
    # `?.` optional chaining counts as a call too (codex): match an optional dot between the
    # object and the method.
    printf '%s' "$csan" \
      | grep -oE "[A-Za-z0-9_\$]+\??\.[A-Za-z0-9_\$]+[[:space:]]*\(" \
      | while IFS= read -r call; do
          obj="${call%%[?.]*}"                     # object before the first '?' or '.'
          rest="${call#*.}"; meth="${rest%%[^A-Za-z0-9_\$]*}"   # method up to the first non-identifier
          [ -n "$meth" ] || continue
          # is the object a namespace THIS FILE imports? exact field match on (file, name),
          # so a '$' is data not a regex, and file A's `db` never resolves against file B's
          tgt=$(awk -F'\t' -v cf="$curfile" -v o="$obj" '$1==cf && $2==o{print $3; exit}' "$NSMAP")
          [ -n "$tgt" ] || continue
          # ambient declaration files and data have export semantics we do not parse → skip
          case "$tgt" in *.json|*.d.ts) continue;; esac
          # if the target's export set is unreadable (export */=/destructured/CommonJS), we
          # cannot prove the method is missing → skip, never block (codex B1)
          exports_undecidable "$tgt" && continue
          # The target's exports are read from the WORKING TREE — as is resolve_file, the
          # namespace map, and the original import-symbol check above. Codex asked for the
          # git index instead; deliberately not (documented override): the gate runs BEFORE a
          # `git add -A && commit`, so the index still holds the OLD target, and reading it
          # would FALSE-BLOCK the common case where the method is added to the target in the
          # very same commit. The working tree's only failure is the mirror image — an unstaged
          # edit to an UNcommitted dependency could mask a missing method — which is a false
          # PASS, exactly the conservative "better to miss than false-block" mode this whole
          # check is built on. A false block is the one thing that drives people to --no-verify.
          #
          # Evidence is a real EXPORTED name matched as a whole line against the parsed set, so
          # a parameter, a comment word or a multi-line block neither clears nor blocks falsely.
          exported_names "$tgt" | grep -qFx -- "$meth" || addv "$curfile" "$obj" "$meth"
        done
  done < "$DIFF"
fi

# build the final list from the file — every addv from every pass, subshell or not
VIOL=$(jq -sc '.' "$VIOLTMP" 2>/dev/null); [ -n "$VIOL" ] || VIOL="[]"
COUNT=$(jq 'length' <<<"$VIOL")
jq -n --argjson v "$VIOL" --argjson s "$SKIP" --argjson c "$COUNT" \
  '{violations:$v,skipped:$s,count:$c}'
[ "$COUNT" -eq 0 ]

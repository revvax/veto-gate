#!/usr/bin/env bash
# veto-gate.sh — PreToolUse hook (matcher: Bash). "veto 2" workflow.
# Blocks `git commit` when a hallucinated import (deterministic) or a codex
# adversarial diff review finds a blocking issue. Opt-in per repo. Fails OPEN
# on codex infra errors. Single-use session override.
set -uo pipefail
LIB="$(dirname "$0")/lib/veto-gate"   # one canonical library path — no alias, no second name
# shellcheck source=lib/veto-cfg.sh
. "$(dirname "$0")/lib/veto-cfg.sh"   # veto_cfg / veto_cfg_on / veto_cfg_name — worktree-aware
# shellcheck source=lib/heartbeat.sh
. "$(dirname "$0")/lib/heartbeat.sh"   # hb / hb_once — the beat that proves this hook ran
# shellcheck source=lib/veto-gate/proof.sh
. "$LIB/proof.sh"   # evidence ledger — every stage leaves a note, never a silent skip
. "$LIB/generated-files.sh"   # the ONE lockfile list — shared with diff-size.sh and pack-diff.sh

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null | tr -dc 'a-zA-Z0-9_-')
[ -z "$CWD" ] && CWD="$PWD"

# only git commit (mirror quality-gate-commit.sh detection). Also match
# `git -C <path> commit` — and honor -C: the commit targets THAT repo, not the
# shell cwd (E1 finding: cwd-based review inspected the wrong repo's diff).
# a shell token: double-quoted (may contain spaces), single-quoted, or bare
# (codex live finding: bare-only parsing broke on 'cd "/path with space"')
TOK='("[^"]+"|'\''[^'\'']+'\''|(\\.|[^[:space:]\\])+)'
TOKCD='("[^"]+"|'\''[^'\'']+'\''|(\\.|[^[:space:];&|\\])+)'
# A commit may END at a shell separator, not only at whitespace or end of line:
# `git commit;` matched NOTHING, so the hook exited 0 and the commit was never
# reviewed at all — measured 2026-07-28.
# A glued `(git commit …` is a structural commit too and was invisible as well.
# `$(git commit …)` must NOT become structural — it is a hidden commit and has its
# own fail-closed path — so the opening `(` is accepted only when it is not preceded
# by a `$`: at the very start of the line, or after any other character.
COMMIT_RE='(^|^\(|[;&|[:space:]]|[^$\]\()git[[:space:]]+(-C[[:space:]]+'"$TOK"'[[:space:]]+)?(-[^[:space:]]+[[:space:]]+)*commit([[:space:];&|)}]|$)'
# Quoted string CONTENTS are data, not commands — cd/git-commit text inside
# quoted args must never steer the parser (codex live finding). blank_quotes()
# replaces them with same-LENGTH spaces, so all structural parsing runs on the
# blanked string and real targets are recovered from the raw string by offset.
# LIMITS (documented, conservative by construction): pathological escape
# mixes (\\" — escaped backslash before a real delimiter) may mis-pair, but
# mis-parsed targets end in the [ -d ] check and fall back to the session
# cwd; a static parser cannot know runtime exit codes, the single-use
# override file stays the sanctioned bypass for everything beyond.
blank_quotes(){
  [ -n "${VETO_GATE_NO_PERL:-}" ] && return 1   # test seam: simulate missing perl
  printf '%s' "$1" | perl -0777 -pe \
    's/\\(["\x27])/"  "/ge;
     s/("[^"]*")|(\x27[^\x27]*\x27)/defined($1) ? "\"".(" " x (length($1)-2))."\"" : "\x27".(" " x (length($2)-2))."\x27"/ge' \
    2>/dev/null
}

# Hooks get the RAW command string — the shell never expanded ~ or $HOME in
# cd/-C targets for us (F19b: unexpanded target failed [ -d ], gate silently
# fell back to the wrong cwd repo). Quoting decides what the shell WOULD have
# expanded (codex live finding): bare → ~ and $HOME expand · "double" → only
# $HOME expands · 'single' → everything stays literal.
resolve_target(){
  local t="$1" q=bare
  case "$t" in
    \"*\") q=dq; t="${t#\"}"; t="${t%\"}";;
    \'*\') t="${t#\'}"; printf '%s' "${t%\'}"; return;;
  esac
  if [ "$q" = "bare" ]; then
    case "$t" in "~") t="$HOME";; "~/"*) t="$HOME/${t#\~/}";; esac
    # \$HOME is a LITERAL dollar for the shell — never expand it (codex find)
    case "$t" in '\$'*) printf '%s' "$t" | sed -E 's/\\(.)/\1/g'; return;; esac
    # unquoted: the shell strips backslash escapes (cd mein\ repo → mein repo)
    t=$(printf '%s' "$t" | sed -E 's/\\(.)/\1/g')
  fi
  case "$t" in
    '$HOME')      t="$HOME";;
    '$HOME/'*)    t="$HOME/${t#\$HOME/}";;
    '${HOME}')    t="$HOME";;
    '${HOME}/'*)  t="$HOME/${t#\$\{HOME\}/}";;
  esac
  printf '%s' "$t"
}

BLANK=$(blank_quotes "$CMD")
# a git commit WITHOUT a leading separator requirement — used to spot commits
# hidden inside $(...)/backtick substitutions, which DO execute
HIDDEN_RE='git[[:space:]]+(-C[[:space:]]+'"$TOK"'[[:space:]]+)?(-[^[:space:]]+[[:space:]]+)*commit([[:space:]]|$|\))'
# interpreters that EXECUTE their (quoted) string argument (codex find #21):
# shells only in their real -c form — a plain 'bash build.sh' next to commit
# PROSE is not suspicious (codex find #22); eval always executes its args
EXEC_RE='(^|[;&|[:space:]])((bash|sh|zsh|ksh|dash)[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*c[a-zA-Z]*([[:space:]]|$)|eval([[:space:]]|$))'
# the SPANS those interpreters execute (the -c argument / the eval tail) —
# a hidden commit counts only INSIDE such a span, not anywhere in the
# command next to an unrelated substitution (codex find #28)
EXECSPAN_RE='(^|[;&|[:space:]])((bash|sh|zsh|ksh|dash)[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*c[a-zA-Z]*[[:space:]]+("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)|eval[[:space:]][^;&|]*)'

# without perl targets cannot be parsed — approximate the per-repo OPT-IN
# over the session repo and every raw -C candidate before failing closed;
# no repo gated → the gate must stay inert (codex find #20). Word-splitting
# over space-paths is an accepted residual of this perl-less approximation.
gated_anywhere(){
  local d t
  for d in "$CWD" $(printf '%s' "$CMD" \
      | grep -oE '(\-C|(^|[;&|[:space:]"(])cd)[[:space:]]+[^[:space:]]+' \
      | sed -E 's/^[;&|[:space:]"(]+//; s/^(-C|cd)[[:space:]]+//'); do
    # same quote-aware resolution as the normal path (codex find #27)
    d=$(resolve_target "$d")
    [ -n "$d" ] || continue
    [ -d "$d" ] || continue
    t=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$t" ] && d="$t"
    veto_gate_armed "$d" && return 0
  done
  return 1
}

if [ -z "$BLANK" ] && [ -n "$CMD" ]; then
  # perl missing/failed → quotes cannot be lexed. Commit commands WITH quotes
  # are not safely parseable → fail CLOSED in gated repos (codex find: raw
  # fallback re-opened the quoted-cd hole); quote-free commands have nothing
  # to blank; commands without a (raw-matched) git commit are none of our
  # business — unless a commit hides in a substitution (codex find #19).
  if ! printf '%s' "$CMD" | grep -qE "$COMMIT_RE"; then
    if printf '%s' "$CMD" | grep -qE '\$\(|`|'"$EXEC_RE" \
       && printf '%s' "$CMD" | grep -qE "$HIDDEN_RE" && gated_anywhere; then
      echo "⛔ VETO-GATE: perl fehlt — möglicher Commit in Substitution/Interpreter. Commit geblockt." >&2
      exit 2
    fi
    hb_once veto-gate skipped "kein Commit im Befehl"
    exit 0
  fi
  case "$CMD" in
    *'"'*|*"'"*)
      if gated_anywhere; then
        echo "⛔ VETO-GATE: perl fehlt — Commit mit Anführungszeichen nicht sicher prüfbar. Commit geblockt." >&2
        exit 2
      fi
      exit 0;;
  esac
  BLANK="$CMD"
fi
# no structural (unquoted) git commit → nothing to gate — UNLESS a commit
# hides inside an EXECUTABLE substitution: $(...) and backticks run, also
# inside double quotes (codex live finding: blanking hid them). Single-quoted
# text stays literal. Hidden commits cannot be target-parsed → HIDDEN blocks
# fail-closed after the per-repo opt-in + override checks below.
HIDDEN=0
LINE=$(printf '%s' "$BLANK" | grep -boE "$COMMIT_RE" | head -1)
if [ -n "$LINE" ]; then
  # a structural match INSIDE an open $(/backtick region is a hidden commit
  # — blanking keeps substitutions visible (codex find #25: echo $(cd repo
  # && git commit)); balanced substitutions before a real commit are fine
  PREB=${BLANK:0:${LINE%%:*}}
  o=$(( $(printf '%s' "$PREB" | grep -o '\$(' | wc -l) ))
  c=$(( $(printf '%s' "$PREB" | grep -o ')' | wc -l) ))
  bt=$(( $(printf '%s' "$PREB" | grep -o '`' | wc -l) ))
  if [ "$o" -gt "$c" ] || [ $(( bt % 2 )) -eq 1 ]; then
    HIDDEN=1; LINE=""
  fi
fi
if [ -z "$LINE" ] && [ "$HIDDEN" = 0 ]; then
  SQB=$(printf '%s' "$CMD" | perl -0777 -pe \
    's/\\(["\x27])/"  "/ge;
     s/\x27[^\x27]*\x27/"\x27".(" " x (length($&)-2))."\x27"/ge' 2>/dev/null)
  [ -z "$SQB" ] && SQB="$CMD"
  # collect only the EXECUTABLE spans: $()/backtick bodies (sq-blanked view —
  # single-quoted substitution text is inert) and interpreter -c/eval
  # arguments (raw view — their sq strings DO execute)
  SPANS=$(
    { printf '%s\n' "$SQB" | grep -oE '\$\([^)]*(\)|$)'
      printf '%s\n' "$SQB" | grep -oE '`[^`]*(`|$)'
      printf '%s\n' "$CMD" | grep -oE "$EXECSPAN_RE"
    } 2>/dev/null
  )
  if [ -n "$SPANS" ] && printf '%s' "$SPANS" | grep -qE "$HIDDEN_RE"; then
    HIDDEN=1
  else
    # The gate fires on EVERY Bash call and most of them are not commits — so
    # until now it beat only on the rare path and stayed silent on the common
    # one. On a day without commits that is indistinguishable from a dead gate.
    hb_once veto-gate skipped "kein Commit im Befehl"
    exit 0
  fi
fi
if [ "$HIDDEN" = 1 ]; then
  if [ -z "${SQB:-}" ]; then
    SQB=$(printf '%s' "$CMD" | perl -0777 -pe \
      's/\\(["\x27])/"  "/ge;
       s/\x27[^\x27]*\x27/"\x27".(" " x (length($&)-2))."\x27"/ge' 2>/dev/null)
    [ -z "$SQB" ] && SQB="$CMD"
  fi
  # a hidden 'git -C <target> commit' or 'cd <target> && git commit' may
  # aim at a GATED repo while the session cwd is not gated (codex finds
  # #18+#23) — check every -C/cd candidate, first gated one owns the
  # block/override paths below
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    cand=$(printf '%s' "$cand" | sed -E 's/^(-C|cd)[[:space:]]+//')
    cand=$(resolve_target "$cand")
    [ -n "$cand" ] || continue
    case "$cand" in /*) ;; *) cand="$CWD/$cand";; esac
    [ -d "$cand" ] || continue
    ctop=$(git -C "$cand" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$ctop" ] && cand="$ctop"
    if veto_gate_armed "$cand"; then
      CWD="$cand"; break
    fi
  done < <({ printf '%s\n' "$SQB"; printf '%s\n' "$CMD"; } | grep -oE '(\-C|(^|[;&|[:space:]"(])cd)[[:space:]]+'"$TOK" | sed -E 's/^[;&|[:space:]"(]+//')
fi
if [ "$HIDDEN" = 0 ]; then
OFF=${LINE%%:*}; M=${LINE#*:}
COMMIT_CALL=${CMD:$OFF:${#M}}          # raw slice — same length as the match
COMMIT_BLANK=${BLANK:$OFF:${#M}}
# Only the part BEFORE the first structural `git commit` may re-target the
# gate: a trailing `cd` after the commit must not bend the review off the
# repo (codex live finding). The -C target is taken from the commit
# invocation itself, not from unrelated git calls elsewhere in the chain.
PRE=${BLANK:0:$OFF}
PRE_RAW=${CMD:0:$OFF}
# the separator char the match consumed decides how the commit is JOINED:
# '&' with an '&' before it = the && operator written without spaces (codex
# live finding: 'cd /repo&&git commit') — strip the operator half; a lone
# '&' (background), ';' or '|' join breaks the commit-runs⟹cd-ran guarantee.
case "${BLANK:$OFF:1}" in
  "&") case "$PRE" in
         *"&") PRE=${PRE%&}; PRE_RAW=${PRE_RAW%&};;
         *)    PRE=""; PRE_RAW="";;
       esac;;
  ";"|"|") PRE=""; PRE_RAW="";;
esac
# `cd <repo> && git commit` targets the cd repo, not the session cwd (F19:
# cwd-based review inspected the session repo's diff, blocked on foreign
# findings — and would wave the real commit through unreviewed). Last cd wins;
# an explicit `git -C` below is more specific and overrides it.
# Honor a cd only when it sits in the FINAL ;-segment of the prefix and that
# segment is a pure && chain up to the commit: the segment starts
# unconditionally (after ; or newline) and every && link must succeed for the
# commit to run — so commit runs ⟹ cd ran. Anything else (| & || subshell,
# backtick) can skip the cd at runtime while the commit still runs — there
# the session cwd stays authoritative (codex live findings #2 and #6).
SEG=${PRE##*;}
SEG=${SEG##*$'\n'}
SEG_RAW=${PRE_RAW:$(( ${#PRE} - ${#SEG} ))}
PURE=$(printf '%s' "$SEG" | sed 's/&&/ /g')
case "$PURE" in *'|'*|*'&'*|*'`'*|*'$('*) SEG="" ;; esac
CDT=""
CDLINE=$(printf '%s' "$SEG" \
  | grep -boE '(^|[;&|])[[:space:]]*cd[[:space:]]+'"$TOKCD" | tail -1)
if [ -n "$CDLINE" ]; then
  CO=${CDLINE%%:*}; CM=${CDLINE#*:}
  # anchored strip — a greedy .*cd would eat into paths containing 'cd '
  CDT=$(printf '%s' "${SEG_RAW:$CO:${#CM}}" | sed -E 's/^[;&|]?[[:space:]]*cd[[:space:]]+//')
fi
CDT=$(resolve_target "$CDT")
if [ -n "$CDT" ]; then
  case "$CDT" in /*) ;; *) CDT="$CWD/$CDT";; esac
  [ -d "$CDT" ] && CWD="$CDT"
fi
GITC=""
GITLINE=$(printf '%s' "$COMMIT_BLANK" \
  | grep -boE '\-C[[:space:]]+'"$TOK" | head -1)
if [ -n "$GITLINE" ]; then
  GO=${GITLINE%%:*}; GM=${GITLINE#*:}
  # anchored strip — a greedy .*-C would eat into paths containing '-C '
  GITC=$(printf '%s' "${COMMIT_CALL:$GO:${#GM}}" | sed -E 's/^-C[[:space:]]+//')
fi
GITC=$(resolve_target "$GITC")
if [ -n "$GITC" ]; then
  # relative -C (git -C . commit) resolves against the cd-adjusted CWD,
  # never against the hook process cwd (codex live finding #3)
  case "$GITC" in /*) ;; *) GITC="$CWD/$GITC";; esac
  [ -d "$GITC" ] && CWD="$GITC"
fi
fi   # HIDDEN=1 skips target parsing — the session cwd stays authoritative

# a commit from a SUBFOLDER commits the whole repo — config and diff live at
# the toplevel (codex live finding: subdir cwd made the gate inert); non-repo
# dirs keep CWD so the opt-in check below stays purely path-based
TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
[ -n "$TOP" ] && [ -d "$TOP" ] && CWD="$TOP"

# LAST RESORT before giving up: the strict parsing above only honours a cd that
# provably ran (final ;-segment, pure && chain). A newline or a redirect defeats
# it, and then the SESSION cwd decides. Live 2026-07-29: that cwd was a repo with
# the gate off, so `cat > f <<EOF … EOF; git add f && git commit` committed a
# planted bug unreviewed and in silence, while the identical command without the
# redirect was blocked. That is how files get written here, so it was not an edge.
# R01 — a diff no reviewer judged is never waved through — outranks precision
# about WHICH repo: reviewing a repo the commit may not reach costs a false
# block that says so out loud; the other direction costs an unreviewed commit
# that says nothing. Same trade the hidden-commit path already makes above.
# Word-splitting over paths with spaces is the accepted residual there too.
if ! veto_gate_armed "$CWD"; then
  for VGC in $(printf '%s' "$CMD" \
      | grep -oE '(\-C|(^|[;&|[:space:]"(])cd)[[:space:]]+[^[:space:]]+' \
      | sed -E 's/^[;&|[:space:]"(]+//; s/^(-C|cd)[[:space:]]+//'); do
    VGC=$(resolve_target "$VGC")
    [ -n "$VGC" ] && [ -d "$VGC" ] || continue
    VGT=$(git -C "$VGC" rev-parse --show-toplevel 2>/dev/null)
    [ -n "$VGT" ] && VGC="$VGT"
    if veto_gate_armed "$VGC"; then CWD="$VGC"; break; fi
  done
fi

# opt-in per repo. A worktree carries no config of its own (gitignored) — the
# main checkout owns it. CWD stays the WORKTREE: the diff must come from there.
CFG=$(veto_gate_cfg "$CWD") || { hb_once veto-gate skipped "kein Gate-Konfig in $CWD"; exit 0; }
# A config that is not exactly one JSON object is BROKEN, not "off": two
# concatenated objects made a later .enabled read return garbage and disarmed an
# armed gate. Fail closed and say which file to fix.
if ! veto_cfg_sound "$CFG"; then
  echo "⛔ VETO-GATE: $CFG ist kaputt (kein einzelnes JSON-Objekt) — Commit geblockt. Datei reparieren oder löschen." >&2
  exit 2
fi
[ "$(jq -r '.enabled // false' "$CFG" 2>/dev/null)" = "true" ] || { hb_once veto-gate skipped "Gate aus in $CWD"; exit 0; }
# effort is the depth knob CONVENTIONS.md forbids turning down, so an unknown or
# missing value lands on "high" rather than on whatever the file happens to say.
EFFORT=$(jq -r '.effort // "high"' "$CFG" 2>/dev/null)
case "$EFFORT" in low|medium|high) ;; *) EFFORT=high;; esac
# The reviewer's time budget is CENTRAL, and a repo may only give MORE, never less.
#
# Measured 2026-07-29 across ten repo configs: 60, 100, 100, 240, 360 — every copy
# inherited whatever the template said the day it was made. The repo that produced
# the timeout report was still on the 60 s default and lost 13 of 30 runs; a fix
# applied to its main checkout never reached the worktree next to it, because that
# one carried its own copy.
#
# More time cannot lower review depth, so raising is allowed and lowering is not.
# A lower value is ignored and named, rather than silently honoured.
VG_TIMEOUT_MIN=360; VG_TIMEOUT2_MIN=420
CFG_TIMEOUT=$(jq -r --argjson m "$VG_TIMEOUT_MIN" '.timeout // $m' "$CFG" 2>/dev/null)
case "$CFG_TIMEOUT" in ''|*[!0-9]*) CFG_TIMEOUT=$VG_TIMEOUT_MIN;; esac
CFG_TIMEOUT2=$(jq -r --argjson d "$CFG_TIMEOUT" --argjson m "$VG_TIMEOUT2_MIN" '.timeout2 // ([$d,$m]|max)' "$CFG" 2>/dev/null)
case "$CFG_TIMEOUT2" in ''|*[!0-9]*) CFG_TIMEOUT2=$VG_TIMEOUT2_MIN;; esac
if [ "$CFG_TIMEOUT" -lt "$VG_TIMEOUT_MIN" ]; then
  echo "ℹ VETO-GATE: ${CFG#$CWD/} setzt timeout=$CFG_TIMEOUT — unter dem Mindestwert $VG_TIMEOUT_MIN, wird angehoben." >&2
  CFG_TIMEOUT=$VG_TIMEOUT_MIN
fi
[ "$CFG_TIMEOUT2" -lt "$VG_TIMEOUT2_MIN" ] && CFG_TIMEOUT2=$VG_TIMEOUT2_MIN
CFG_MAXLINES=$(jq -r '.max_lines // 300' "$CFG" 2>/dev/null)
# a non-numeric max_lines would make -gt fail silently and disarm the size
# gate (codex live finding) → fall back to the default
[ -z "${CFG_MAXLINES##*[!0-9]*}" ] && CFG_MAXLINES=300
# E3: prechecker choice — an explicit valid value wins, legacy "qwen": false
# maps to none. NB: jq's // treats false as empty — values are tested
# explicitly. Must resolve exactly like serve.py's _prechecker so the panel
# never shows a different stage than the gate runs.
CFG_PRE=$(jq -r '(.prechecker // "") as $p |
  if ($p == "minimax" or $p == "groq" or $p == "gemini" or $p == "none") then $p
  elif .qwen == false then "none" else "minimax" end' "$CFG" 2>/dev/null)
case "$CFG_PRE" in minimax|groq|gemini|none) ;; *) CFG_PRE="minimax";; esac
CFG_PLAN=$(jq -r '.plan_review // false' "$CFG" 2>/dev/null)
CFG_PLANPATH=$(jq -r '.plan_path // "docs/superpowers/plans/"' "$CFG" 2>/dev/null)

# single-use override: the flag file is consumed by the run it lets through, so
# one deliberate skip never turns into a standing exemption.
OVERRIDE="$CWD/.claude/session-flags/${SID}-veto-gate-override"
# ONE wording for the escape hatch — it used to stand 11 times verbatim, so
# teaching it the reason form meant editing 11 lines and missing one.
OV_CMD="printf '%s' 'DEIN GRUND' > \"$OVERRIDE\""
OV_HINT="Bewusst überspringen (in SEPARATEM Befehl VOR dem Commit; der Grund wird protokolliert): $OV_CMD"
if [ -f "$OVERRIDE" ]; then
  # The WHY travels in the file itself — `printf '%s' 'Grund' > <datei>` instead
  # of a bare `touch`. Measured 2026-08-13: 335 of the 1000 ledger entries are
  # bypasses and not one says why, so "the gate is too strict" and "we were in a
  # hurry" leave exactly the same trace and neither can be answered.
  #
  # First line only, control characters out, cut at 200 CHARACTERS (cut -c is
  # character-aware here, measured with umlauts) — a newline would split one run
  # into two ledger lines, and the ledger is a stats file, not an archive.
  OV_REASON=$(head -1 "$OVERRIDE" 2>/dev/null | tr -d '\000-\010\013\014\016-\037' | cut -c1-200)
  rm -f "$OVERRIDE"
  # A wave-through that leaves no trace cannot be counted. That is why the score
  # card printed `?` under REIBUNG for every single hook (E4, 2026-07-30): nothing
  # anywhere recorded how often the gate was stepped around, so "it helped" and
  # "it got in the way" were indistinguishable. Same shape as the silent early
  # exits E5 found — something happens and says nothing.
  #
  # log_run() is defined far below and needs REPO/BRANCH/START/DIFF, none of which
  # exist yet; the ledger script is called directly instead. --dur stays absent
  # (defaults to 0) because this path waits for no reviewer — inventing a duration
  # would pollute the wait-time figure that sits in the next column.
  hb_once veto-gate override "bewusste Umgehung (Override-Datei verbraucht)"
  bash "$LIB/log-run.sh" --repo "$(basename "$CWD")" \
    --branch "$(git -C "$CWD" branch --show-current 2>/dev/null)" \
    --result override --blocking 0 --reason "$OV_REASON" 2>/dev/null || true
  exit 0
fi

if [ "$HIDDEN" = 1 ]; then
  {
    echo "⛔ VETO-GATE: git commit versteckt in Befehls-Substitution (\$(..)/Backticks) — Ziel nicht parsebar, Commit geblockt."
    echo "Direkt committen (git commit ...) oder bewusst überspringen (SEPARATER Befehl VOR dem Commit): $OV_CMD"
  } >&2
  exit 2
fi

# diff to review. Normally the staged index. BUT if the commit is chained with
# `git add` or uses -a/--all, the index is still empty when this PreToolUse hook
# fires (before the command runs) → review the full working-tree diff (git diff
# HEAD), a superset that catches modified tracked files. (Residual gap: brand-new
# untracked files added via a chained `git add newfile && commit` are not in
# `git diff HEAD` — see testbench S7/TODO.)
DIFF=$(mktemp -t veto-gate-diff); MARKER=""
# The file lists come from GIT, never from the diff TEXT (codex). Two holes, one shape: a binary
# file has no "+++ b/" line at all, and a CONTENT line "++ b/package.json" arrives in the diff as
# "+++ b/package.json" — read as a filename it made the gate believe the test machinery had changed
# and switched the whole test stage off. A file's own text must not be able to disarm the checks
# that read it.
NAMES=$(mktemp -t veto-gate-names); DELNAMES=$(mktemp -t veto-gate-delnames)
PRIORF=""   # set from round 2 on (codex memory) — in the trap before it exists
# PROOF_FILE too: the ledger writes one file per run into the log dir, and without this it
# would pile them up there forever. (proof.sh is sourced above, so the variable exists —
# empty until proof_init, and the trap expands it at exit, not now.)
trap 'rm -f "$DIFF" "$NAMES" "$DELNAMES"; [ -n "$MARKER" ] && rm -f "$MARKER"; [ -n "$PROOF_FILE" ] && rm -f "$PROOF_FILE"; [ -n "$PRIORF" ] && rm -f "$PRIORF"; [ -n "${INTENTF:-}" ] && rm -f "$INTENTF"' EXIT
ADD_CHAIN=0; COMMIT_ALL=0
printf '%s' "$BLANK" | grep -qE '(^|[;&|`])[[:space:]]*git[[:space:]]+(-C[[:space:]]+'"$TOK"'[[:space:]]+)?add' && ADD_CHAIN=1
# -a/--all may sit ANYWHERE in the commit invocation's flag list, not only
# right after 'commit' (isolated-auditor finding: 'git commit -m x -a' had
# an empty index at PreToolUse time and the --cached review saw nothing).
# Token scan over the blanked span up to the next separator/newline: values
# of -m/-F/-C/-c/-t are skipped ('-m -a' is a message, not commit-all),
# '--' ends option parsing (a path named -a is not a flag), and long
# options like --amend/--author never count (codex rounds on this fix).
# scan ONE commit invocation's flag span for -a/--all. Escapes are
# neutralized BEFORE cutting at separators ('\;' is a literal for the shell,
# '\'+newline continues the command, 'x\ -a' is one message word); a failing
# perl falls back to the raw span so the basic '-m x -a' case still counts.
# Short flags char by char: 'a' anywhere = commit-all, but a value-taking
# letter (m/F/C/c/t) consumes the rest as attached value; standalone value
# options skip their next word; '--' ends option parsing (codex rounds).
scan_commit_all(){
  local span="$1" cooked skip=0 w rest ch
  if [ -z "${VETO_GATE_NO_PERL:-}" ] \
     && cooked=$(printf '%s' "$span" | perl -0777 -pe 's/\\\n/ /g; s/\\./__/g' 2>/dev/null) \
     && [ -n "$cooked" ]; then
    span="$cooked"
  fi
  span=${span%%[;&|]*}
  span=${span%%$'\n'*}
  set -f
  for w in $span; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$w" in
      --) break;;
      -m|--message|-F|--file|-C|--reuse-message|-c|--reedit-message|-t|--template) skip=1;;
      --all) set +f; return 0;;
      --*) ;;
      -[a-zA-Z]*)
        rest=${w#-}
        while [ -n "$rest" ]; do
          ch=$(printf '%.1s' "$rest"); rest=${rest#?}
          case "$ch" in
            a) set +f; return 0;;
            m|F|C|c|t) [ -z "$rest" ] && skip=1; rest="";;
          esac
        done;;
    esac
  done
  set +f
  return 1
}
# EVERY structural commit in the line gets its span scanned — a second
# 'git commit -a' later in the same chain must count too (codex round)
while IFS= read -r CLINE; do
  [ -z "$CLINE" ] && continue
  CO=${CLINE%%:*}; CM=${CLINE#*:}
  if scan_commit_all "${BLANK:$(( CO + ${#CM} ))}"; then COMMIT_ALL=1; break; fi
done < <(printf '%s' "$BLANK" | grep -boE "$COMMIT_RE")
# Both size numbers must be SOUND before anything is computed from them. Without this
# an empty CHANGED became `${CHANGED:-0}` → the size stage recorded "0 Code-Zeilen" and
# passed a diff nobody measured (UL-006: a check that could not run is never an
# all-clear). diff-size.sh can now fail in a new way — it sources the shared lockfile
# list — so the gate blocks here exactly as pre-commit.sh already does.
# Called as a statement, never inside $( ): an exit in a command substitution would
# only end the subshell and let the run continue with the same bad number.
size_numbers_sound(){
  case "${CHANGED:-}" in ''|*[!0-9]*)
    {
      echo "⛔ VETO-GATE: Größenprüfung selbst fehlgeschlagen (kein brauchbarer Zählwert) — Commit geblockt."
      echo "$OV_HINT"
    } >&2
    exit 2;;
  esac
  # the lockfile share only ever SUBTRACTS, so an unusable value falls strict: 0
  case "${LOCKL:-}" in ''|*[!0-9]*) LOCKL=0;; esac
  [ "$LOCKL" -gt "$CHANGED" ] && LOCKL="$CHANGED"
  return 0; }

if [ "$ADD_CHAIN" = 1 ] || [ "$COMMIT_ALL" = 1 ]; then
  # index is empty/incomplete at PreToolUse time → review working-tree vs HEAD.
  # What does the chain really add? (codex round 3 / F6): extract the add
  # paths quote-aware and NARROW the review diff to them — a foreign change
  # elsewhere in the tree must neither size- nor cap- nor grounding-block a
  # small path add. add -A/--all/. and commit -a really take the whole tree;
  # unparseable add args fall back to the old conservative superset.
  # Residual (documented): paths added from a subdir cwd or via globs don't
  # match and drop out of the narrowed scope — the pre-commit hook (B6)
  # measures the real index exactly.
  APATHS=""; SCOPE=all
  # UNTRACKED scope comes ONLY from what the add really names — commit -a
  # never takes untracked files, so COMMIT_ALL must not widen it (auditor-2
  # finding: 'git add path && git commit -am x' pulled a foreign untracked
  # file into size count and bundle). TRACKED scope: -a/-A take the whole
  # tree; named add paths narrow it; unparseable adds fall back to full.
  USCOPE=none; TPATHS=""; TRACKED_ALL=0; SIZEMODE=wide
  if [ "$ADD_CHAIN" = 1 ]; then
    APATHS=$(printf '%s' "$CMD" | bash "$LIB/add-paths.sh" 2>/dev/null)
    if [ -n "$APATHS" ]; then
      case "$APATHS" in
        *::ALL::*) USCOPE=all; APATHS="";;
        *::VAR::*)
          # an expanding variable in any add makes the chain undecidable —
          # full fallback (grounding superset; F6 size rule). SAFELY named
          # paths survive for the SIZE measurement; a bare -u in the chain
          # REALLY stages all tracked mods, so those size-count too, while
          # -u pathspecs only bound tracked counting and NEVER make new
          # files count (codex finds).
          USCOPE=fallback; TRACKED_ALL=0; SIZEMODE=narrow
          printf '%s\n' "$APATHS" | grep -qx '::TRACKED::' && TRACKED_ALL=1
          TPATHS=$(printf '%s\n' "$APATHS" | sed -n 's/^::TRACKED::\(..*\)/\1/p')
          APATHS=$(printf '%s\n' "$APATHS" | grep -vE '^::(VAR|TRACKEDVAR|TRACKED)');;
        *::TRACKEDVAR::*)
          # -u with a variable: no untracked files; the REVIEW stays wide
          # (the variable may stage any tracked file), only the size count
          # is narrow (codex finds)
          SIZEMODE=narrow
          TPATHS=$(printf '%s\n' "$APATHS" | sed -n 's/^::TRACKED::\(..*\)/\1/p')
          APATHS=$(printf '%s\n' "$APATHS" | grep -vE '^::TRACKED')
          if [ -n "$APATHS" ]; then USCOPE=paths; else USCOPE=none; fi;;
        *)
          # 'git add -u [pathspec]' stages tracked changes only: its paths
          # scope the TRACKED diff (the commit takes those changes) but
          # never contribute untracked files; a bare -u means all tracked
          # (codex finds on the auditor-2 fix)
          TPATHS=$(printf '%s\n' "$APATHS" | sed -n 's/^::TRACKED:://p')
          printf '%s\n' "$APATHS" | grep -qx '::TRACKED::' && TRACKED_ALL=1
          APATHS=$(printf '%s\n' "$APATHS" | grep -v '^::TRACKED::')
          if [ -n "$APATHS" ]; then USCOPE=paths; else USCOPE=none; fi;;
      esac
    else
      USCOPE=fallback
    fi
  fi
  SCOPE=all
  # narrow-size modes keep the REVIEW wide (a variable add may stage
  # anything) — SCOPE=paths only when every add is fully decidable (codex)
  if [ "$COMMIT_ALL" = 0 ] && [ "$TRACKED_ALL" = 0 ] && [ "$SIZEMODE" = wide ] \
     && { [ "$USCOPE" = paths ] || [ -n "$TPATHS" ]; } \
     && [ "$USCOPE" != all ] && [ "$USCOPE" != fallback ]; then
    SCOPE=paths
  fi
  set --
  if [ "$SCOPE" = paths ] || { [ "$SIZEMODE" = narrow ] && [ -n "$APATHS$TPATHS" ]; }; then
    # tracked diff scope = named add paths PLUS -u pathspecs; in the
    # narrow-size modes the safe paths only feed the size measurement
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      p=${p%/}
      [ -z "$p" ] && continue
      set -- "$@" "$p"
    done <<EOF_AP
$APATHS
$TPATHS
EOF_AP
  fi
  if [ "$SCOPE" = paths ]; then
    git -C "$CWD" diff HEAD --unified=3 -- "$@" > "$DIFF" 2>/dev/null || true
    git -C "$CWD" diff HEAD --name-only -- "$@" > "$NAMES" 2>/dev/null || true
    git -C "$CWD" diff HEAD --name-status -M -- "$@" 2>/dev/null \
      | awk -F'\t' '$1 ~ /^[DR]/ { print $2 }' > "$DELNAMES" || true
  else
    git -C "$CWD" diff HEAD --unified=3 > "$DIFF" 2>/dev/null || true
    git -C "$CWD" diff HEAD --name-only > "$NAMES" 2>/dev/null || true
    git -C "$CWD" diff HEAD --name-status -M 2>/dev/null \
      | awk -F'\t' '$1 ~ /^[DR]/ { print $2 }' > "$DELNAMES" || true
  fi
  # untracked matching uses ONLY the plain add paths, never -u pathspecs
  under_apaths(){
    local f="$1" p
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      p=${p%/}   # 'git add src/' names the dir — trailing slash would
                 # break the child match "$p"/* (codex round)
      [ -z "$p" ] && continue
      [ "$f" = "$p" ] && return 0
      case "$f" in "$p"/*) return 0;; esac
    done <<EOF_UP
$APATHS
EOF_UP
    return 1
  }
  if [ "$USCOPE" = fallback ] || [ "$SIZEMODE" = narrow ]; then
    # F6 size rule (CONVENTIONS): the superset diff feeds the review stages,
    # but the size gate must not count foreign tracked changes that are not
    # provably part of this commit — measure from the index PLUS the safely
    # named add paths (a big named change beside a \$VAR add still counts;
    # rare double-staging of a named path may count twice — errs strict).
    # Safely named untracked files still add up below (codex finds).
    SDIFF=$(mktemp -t veto-gate-sizediff)
    if [ "$TRACKED_ALL" = 1 ] || [ "$COMMIT_ALL" = 1 ]; then
      # a bare -u or commit -a stages the WORKTREE state of every tracked
      # file — 'git diff HEAD' measures exactly that (staged new files
      # included), with no overlap to double-count (codex round)
      git -C "$CWD" diff HEAD --unified=3 > "$SDIFF" 2>/dev/null || true
    elif [ $# -gt 0 ]; then
      # named paths measure their worktree state; already-staged FOREIGN
      # changes still ride along — count them via --cached EXCLUDING the
      # named paths so nothing counts twice (codex round). The exclude
      # pathspecs are appended after the originals, then the originals
      # are shifted off (bash 3.2: no arrays).
      git -C "$CWD" diff HEAD --unified=3 -- "$@" > "$SDIFF" 2>/dev/null || true
      N=$#
      for p in "$@"; do set -- "$@" ":(exclude)$p"; done
      shift "$N"
      git -C "$CWD" diff --cached --unified=3 -- . "$@" >> "$SDIFF" 2>/dev/null
    else
      git -C "$CWD" diff --cached --unified=3 > "$SDIFF" 2>/dev/null || true
    fi
    CHANGED=$(bash "$LIB/diff-size.sh" --diff "$SDIFF")
    # the lockfile share of the SAME diff — measuring it on a different one would let a
    # narrow count be reduced by a wide file list and hand-wave real code past the gate
    LOCKL=$(bash "$LIB/diff-size.sh" --diff "$SDIFF" --lockfile-lines)
    rm -f "$SDIFF"
  else
    CHANGED=$(bash "$LIB/diff-size.sh" --diff "$DIFF")
    LOCKL=$(bash "$LIB/diff-size.sh" --diff "$DIFF" --lockfile-lines)
  fi
  # BEFORE the untracked loop below adds to either number — arithmetic on an empty
  # CHANGED would quietly turn it into "just the new files" and hide the failure
  size_numbers_sound
  # a `git add` can also stage NEW untracked files → append the ADDED ones as
  # synthetic additions so grounding sees hallucinated imports in new files
  # too — and only the added ones, so foreign untracked files can't inflate
  # the bundle over the cap or the size count (codex round 3).
  if [ "$ADD_CHAIN" = 1 ]; then
    while IFS= read -r uf; do
      [ -z "$uf" ] && continue
      ADDED=0; COUNT=1
      case "$USCOPE" in
        all) ADDED=1;;
        paths)
          under_apaths "$uf" && ADDED=1;;
        fallback)
          # unparseable add args: CONVENTIONS demand the conservative
          # SUPERSET for grounding (codex find) — but only files SAFELY
          # named in a parsed add count against the size gate (F6: a
          # foreign untracked file must not false-block; parsed paths
          # cover quoted names, and no substring lookalikes — codex).
          ADDED=1
          under_apaths "$uf" || COUNT=0;;
      esac
      [ "$ADDED" = 1 ] || continue
      # emit a VALID new-file hunk, not a bare `+++ b/…` with loose `+` lines: without the
      # `diff --git` / `--- /dev/null` / `@@` frame codex reads the entry as malformed and may
      # not review the new file as a real change (codex). The header lines start with d/-/@,
      # never `+`, so the size gate and grounding (which skip these) are unaffected.
      # awk NR, not `grep -c ''`: on an EMPTY file grep prints 0 AND exits 1, so `|| echo 0`
      # appended a SECOND 0 and broke the hunk header (codex). awk prints exactly one count.
      UNL=$(awk 'END{print NR+0}' "$CWD/$uf" 2>/dev/null); [ -n "$UNL" ] || UNL=0
      {
        printf 'diff --git a/%s b/%s\n' "$uf" "$uf"
        printf 'new file mode 100644\n'
        printf -- '--- /dev/null\n'
        printf '+++ b/%s\n' "$uf"
        printf '@@ -0,0 +1,%s @@\n' "$UNL"
        sed 's/^/+/' "$CWD/$uf" 2>/dev/null
      } >> "$DIFF"
      printf '%s\n' "$uf" >> "$NAMES"
      case "$uf" in
        *.md|*.txt|*.log) ;;
        *) if [ "$COUNT" = 1 ]; then
             CHANGED=$(( CHANGED + UNL ))
             # a brand-new lockfile is machine output too — it must land in BOTH
             # numbers, or the size gate would subtract a share it never added
             veto_is_generated "$uf" && LOCKL=$(( LOCKL + UNL ))
           fi;;
      esac
    done < <(git -C "$CWD" ls-files --others --exclude-standard 2>/dev/null)
  fi
else
  git -C "$CWD" diff --cached --unified=3 > "$DIFF" 2>/dev/null || exit 0
  git -C "$CWD" diff --cached --name-only > "$NAMES" 2>/dev/null || true
  git -C "$CWD" diff --cached --name-status -M 2>/dev/null \
    | awk -F'\t' '$1 ~ /^[DR]/ { print $2 }' > "$DELNAMES" || true
  CHANGED=$(bash "$LIB/diff-size.sh" --diff "$DIFF")
  LOCKL=$(bash "$LIB/diff-size.sh" --diff "$DIFF" --lockfile-lines)
  size_numbers_sound
fi
[ -s "$DIFF" ] || exit 0     # nothing to review

# live-watch logging context
START=$(date +%s)
REPO=$(basename "$CWD")
hb_once veto-gate ran "$REPO"   # the gate is alive and armed for this repo
BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
FILES=$(grep -c '^+++ b/' "$DIFF" 2>/dev/null || echo 0)

# A single-use note for the residual channel (pre-commit.sh): what THIS run has
# under review, named by CONTENT. Since the review stage moved in there, every
# normal commit would otherwise be reviewed twice — once here, once there:
# double wait, double codex quota. A time window would be too coarse a proof; it
# would also wave through a second, unreviewed commit that merely arrives fast.
#
# Blob ids rather than the diff text, because the two channels cannot produce
# the same text: this hook fires BEFORE the command, so it reads `git diff HEAD`
# (a superset — the index is still empty), while pre-commit reads --cached. The
# blob of a file is the same in both. And a worktree change is not in the object
# store yet, so `--raw` prints zeros for it (measured) — hash-object yields the
# id the index will carry.
#
# Only reached in an ARMED repo with a non-empty diff, i.e. exactly when this
# gate really does review. A note in a repo the gate never inspected would
# disarm the channel that exists to back it up.
if GITDIR=$(git -C "$CWD" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$GITDIR" ]; then
  {
    while IFS= read -r nf; do
      [ -n "$nf" ] || continue
      # A quoted path (spaces, non-ASCII) does not round-trip through this
      # plain-text note; it is simply left out, and the missing line makes
      # pre-commit review that commit itself. Erring toward a second review.
      [ -f "$CWD/$nf" ] || continue
      NB=$(git -C "$CWD" hash-object --path "$nf" "$CWD/$nf" 2>/dev/null) || continue
      printf '%s %s\n' "$NB" "$nf"
    done < "$NAMES"
  } > "$GITDIR/veto-gate-reviewed" 2>/dev/null || rm -f "$GITDIR/veto-gate-reviewed" 2>/dev/null
fi

# Stufe 2 — correction-sequence identity: a blocked attempt and its retries form ONE
# sequence, keyed by repo+branch+HEAD. HEAD only moves when a commit passes, so the
# key survives every blocked round and renews itself on success. kreisel.sh owns the
# state; the gate only needs the id + round number here (and the prior findings later).
BASE=$(git -C "$CWD" rev-parse --short=12 HEAD 2>/dev/null) || BASE=""
KSTATE=$(bash "$LIB/kreisel.sh" state --repo "$REPO" --branch "$BRANCH" --base "$BASE" \
  --names "$NAMES" --diff "$DIFF" 2>/dev/null)
KSEQ=$(printf '%s' "$KSTATE" | jq -r '.seq // ""' 2>/dev/null)
KROUND=$(printf '%s' "$KSTATE" | jq -r '.round // ""' 2>/dev/null)
case "$KROUND" in ''|*[!0-9]*) KROUND="";; esac
# a failed state read is a GAP, not a genuine round 1 — the ledger gets an explicit
# 'unavailable' id and no round number, so statistics cannot mistake it (codex)
if [ -z "$KSEQ" ]; then KSEQ="unavailable"; KROUND=""; fi
# E3.5: mirror the gate lifecycle into the per-repo status bar (render.sh
# gate.* segment). Display only — never a blocker, every failure is silent.
# gate.plan keeps the label honest: only plan-mode runs show as VETO3-Plan.
BAR="$HOME/.claude/statusline/status-set.sh"
bar_set(){ [ -x "$BAR" ] && "$BAR" "$CWD" gate.stage="$1" gate.name="${2:--}" \
  gate.found="${3:-0}" gate.plan="$([ -n "${PLAN_FLAG:-}" ] && echo true || echo false)" \
  gate.ts="$(date +%s)" >/dev/null 2>&1 || true; }

# Push to Discord what the gate just told Claude (owner 2026-07-13), with enough
# context to be read on a phone: the commit Claude attempted + the files it
# touched. Reported: real findings, invented code, and "nobody reviewed this"
# (quota/timeout). Size/cap blocks stay silent — bookkeeping, not a finding.
# Display only: never blocks, every failure is swallowed.
# resolved via $LIB, never a hardcoded personal path: a worktree checkout would
# otherwise notify through the MAIN checkout's (possibly older) script
DNOTIFY="$LIB/discord-codex-findings.sh"
CMSG=$(printf '%s' "$CMD" | sed -n 's/.*-m[[:space:]]*["'"'"']\([^"'"'"']*\).*/\1/p' | head -1)
notify_discord(){ # $1 = kind, $2 = reviewer, $3 = stdin payload, $4 = detail
  [ -x "$DNOTIFY" ] || return 0
  # NB: `paste -sd', '` would alternate the two chars as separators — join by hand.
  _f=$(sed -n 's|^+++ b/||p' "$DIFF" 2>/dev/null | head -6 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  printf '%s' "${3:-}" | bash "$DNOTIFY" --kind "$1" --reviewer "$2" \
    --repo "$REPO" --branch "$BRANCH" --commit-msg "$CMSG" --files "$_f" \
    --detail "${4:-}" >/dev/null 2>&1 || true
}

# How much reading a review really was. pack-diff copies every touched file WHOLE,
# so the work grows with FILE size, not with diff size — without this number in the
# ledger, "the diff was small, why did it time out" has no answer (testbau-repo 2026-07-28).
#
# The rule is one sentence: count a bundle when it is HANDED OVER, not when it is
# built. So btok_add sits at the two reviewer calls and nowhere else — a run that
# ends before them (cap, quota, refused request) then needs no special case at all.
# '?' means "handed over, size unreadable"; log-run.sh drops any non-number, so an
# incomplete sum can never masquerade as the full reading work.
# Digits only before any arithmetic: measured, `$(( 0 + 1.5 ))` does not just fail,
# it KILLS the shell — the gate would die before writing its log entry.
BTOK=""
btok_add(){
  local t; t=$(jq -r '.tokens // empty' "$1/SIZE.json" 2>/dev/null) || t=""
  case "$t" in ''|*[!0-9]*) BTOK="?"; return 0;; esac
  [ "$BTOK" = "?" ] || BTOK=$(( ${BTOK:-0} + t )); }

log_run(){
  # peek --result/--blocking for the status bar without consuming "$@"
  _res=""; _blk="0"; _prev=""
  for _w in "$@"; do
    [ "$_prev" = "--result" ] && _res="$_w"
    [ "$_prev" = "--blocking" ] && _blk="$_w"
    _prev="$_w"
  done
  case "$_res" in
    codex-pass) bar_set pass "$_res" 0;;
    *-block)    bar_set block "$_res" "$_blk";;
  esac
  bash "$LIB/log-run.sh" --repo "$REPO" --branch "$BRANCH" --files "$FILES" \
    --changed "${CHANGED:-0}" --names "$NAMES" --seq "${KSEQ:-}" --seq-round "${KROUND:-}" \
    --bundle-tokens "${BTOK:-}" \
    --dur "$(( $(date +%s) - START ))" "$@" 2>/dev/null || true; }

# The closed loop (UL-006): a run sized 'light' that a reviewer blocks anyway was
# mis-sized and must leave evidence. Only real reviewer findings are passed here — a
# timeout, an empty quota or an oversized diff say nothing about the right depth.
# log-mismatch.sh itself decides what counts, so this may be called unconditionally.
log_mismatch(){ bash "$LIB/log-mismatch.sh" --repo "$REPO" --branch "$BRANCH" \
  --profile "${TRIAGE_PROFILE:-normal}" --effort "${TRIAGE_EFFORT:-}" \
  --changed "${CHANGED:-0}" --result "$1" --blocking "${2:-0}" 2>/dev/null || true; }

# Stufe 2: one reviewer block = one recorded correction round. kreisel.sh owns storage,
# thresholds and the spiral verdict; the gate just reports what happened this round.
kreisel_record(){ # $1 = result, $2 = verdict JSON → stdout: record JSON ({kreisel:…})
  printf '%s' "${2:-}" | bash "$LIB/kreisel.sh" record --repo "$REPO" --branch "$BRANCH" \
    --base "$BASE" --changed "${CHANGED:-0}" --result "$1" --diff "$DIFF" --names "$NAMES" 2>/dev/null \
    || printf '{"kreisel":"unavailable"}'; }
kreisel_read(){ # reads $KJ → KFIRE/KFROM/KTO for the block text and the ledger flag.
  # A check that could not run is 'unavailable', never false — the ledger must not
  # record an all-clear nobody computed (UL-006).
  # NB: jq's // treats FALSE as empty (the triage effort_auto lesson) — ask has()
  KFIRE=$(printf '%s' "$KJ" | jq -r 'if has("kreisel") then (.kreisel|tostring) else "unavailable" end' 2>/dev/null)
  case "$KFIRE" in true|false) ;; *) KFIRE=unavailable;; esac
  KFROM=$(printf '%s' "$KJ" | jq -r '.from // 0' 2>/dev/null)
  KTO=$(printf '%s' "$KJ" | jq -r '.to // 0' 2>/dev/null)
  # the warning names the round the RECORD just assigned — authoritative at block time
  KRND=$(printf '%s' "$KJ" | jq -r '.round // "?"' 2>/dev/null); }
# The churn feedback (spec Teil B, Reagieren 2): tell the FIXER he is spiraling —
# name the principle instead of piling on more mechanics. Text only, never a block
# reason of its own and never a reduction of review depth.
kreisel_warn(){
  [ "${KFIRE:-false}" = true ] || return 0
  echo "🌀 KREISEL erkannt: Runde $KRND dieser Korrektur-Folge — der Diff wuchs von $KFROM auf $KTO Code-Zeilen, und neue Funde treffen Zeilen, die deine letzte Korrektur erst hinzugefügt hat."
  echo "   Du baust vermutlich immer mehr Mechanik. Nenn das PRINZIP statt neuer Rezepte — mach den Fix KLEINER, nicht größer."; }

# live marker: lets `veto-gate serve` show which repo/stage the gate works on NOW
RUNDIR="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}/running"; mkdir -p "$RUNDIR" 2>/dev/null || true
MARKER="$RUNDIR/gate-$$.json"
mark(){ jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg repo "$REPO" \
  --arg br "$BRANCH" --argjson files "${FILES:-0}" --arg stage "$1" \
  '{ts:$ts,repo:$repo,branch:$br,files:$files,stage:$stage}' > "$MARKER" 2>/dev/null || true
  bar_set running "$1"; }
mark size
proof_init     # from here on every stage leaves a note — a check that vanishes is an alarm

# Stage 1.5 — B4: hard size gate. Huge diffs overwhelm every reviewer (human,
# qwen, codex); doc lines don't count (see diff-size.sh). One topic = one
# commit; the single-use override stays the sanctioned escape.
# Lockfile lines are left out of the COMPARISON for the same reason doc lines are: the
# package manager wrote them and nobody reviews them by hand. They stay in CHANGED (the
# doc-only skip in pre-commit.sh depends on that) and are subtracted only here. Without
# this, every dependency commit blocked — and "split it up" cannot be followed when
# manifest and lockfile are one statement, so it sent the author to the override and
# the security upgrade got NO review at all. The bundle cap still bounds the real work.
CODEL=$(( ${CHANGED:-0} - LOCKL ))
[ "$CODEL" -lt 0 ] && CODEL=0
SIZENOTE="${CODEL} Code-Zeilen"
[ "$LOCKL" -gt 0 ] && SIZENOTE="$SIZENOTE (+$LOCKL Lockfile-Zeilen, nicht gezählt)"
if [ "$CODEL" -gt "$CFG_MAXLINES" ]; then
  proof_add size fail "$SIZENOTE > $CFG_MAXLINES"
  {
    echo "⛔ VETO-GATE: Diff zu groß ($SIZENOTE > $CFG_MAXLINES) — bitte aufteilen: ein Thema = ein Commit."
    echo "$OV_HINT"
  } >&2
  log_run --result size-block --blocking 1 --proofs "$(proof_json)"
  exit 2
fi
proof_add size pass "$SIZENOTE"

# Stage 1.6 — effort triage: the depth of the review follows the FACTS of the diff
# (which paths it touches, how many code lines), computed deterministically and for
# free. Floor, never ceiling — see triage.sh. It runs HERE, before every reviewer, so
# the whole run knows how it was sized (the prechecker block site needs it too).
TRIAGE=$(bash "$LIB/triage.sh" --names "$NAMES" --changed "${CHANGED:-0}" --cfg "$CFG" 2>/dev/null)
TRIAGE_EFFORT=$(printf '%s' "$TRIAGE" | jq -r '.effort // empty' 2>/dev/null)
TRIAGE_PROFILE=$(printf '%s' "$TRIAGE" | jq -r '.profile // empty' 2>/dev/null)
TRIAGE_REASON=$(printf '%s' "$TRIAGE" | jq -r '.reason // empty' 2>/dev/null)
# A broken triage must never make the review WEAKER than the config says: fall back to
# the configured effort and say so, rather than silently guessing a depth.
case "$TRIAGE_EFFORT" in low|medium|high) ;; *) TRIAGE_EFFORT="$EFFORT"; TRIAGE_PROFILE=normal
  TRIAGE_REASON="Triage ohne Antwort — Config-Wert gilt";; esac
case "$TRIAGE_PROFILE" in light|normal) ;; *) TRIAGE_PROFILE=normal;; esac
EFFORT="$TRIAGE_EFFORT"
proof_add triage pass "$EFFORT ($TRIAGE_PROFILE) — $TRIAGE_REASON"

mark grounding

# Stage 2 — deterministic grounding (0 token, fail-closed)
GROUND=$(bash "$LIB/grounding-check-diff.sh" --diff "$DIFF" --repo "$CWD" 2>/dev/null); GRC=$?
# 65 = the checker refused to run (a required tool is missing). Not "no findings":
# it never looked. Block, and say why — reporting it as a clean grounding pass
# would be the exact silent all-clear this exit code exists to prevent.
if [ "$GRC" = 65 ]; then
  proof_add grounding fail "Prüfer konnte nicht laufen (perl fehlt)"
  {
    echo "⛔ VETO-GATE: die Grounding-Prüfung konnte nicht laufen — perl fehlt auf diesem System."
    echo "  perl ist Pflicht, nicht optional: ohne es bleibt die Prüfung auf erfundene"
    echo "  Methoden-Aufrufe stumm. Selbsttest: veto-gate doctor"
    echo "$OV_HINT"
  } >&2
  log_run --result grounding-infra-block --blocking 0 --proofs "$(proof_json)"
  exit 2
fi
if [ "$GRC" != 0 ]; then
  N=$(printf '%s' "$GROUND" | jq -r '.count // "?"' 2>/dev/null)
  proof_add grounding fail "$N erfundene(r) Import(e)/Aufruf(e)"
  {
    echo "⛔ VETO-GATE: $N halluzinierte(r) Import(e)/Pfad(e) im Diff — Commit geblockt."
    printf '%s' "$GROUND" | jq -r '.violations[]? | "  \(.file): \(.import)\(if .symbol then " → Symbol \(.symbol) fehlt" else "" end)"' 2>/dev/null
    echo "Fix die Pfade, dann erneut. $OV_HINT"
  } >&2
  log_run --result grounding-block --blocking "${N:-0}" \
    --violations "$(printf '%s' "$GROUND" | jq -c '.violations // []' 2>/dev/null)" \
    --proofs "$(proof_json)"
  notify_discord grounding "$CFG_PRE" "$GROUND"
  exit 2
fi
proof_add grounding pass "keine erfundenen Importe"

# Stage 2.2 — Sorte C: RUN the tests. The only proof that the code does the RIGHT thing; reading it
# proves nothing. Costs 0 tokens, costs time — so only the tests the change actually touches.
#
# The gate hands over ITS OWN file list, not the index: for `git add x && git commit` the add has
# not run yet, and for `git commit -a` git stages afterwards — in both cases the index holds the OLD
# content, and testing it would prove nothing about this commit (codex). --overlay says: take those
# files' WORKING-TREE content, because that is what will be written.
#
# Doc-only diffs are NOT skipped here: an .md can be product content or test data, and run-tests.sh
# asks the module graph rather than the file extension. It decides; the gate does not pre-judge.
mark tests
TFILES=$(sort -u "$NAMES" 2>/dev/null | grep -v '^$')
TDEL=$(sort -u "$DELNAMES" 2>/dev/null | grep -v '^$')
TOV=""
[ "$ADD_CHAIN" = 1 ] || [ "$COMMIT_ALL" = 1 ] && TOV="--overlay"
TRES=$(bash "$LIB/run-tests.sh" --repo "$CWD" --scope commit \
       --files "$TFILES" --deleted "$TDEL" $TOV 2>/dev/null)
TST=$(printf '%s' "$TRES" | jq -r '.status // ""' 2>/dev/null)
TDET=$(printf '%s' "$TRES" | jq -r '.detail // "?"' 2>/dev/null)
TDUR=$(printf '%s' "$TRES" | jq -r '.dur // 0' 2>/dev/null)
[ -n "$TST" ] || { TST=unavailable; TDET="run-tests.sh lieferte keine Antwort — nichts bewiesen"; }
proof_add tests "$TST" "$TDET (${TDUR}s)"
if [ "$TST" = "fail" ]; then
  {
    echo "⛔ VETO-GATE: Tests rot — Commit geblockt."
    echo "  $TDET"
    echo "Erst grün machen, dann committen. $OV_HINT"
  } >&2
  log_run --result tests-block --blocking 1 --proofs "$(proof_json)"
  notify_discord findings tests \
    "$(jq -cn --arg d "$TDET" '{blocking:[{id:"TEST",claim:"Die Tests sind rot",why:$d,fix:"Erst die Tests grün machen, dann committen."}]}')"
  exit 2
fi

# B5: a docs-only diff in a plan_review repo runs in PLAN mode — the design
# gets reviewed (F5 feature), code sketches don't false-block (F18 lesson).
# The opt-in switches the MODE, never the review itself on or off.
PLAN_FLAG=""
if [ "$CFG_PLAN" = "true" ]; then
  # EVERY changed file (both diff sides — a deletion is only named on its
  # '--- a/' line) must be a .md UNDER the plan path (config plan_path,
  # default docs/superpowers/plans/). Codex live findings: deletions slipped
  # in/out of plan mode; not every .md is a plan (CONVENTIONS.md deserves
  # the normal review); and one small plan file must never downgrade the
  # review of binding docs riding in the same diff.
  # plan_path is a directory PREFIX, never a pattern (codex live finding:
  # 'docs/plans' must not match 'docs/plans-private.md', and regex chars in
  # the config value must not bend the match) → force one trailing slash,
  # escape regex metacharacters
  PP="${CFG_PLANPATH%/}/"
  PPE=$(printf '%s' "$PP" | sed -E 's/[][\.^$*+?(){}|\\]/\\&/g')
  NONPLAN=$(grep -E '^(\+\+\+ b|--- a)/' "$DIFF" | grep -cvE "^(\+\+\+ b|--- a)/$PPE.*\.md$")
  PLANN=$(grep -cE "^(\+\+\+ b|--- a)/$PPE.*\.md$" "$DIFF")
  [ "${NONPLAN:-1}" -eq 0 ] && [ "${PLANN:-0}" -gt 0 ] && PLAN_FLAG="--plan"
fi

# Stage 2.4 — the spiral STOPS instead of spinning.
#
# Measured twice on 2026-07-28/29: seven review rounds on one markdown parser
# (71 min, 41% of that session) and nineteen on one shell parser. Both times the
# gate DETECTED the spiral and only printed a sentence, then reviewed again. The
# cost is not the detection, it is the next review — so the stop has to happen
# HERE, before any reviewer is called, not after the verdict comes back.
#
# The deterministic checks above (size, grounding, tests) have already run: they
# are cheap and might name the real problem. What stops is the expensive part.
#
# This is not less review depth. Nothing is waved through — the commit is
# BLOCKED, harder than before, and only a deliberate override moves it. What
# changes is that the third round costs seconds instead of minutes, and the
# message asks the one question that ends spirals: is the FORM wrong?
# Threshold 4, not 3: measured on 864 runs / 151 sequences, 62% of real correction
# sequences end within 2 rounds, so three honest rounds stay untouched and only the
# tail is stopped. The asymmetry decides it — a false stop costs one deliberate
# override, a missed spiral cost 71 minutes in one measured session. 0 switches it off.
KSTOP="${VETO_GATE_KREISEL_STOP:-$(jq -r '.kreisel_stop // 4' "$CFG" 2>/dev/null)}"
case "$KSTOP" in ''|*[!0-9]*) KSTOP=4;; esac

# The round number alone is not evidence of a spiral. Measured 2026-08-12 on two
# sequences: one where round 4 SHRANK from 162 to 154 lines (the author had done
# exactly what the round-3 message demanded — "make the fix smaller") and one
# where round 4 was the rewrite the reviewer itself had asked for, 3 files to 6
# plus a schema change. Both were stopped unseen. A counter cannot tell a fourth
# patch from a new approach; these three questions can, and the numbers for them
# were already in the sequence store, unused.
KPREV=$(printf '%s' "$KSTATE" | jq -r '.prev_changed // -1' 2>/dev/null)
KSHARED=$(printf '%s' "$KSTATE" | jq -r '.shared_files // 0' 2>/dev/null)
KPREVF=$(printf '%s' "$KSTATE" | jq -r '.prev_files // 0' 2>/dev/null)
KCARRY=$(printf '%s' "$KSTATE" | jq -r '.carry_pct // -1' 2>/dev/null)
case "$KPREV"   in ''|*[!0-9-]*) KPREV=-1;; esac   # -1 = no previous round stored
case "$KSHARED" in ''|*[!0-9]*)  KSHARED=0;; esac
case "$KPREVF"  in ''|*[!0-9]*)  KPREVF=0;; esac
case "$KCARRY"  in ''|*[!0-9-]*) KCARRY=-1;; esac  # -1 = not measurable
NOWF=$(grep -c . "$NAMES" 2>/dev/null || echo 0)
case "$NOWF" in ''|*[!0-9]*) NOWF=0;; esac

KWHY=""            # non-empty = this is not a spiral, and why
if [ "${CHANGED:-0}" -eq 0 ]; then
  # Nothing for a reviewer to spiral on, and splitting work into a docs-first
  # commit is the very move the stop wants to encourage. "0 code lines" is the
  # honest wording: docs are the common case, but a pure deletion or a lockfile
  # counts the same, and size_numbers_sound() has already aborted on an
  # unmeasurable diff — a 0 here is counted, not missing.
  KWHY="keine Code-Zeilen (Doku, Löschung oder Sperrdatei)"
elif [ "$KPREV" -ge 0 ] && [ "${CHANGED:-0}" -lt "$KPREV" ]; then
  # strictly smaller, never equal (codex R07): re-submitting the SAME change
  # unchanged would otherwise buy a fresh review every time — rewarding the one
  # move the brake exists to stop. Equal size that is genuinely a rewrite still
  # gets through, via the file check below.
  KWHY="kleiner geworden ($KPREV → ${CHANGED:-0} Code-Zeilen)"
elif [ "$KPREVF" -gt 0 ] && [ "$NOWF" -gt 0 ] && [ "$KSHARED" -ge 0 ] \
     && [ $(( (NOWF - KSHARED) * 2 )) -gt "$NOWF" ]; then
  # KSHARED of -1 means "not measurable" and must never reach the arithmetic:
  # it would make (NOWF+1)*2 > NOWF true for every attempt and free-pass the lot.
  # Majority of THIS attempt's files are new. Measured against the current list,
  # not the previous one (codex R07): ten files last round and one of them now
  # is the same patch narrowed down, yet it cleared a previous-list threshold
  # easily. A rewrite reaches for other files; a patch keeps poking the same one.
  # The old reset needed ZERO files in common, which never happens when you
  # rebuild the same function — so it never fired for its own use case.
  KWHY="Bauform gewechselt ($((NOWF - KSHARED)) von $NOWF Dateien neu)"
elif [ "$KCARRY" -ge 0 ] && [ "$KCARRY" -lt 50 ]; then
  # Same file, same size, different content — a rewrite that names and counts
  # cannot see (codex BRK-02). Under half the added lines were already added
  # last round, so this is not the previous attempt with another patch on top.
  KWHY="Inhalt neu geschrieben (nur $KCARRY% der Zeilen wie zuvor)"
fi

# Second switch, and deliberately not the existing one: the message used to offer
# "or have it reviewed anyway" and then named the override — which exits the hook
# entirely, so nobody reviews anything. This one lifts the brake and leaves every
# reviewer in place. Single use, consumed here.
KOVERRIDE="$CWD/.claude/session-flags/${SID}-kreisel-override"
if [ -f "$KOVERRIDE" ]; then
  rm -f "$KOVERRIDE"
  KWHY="Bremse bewusst gelöst — Prüfung läuft weiter"
fi

if [ -n "$KROUND" ] && [ "$KSTOP" -gt 0 ] && [ "$KROUND" -ge "$KSTOP" ] && [ -z "$KWHY" ]; then
  proof_add kreisel fail "Runde $KROUND derselben Korrektur-Folge — vor dem Prüfer gestoppt"
  {
    echo "⛔ VETO-GATE: Runde $KROUND an DEMSELBEN Stand — hier wird nicht weiter geprüft."
    echo "   Du hast $((KROUND - 1)) Mal nachgebessert, und der Umfang wächst weiter"
    echo "   (${KPREV} → ${CHANGED:-0} Code-Zeilen, $KSHARED von $KPREVF Dateien dieselben)."
    echo "   Wer dreimal dasselbe Muster repariert, hat meist die falsche BAUFORM gewählt."
    echo "   Frage dich EINE Sache: Deute ich hier Freitext, wo eine Datenform gehörte?"
    echo "   Der Weg raus ist KLEINER oder ANDERS — beides lässt die Bremse von selbst los:"
    echo "     kleiner als $CHANGED Code-Zeilen, oder mehrheitlich andere Dateien."
    echo "   Trotzdem prüfen lassen (SEPARATER Befehl VOR dem Commit):"
    echo "     touch \"$KOVERRIDE\""
    echo "   Ganz ohne Prüfung durchlassen: $OV_CMD"
  } >&2
  # Record the stop as a round. Without this the counter stood still: every later
  # attempt was round 4 again, so no amount of rework could earn a review back —
  # only waiting out the two-hour window or bypassing the gate could.
  kreisel_record kreisel-stop '{}' >/dev/null 2>&1 || true
  log_run --result kreisel-stop --blocking 1 --seq "${KSEQ:-}" --seq-round "$KROUND" \
          --proofs "$(proof_json)"
  exit 2
fi
if [ -n "$KROUND" ] && [ "$KSTOP" -gt 0 ] && [ "$KROUND" -ge "$KSTOP" ] && [ -n "$KWHY" ]; then
  proof_add kreisel pass "Runde $KROUND, aber kein Kreisel: $KWHY"
  echo "ⓘ VETO-GATE: Runde $KROUND, Bremse greift nicht — $KWHY. Es wird normal geprüft." >&2
fi

# Stage 2.5 — B2: local pre-reviewer (MiniMax-M3 via hermes). Free filter BEFORE
# codex: findings block immediately (no codex quota burned); any infra
# problem (down, timeout, oversized, bad JSON) falls open to codex — the
# gate never gets weaker than before. A local pass is not a verdict.
# Plan-mode diffs skip the local stage: the small model lacks the F18
# context and would false-block sketches — codex with the plan prompt is
# the right reviewer there.
if [ "$CFG_PRE" != "none" ] && [ -z "$PLAN_FLAG" ]; then
  mark "$CFG_PRE"
  QRC=0
  case "$CFG_PRE" in
    minimax) QV=$(bash "$LIB/minimax-diff-review.sh" --diff "$DIFF" 2>/dev/null) || QRC=$?;;
    *)    QV=$(bash "$LIB/remote-diff-review.sh" --provider "$CFG_PRE" --diff "$DIFF" 2>/dev/null) || QRC=$?;;
  esac
  if [ "$QRC" = 0 ]; then
    QBLK=$(printf '%s' "$QV" | jq '.blocking | length' 2>/dev/null || echo 0)
    if [ "${QBLK:-0}" -gt 0 ]; then
      proof_add prechecker fail "$QBLK Fund(e) ($CFG_PRE)"
      KJ=$(kreisel_record "${CFG_PRE}-block" "$QV")
      kreisel_read
      {
        echo "⛔ VETO-GATE: Vorprüfer ($CFG_PRE) fand $QBLK blockierende(s) Problem(e) — Commit geblockt (Codex-Kontingent gespart)."
        printf '%s' "$QV" | jq -r '.blocking[] | "  [\(.id)] \(.claim)\n     warum: \(.why)\n     fix: \(.fix)"' 2>/dev/null
        kreisel_warn
        echo "Fix, dann erneut. $OV_HINT"
      } >&2
      log_run --result "${CFG_PRE}-block" --blocking "$QBLK" --kreisel "$KFIRE" \
        --verdict "$(printf '%s' "$QV" | jq -c . 2>/dev/null)" \
        --proofs "$(proof_json)"
      log_mismatch "${CFG_PRE}-block" "$QBLK"
      notify_discord findings "$CFG_PRE" "$QV"
      exit 2
    fi
    proof_add prechecker pass "keine Funde ($CFG_PRE)"
  else
    # QRC!=0 (down/timeout/too big/no key/bad JSON) → fail open to codex. That is right —
    # a dead pre-reviewer must not block a commit. But it must not be INVISIBLE either:
    # until today this stage could be down for weeks and nothing said so.
    proof_add prechecker unavailable "Vorprüfer ($CFG_PRE) nicht erreichbar oder ohne Antwort"
  fi
elif [ -n "$PLAN_FLAG" ]; then
  proof_add prechecker skipped "Plan-Prüfmodus — der kleine Prüfer würde Skizzen fälschlich blocken"
else
  proof_add prechecker skipped "Vorprüfer aus (prechecker: none)"
fi

# Dashboard docs toggle: config .docs (default true). Off → skip the docs stage.
DOCS_FLAG=""
[ "$(jq -r 'if has("docs") then .docs else true end' "$CFG" 2>/dev/null)" = false ] && DOCS_FLAG="--docs off"

# Stufe 2: from round 2 of a correction sequence, hand codex the previous rounds'
# findings — his memory. KSTATE was read BEFORE this run, so it holds exactly the
# prior rounds; pack-diff decides whether it fits (best-effort, like the docs).
if [ -n "${KROUND:-}" ] && [ "${KROUND:-1}" -ge 2 ]; then
  PRIORF=$(mktemp -t veto-gate-prior)
  printf '%s' "$KSTATE" | jq -c '{runde:.round, vorrunden:.prior}' > "$PRIORF" 2>/dev/null || : > "$PRIORF"
fi

# The ORDER this change was built for, so codex can judge the diff against it instead
# of guessing the goal backwards. It comes from the SAME parser the claim stage uses —
# segment-aware and quote-aware, reading every -m/--message/-F/-C part of the ACTUAL
# `git commit` segment. A second, looser scan of the whole command line would take a -m
# from an unrelated `echo -m …` and miss --message, -F and every message beyond the first
# (codex find). So the parser moved up here; the claim VERDICT still happens further down.
# Without an order the bundle SAYS so — a check nobody could run must be visible (UL-006).
# Exactly ONE commit in the line may hand over an order — decided by the simplest
# unambiguous signal, not by parsing shell: how often the WORD `commit` occurs in the
# quote-blanked line. No pattern can enumerate every shape that hides a second commit
# (`git commit;`, `(git commit)`, `env -u FOO git commit`, …), but every commit
# invocation must literally say `commit`. Two or more → no order at all. Anything the
# count cannot read as exactly one fails toward "no order", never toward a wrong one.
# The rules travel with every review. A rules file that describes a stage the gate
# does not have is BROKEN, not merely wrong — it would teach the reviewer a system
# that is not there. So it is checked first and dropped loudly if it fails.
RULESF="$(dirname "$0")/../rules/gate-rules.json"
if [ -f "$RULESF" ]; then
  bash "$(dirname "$0")/rules-check.sh" --quiet || RULESF=""
else
  RULESF=""
fi

INTENTF=$(mktemp -t veto-gate-intent 2>/dev/null) || INTENTF=""
if [ "$(printf '%s' "$BLANK" | grep -oE '(^|[^A-Za-z-])commit([^A-Za-z-]|$)' | wc -l | tr -d ' ')" != 1 ]; then
  [ -n "$INTENTF" ] && rm -f "$INTENTF"; INTENTF=""
fi
# …and NOTHING is sent from a command carrying an unexpanded substitution anywhere:
# `git commit -m außen "$(git commit -m innen)"` runs the inner commit FIRST, and no
# count over the written text can see it (codex find). The gate cannot expand the shell,
# so it does not try — the whole class is excluded instead of chased case by case.
case "$CMD" in *'$('*|*'${'*|*'`'*) [ -n "$INTENTF" ] && rm -f "$INTENTF"; INTENTF="";; esac
# The same move, generalised: an order ships only from a command that is NOTHING BUT git
# invocations. `bash -c`, `eval`, `xargs`, a grouping bracket — each can run a commit no
# count over this text will ever see, and enumerating them is endless. A whitelist ends
# the enumeration: a shape that is not plainly a git chain is simply not eligible.
GITONLY=1
while IFS= read -r SEG; do
  SEG=${SEG#"${SEG%%[! ]*}"}                      # trim leading blanks
  [ -z "$SEG" ] && continue
  case "${SEG%% *}" in git) ;; *) GITONLY=0; break;; esac
  # …and only the two subcommands this shape is about. A git ALIAS is an arbitrary word
  # that can run anything, including another commit before the visible one (codex find).
  REST=${SEG#* }; REST=${REST#"${REST%%[! ]*}"}
  # -C <dir> is the one global option the gate itself models (COMMIT_RE knows it), so a
  # `git -C <dir> commit` keeps its order instead of losing it to the whitelist
  case "${REST%% *}" in -C) REST=${REST#* }; REST=${REST#"${REST%%[! ]*}"}
                            REST=${REST#* }; REST=${REST#"${REST%%[! ]*}"};; esac
  case "${REST%% *}" in add|commit) ;; *) GITONLY=0; break;; esac
done <<GITCHAIN
$(printf '%s' "$BLANK" | tr ';&|' '\n\n\n')
GITCHAIN
[ "$GITONLY" = 1 ] || { [ -n "$INTENTF" ] && rm -f "$INTENTF"; INTENTF=""; }
# Anything UNQUOTED that the shell still rewrites before git sees it — a tilde, a glob,
# `[a]`, `{A,B}`, `<(…)`, an escape — would make the text read here differ from the message
# git actually commits. Listing those forms is the same endless game as listing hidden
# commits, so this is a positive character set instead: letters, digits, and the handful
# of punctuation marks that appear in paths, options and separators. Quoted text is blanked
# to spaces, so a normal message never reaches this check.
# The quote MARKS themselves stay in the blanked line (only their content became spaces),
# so they belong in the safe set.
SAFECHARS="A-Za-z0-9 ._/:@,+=&;|()\"'-"
if [ -n "$(printf '%s' "$BLANK" | LC_ALL=C tr -d "$SAFECHARS")" ]; then
  [ -n "$INTENTF" ] && rm -f "$INTENTF"; INTENTF=""
fi
# Detecting the claim is done in python, because a loose sed gets it wrong three ways codex
# found: it must read ONLY the `git commit` segment's options (not a `-m` from a `grep … &&`
# earlier in the line), it must be QUOTE-AWARE (an unquoted `-m Getestet` or `--message "…"`
# counts too), and it must judge each -m value on its OWN — a "nicht verifiziert" in one -m
# must not hide a "Tests grün" in another, and a negated span never counts as a claim.
IS_CLAIM=$(printf '%s' "$CMD" | VETO_GATE_CLAIM_CWD="$CWD" VETO_GATE_INTENT_OUT="$INTENTF" python3 -c '
import os, re, shlex, stat, subprocess, sys
cmd = sys.stdin.read().replace("\\\n", "")   # drop backslash line-continuations first (codex)
CWD = os.environ.get("VETO_GATE_CLAIM_CWD","")
# Split the shell line on separators OUTSIDE quotes — a hand-written state machine, because
# shlex does NOT treat ;/&&/| as separators, and they often glue to a word (`"feat";`), so a
# later -m from `echo -m "…"` would otherwise be read as the commit message (codex). An
# unquoted `#` at a word boundary starts a shell comment → the rest of the line is dropped.
# A `\`-escape is KEPT (both chars) so an escaped separator does not split AND shlex can still
# assemble `Tests\ grün` into one token (codex) — the escape is resolved by shlex, not here.
segs = []; cur = ""; i = 0; n = len(cmd); q = None
while i < n:
    c = cmd[i]
    if q is not None:
        cur += c
        if c == "\\" and q == chr(34) and i+1 < n: cur += cmd[i+1]; i += 2; continue
        if c == q: q = None
        i += 1; continue
    if c == "\\" and i+1 < n: cur += cmd[i:i+2]; i += 2; continue   # keep the escape for shlex
    if c in ("\x27", chr(34)): q = c; cur += c; i += 1; continue
    if c == "#" and (not cur or cur[-1].isspace()):
        while i < n and cmd[i] != "\n": i += 1
        continue
    if cmd[i:i+2] in ("&&", "||"): segs.append(cur); cur = ""; i += 2; continue
    if c in (";", "|", "&", "\n"): segs.append(cur); cur = ""; i += 1; continue
    cur += c; i += 1
segs.append(cur)
# msgs = everything the claim stage must scan (LOCAL only).
# inline = the subset that may become the review ORDER and thus LEAVE the machine:
# literal -m/--message values, tagged with the segment they came from. A -F file or a
# reused commit message is deliberately NOT in here (see the write-out below).
# filerd = segments whose message came (partly) from a file or from git history, so the
# order for that commit is not fully readable from the command. CURSI names the segment
# currently being parsed, so the helpers below can mark it.
msgs = []; inline = []; filerd = set(); commits = set(); CURSI = -1; NOARG = set("aeinopqsvz")
def read_msg_file(p):    # -F/--file: the message lives in a file — read what GIT would read
    filerd.add(CURSI)    # …and that text is never the shipped order (see the write-out)
    path = p if os.path.isabs(p) else os.path.join(CWD, p)
    # git FOLLOWS a symlinked message file, so we must too (codex) — O_NONBLOCK still stops a
    # FIFO from hanging and fstat still refuses a non-regular or oversized file. The content is
    # only scanned for a claim, never shipped, so following the link leaks nothing.
    try: fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError: return
    try:
        st = os.fstat(fd)
        if stat.S_ISREG(st.st_mode) and st.st_size < 1_000_000:
            with os.fdopen(fd, "r", errors="replace") as f: msgs.append(f.read()); return
    except OSError: pass
    try: os.close(fd)
    except OSError: pass
def read_reuse(ref):     # -C/-c/--reuse-message/--reedit-message: read the reused commit message
    filerd.add(CURSI)    # …and that text is never the shipped order (see the write-out)
    try:
        r = subprocess.run(["git","-C",CWD,"log","-1","--format=%B",ref],
                           capture_output=True, text=True, timeout=5)
        if r.returncode == 0: msgs.append(r.stdout)
    except Exception: pass
GARG = {"-C","-c","--git-dir","--work-tree","--namespace","--exec-path","--super-prefix"}
# exec wrappers and shell keywords that legitimately precede a real command
WRAP = {"env","command","sudo","doas","nice","nohup","time","stdbuf","nocorrect",
        "if","then","else","elif","while","until","do","!","builtin","exec"}
# NOTE (documented scope): this best-effort backstop does NOT chase every exotic shell shape —
# a wrapper option that takes a VALUE (`sudo -u bob git commit`) or a message file named
# relative to a `cd` that differs from the resolved repo (`cd src && git commit -F m`) may be
# missed. Baustein C (the gate runs the suite) is the real defense against an unbacked test
# claim; a missed exotic form still has its tests run there. Perfecting the parse would risk
# false-blocks and duplicate COMMIT_RE, which is the authoritative commit detector.
# A message hidden in a shell variable or command substitution (`-m "$MSG"`, `-m "$(cat x)"`)
# is DELIBERATELY not chased (documented override — codex asked to block on `$`). The gate is
# deterministic and cannot expand the shell, and blocking every `$`-message would false-block a
# huge class of legitimate scripted commits. This stage is a best-effort backstop for INLINE
# literal claims; Baustein C (the gate runs the suite) is the real defense, so an unresolvable
# value is skipped, never blocked.
for si, seg in enumerate(segs):
    CURSI = si
    try: toks = shlex.split(seg)
    except ValueError: continue
    # the command must ACTUALLY be git, not just contain the word (codex: `echo git commit …`
    # must not count). Skip leading VAR=val assignments, exec wrappers (`env`, `sudo`, …) and
    # their options (codex: `env git commit …` IS a real commit), then require basename == git.
    start = 0
    while start < len(toks):
        t = toks[start]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t) or os.path.basename(t) in WRAP or t.startswith("-"):
            start += 1; continue
        break
    if start >= len(toks) or os.path.basename(toks[start]) != "git": continue
    # the SUBCOMMAND must be commit, not just the word appearing later (codex: `git log commit`
    # must not count). Skip git global options; some take a separate value.
    k = start + 1
    while k < len(toks) and toks[k].startswith("-"):
        k += 2 if toks[k] in GARG else 1
    if k >= len(toks) or toks[k] != "commit": continue
    # second, independent commit count. shlex REMOVES quotes, so this one sees a spliced
    # `git com"mit"` that the word count in the blanked line cannot (codex find). Neither
    # detector is complete alone; the order ships only if BOTH say exactly one.
    commits.add(si)
    j = k + 1
    while j < len(toks):
        t = toks[j]
        if t == "--": break                       # after -- git takes pathspecs, not options
        if t in ("-m", "--message"):
            if j+1 < len(toks): msgs.append(toks[j+1]); inline.append((si, toks[j+1])); j += 2; continue
        elif t.startswith("--message="): msgs.append(t[len("--message="):]); inline.append((si, t[len("--message="):]))
        # Options that REQUIRE a value: their value is not a message and must not be read
        # as one. `git commit -t -mZiel` read a template name as an order, and
        # `--author "-m falsch"` would read an author as one (codex finds); the claim stage
        # shared both misreadings. -S/--gpg-sign is left out on purpose: its value is
        # optional, so skipping the next token would eat a real argument. A cluster like
        # -tm is already refused, because t is not in NOARG.
        elif t in ("-t", "--template", "--author", "--date", "--cleanup",
                   "--fixup", "--squash", "--trailer", "--pathspec-from-file"):
            j += 2; continue
        elif t in ("-F", "--file"):
            if j+1 < len(toks): read_msg_file(toks[j+1]); j += 2; continue
        elif t.startswith("--file="): read_msg_file(t[len("--file="):])
        elif t.startswith("-F") and len(t) > 2: read_msg_file(t[2:])
        # reused message (codex): the new commit inherits it, so it must still be backed
        elif t in ("-C", "--reuse-message", "-c", "--reedit-message"):
            if j+1 < len(toks): read_reuse(toks[j+1]); j += 2; continue
        elif t.startswith("--reuse-message="): read_reuse(t[len("--reuse-message="):])
        elif t.startswith("--reedit-message="): read_reuse(t[len("--reedit-message="):])
        elif (t.startswith("-C") or t.startswith("-c")) and len(t) > 2: read_reuse(t[2:])
        elif t.startswith("-") and not t.startswith("--"):   # short cluster: -m, -am, -ma, -mMSG
            body = t[1:]
            # A cluster carrying F/C/c/t takes its text from a file or from history:
            # `-aF auftrag.txt -m Zusatz` would leave only "Zusatz" posing as the whole
            # order (codex find). Mark the segment unreadable instead.
            if any(ch in body for ch in "FCct"): filerd.add(CURSI)
            kk = body.find("m")
            if kk != -1 and all(ch in NOARG for ch in body[:kk]):
                rest = body[kk+1:]
                if rest: msgs.append(rest); inline.append((si, rest))
                elif j+1 < len(toks): msgs.append(toks[j+1]); inline.append((si, toks[j+1])); j += 2; continue
        j += 1
LINK = r"(?:(?:sind|alle|are|all|now|jetzt|wieder|waren|were|still)[:\s]+)*"
NEG = re.compile(r"ungetestet|unverifiziert|nicht\s+getestet|nicht\s+verifiziert|untested|unverified|not\s+tested|not\s+verified|tests?\s+rot|tests?\s+fail|no\s+tests", re.I)
# green/gruen/grun/green, with optional linking words ("Tests sind grün"); "tests pass";
# and the bare verbs. Bounded to a small link set so an unrelated later "green" cannot match.
POS = re.compile(r"tests?[:\s]+" + LINK + r"gr(?:ü|ue|u|ee)n\b|tests?[:\s]+" + LINK + r"pass|\bverifiziert\b|\bgetestet\b|\bverified\b", re.I)
# The same message parts are the ORDER for the review bundle. Written to a file, not
# printed, so the claim flag stays this program'"'"'s only stdout contract.
#
# Three limits, because this text LEAVES the machine while the claim scan stays local:
#   1. Only literal -m/--message values. A -F file is read with git semantics — symlinks
#      followed, path resolved outside the repo — which is fine for a local regex scan and
#      NOT fine for a bundle shipped to an external service (codex find). Same for -C, whose
#      text comes from git history rather than from this command.
#   2. No unexpanded shell construct ($(…), ${…}, $VAR, backticks): the gate cannot expand
#      the shell, and shipping `$(cat msg.txt)` as "the order" would have codex judge the
#      diff against nonsense. Worse than no order, which the bundle states honestly.
# Every limit fails toward "no order" — never toward a wrong one.
out = os.environ.get("VETO_GATE_INTENT_OUT","")
if out:
    UNEXP = re.compile(r"[$`]")
    bad = {si for si, t in inline if UNEXP.search(t or "") or not t.strip()} | filerd
    # ALL or NOTHING: dropping only the unusable parts would present a fragment as the whole
    # order, and codex would judge the diff against half a goal (codex find).
    text = "\n\n".join(t.strip() for si, t in inline if t.strip()) \
           if inline and not bad and len(commits) == 1 else ""
    if text:
        try:
            with open(out, "w") as f: f.write(text + "\n")
        except OSError: pass
print("1" if any(POS.search(NEG.sub(" ", m)) for m in msgs) else "")   # strip negated spans, then look for a survivor
' 2>/dev/null); PYRC=$?
# CLAIM-3 (codex): if the parser could not run (python missing, crash), do NOT skip the check
# silently — a "Tests grün" would slip through. Fall back to a coarse scan of the whole command;
# it may over-match, but the claim stage errs toward asking for the receipt, never toward a lie.
if [ "$PYRC" -ne 0 ]; then
  case "$CMD" in
    *[Tt]ests*gr[uü]n*|*[Tt]ests*gruen*|*[Tt]ests*pass*|*[Vv]erifiziert*|*[Gg]etestet*|*[Vv]erified*) IS_CLAIM=1;;
    *) IS_CLAIM="";;
  esac
fi
# nothing extractable (e.g. a message hidden in a command substitution, which this parser
# deliberately does not chase) → no order rides along, and pack-diff names the gap
[ -n "$INTENTF" ] && [ -s "$INTENTF" ] || { [ -n "$INTENTF" ] && rm -f "$INTENTF"; INTENTF=""; }

# Stage 3 — codex diff review
# B4c: cap overflow now BLOCKS ("aufteilen") instead of waving unreviewed
# code through — the old fail-open contradicted the gate's whole point.
# pack-diff's stderr carries the only numbers that explain the block (actual vs. cap,
# and WHICH item burst it). Swallowing it left the author guessing whether the limit
# was 130k or 426k — so guessing whether splitting the commit could possibly help.
PDERR=$(mktemp -t veto-packerr 2>/dev/null) || PDERR=""
if ! BUNDLE=$(bash "$LIB/pack-diff.sh" --diff "$DIFF" --repo "$CWD" --cap "${VETO_GATE_CAP:-120000}" --tests "$TST: $TDET" ${PRIORF:+--prior "$PRIORF"} ${INTENTF:+--intent "$INTENTF"} ${RULESF:+--rules "$RULESF"} $PLAN_FLAG $DOCS_FLAG 2>"${PDERR:-/dev/null}"); then
  CAPDET=""
  [ -n "$PDERR" ] && CAPDET=$(grep -E '^(DIFF BUNDLE CAP EXCEEDED|TOP:)' "$PDERR" 2>/dev/null | head -4)
  # only the item that REALLY dominates earns the "one file" wording — two files at 49 %
  # each are a diff that genuinely wants splitting, and claiming otherwise would send the
  # author looking for a culprit that is not there.
  # Split on ' · ', not on whitespace: the path is the LAST field and may contain spaces.
  CAPTOP=$(printf '%s' "$CAPDET" | awk -F' · ' '/^TOP: /{split($1,a," "); if (a[2]+0 >= 50) print $3; exit}')
  rm -f "$PDERR" 2>/dev/null
  proof_add codex fail "Diff passt nicht ins Review-Bündel (Kappe ${VETO_GATE_CAP:-120000})${CAPTOP:+, größter Anteil: $CAPTOP}"
  {
    # Only say "split it up" when the CHANGES are what is big. If one file dominates,
    # that advice is not followable and would push the author to the override, i.e. to
    # no review — the exact outcome this gate exists to prevent.
    case "$CAPTOP" in
      ''|DIFF.patch) echo "⛔ VETO-GATE: Diff zu groß fürs Review-Bündel — bitte aufteilen: ein Thema = ein Commit.";;
      *) echo "⛔ VETO-GATE: Das Review-Bündel ist zu groß — den Ausschlag gibt EINE Datei: $CAPTOP."
         echo "   Aufteilen hilft nur, wenn genau diese Datei in einen eigenen Commit kann.";;
    esac
    [ -n "$CAPDET" ] && printf '%s\n' "$CAPDET"
    echo "$OV_HINT"
  } >&2
  log_run --result cap-block --blocking 1 --proofs "$(proof_json)"
  exit 2
fi
rm -f "$PDERR" 2>/dev/null

# D: did the REAL library docs make it into the bundle, or did codex have to guess? pack-diff
# wrote the outcome to DOCS.json. `unavailable` (lookup skipped / wrong version / no docs) is
# a visible gap, not a block — a missing Context7 lookup is not the code's fault, but the owner
# must learn codex judged an external API from an old training set.
DOCST=$(jq -r '.status // "unavailable"' "$BUNDLE/DOCS.json" 2>/dev/null)
DOCDT=$(jq -r '.detail // "?"' "$BUNDLE/DOCS.json" 2>/dev/null)
case "$DOCST" in pass|skipped|unavailable) ;; *) DOCST=unavailable; DOCDT="DOCS.json unlesbar";; esac
proof_add docs "$DOCST" "$DOCDT"

# B7: a known-closed codex window is not worth running into — block with the
# countdown instead of burning two timeouts (F20 supplies the reset time).
# Broken/garbage quota.json is ignored (never block on our own state file);
# an elapsed window is cleared so codex gets tried again normally.
QF="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}/quota.json"
if [ -f "$QF" ]; then
  QE=$(jq -r '.reset_epoch // 0' "$QF" 2>/dev/null)
  case "$QE" in ''|*[!0-9]*) QE=0;; esac
  NOW=$(date +%s)
  if [ "$QE" -gt "$NOW" ]; then
    QAT=$(jq -r '.reset_at // "?"' "$QF" 2>/dev/null)
    proof_add codex fail "Kontingent leer bis $QAT — niemand hat den Diff angeschaut"
    {
      echo "⛔ VETO-GATE: Codex-Fenster zu bis $QAT (noch $(( (QE - NOW + 59) / 60 )) min) — Commit geblockt statt anzurennen."
      echo "Weiterbauen + Commits batchen; oder bewusst überspringen (SEPARATER Befehl VOR dem Commit): $OV_CMD"
    } >&2
    log_run --result quota-block --proofs "$(proof_json)"
    notify_discord quota codex "" "wieder frei ab $QAT"
    exit 2
  fi
  rm -f "$QF" 2>/dev/null   # window elapsed or file garbage-without-epoch
fi

mark codex

btok_add "$BUNDLE"
# EFFORT was set by the triage stage above (stage 1.6), from the facts of the diff.
if ! VERDICT=$(VETO_GATE_TIMEOUT="${VETO_GATE_TIMEOUT:-$CFG_TIMEOUT}" VETO_GATE_TIMEOUT2="${VETO_GATE_TIMEOUT2:-$CFG_TIMEOUT2}" bash "$LIB/codex-diff-review.sh" --bundle "$BUNDLE" --effort "$EFFORT"); then
  proof_add codex fail "keine Antwort (${CFG_TIMEOUT}s + ${CFG_TIMEOUT2}s) — niemand hat den Diff angeschaut"
  {
    echo "⛔ VETO-GATE: codex konnte den Diff nicht prüfen (2 Versuche: ${CFG_TIMEOUT}s + ${CFG_TIMEOUT2}s) — Commit GEBLOCKT (nicht durchgewinkt)."
    echo "Optionen: kleiner committen · effort \"medium\" · bewusst überspringen (SEPARATER Befehl VOR dem Commit): $OV_CMD"
  } >&2
  log_run --result timeout-block --proofs "$(proof_json)"
  notify_discord timeout codex "" "${CFG_TIMEOUT}s + ${CFG_TIMEOUT2}s"
  exit 2     # fail-closed: unreviewed code does NOT pass
fi

TH=$(grep -o '"thread_id":"[^"]*"' "$BUNDLE/events.jsonl" 2>/dev/null | head -1 | cut -d'"' -f4)

BLOCKING=$(printf '%s' "$VERDICT" | jq '.blocking | length' 2>/dev/null || echo 0)

# A1: codex may ASK for the files he needs to judge (context_requests has been in his
# answer schema from day one). Until today the gate ignored the field completely — he
# said "I need db.ts to decide this", nobody listened, and he had to guess about exactly
# the code he could not see.
#
# Exactly ONE extra round (no endless ping-pong), and only when he found nothing yet —
# a block already stands on its own. What ships is the INTERFACE of the file, never its
# body (see pack-diff.sh). Every outcome leaves a note: a request that was refused must
# never read as "delivered", or codex judges blind while the run looks clean.
# one path per line, never comma-joined — a comma is legal in a filename and would tear a
# real path apart (codex find). pack-diff reads --add-files line by line.
REQ=$(printf '%s' "$VERDICT" | jq -r '.context_requests[]?.file' 2>/dev/null)
if [ "${BLOCKING:-0}" -eq 0 ] && [ -n "$REQ" ]; then
  mark codex
  if BUNDLE2=$(bash "$LIB/pack-diff.sh" --diff "$DIFF" --repo "$CWD" --cap "${VETO_GATE_CAP:-120000}" --tests "$TST: $TDET" --add-files "$REQ" ${PRIORF:+--prior "$PRIORF"} ${INTENTF:+--intent "$INTENTF"} ${RULESF:+--rules "$RULESF"} $PLAN_FLAG $DOCS_FLAG 2>/dev/null); then
    DELIV=$(jq -r '.delivered | join(", ")' "$BUNDLE2/ADDED.json" 2>/dev/null)
    REFUS=$(jq -r '.refused' "$BUNDLE2/ADDED.json" 2>/dev/null)
    [ "$REFUS" = null ] && REFUS=""
    if [ -z "$DELIV" ]; then
      proof_add codex_round2 unavailable "Nachforderung NICHT geliefert: ${REFUS:-unbekannt} — Codex urteilt ohne die Datei, die er brauchte"
    else
      btok_add "$BUNDLE2"
      if V2=$(VETO_GATE_TIMEOUT="${VETO_GATE_TIMEOUT:-$CFG_TIMEOUT}" VETO_GATE_TIMEOUT2="${VETO_GATE_TIMEOUT2:-$CFG_TIMEOUT2}" bash "$LIB/codex-diff-review.sh" --bundle "$BUNDLE2" --effort "$EFFORT"); then
        VERDICT="$V2"
        BLOCKING=$(printf '%s' "$VERDICT" | jq '.blocking | length' 2>/dev/null || echo 0)
        # the log must point at the run that actually produced the verdict, not at round 1
        TH=$(grep -o '"thread_id":"[^"]*"' "$BUNDLE2/events.jsonl" 2>/dev/null | head -1 | cut -d'"' -f4)
        if [ -n "$REFUS" ]; then
          proof_add codex_round2 unavailable "teilweise geliefert: $DELIV — abgelehnt: $REFUS"
        else
          proof_add codex_round2 pass "Nachforderung geliefert: $DELIV"
        fi
      else
        # NOT "unavailable". Round 1 said itself that it lacked the file — its "no findings"
        # was given under reservation. If round 2 then cannot answer, nobody has actually
        # judged this diff, and codex is the one stage that is fail-closed (codex find).
        proof_add codex_round2 fail "Nachrunde gescheitert, obwohl die Datei geliefert wurde — Runde 1 urteilte ausdrücklich ohne sie, also hat NIEMAND den Diff geprüft"
      fi
    fi
  else
    # Same class as a dead second round, so the same answer: BLOCK (codex find). Round 1
    # said itself it lacked a file; if we cannot even build the second bundle, that
    # provisional "nothing found" is all there is, and codex is the one fail-closed stage.
    # A gap note here would wave through a diff its own reviewer called incompletely judged.
    proof_add codex_round2 fail "Nachrunde konnte nicht gepackt werden — Runde 1 urteilte ausdrücklich ohne die angeforderte Datei, also hat NIEMAND den Diff vollständig geprüft"
  fi
fi

if [ "${BLOCKING:-0}" -gt 0 ]; then
  proof_add codex fail "$BLOCKING Fund(e) (effort=$EFFORT)"
  KJ=$(kreisel_record codex-block "$VERDICT")
  kreisel_read
  {
    echo "⛔ VETO-GATE: codex fand $BLOCKING blockierende(s) Problem(e) im Diff — Commit geblockt."
    printf '%s' "$VERDICT" | jq -r '.blocking[] | "  [\(.id)] \(.claim)\n     warum: \(.why)\n     fix: \(.fix)"' 2>/dev/null
    kreisel_warn
    echo "Fix, dann erneut. $OV_HINT"
  } >&2
  log_run --result codex-block --blocking "$BLOCKING" --thread "$TH" --kreisel "$KFIRE" \
    --verdict "$(printf '%s' "$VERDICT" | jq -c . 2>/dev/null)" \
    --proofs "$(proof_json)"
  log_mismatch codex-block "$BLOCKING"
  notify_discord findings codex "$VERDICT"
  exit 2
fi
proof_add codex pass "keine Funde (effort=$EFFORT)"

# ── E: a claim needs a receipt ──────────────────────────────────────────────
# If the commit message says the tests are green but the ledger has no green test run, the
# message is a lie — and a lie about the work is worse than a bug: it poisons every other
# claim in that message, and the owner has no way to tell which ones still hold. Baustein C
# (the gate runs the tests itself) makes this mostly moot; this is the backstop for when the
# tests were `unavailable` and the claim got written anyway.
#
if [ "$IS_CLAIM" = 1 ]; then
  if proof_json | jq -e 'any(.[]; .stage=="tests" and .status=="pass")' >/dev/null 2>&1; then
    proof_add claim pass "Behauptung durch Testlauf gedeckt"
  else
    proof_add claim fail "Behauptung ohne Beleg in der Commit-Nachricht"
    {
      echo "⛔ VETO-GATE: Die Commit-Nachricht behauptet, die Tests seien grün — es lief aber kein grüner Testlauf."
      echo "  Zettel: $(proof_json | jq -r '[.[] | select(.stage=="tests") | "\(.status): \(.detail)"] | join("; ")')"
      echo "Entweder Tests laufen lassen, oder die Behauptung aus der Nachricht nehmen."
      echo "$OV_HINT"
    } >&2
    log_run --result claim-block --blocking 1 --thread "$TH" --proofs "$(proof_json)"
    notify_discord findings claim \
      "$(jq -cn '{blocking:[{id:"CLAIM",claim:"Die Nachricht behauptet Tests grün ohne Testlauf",why:"Eine falsche Behauptung vergiftet jede andere Aussage im Commit.",fix:"Tests laufen lassen oder die Behauptung streichen."}]}')"
    exit 2
  fi
fi

# ── the ledger passes judgment ─────────────────────────────────────────────
# Decide FIRST, log ONCE. Writing `codex-pass` here and only then reading the ledger would
# leave a SUCCESS entry behind a run that ended in a block — the log would have lied about
# the very thing it exists to record, and every statistic drawn from it with it.
#
# A mandatory checker (`"required"` in .claude/config/veto-gate.json) that could not run blocks;
# everything else that could not run passes and is REPORTED. Blocking on any missing checker
# would make every bash repo uncommittable — they have no typechecker, and never will.
CFG_REQUIRED=$(jq -c '.required // []' "$CFG" 2>/dev/null) || CFG_REQUIRED='[]'
[ -n "$CFG_REQUIRED" ] || CFG_REQUIRED='[]'
proof_verdict "$CFG_REQUIRED"; PV=$?
PROOFS=$(proof_json)     # AFTER the verdict — it may have added a note of its own
[ -n "$PROOFS" ] || PROOFS="[]"

# Only three answers exist: 0 clean · 1 block · 2 gap. ANYTHING else means the ledger did
# not reach a verdict at all — the module is gone, renamed, or it crashed (127, 126, …).
# Falling through to `exit 0` there would let a broken guard read as "go ahead", which is
# the one thing this whole design exists to prevent (codex).
case "$PV" in
  0|1|2) ;;
  *)
    {
      echo "⛔ VETO-GATE: Die Beweis-Prüfung selbst ist gescheitert (unerwarteter Code $PV) — Commit gestoppt."
      echo "  Der Wächter konnte kein Urteil fällen. Ein kaputter Wächter heißt nicht 'geh weiter'."
      echo "$OV_HINT"
    } >&2
    log_run --result proof-error --blocking 1 --thread "$TH" --proofs "$PROOFS"
    notify_discord gap codex "" "Beweis-Prüfung gescheitert (Code $PV)"
    exit 2;;
esac

if [ "$PV" = 1 ]; then
  # The first draft handled only PV=2 and then fell through to `exit 0`: a `fail` that no
  # stage had already blocked on would have passed the commit — the ledger would have
  # recorded the error and the gate would have ignored its own verdict.
  FAILED=$(printf '%s' "$PROOFS" | jq -r --argjson r "$CFG_REQUIRED" \
    '[.[] | select(.status=="fail" or (.status=="unavailable" and (.stage as $s | $r | index($s))))
          | "\(.stage) [\(.status)]: \(.detail)"] | join("; ")' 2>/dev/null)
  [ -n "$FAILED" ] || FAILED="Beweis-Zettel unlesbar — $(proof_missing)"
  {
    echo "⛔ VETO-GATE: Beweis-Zettel blockt — Commit gestoppt."
    echo "  $FAILED"
    echo "  (Pflicht-Prüfer laut .claude/config/${CFG##*/} → \"required\": $CFG_REQUIRED)"
    echo "$OV_HINT"
  } >&2
  log_run --result proof-block --blocking 1 --thread "$TH" --proofs "$PROOFS"
  notify_discord gap codex "" "$FAILED"
  exit 2
fi

# only now, with nothing left to block on, is this run a success — and only now is it logged
log_run --result codex-pass --blocking 0 --thread "$TH" \
  --verdict "$(printf '%s' "$VERDICT" | jq -c . 2>/dev/null)" \
  --proofs "$PROOFS"

if [ "$PV" = 2 ]; then
  MISS=$(proof_missing)
  echo "⚠️ VETO-GATE: Commit durch, aber NICHT geprüft: $MISS" >&2
  notify_discord gap codex "" "$MISS"
fi
exit 0

#!/usr/bin/env bash
# kreisel.sh — correction-sequence store + spiral (Kreisel) verdict for the veto gate.
#
# One blocked commit attempt and its retries form ONE correction sequence, keyed by
# repo + branch + HEAD (BASE): HEAD only moves when a commit passes, so the key is
# stable across blocked rounds and renews itself on success. Stored per sequence:
# every reviewer-block round (findings, code-line count, git name list) plus the
# EXACT diff of the LAST round — the spiral test must know which lines the previous
# fix added.
#
# Detection is free (0 tokens) and NEVER blocks on its own — it only labels.
# Exit 0 always: a bookkeeper that crashes a commit would be worse than a lost entry
# (same contract as log-run.sh / log-mismatch.sh).
#
# Deliberately NO lock on the state files (documented decision, same shape as the
# mismatch ledger): writes are tmp+mv (atomic), and a loss needs TWO simultaneous
# gate runs of the SAME repo+branch+HEAD both sitting at a reviewer block — two
# parallel commit attempts of one working state. The damage would be one lost round
# in a warning statistic that never blocks; ~25 lines of lock mechanics (macOS has
# no flock(1)) in a bookkeeper would cost more than the loss it prevents.
set -uo pipefail
# stored diffs may hold secrets (plan-review B3): dir 700, files 600, always
umask 077

LOG_DIR="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}"
KDIR="$LOG_DIR/kreisel"
# thresholds measured on 864 runs / 151 sequences (2026-07-16), env = test seam:
# 62% of real sequences end within 2 rounds; observed round gaps median 4.6 min,
# p90 8.9, max 98 → 120 min covers every real loop, older = resumed work.
KN="${VETO_GATE_KREISEL_ROUNDS:-3}"
KW="${VETO_GATE_KREISEL_WINDOW:-7200}"
case "$KN" in ''|*[!0-9]*) KN=3;; esac
case "$KW" in ''|*[!0-9]*) KW=7200;; esac

CMD="${1:-}"; [ $# -gt 0 ] && shift
REPO=""; BRANCH=""; BASE=""; CHANGED=0; RESULT=""; DIFF=""; NAMES=""
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --branch) BRANCH="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --base) BASE="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --changed) CHANGED="${2:-0}"; shift 2 2>/dev/null || shift $#;;
  --result) RESULT="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --diff) DIFF="${2:-}"; shift 2 2>/dev/null || shift $#;;
  --names) NAMES="${2:-}"; shift 2 2>/dev/null || shift $#;;
  *) shift;;
esac; done
case "$CHANGED" in ''|*[!0-9]*) CHANGED=0;; esac

# key → filename via hash: a branch name may contain '/' or '..' and must never
# steer where the state file lands
SEQ=$(printf '%s|%s|%s' "$REPO" "$BRANCH" "$BASE" | shasum 2>/dev/null | cut -c1-16)
[ -n "$SEQ" ] || { printf '{"seq":"","round":1,"rounds":0,"prior":[],"kreisel":false}\n'; exit 0; }
SF="$KDIR/$SEQ.json"; DF="$KDIR/$SEQ.diff"
NOW=$(date +%s)

# housekeeping: a sequence dies with its HEAD — after any passed commit its files
# are dead weight. 7 days is generous for any resumed work.
[ -d "$KDIR" ] && find "$KDIR" -type f -mtime +7 -delete 2>/dev/null

# current state, with two liveness rules applied:
#   time window — if the LAST round is older than KW, the sequence has expired
#     (an attempt hours later is resumed work, not a loop);
#   relatedness (plan-review rounds 1/3/7) — a change that shares NO touched file
#     with the stored previous round is NEW work on the same HEAD (abandoned
#     attempt, fresh attempt): treating it as round N would feed foreign findings
#     into the review and could report a false spiral. The names come from GIT
#     (the gate's $NAMES list, one path per line — deletions and renames included),
#     never parsed out of diff text: only the git spelling survives spaces and
#     escapes. No stored names / no --names given → related (keep the sequence).
read_state(){
  jq -e 'type=="object" and (.rounds|type=="array")' "$SF" >/dev/null 2>&1 \
    || { printf '{"rounds":[]}'; return; }
  local last a b
  last=$(jq -r '.rounds[-1].epoch // 0' "$SF" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  if [ $(( NOW - last )) -gt "$KW" ]; then printf '{"rounds":[]}'; return; fi
  if [ -n "$NAMES" ] && [ -f "$NAMES" ]; then
    a=$(jq -r '.rounds[-1].names[]? // empty' "$SF" 2>/dev/null | grep -v '^$' | sort -u)
    b=$(sort -u "$NAMES" 2>/dev/null | grep -v '^$')
    if [ -n "$a" ] && [ -n "$b" ] \
       && [ -z "$(comm -12 <(printf '%s\n' "$a") <(printf '%s\n' "$b") 2>/dev/null | head -1)" ]; then
      printf '{"rounds":[]}'; return
    fi
  fi
  cat "$SF" 2>/dev/null
}

case "$CMD" in
state)
  ST=$(read_state)
  N=$(printf '%s' "$ST" | jq '.rounds|length' 2>/dev/null); case "$N" in ''|*[!0-9]*) N=0;; esac
  # round = total ever + 1, not kept-rounds + 1: the store caps at 12 kept rounds,
  # and the counter must keep counting past the cap (codex B3)
  TOT=$(printf '%s' "$ST" | jq '.total // (.rounds|length)' 2>/dev/null)
  case "$TOT" in ''|*[!0-9]*) TOT="$N";; esac
  # How much of THIS attempt is the previous one again. The caller's stop used to
  # know only the round number, so a rewrite and a fourth patch looked identical
  # to it — while the answer was sitting here unused (2026-08-12).
  #   prev_changed — code lines of the last stored round, -1 when there is none
  #   shared_files — files this attempt has in common with it
  #   prev_files   — how many the last round touched
  PREVCH=$(printf '%s' "$ST" | jq '.rounds[-1].changed // -1' 2>/dev/null)
  case "$PREVCH" in ''|*[!0-9]*) PREVCH=-1;; esac
  # -1 throughout means NOT MEASURABLE, never 0. A 0 here reads as "no file in
  # common" — exactly the shape of a rewrite — so a missing or unreadable name
  # list would hand the caller a free pass past the round-4 question (codex B1).
  SHARED=-1; PREVF=0
  PA=$(printf '%s' "$ST" | jq -r '.rounds[-1].names[]? // empty' 2>/dev/null | grep -v '^$' | sort -u)
  if [ -n "$PA" ]; then
    PREVF=$(printf '%s\n' "$PA" | grep -c .)
    if [ -n "$NAMES" ] && [ -f "$NAMES" ]; then
      PB=$(sort -u "$NAMES" 2>/dev/null | grep -v '^$')
      [ -n "$PB" ] && SHARED=$(comm -12 <(printf '%s\n' "$PA") <(printf '%s\n' "$PB") 2>/dev/null | grep -c .)
    fi
  fi
  case "$SHARED" in ''|*[!0-9-]*) SHARED=-1;; esac
  case "$PREVF" in ''|*[!0-9]*) PREVF=0;; esac
  # carry — how much of what this attempt ADDS was already added last round, in
  # percent. File names and line counts cannot see a rewrite that stays in one
  # file at the same size; the stored diff can. -1 = not measurable.
  CARRY=-1
  # Only against a round this sequence still owns. read_state() drops the rounds
  # when the window expired or the work is unrelated, but the diff snapshot stays
  # on disk — measuring against it would compare this attempt with a stranger
  # (codex B2).
  if [ "$N" -gt 0 ] && [ -n "$DIFF" ] && [ -f "$DIFF" ] && [ -f "$DF" ]; then
    nrm(){ grep '^+' "$1" 2>/dev/null | grep -vE '^\+\+\+ (b/|/dev/null)' \
           | sed -e 's/^+//' -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'; }
    CARRY=$({ nrm "$DF" | sed 's/^/P /'; nrm "$DIFF" | sed 's/^/C /'; } | awk '
      /^P /{p[substr($0,3)]=1; next}
      # lines under 5 chars ("fi", "}") are structure, not content — counting them
      # would make every rewrite look like a repeat
      /^C /{l=substr($0,3); if(length(l)<5) next; n++; if(l in p) s++}
      END{ if(n>0) printf "%d", (s*100)/n; else printf "-1" }' 2>/dev/null)
    case "$CARRY" in ''|*[!0-9-]*) CARRY=-1;; esac
  fi
  printf '%s' "$ST" | jq -c --arg seq "$SEQ" --argjson n "$N" --argjson t "$TOT" \
    --argjson pc "$PREVCH" --argjson sh "$SHARED" --argjson pf "$PREVF" --argjson cy "$CARRY" \
    '{seq:$seq, round:($t+1), rounds:$n, prev_changed:$pc, shared_files:$sh, prev_files:$pf,
      carry_pct:$cy, prior:[.rounds[] | {round, result, changed, findings}]}' 2>/dev/null \
    || printf '{"seq":"%s","round":1,"rounds":0,"prev_changed":-1,"shared_files":0,"prev_files":0,"carry_pct":-1,"prior":[]}\n' "$SEQ"
  ;;
record)
  VERDICT=""; [ -t 0 ] || VERDICT=$(cat 2>/dev/null)
  ST=$(read_state)
  # the true round number is the TOTAL ever recorded, not the (capped) kept rounds —
  # otherwise the counter would jam at cap+1 and hand out duplicates (codex B3)
  TOT=$(printf '%s' "$ST" | jq '.total // (.rounds|length)' 2>/dev/null)
  case "$TOT" in ''|*[!0-9]*) TOT=$(printf '%s' "$ST" | jq '.rounds|length' 2>/dev/null);; esac
  case "$TOT" in ''|*[!0-9]*) TOT=0;; esac
  ROUND=$(( TOT + 1 ))
  # ---- spiral verdict for THIS round, decided BEFORE the round is stored ----
  # All three must hold (spec Teil B, thresholds measured — see header):
  #   1. enough rounds in this sequence
  #   2. the diff grew STRICTLY round over round (codex B2: a flat step is not
  #      growth) — a converging fix removes or rewrites; a spiral adds machinery
  #   3. a current finding QUOTES a line the previous round's fix added — matched
  #      by CONTENT, whitespace-normalized, because line numbers shift every round
  FIRE=false; FROM=0
  if [ "$ROUND" -ge "$KN" ]; then
    G=$(printf '%s' "$ST" | jq --argjson c "$CHANGED" \
      '([.rounds[].changed] + [$c]) as $a
       | reduce range(1; $a|length) as $i (true; . and ($a[$i] > $a[$i-1]))' 2>/dev/null)
    FROM=$(printf '%s' "$ST" | jq '.rounds[0].changed // 0' 2>/dev/null)
    case "$FROM" in ''|*[!0-9]*) FROM=0;; esac
    if [ "$G" = true ] && [ -f "$DF" ] && [ -f "$DIFF" ]; then
      # normalize: drop the leading '+', squeeze whitespace — quotes and diff lines
      # must meet on CONTENT, not on formatting
      norm(){ sed -e 's/^+//' -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//'; }
      # fresh = added now but not added in the previous round's diff. A quote hits if
      # it equals a fresh line or one contains the other. Lines under 5 chars ('fi',
      # '}') are structural noise, not an anchor — they would match everywhere.
      # ONE tagged stream, not three files: awk's per-file counter silently skips an
      # EMPTY file and every later stream would be misclassified (codex B4 — a
      # deletion-only previous round has no added lines at all).
      # header filter matches the header SHAPE ('+++ b/…', '+++ /dev/null'), never a
      # bare '^+++': an added code line starting with '++' arrives as '+++…' in the
      # diff and is content (codex round 3 — same lesson as the gate's name lists)
      HIT=$({ grep '^+' "$DF" 2>/dev/null | grep -vE '^\+\+\+ (b/|/dev/null)' | norm | sed 's/^/P /'
              grep '^+' "$DIFF" 2>/dev/null | grep -vE '^\+\+\+ (b/|/dev/null)' | norm | sed 's/^/C /'
              printf '%s' "$VERDICT" | jq -r '.blocking[]?.quote // empty' 2>/dev/null | norm | sed 's/^/Q /'
            } | awk '
        /^P /{prev[substr($0,3)]=1;next}
        /^C /{l=substr($0,3); if(!(l in prev) && length(l)>=5) neu[l]=1; next}
        /^Q /{q=substr($0,3); if(length(q)<5) next
              if(q in neu){print "HIT"; exit}
              for(l in neu) if(index(l,q) || index(q,l)){print "HIT"; exit}}' 2>/dev/null)
      [ "$HIT" = "HIT" ] && FIRE=true
    fi
  fi
  # store the round — bounded (10 findings, 300/400-char fields, last 12 rounds),
  # written atomically (tmp+mv); storage failure never changes the output
  mkdir -p "$KDIR" 2>/dev/null || true
  if [ -d "$KDIR" ]; then
    FIND=$(printf '%s' "$VERDICT" | jq -c \
      '[.blocking[]? | {id:(.id//""|tostring|.[0:40]), claim:(.claim//""|tostring|.[0:300]),
        fix:(.fix//""|tostring|.[0:300]), quote:(.quote//""|tostring|.[0:400])}] | .[0:10]' 2>/dev/null)
    [ -n "$FIND" ] || FIND='[]'
    # the round keeps its git-produced name list — the relatedness check above
    # compares against exactly this on the NEXT round
    NJ='[]'
    if [ -n "$NAMES" ] && [ -f "$NAMES" ]; then
      NJ=$(sort -u "$NAMES" 2>/dev/null | grep -v '^$' | jq -R . | jq -sc . 2>/dev/null)
      printf '%s' "$NJ" | jq -e 'type=="array"' >/dev/null 2>&1 || NJ='[]'
    fi
    printf '%s' "$ST" | jq -c --arg repo "$REPO" --arg br "$BRANCH" --arg base "$BASE" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ep "$NOW" --argjson round "$ROUND" \
      --arg res "$RESULT" --argjson ch "$CHANGED" --argjson f "$FIND" --argjson nm "$NJ" \
      '{repo:$repo, branch:$br, base:$base, total:$round,
        rounds:((.rounds + [{round:$round, ts:$ts, epoch:$ep, result:$res, changed:$ch, names:$nm, findings:$f}]) | .[-12:])}' \
      > "$SF.tmp.$$" 2>/dev/null && chmod 600 "$SF.tmp.$$" 2>/dev/null \
      && mv "$SF.tmp.$$" "$SF" 2>/dev/null || rm -f "$SF.tmp.$$" 2>/dev/null
    # perms on the TEMP copy, BEFORE mv publishes it (plan-review round 2): umask 077
    # already keeps it private, the explicit chmod holds even for a pre-existing tmp.
    # If no fresh copy can be made, the OLD snapshot must go too (codex B3): keeping
    # it would make the next spiral check compare against a foreign, older round.
    if [ -f "$DIFF" ] && cp "$DIFF" "$DF.tmp.$$" 2>/dev/null \
       && chmod 600 "$DF.tmp.$$" 2>/dev/null && mv "$DF.tmp.$$" "$DF" 2>/dev/null; then
      :
    else
      rm -f "$DF.tmp.$$" "$DF" 2>/dev/null
    fi
    chmod 700 "$KDIR" 2>/dev/null
  fi
  jq -cn --arg seq "$SEQ" --argjson round "$ROUND" --argjson fire "$FIRE" \
    --argjson from "$FROM" --argjson to "$CHANGED" \
    '{seq:$seq, round:$round, kreisel:$fire, from:$from, to:$to}' 2>/dev/null \
    || printf '{"seq":"%s","round":%s,"kreisel":false}\n' "$SEQ" "$ROUND"
  ;;
clear)
  rm -f "$SF" "$DF" 2>/dev/null
  ;;
*)
  printf '{"seq":"","round":1,"rounds":0,"prior":[],"kreisel":false}\n'
  ;;
esac
exit 0

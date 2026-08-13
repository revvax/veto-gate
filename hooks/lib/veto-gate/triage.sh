#!/usr/bin/env bash
# triage.sh — deterministic effort floor from the FACTS of a diff: which paths it
# touches and how many code lines it changes. No LLM, 0 tokens: the AI being judged
# must not be able to talk its own difficulty down.
#
# Floor, never ceiling. The configured effort stays the maximum (a repo set to
# 'medium' is never silently raised); triage may only go DOWN, and never below the
# floor the facts demand.
#
# Replaces the old crutch in veto-gate.sh (effort_auto/effort_small_lines), which
# lowered EVERY diff under 80 lines by line count alone — a 10-line auth change was
# downgraded too. That gap is what `sensitive` closes.
set -uo pipefail
NAMES=""; CHANGED=""; CFG=""
while [ $# -gt 0 ]; do case "$1" in
  --names) NAMES="$2"; shift 2;;
  --changed) CHANGED="$2"; shift 2;;
  --cfg) CFG="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 64;;
esac; done

# A non-numeric size means "we do not know", never 0 — 0 is the one value that
# unlocks the light profile, and an unknown size must not unlock anything.
case "$CHANGED" in ''|*[!0-9]*) CHANGED=-1;; esac

# A fact we could not READ is not a fact. Without the names file we cannot tell whether
# a sensitive path is in play; without valid config we know neither the ceiling nor
# whether the off-switch is set. Either way: lowering would be a guess, so we don't.
#
# Each input is read exactly ONCE, then only the copy in memory is used. Re-reading the
# config per field would let it change between the check and the use — the off-switch or
# a sensitive path could vanish while we still lower (codex find). And an unreadable
# names file must never read as "no sensitive path in this diff".
KNOWN=1
NAMES_TXT=""; CFG_TXT=""
NAMES_TXT=$(cat "$NAMES" 2>/dev/null) || KNOWN=0
CFG_TXT=$(cat "$CFG" 2>/dev/null) || KNOWN=0
# An EMPTY list answers nothing: with no file names we cannot tell whether a sensitive
# path is in play, and "we found no names" is not "there is nothing sensitive" (codex).
[ -n "$NAMES_TXT" ] || KNOWN=0
# Valid JSON is not enough, it must be an OBJECT: on an array or a string every field
# lookup below silently yields nothing, so the off-switch would be ignored (codex find).
printf '%s' "$CFG_TXT" | jq -e 'type=="object"' >/dev/null 2>&1 || KNOWN=0
# sensitive_paths is the ONE field whose fallback points the wrong way: an unusable
# `effort` falls back to high and an unusable `effort_small_lines` to 80 — both strict.
# A malformed sensitive_paths ("billing" instead of ["billing"]) would fall back to an
# empty list, silently meaning "nothing is sensitive". So a present-but-wrong-shaped
# list is not a fact either (codex find).
printf '%s' "$CFG_TXT" | jq -e 'if has("sensitive_paths")
  then (.sensitive_paths | type=="array" and all(.[]; type=="string")) else true end' \
  >/dev/null 2>&1 || KNOWN=0

CEIL=$(printf '%s' "$CFG_TXT" | jq -r '.effort // "high"' 2>/dev/null)
case "$CEIL" in low|medium|high) ;; *) CEIL=high;; esac
# `.effort_auto // true` would be a lie — jq's // treats FALSE as "not set" and hands
# back true, so the off-switch would not switch anything off. Ask whether the key is there.
AUTO=$(printf '%s' "$CFG_TXT" | jq -r 'if has("effort_auto") then .effort_auto else true end' 2>/dev/null)
SMALL=$(printf '%s' "$CFG_TXT" | jq -r '.effort_small_lines // 80' 2>/dev/null)
case "$SMALL" in ''|*[!0-9]*) SMALL=80;; esac

# Conservative default list. Repo config EXTENDS it, it never replaces it: a repo must
# not be able to configure the safety defaults away, only add to them.
DEFAULT_SENS='auth
payment
secret
credential
token
.env
migration
security
hooks/
.claude/config
.github/workflows'
EXTRA=$(printf '%s' "$CFG_TXT" | jq -r '(.sensitive_paths // []) | .[]? | select(type=="string")' 2>/dev/null)
PATTERNS=$(printf '%s\n%s' "$DEFAULT_SENS" "$EXTRA" | grep -v '^$')

# Literal substring, case-insensitive — deliberately NOT a regex: a metacharacter in a
# config value ('.', '*', '(') would bend the match, the same trap veto-gate.sh escapes
# for plan paths. A substring over-matches ('token' hits 'tokenizer') — that is the
# STRICT direction and therefore wanted: when in doubt, do not lower.
# ONE grep over ALL patterns, not a loop per pattern: that leaves exactly one exit code
# to read, so "no match" (1) stays distinguishable from "the search itself failed" (2+).
# A failed search must never read as "no sensitive path in this diff" (codex find).
#
# Here-string, NOT a pipe: -m1 makes grep stop at the first match, which kills a piping
# writer with SIGPIPE — and `set -o pipefail` would then report the whole pipeline as
# failed and throw the hit away. Only bites once the list outgrows the pipe buffer, so
# it would have passed every small fixture and lied on a real big diff (codex find).
SENSITIVE=false; HIT=""
HIT=$(grep -i -F -m1 -f <(printf '%s\n' "$PATTERNS") <<<"$NAMES_TXT" 2>/dev/null)
case $? in
  0) SENSITIVE=true;;
  1) ;;          # searched cleanly, nothing sensitive in this diff
  *) KNOWN=0;;   # the search itself broke — we do not know, so we do not lower
esac

# rank: only ever pick the LOWER of (proposal, ceiling)
rank(){ case "$1" in low) echo 1;; medium) echo 2;; *) echo 3;; esac; }
floor_at(){ if [ "$(rank "$1")" -lt "$(rank "$CEIL")" ]; then echo "$1"; else echo "$CEIL"; fi; }

PROFILE=normal
if [ "$KNOWN" = 0 ]; then
  EFFORT="$CEIL"; REASON="Fakten nicht lesbar (Namensliste/Config) — kein Runterstufen"
elif [ "$SENSITIVE" = true ]; then
  EFFORT="$CEIL"; REASON="heikler Pfad berührt ($HIT) — kein Runterstufen"
elif [ "$AUTO" = false ]; then
  EFFORT="$CEIL"; REASON="effort_auto aus — Config-Wert gilt"
elif [ "$CHANGED" -eq 0 ]; then
  EFFORT=$(floor_at low); PROFILE=light; REASON="0 Code-Zeilen (reine Doku/Config), kein heikler Pfad"
elif [ "$CHANGED" -ge 0 ] && [ "$CHANGED" -le "$SMALL" ] && [ "$CEIL" = high ]; then
  EFFORT=medium; REASON="$CHANGED Code-Zeilen ≤ $SMALL, kein heikler Pfad"
else
  EFFORT="$CEIL"; REASON="$CHANGED Code-Zeilen — Config-Wert gilt"
fi

jq -cn --arg e "$EFFORT" --arg p "$PROFILE" --argjson s "$SENSITIVE" --arg r "$REASON" \
  '{effort:$e,profile:$p,sensitive:$s,reason:$r}'

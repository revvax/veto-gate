#!/usr/bin/env bash
# remote-diff-review.sh — free-tier remote pre-reviewer (groq | gemini), both
# OpenAI-compatible. Same contract as minimax-diff-review.sh: FILTER before
# codex, never the final verdict. Exit 0 = verdict JSON on stdout · 3 = infra
# error (caller fails open to codex) · 4 = diff too big · 64 = bad args.
# §10: intended for free tiers only (responsibility sits with the stored
# key, see CONVENTIONS); the diff LEAVES the machine — choosing groq/gemini
# is a deliberate per-repo opt-in surfaced in the panel.
set -uo pipefail

PROVIDER=""; DIFF=""
# a dangling flag would make `shift 2` fail and loop forever (codex find)
while [ $# -gt 0 ]; do case "$1" in
  --provider) [ $# -ge 2 ] || { echo "missing value for --provider" >&2; exit 64; }; PROVIDER="$2"; shift 2;;
  --diff) [ $# -ge 2 ] || { echo "missing value for --diff" >&2; exit 64; }; DIFF="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 64;;
esac; done
[ -n "$PROVIDER" ] || { echo "usage: remote-diff-review.sh --provider groq|gemini --diff FILE" >&2; exit 64; }
[ -f "$DIFF" ] || { echo "diff not found: $DIFF" >&2; exit 64; }

LOG_DIR="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}"
case "$PROVIDER" in
  groq)
    URL="${VETO_GATE_GROQ_URL:-https://api.groq.com/openai/v1/chat/completions}"
    MODEL="${VETO_GATE_GROQ_MODEL:-llama-3.3-70b-versatile}"
    MAXB="${VETO_GATE_GROQ_MAXBYTES:-16000}"   # free tier: 6k tokens/min
    ALLOW="https://api.groq.com/"
    ENVKEY="${GROQ_API_KEY:-}"; KEYFILE="$LOG_DIR/keys/groq.key";;
  gemini)
    URL="${VETO_GATE_GEMINI_URL:-https://generativelanguage.googleapis.com/v1beta/openai/chat/completions}"
    MODEL="${VETO_GATE_GEMINI_MODEL:-gemini-3.5-flash}"
    MAXB="${VETO_GATE_GEMINI_MAXBYTES:-60000}"
    ALLOW="https://generativelanguage.googleapis.com/"
    ENVKEY="${GEMINI_API_KEY:-}"; KEYFILE="$LOG_DIR/keys/gemini.key";;
  *) echo "unknown provider: $PROVIDER" >&2; exit 64;;
esac

# Diff + key only ever go to THIS provider's real host (https) or to
# localhost (hermetic test mocks). userinfo (@) is banned outright:
# http://127.0.0.1:4094@evil.example passes a naive glob but curl connects
# to evil.example. A groq key can never be sent to gemini's host or vice
# versa (per-provider ALLOW binding). Anything else = infra → fail open.
LOCAL=0
case "$URL" in
  *@*|*" "*) exit 3;;
  "$ALLOW"*) ;;
  http://127.0.0.1:[0-9]*/*|http://localhost:[0-9]*/*|https://127.0.0.1:[0-9]*/*) LOCAL=1;;
  *) exit 3;;
esac

# Env keys are a TEST seam and count only for localhost targets — production
# sends authenticate EXCLUSIVELY via the shared key file, the same source
# the panel reports. Otherwise the panel could say "Schlüssel fehlt" while a
# gate env key silently ships diffs off-machine.
KEY=""
[ "$LOCAL" = 1 ] && KEY="$ENVKEY"
[ -n "$KEY" ] || { [ -f "$KEYFILE" ] && KEY=$(cat "$KEYFILE" 2>/dev/null); }
[ -n "$KEY" ] || exit 3   # no key = stage not set up → fail open to codex

TIMEOUT="${VETO_GATE_REMOTE_TIMEOUT:-60}"
# a broken size cap must never disarm the size check and ship the diff
# anyway — non-numeric/empty MAXB fails open to codex (codex find, same
# class as the gate's max_lines guard)
[ -z "${MAXB##*[!0-9]*}" ] && exit 3
[ "$MAXB" -gt 0 ] || exit 3
[ "$(wc -c < "$DIFF")" -gt "$MAXB" ] && exit 4

# same finding contract as qwen: only defects the diff text itself proves;
# missing-reference findings are forbidden (no repo context at this stage)
SYS='Du prüfst einen Code-DIFF auf ECHTE Fehler, die der Diff-Text SELBST beweist: kaputte Logik, Sicherheitslücken (Injection, Secrets), Datenverlust. Keine Stil-Nörgelei, keine Vermutungen. WICHTIG: Melde KEINE fehlenden/unbekannten Funktionen, Felder oder Imports — dir fehlt der Repo-Kontext, das prüft die nächste Stufe. Antworte mit GENAU EINEM JSON-Objekt, kein Freitext, kein Markdown: {"blocking":[{"id":"","claim":"","why":"","fix":""}],"non_blocking":[{"id":"","note":""}],"questions":[],"context_requests":[],"unverified_claims":[]} — claim/why/fix in einfacher deutscher Sprache.'

REQ=$(jq -n --arg m "$MODEL" --arg sys "$SYS" --rawfile diff "$DIFF" \
  '{model:$m, temperature:0, max_tokens:4000, stream:false,
    messages:[{role:"system",content:$sys},{role:"user",content:$diff}]}') || exit 3

# The key must never appear in argv (process list is world-readable) — the
# Authorization header travels via a 0600 temp file (curl -H @file). The
# REQUEST carries the whole diff (may contain secrets) — body via stdin.
HDR=$(umask 177 && mktemp "${TMPDIR:-/tmp}/veto-gate-hdr.XXXXXX") || exit 3
trap 'rm -f "$HDR"' EXIT
printf 'Authorization: Bearer %s\n' "$KEY" > "$HDR" || exit 3
RESP=$(printf '%s' "$REQ" | curl -sS --max-time "$TIMEOUT" \
  -H 'Content-Type: application/json' -H @"$HDR" \
  --data-binary @- "$URL" 2>/dev/null) || exit 3

CONTENT=$(printf '%s' "$RESP" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
[ -n "$CONTENT" ] || exit 3   # covers HTTP 429/4xx error bodies too

# cut to the outermost JSON object; models may wrap it in prose/markdown
VERDICT=$(printf '%s' "$CONTENT" | perl -0777 -pe 's/^[^{]*//s; s/[^}]*$//s' 2>/dev/null)
# shape-valid garbage must fall open, never block: every blocking entry
# needs a non-empty STRING claim — jq's length on a number is its absolute
# value and on an object its key count, so claim:5 or claim:{} would
# otherwise pass as a "finding" (codex find)
printf '%s' "$VERDICT" | jq -e '
  type=="object" and has("blocking") and (.blocking|type=="array")
  and (.blocking | all(type=="object"
    and ((.claim // "") | type=="string" and length > 0)))
' >/dev/null 2>&1 || exit 3
printf '%s' "$VERDICT" | jq -c .

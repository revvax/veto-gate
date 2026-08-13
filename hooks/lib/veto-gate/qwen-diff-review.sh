#!/usr/bin/env bash
# qwen-diff-review.sh — local pre-reviewer via LM Studio (OpenAI-compatible).
# Free, local (§10). Role: FILTER before codex — obvious bugs block without
# burning codex quota; a local pass is NOT a verdict (codex stays the final
# reviewer). Exit 0 = verdict JSON on stdout · 3 = infra error (caller fails
# open to codex) · 4 = diff too big for local · 64 = bad args.
set -uo pipefail
. "$(dirname "$0")/env-compat.sh"   # VETO_GATE_* -> VETO_GATE_* transition

DIFF=""
while [ $# -gt 0 ]; do case "$1" in
  --diff) DIFF="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 64;;
esac; done
[ -f "$DIFF" ] || { echo "diff not found: $DIFF" >&2; exit 64; }

URL="${VETO_GATE_QWEN_URL:-http://127.0.0.1:1234/v1/chat/completions}"
MODEL="${VETO_GATE_QWEN_MODEL:-qwen3.6-35b-a3b-mlx}"
TIMEOUT="${VETO_GATE_QWEN_TIMEOUT:-60}"
MAXB="${VETO_GATE_QWEN_MAXBYTES:-60000}"

[ "$(wc -c < "$DIFF")" -gt "$MAXB" ] && exit 4

# identity check (codex live finding): a diff may contain sensitive content —
# only ship it to a server that actually lists the configured model on
# /v1/models. Custom URLs not ending in /chat/completions skip the check
# (explicitly configured = deliberate).
case "$URL" in
  */chat/completions)
    MODELS=$(curl -sS --max-time 5 "${URL%/chat/completions}/models" 2>/dev/null) || exit 3
    printf '%s' "$MODELS" | jq -e --arg m "$MODEL" \
      '.data | type=="array" and (map(.id) | index($m) != null)' >/dev/null 2>&1 || exit 3
    ;;
esac

# thinking mode burns the 60s budget AND the token cap (live-measured: content
# stayed empty, finish=length). chat_template_kwargs.enable_thinking=false is
# the LM-Studio-native switch (live: 4.8s, clean content); /no_think in the
# prompt stays as belt-and-braces for other builds, max_tokens leaves room in
# case a build thinks anyway. temperature 0 keeps verdicts reproducible.
# Same JSON schema as codex so the gate and serve.py consume both identically.
SYS='/no_think Du prüfst einen Code-DIFF auf ECHTE Fehler, die der Diff-Text SELBST beweist: kaputte Logik, Sicherheitslücken (Injection, Secrets), Datenverlust. Keine Stil-Nörgelei, keine Vermutungen. WICHTIG: Melde KEINE fehlenden/unbekannten Funktionen, Felder oder Imports — dir fehlt der Repo-Kontext, das prüft die nächste Stufe. Antworte mit GENAU EINEM JSON-Objekt, kein Freitext, kein Markdown: {"blocking":[{"id":"","claim":"","why":"","fix":""}],"non_blocking":[{"id":"","note":""}],"questions":[],"context_requests":[],"unverified_claims":[]} — claim/why/fix in einfacher deutscher Sprache.'

REQ=$(jq -n --arg m "$MODEL" --arg sys "$SYS" --rawfile diff "$DIFF" \
  '{model:$m, temperature:0, max_tokens:4000, stream:false,
    chat_template_kwargs:{enable_thinking:false},
    messages:[{role:"system",content:$sys},{role:"user",content:$diff}]}') || exit 3

RESP=$(curl -sS --max-time "$TIMEOUT" -H 'Content-Type: application/json' \
  -d "$REQ" "$URL" 2>/dev/null) || exit 3

CONTENT=$(printf '%s' "$RESP" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
[ -n "$CONTENT" ] || exit 3

# strip <think>…</think> defensively, then cut to the outermost JSON object
VERDICT=$(printf '%s' "$CONTENT" | perl -0777 -pe 's/<think>.*?<\/think>//gs; s/^[^{]*//s; s/[^}]*$//s' 2>/dev/null)
# a small model may emit shape-valid garbage — every blocking entry must be a
# real finding (object with a non-empty claim), anything else is an infra
# failure that falls open to codex, never a block (codex live finding)
printf '%s' "$VERDICT" | jq -e '
  type=="object" and has("blocking") and (.blocking|type=="array")
  and (.blocking | all(type=="object" and ((.claim // "") | length > 0)))
' >/dev/null 2>&1 || exit 3
printf '%s' "$VERDICT" | jq -c .

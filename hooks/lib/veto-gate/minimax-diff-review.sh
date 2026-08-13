#!/usr/bin/env bash
# minimax-diff-review.sh — pre-reviewer via MiniMax-M3 through the hermes CLI.
#
# Replaces the local qwen stage. Role is unchanged: a FILTER before codex, never
# a verdict of its own — codex stays the final reviewer.
#
# No API key appears anywhere in this file, and none may be added. hermes holds
# the credential itself (provider "minimax-oauth"); this script only runs the
# command. That is the whole reason the CLI is used instead of an HTTP call: a
# key that never enters our code cannot leak from our code.
#
# Exit 0 = verdict JSON on stdout · 3 = infra error (caller falls open to codex)
#        · 4 = diff too big for this stage · 64 = bad args.
set -uo pipefail
# shellcheck source=with-timeout.sh
. "$(dirname "$0")/with-timeout.sh"

DIFF=""
while [ $# -gt 0 ]; do case "$1" in
  --diff) DIFF="$2"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 64;;
esac; done
[ -f "$DIFF" ] || { echo "diff not found: $DIFF" >&2; exit 64; }

BIN="${VETO_GATE_HERMES_BIN:-hermes}"
MODEL="${VETO_GATE_MINIMAX_MODEL:-MiniMax-M3}"
PROVIDER="${VETO_GATE_MINIMAX_PROVIDER:-minimax-oauth}"
TIMEOUT="${VETO_GATE_MINIMAX_TIMEOUT:-120}"
MAXB="${VETO_GATE_MINIMAX_MAXBYTES:-60000}"

[ "$(wc -c < "$DIFF")" -gt "$MAXB" ] && exit 4
command -v "$BIN" >/dev/null 2>&1 || exit 3

# Describing is not causing (live 2026-07-28): a diff consisting of ONE new
# markdown file was blocked because the file DESCRIBED bugs. A report or handover
# introduces nothing — it names something that already exists elsewhere.
# The exemption is DELIBERATELY narrow: a changed line that CARRIES something
# harmful stays a finding, in a text or config file too.
SYS='Du prüfst einen Code-DIFF auf ECHTE Fehler, die der Diff-Text SELBST beweist: kaputte Logik, Sicherheitslücken (Injection, Secrets), Datenverlust. Keine Stil-Nörgelei, keine Vermutungen. WICHTIG: Melde KEINE fehlenden/unbekannten Funktionen, Felder oder Imports — dir fehlt der Repo-Kontext, das prüft die nächste Stufe. WICHTIG: Ein Text, der ein Problem BESCHREIBT, verursacht es nicht. Schildert eine geänderte Zeile einen anderswo vorhandenen Fehler (Bericht, Übergabe, Notiz, Kommentar, Commit-Beschreibung), ist das ein BERICHT darüber und KEIN blocking-Fund. Das gilt NUR für die Schilderung selbst: Bringen die geänderten Zeilen etwas Schädliches mit — ein echtes Geheimnis (Schlüssel, Passwort, Token), eine unsichere Einstellung, einen gefährlichen Befehl —, ist das sehr wohl ein Fund, auch in einer Text- oder Konfigurationsdatei. Prüffrage bei jedem Fund: Ist das Problem hier nur BESCHRIEBEN, oder ist es hier VORHANDEN? Antworte mit GENAU EINEM JSON-Objekt, kein Freitext, kein Markdown: {"blocking":[{"id":"","claim":"","why":"","fix":""}],"non_blocking":[{"id":"","note":""}],"questions":[],"context_requests":[],"unverified_claims":[]} — claim/why/fix in einfacher deutscher Sprache.'

# The diff rides in the prompt. hermes takes it as one argument, so nothing is
# written to a shared temp file that another process could read or swap.
PROMPT=$(printf '%s\n\n--- DIFF ---\n%s' "$SYS" "$(cat "$DIFF")") || exit 3

OUT=$(with_timeout "$TIMEOUT" "$BIN" -z "$PROMPT" -m "$MODEL" --provider "$PROVIDER" 2>/dev/null) || exit 3
[ -n "$OUT" ] || exit 3

# cut to the outermost JSON object; a model may wrap it in prose or a fence
VERDICT=$(printf '%s' "$OUT" | perl -0777 -pe 's/^[^{]*//s; s/[^}]*$//s' 2>/dev/null)
# shape-valid garbage must never block: every blocking entry needs a real claim,
# anything else is an infra failure that falls open to codex
printf '%s' "$VERDICT" | jq -e '
  type=="object" and has("blocking") and (.blocking|type=="array")
  and (.blocking | all(type=="object" and ((.claim // "") | length > 0)))
' >/dev/null 2>&1 || exit 3
printf '%s' "$VERDICT" | jq -c .

#!/usr/bin/env bash
# discord-codex-findings.sh — push what the gate told Claude to Discord.
#
# Layout (owner 2026-07-13): ALWAYS the same three headings, so the phone shows
# the shape of the problem at a glance — WAS / WARUM / WIE WIRD ES GELÖST.
# Discord embed *fields* carry them (bold heading + own block), never one wall
# of text. Noise (file list, commit message) is demoted to the footer.
#
# Four kinds. Verwaltungs-Blocks (size/cap) stay silent on purpose.
#   --kind findings   stdin = verdict json {"blocking":[{id,claim,why,fix}]}
#   --kind grounding  stdin = grounding json {"count":N,"violations":[{file,import,symbol}]}
#   --kind quota      no stdin — codex window closed, NOTHING was reviewed
#   --kind timeout    no stdin — codex stayed silent, NOTHING was reviewed
#   --kind gap        no stdin — a checker could not run at all; --detail names the stages
#
# Context flags: --repo --branch --reviewer --commit-msg --files --detail
#
# Required env: DISCORD_VETO_WEBHOOK (missing → silent no-op).
# Optional env: VETO_GATE_DISCORD_DRY_RUN=1 → print payload, no curl.
#
# ALWAYS exits 0. This runs inside the commit gate; a notification problem must
# never turn into a commit problem.
set -uo pipefail

KIND="findings"; REPO=""; BRANCH=""; REVIEWER="codex"; CMSG=""; FILES=""; DETAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)       KIND="${2:-findings}"; shift 2;;
    --repo)       REPO="${2:-}"; shift 2;;
    --branch)     BRANCH="${2:-}"; shift 2;;
    --reviewer)   REVIEWER="${2:-codex}"; shift 2;;
    --commit-msg) CMSG="${2:-}"; shift 2;;
    --files)      FILES="${2:-}"; shift 2;;
    --detail)     DETAIL="${2:-}"; shift 2;;
    *) shift;;
  esac
done

IN=$(cat 2>/dev/null)
[ -n "${DISCORD_VETO_WEBHOOK:-}" ] || [ "${VETO_GATE_DISCORD_DRY_RUN:-0}" = "1" ] || exit 0

RED=15548997      # Claude got it wrong — a real finding
ORANGE=16753920   # nobody reviewed it — a gap, not a fault

# fields_json <was> <warum> <wie>  → the three fixed headings, in order.
fields_json(){
  jq -cn --arg a "$1" --arg b "$2" --arg c "$3" \
    '[{name:"❶ WAS",              value:($a[0:1020]), inline:false},
      {name:"❷ WARUM",            value:($b[0:1020]), inline:false},
      {name:"❸ WIE WIRD ES GELÖST", value:($c[0:1020]), inline:false}]'
}

case "$KIND" in
  findings)
    N=$(printf '%s' "$IN" | jq '.blocking | length' 2>/dev/null) || exit 0
    case "$N" in ''|*[!0-9]*) exit 0;; esac
    [ "$N" -gt 0 ] || exit 0
    COLOR=$RED
    if [ "$N" -eq 1 ]; then
      TITLE="⛔ 1 Problem"
      FIELDS=$(fields_json \
        "$(printf '%s' "$IN" | jq -r '.blocking[0].claim // "?"')" \
        "$(printf '%s' "$IN" | jq -r '.blocking[0].why // "?"')" \
        "$(printf '%s' "$IN" | jq -r '.blocking[0].fix // "?"')")
    else
      # More than one: one field per finding — heading = WAS, body = warum + lösung.
      TITLE="⛔ ${N} Probleme"
      FIELDS=$(printf '%s' "$IN" | jq -c '[.blocking[:5][] |
        {name: (("⛔ " + (.claim // "?"))[0:250]),
         value: (("**Warum:** " + (.why // "?") + "\n**Lösung:** " + (.fix // "?"))[0:1020]),
         inline: false}]
        + (if (.blocking | length) > 5
           then [{name:"…", value:("+ " + ((.blocking | length) - 5 | tostring) + " weitere — am Rechner nachsehen"), inline:false}]
           else [] end)' 2>/dev/null)
    fi
    ;;
  grounding)
    N=$(printf '%s' "$IN" | jq '.count // (.violations | length)' 2>/dev/null) || N=0
    case "$N" in ''|*[!0-9]*) N=0;; esac
    COLOR=$RED
    TITLE="⛔ Erfundener Code"
    WAS=$(printf '%s' "$IN" | jq -r '[.violations[:4][]? |
      "`\(.import)`\(if .symbol then " → `\(.symbol)`" else "" end) in \(.file)"] | join("\n")' 2>/dev/null)
    [ -n "$WAS" ] || WAS="Claude benutzt etwas, das im Code nicht existiert."
    FIELDS=$(fields_json "$WAS" \
      "Das gibt es nirgends im Code. Der Programmcode würde beim Start abstürzen." \
      "Pfad/Name korrigieren — oder das Fehlende wirklich anlegen.")
    ;;
  quota|timeout)
    COLOR=$ORANGE
    TITLE="⚠️ Nicht geprüft"
    if [ "$KIND" = "quota" ]; then
      WAS="Codex hatte kein Kontingent mehr${DETAIL:+ ($DETAIL)}."
      WIE="Commit ist gestoppt. Warten bis das Fenster wieder aufgeht — oder bewusst überspringen."
    else
      WAS="Codex hat zweimal nicht rechtzeitig geantwortet${DETAIL:+ ($DETAIL)}."
      WIE="Commit ist gestoppt. Kleiner committen, oder später erneut versuchen."
    fi
    FIELDS=$(fields_json "$WAS" \
      "**Niemand hat diesen Code angeschaut.** Es gibt keine Prüfung, auf die du dich verlassen kannst." \
      "$WIE")
    ;;
  gap)
    # A stage did not run. Nobody got it WRONG — nobody LOOKED. That is a different kind of
    # bad news than a finding, so it gets a different colour: this must not train the eye to
    # ignore red. The commit went through; the code is not proven wrong, it is unexamined.
    COLOR=$ORANGE
    TITLE="⚠️ Nicht geprüft"
    FIELDS=$(fields_json \
      "Diese Prüfungen liefen NICHT: ${DETAIL:-unbekannt}" \
      "**Niemand hat das angeschaut.** Der Prüfer fehlt im Projekt, oder ein Dienst war aus." \
      "Der Commit ging trotzdem durch — der Code ist nicht falsch, er ist nur ungeprüft. Prüfer nachrüsten oder Dienst starten.")
    ;;
  *) exit 0;;
esac
[ -n "$FIELDS" ] || exit 0

# Noise → footer: where it happened, what Claude wanted, how much it touched.
NFILES=0
[ -n "$FILES" ] && NFILES=$(printf '%s' "$FILES" | tr ',' '\n' | grep -c '[^[:space:]]')
FOOT="${REPO:-?}${BRANCH:+ · $BRANCH}${REVIEWER:+ · geprüft von $REVIEWER}"
[ "$NFILES" -gt 0 ] && FOOT="$FOOT · ${NFILES} Datei(en)"
[ -n "$CMSG" ]      && FOOT="$FOOT · Commit: ${CMSG}"

PAYLOAD=$(jq -cn --arg t "$TITLE" --arg f "$FOOT" --argjson c "$COLOR" --argjson fl "$FIELDS" \
  '{embeds:[{title:($t[0:250]), color:$c, fields:$fl, footer:{text:($f[0:2040])}}]}' 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

if [ "${VETO_GATE_DISCORD_DRY_RUN:-0}" = "1" ]; then printf '%s\n' "$PAYLOAD"; exit 0; fi
curl -sS -m 10 -H 'Content-Type: application/json' -d "$PAYLOAD" "$DISCORD_VETO_WEBHOOK" >/dev/null 2>&1 || true
exit 0

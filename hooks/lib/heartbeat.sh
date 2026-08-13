#!/usr/bin/env bash
# heartbeat.sh — every hook says that it ran, and what it decided.
#
# Why this exists. A hook that finds no config exits 0 and says nothing. A dead
# hook and a satisfied hook look IDENTICAL from outside. Measured 2026-07-29:
# after a config rename three hooks were dead, one was noticed, the other two ran
# nowhere for eleven days. Nobody could have seen it — there was no place where
# a hook says "I am here".
#
# The rule this file enforces is not about names or configs, and that is the
# point: whatever kills a hook next — a rename, a typo, a broken path, a missing
# dependency — it shows up in the same place, because the SILENCE is what gets
# noticed, not the cause.
#
#   hb <name> <decision> [detail]   → one line into this session's beat file
#
# decision is free text, but three words carry meaning downstream:
#   ran      — the hook did its work
#   skipped  — deliberately not applicable here (no config, wrong file type)
#   blind    — the hook wanted to work and could NOT (missing tool, unreadable
#              state). This is the one that must never pass unnoticed.
#
# Writing a beat must never cost a hook its run: every failure here is silent
# and returns 0. A bookkeeper that breaks the thing it books would be worse than
# no bookkeeping at all.

# --- Zeit je Hook (E1) ------------------------------------------------------
#
# Die Frage ist: was kostet ein Hook den Benutzer? Sie wurde bisher nur auf dem
# Prüfstand beantwortet, nie im Betrieb. Der Einbau sitzt HIER und nicht in den
# 25 Hooks, weil jeder von ihnen diese Datei in seinen ersten 35 Zeilen einbindet
# (gemessen: Zeile 8 bis 35 von 27 Dateien). Der Startzeitpunkt entsteht also beim
# Einbinden, und kein einziger Hook muss dafür geändert werden.
#
# ZUERST das Messgerät geprüft, wie der Plan es verlangt — alles gemessen am
# 2026-07-30, 200 Durchläufe je Kandidat, unter /bin/bash 3.2.57:
#
#   $SECONDS (eingebaut)          0,05 ms   nur ganze Sekunden → unbrauchbar
#   times (eingebaut)             0,05 ms   1-ms-Auflösung, aber RECHENzeit
#   date +%s                      2,3 ms    nur ganze Sekunden
#   perl Time::HiRes              5,8 ms    Millisekunden, das einzige Uhrwerk
#   python3                      20,5 ms    zu teuer
#
# Drei Befunde, die den Bau bestimmt haben:
#   1. ALLE 27 Hooks laufen auf bash 3.2.57 — nicht 11, wie der Plan annahm.
#      `/usr/bin/env bash` löst hier auf dasselbe /bin/bash auf, eine neuere bash
#      gibt es auf dieser Maschine nicht. `$EPOCHREALTIME` fehlt also überall,
#      `printf '%(%s)T'` ebenfalls (erst ab bash 4.2).
#   2. `date +%s%3N` sieht aus wie eine Millisekunden-Uhr und ist keine: BSD-date
#      kennt %N nicht und hängt die Zeichen „3N" an die Sekunden. Das Ergebnis
#      liest sich wie ein Zeitstempel und ist Müll.
#   3. Eine Zeitspanne braucht ZWEI Zeitpunkte, also 12,6 ms je gemessenem Lauf.
#      Das ist mehr als die 5 ms aus dem Plan → es wird GESTICHPROBT.
#
# Die Stichprobe entscheidet die eigene Prozessnummer modulo Rate (0,035 ms, kein
# Unterprozess). Jeder Hook-Lauf ist ein eigener Prozess, die Nummern laufen
# hoch — das streut von sich aus. Bei Rate 16 kostet die Messung im Schnitt
# 12,6/16 = 0,79 ms je Hook-Lauf. Diese Zahl gehört in den Bericht, nicht in eine
# Fußnote: ein Messgerät, dessen Preis niemand kennt, ist keins.
_HB_T0=""; _HB_TIMED=""
_hb_rate="${VETO_HB_TIME_RATE:-16}"
case "$_hb_rate" in ''|*[!0-9]*) _hb_rate=16;; esac
if [ "$_hb_rate" -gt 0 ] && [ $(( $$ % _hb_rate )) -eq 0 ]; then
  _HB_T0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000' 2>/dev/null) || _HB_T0=""
  case "$_HB_T0" in ''|*[!0-9]*) _HB_T0="";; esac
fi

# ABGELEHNT, mit Messung: eine zweite Spalte mit der RECHENzeit aus dem
# eingebauten `times`. Sie wäre kostenlos gewesen (0,05 ms) und eine gute
# Gegenprobe — liegt die Uhrzeit weit über der Rechenzeit, hat der Hook GEWARTET
# statt gerechnet. `times` schreibt aber nur auf die Ausgabe, und einlesen heißt
# `$(times)` — eine Unter-Shell. Die ist ein eigener Prozess und beginnt ihre
# Zählung bei null: gemessen meldet sie „0m0.000s 0m0.000s", während dasselbe
# `times` direkt 0m0.068s zeigt. Die einzige kostenlose Rechenzeit-Uhr in bash 3.2
# lässt sich also nicht kostenlos lesen. Über eine Zwischendatei wäre es gegangen,
# um den Preis einer Restdatei je Hook-Prozess — mehr Mechanik als die Gegenprobe
# wert ist. Wer es erneut versucht, findet hier, warum es nicht geht.

# Eine Zeile je gestichprobtem Lauf, in eine EIGENE Tagesdatei mit der Endung
# .times — bewusst nicht .tsv: hook-health liest die Lebenszeichen mit
# `find -name '*.tsv'`, und eine Zeitdatei mit dieser Endung würde dort als
# Lebenszeichen gelesen und die Spalten falsch gedeutet.
_hb_write_time() {
  local name="${1:-?}" t1 wall dir ts off
  [ -n "$_HB_T0" ] || return 0
  [ -z "$_HB_TIMED" ] || return 0      # hb_once ruft hb — nur EINE Zeile je Lauf
  _HB_TIMED=1
  t1=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000' 2>/dev/null) || return 0
  case "$t1" in ''|*[!0-9]*) return 0;; esac
  # Der Startaufwand des ZWEITEN perl-Aufrufs steckt in der Differenz mit drin:
  # beide melden ihre Zeit erst NACH dem Hochfahren. Gemessen über 200 Paare mit
  # nichts dazwischen: 6,12 ms. Dieser Versatz wird abgezogen, sonst bekäme jeder
  # Hook 6 ms Messaufwand als eigene Laufzeit angerechnet. Unterhalb von etwa
  # 3 ms ist das Verfahren damit am Rauschen — auch das steht im Bericht.
  off="${VETO_HB_TIME_OFFSET:-6}"
  case "$off" in ''|*[!0-9]*) off=6;; esac
  wall=$(( t1 - _HB_T0 - off ))
  [ "$wall" -ge 0 ] || wall=0
  dir="${VETO_HB_DIR:-$HOME/.claude/heartbeat}"
  mkdir -p "$dir" 2>/dev/null || return 0
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 0
  printf '%s\t%s\t%s\n' "$ts" "$name" "$wall" \
    >> "$dir/zeit-${ts:0:10}.times" 2>/dev/null || true
  return 0
}

hb() {
  _hb_write_time "${1:-?}"
  local name="${1:-?}" decision="${2:-?}" detail="${3:-}"
  local dir sid
  # The fallback is the DATE, not a fixed name. Measured 2026-07-29: every beat
  # on this machine had landed in one unknown.tsv, 4822 lines and growing without
  # bound, because CLAUDE_SESSION_ID is empty in a hook — the id arrives on
  # stdin, which is where veto-gate.sh reads it. A single file that is rewritten
  # forever also never ages, and that is what made hook-health's window
  # meaningless until it moved onto the line timestamps. A dated file rotates by
  # itself and ages honestly, whether or not an id ever shows up.
  sid="${VETO_HB_SESSION:-${CLAUDE_SESSION_ID:-}}"
  # the session id becomes a FILE NAME — never let path characters in
  case "$sid" in ''|*[!A-Za-z0-9_-]*) sid=$(date -u +%Y-%m-%d);; esac
  dir="${VETO_HB_DIR:-$HOME/.claude/heartbeat}"
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$decision" "$detail" \
    >> "$dir/$sid.tsv" 2>/dev/null || true
  return 0
}

# hb_once — like hb, but at most one line per hook AND decision per file.
#
# This is what makes instrumenting the rest of the hooks possible at all.
# Measured 2026-07-29: four instrumented hooks wrote 6557 lines in ONE day, 6213
# of them veto-gate. Fitting the other 21 the same way — trace-logger and
# status-actor fire on every single tool call — would bury the watcher under its
# own data, and hook-health reads all of it at every session start.
#
# For the question this file answers, "did this hook report inside the window",
# one line a day is as good as ten thousand. What a run actually decided lives
# in runs.jsonl; that is not this file's job. A CHANGED decision does get
# through, so a hook that starts failing on a day it already reported success
# still becomes visible.
#
# Self-limiting by construction: the file it greps stays small precisely because
# of the grep, and it rotates with the date, so a new day reports afresh.
hb_once() {
  # VOR der Entdopplung: die Zeitmessung darf nicht daran hängen, ob dieser Hook
  # heute schon ein Lebenszeichen geschrieben hat. Sonst gäbe es je Hook genau
  # EINEN Messwert pro Tag, und aus einem Wert kommt kein p95.
  _hb_write_time "${1:-?}"
  local name="${1:-?}" decision="${2:-?}" dir sid f
  sid="${VETO_HB_SESSION:-${CLAUDE_SESSION_ID:-}}"
  case "$sid" in ''|*[!A-Za-z0-9_-]*) sid=$(date -u +%Y-%m-%d);; esac
  dir="${VETO_HB_DIR:-$HOME/.claude/heartbeat}"
  f="$dir/$sid.tsv"
  # Tabs around the fields, so a hook named `veto` never matches `veto-gate`
  # and a decision `ran` never matches `random`.
  if [ -f "$f" ] && grep -qF "	$name	$decision	" "$f" 2>/dev/null; then
    return 0
  fi
  hb "$@"
}

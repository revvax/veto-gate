#!/usr/bin/env bash
# skilltrail: die Ampel je Auftrag.
#
# Drei Quellen: was gefordert war, was lief, was behauptet wurde. Rot ist,
# wenn sie auseinanderfallen. Die vierte Farbe ist die wichtigste: ein Zug
# OHNE Spur ist nicht gruen, sondern "nicht erfasst" — ein ausgefallener
# Waechter darf nie wie ein zufriedener aussehen (Befund aus E5).
set -uo pipefail
M="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/skilltrail.py"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1' want '$2')"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

L(){ python3 -c "
import json,sys
sys.path.insert(0, '$(dirname "$M")')
import skilltrail
print(json.dumps(skilltrail.turn_light($1, $2, $3, $4)))
"; }

# A1: alles deckungsgleich → gruen
ok "$(L "[('critical','brainstorming')]" "['brainstorming']" "['brainstorming']" True | jq -r .light)" \
   "gruen" "A1 gefordert, gelaufen, genannt"

# A2: Pflicht gefordert, nie gelaufen → rot, und der Skill wird BENANNT
ok "$(L "[('critical','brainstorming')]" "[]" "[]" True | jq -r .light)" "rot" "A2 Pflicht ausgelassen"
ok "$(L "[('critical','brainstorming')]" "[]" "[]" True | jq -r '.reasons[0]|contains("brainstorming")')" \
   "true" "A2b und nennt welchen"

# A3: behauptet, aber nicht gelaufen → rot
ok "$(L "[]" "[]" "['simplify']" True | jq -r .light)" "rot" "A3 behauptet ohne Lauf"

# A4: gelaufen, aber nicht genannt → rot
ok "$(L "[]" "['simplify']" "[]" True | jq -r .light)" "rot" "A4 gelaufen ohne Nennung"

# A5: Immer-Pflicht faerbt NICHT rot (owner 2026-07-30) — sie laeuft in jedem Zug
# und wuerde jeden Zug einfaerben; ein Daueralarm lehrt das Ueberfliegen.
ok "$(L "[('always','answer-style')]" "[]" "[]" True | jq -r .light)" "grau" "A5 Immer-Pflicht faerbt nicht"

# A6: nichts gefordert, nichts gelaufen, nichts behauptet → grau, kein Fehler
ok "$(L "[]" "[]" "[]" True | jq -r .light)" "grau" "A6 leerer Zug ist grau"

# A7: keine Spur → NICHT gruen
ok "$(L "[]" "[]" "[]" False | jq -r .light)" "nicht erfasst" "A7 ohne Spur ist nichts bewiesen"
ok "$(L "[('critical','x')]" "['x']" "['x']" False | jq -r .light)" "nicht erfasst" \
   "A7b auch wenn alles zu passen scheint"

# --- Fix-Runde 1 (Koordinator, 2026-07-31): fehlende Forderungs-Datei ist
# NICHT dasselbe wie eine leere — beide wurden vorher gleich behandelt.
L5(){ python3 -c "
import json,sys
sys.path.insert(0, '$(dirname "$M")')
import skilltrail
print(json.dumps(skilltrail.turn_light($1, $2, $3, $4, demand_known=$5)))
"; }

# B1: turn_light direkt — Forderungs-Datei DA, aber leer (demand_known=True,
# demanded=[]) + Spur da, nichts gelaufen/behauptet → bleibt grau
ok "$(L5 "[]" "[]" "[]" True True | jq -r .light)" "grau" "B1 leere-aber-vorhandene Forderung bleibt grau"

# B2: turn_light direkt — Forderungs-Datei FEHLT (demand_known=False),
# Spur DA → dennoch "nicht erfasst", nicht grau
ok "$(L5 "[]" "[]" "[]" True False | jq -r .light)" "nicht erfasst" \
   "B2 fehlende Forderungs-Datei ist nicht erfasst, obwohl Spur da ist"
ok "$(L5 "[]" "[]" "[]" True False | jq -r '.reasons[0]|contains("Forderung")')" "true" \
   "B2b und der Grund nennt die Forderung, nicht die Spur"

# B3: beide Quellen fehlen → nicht erfasst, BEIDE Gruende stehen drin
ok "$(L5 "[]" "[]" "[]" False False | jq -r .light)" "nicht erfasst" "B3 beide Quellen fehlen"
ok "$(L5 "[]" "[]" "[]" False False | jq -r '.reasons|length')" "2" "B3b und beide Gruende stehen drin"

# B4/B5: session_trail end-to-end — der reale Fall aus dem Befund: der
# prompt-gate bricht VOR dem Anlegen der Forderungs-Datei ab (ungueltiger
# Arbeitsordner), der Trace-Hook prueft unabhaengig davon und schreibt
# trotzdem. Vorher: GRAU ("nichts noetig"). Jetzt: "nicht erfasst".
TMP2=$(mktemp -d)
mkdir -p "$TMP2/.claude/session-trace"
printf '{"turn":5,"tool":"Bash"}\n' > "$TMP2/.claude/session-trace/sB.jsonl"
# bewusst KEINE session-flags/sB-expected-skills-5 Datei angelegt
B4=$(python3 -c "
import json,sys
sys.path.insert(0, '$(dirname "$M")')
import skilltrail
from pathlib import Path
print(json.dumps(skilltrail.session_trail(Path('$TMP2'), 'sB')))
")
ok "$(echo "$B4" | jq -r '.[0].turn')" "5" "B4 Zug 5 erscheint (die Spur kennt ihn)"
ok "$(echo "$B4" | jq -r '.[0].light')" "nicht erfasst" \
   "B4b fehlende Forderungs-Datei macht den Zug nicht erfasst, nicht grau"

# Gegenprobe: dieselbe Sitzung, jetzt legt der prompt-gate seine (leere)
# Forderungs-Datei nachtraeglich an, UND audit-diff seine (leere) Behauptungs-
# Datei (seit Task 7b die dritte Pflichtquelle) — erst wenn alle drei
# Waechter (Spur, Forderung, Behauptung) etwas vorliegen haben, kann Zug 5
# zurueck auf grau kippen.
mkdir -p "$TMP2/.claude/session-flags"
: > "$TMP2/.claude/session-flags/sB-expected-skills-5"
: > "$TMP2/.claude/session-flags/sB-claimed-skills-5"
B5=$(python3 -c "
import json,sys
sys.path.insert(0, '$(dirname "$M")')
import skilltrail
from pathlib import Path
print(json.dumps(skilltrail.session_trail(Path('$TMP2'), 'sB')))
")
ok "$(echo "$B5" | jq -r '.[0].light')" "grau" "B5 leere aber vorhandene Forderungs-Datei bleibt grau"
rm -rf "$TMP2"

# --- Task 7b (Koordinator, 2026-07-31): die dritte Quelle bekommt einen
# Schreiber im Audit-Hook — vorher stand hier ersatzweise `claimed = ran`,
# das faerbte zwei der drei Rot-Regeln (2 und 3) permanent tot. Dieses
# Testfile ruft den Hook selbst nicht auf (nur skilltrail.py direkt), es
# liest lediglich die Dateien, die er schreibt.
T(){ python3 -c "
import json,sys
sys.path.insert(0, '$(dirname "$M")')
import skilltrail
from pathlib import Path
print(json.dumps(skilltrail.session_trail(Path('$1'), '$2')))
"; }

# B1: behauptet, aber nicht gelaufen -> rot, aus der DATEI gelesen
R="$TMP/repo2"; mkdir -p "$R/.claude/session-trace" "$R/.claude/session-flags"
printf '{"ts":"2026-07-31T10:00:00Z","turn":1,"tool":"Read"}\n' > "$R/.claude/session-trace/sB.jsonl"
: > "$R/.claude/session-flags/sB-expected-skills-1"
printf 'simplify\n' > "$R/.claude/session-flags/sB-claimed-skills-1"
ok "$(T "$R" sB | jq -r '.[0].light')" "rot" "B1 Behauptung ohne Lauf ist rot"

# B2: gelaufen, aber nicht genannt -> rot
printf '{"ts":"2026-07-31T10:00:00Z","turn":2,"tool":"Skill","skill_name":"simplify"}\n' \
  >> "$R/.claude/session-trace/sB.jsonl"
: > "$R/.claude/session-flags/sB-expected-skills-2"
: > "$R/.claude/session-flags/sB-claimed-skills-2"
ok "$(T "$R" sB | jq -r '.[1].light')" "rot" "B2 Lauf ohne Nennung ist rot"

# B3: fehlt die Datei ganz, ist die Behauptung NICHT ERFASST — und ein Zug darf
# davon nicht gruen werden. Sonst waere das Fehlen des Schreibers ein Freibrief.
printf '{"ts":"2026-07-31T10:00:00Z","turn":3,"tool":"Skill","skill_name":"simplify"}\n' \
  >> "$R/.claude/session-trace/sB.jsonl"
: > "$R/.claude/session-flags/sB-expected-skills-3"
ok "$(T "$R" sB | jq -r '.[2].light')" "nicht erfasst" "B3 ohne Behauptungs-Datei nichts bewiesen"

# B4: eine GUELTIGE, aber nicht-objektartige Zeile (`null`, `123`) kam durch den
# JSONDecodeError-Fang durch und warf dann einen AttributeError: /data brach ab,
# das JS verschluckte den Fehler, das Panel fror ein und sah dabei normal aus.
# Die Zeile ist kein Eintrag — die Auswertung laeuft weiter.
R2="$TMP/repo3"; mkdir -p "$R2/.claude/session-trace" "$R2/.claude/session-flags"
printf 'null\n123\n"text"\n[1,2]\n{"turn":1,"tool":"Read"}\n' > "$R2/.claude/session-trace/sC.jsonl"
: > "$R2/.claude/session-flags/sC-expected-skills-1"
: > "$R2/.claude/session-flags/sC-claimed-skills-1"
ok "$(T "$R2" sC | jq -r 'length')" "1" "B4 Nicht-Objekt-Zeilen stuerzen nicht ab"
ok "$(T "$R2" sC | jq -r '.[0].light')" "grau" "B4b und der echte Eintrag wird normal bewertet"

# --- C: Antwortzeit. Der Zeitstrahl wird alle 2 Sekunden abgerufen; die
# Schwelle des Entwurfs ist 500 ms. Gemessen an beispiel-repo (234 Sitzungen,
# 1852 Zuege, 3473 Zettel im Flag-Ordner): 1479 ms, davon 84 ms echte
# Auswertung — der Rest war dieselbe Verzeichnis-Listung, 468 Mal wiederholt
# (zwei Praefixe je Sitzung). Die frueher gemessenen 333 ms liefen OHNE
# eingelocktes Repo, also im einzigen Modus, in dem der Zeitstrahl nichts
# anzeigt und session_trail() gar nicht laeuft.
#
# C1/C2 pruefen die URSACHE deterministisch (Zahl der Listungen), C3 misst.
PERF="$TMP/perf"
python3 -c "
import sys
from pathlib import Path
r = Path('$PERF')
(r/'.claude'/'session-trace').mkdir(parents=True)
(r/'.claude'/'session-flags').mkdir(parents=True)
for i in range(200):
    (r/'.claude'/'session-trace'/('s%d.jsonl' % i)).write_text('{\"turn\":1,\"tool\":\"Read\"}\n')
    for t in range(1, 9):
        (r/'.claude'/'session-flags'/('s%d-expected-skills-%d' % (i, t))).write_text('')
        (r/'.claude'/'session-flags'/('s%d-claimed-skills-%d' % (i, t))).write_text('')
"
COUNT(){ python3 -c "
import sys
sys.path.insert(0, '$(dirname "$M")')
from pathlib import Path
import skilltrail
calls = {'n': 0}
real = Path.iterdir
def counting(self):
    if self.name == 'session-flags':
        calls['n'] += 1
    return real(self)
Path.iterdir = counting
repo = Path('$PERF')
names = skilltrail.flag_file_names(repo) if '$1' == 'shared' else None
for i in range(5):
    skilltrail.session_trail(repo, 's%d' % i, flag_names=names)
print(calls['n'])
"; }
ok "$(COUNT shared)" "1" "C1 durchgereichte Namen: EINE Listung fuer 5 Sitzungen"
ok "$(COUNT eigen)" "5" "C2 ohne Durchreichen eine je Sitzung — nie zwei (Praefix-Schleife)"

MS=$(python3 -c "
import sys, time
sys.path.insert(0, '$(dirname "$M")')
from pathlib import Path
import skilltrail
repo = Path('$PERF')
sessions = sorted((repo/'.claude'/'session-trace').glob('*.jsonl'))
t = time.time()
names = skilltrail.flag_file_names(repo)
turns = sum(len(skilltrail.session_trail(repo, f.stem, flag_names=names)) for f in sessions)
ms = round((time.time() - t) * 1000)
print('%d %d' % (ms, turns))
")
ok "$(printf '%s' "$MS" | cut -d' ' -f2)" "1600" "C3 Fixture: 200 Sitzungen, 8 Zuege je Sitzung"
DUR=$(printf '%s' "$MS" | cut -d' ' -f1)
if [ "$DUR" -lt 500 ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: C3b Zeitstrahl ueber der 500-ms-Schwelle (${DUR} ms)"; fi

echo "skilltrail: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

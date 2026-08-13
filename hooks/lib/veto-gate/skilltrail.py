"""Wurde in diesem Auftrag ein Pflicht-Schritt ausgelassen?

Drei Quellen, die es alle schon gibt: was der prompt-gate GEFORDERT hat (seit
Baustein 0 mitgeschrieben), was die Spur als GELAUFEN führt, und was die
Kopfzeile BEHAUPTET hat. Rot ist, wo sie auseinanderfallen.

Die vierte Farbe trägt das Ganze: ein Zug ohne Spur-Datei ist NICHT grün.
Dasselbe gilt für die Forderungs-Datei — fehlt SIE (nicht bloß leer, ganz
weg), ist ebenso nichts bewiesen, auch wenn die Spur brav mitschrieb. Und
dasselbe gilt seit Task 7b für die Behauptungs-Datei (was die Kopfzeile der
Antwort sagte): fehlt sie, ist nicht erfasst, was behauptet wurde — auch
wenn Spur und Forderung beide brav dastehen. Drei Wächter, die unabhängig
voneinander ausfallen können (Fix-Runde 1, 2026-07-31: der prompt-gate hat
einen Abbruchweg VOR dem Anlegen der Datei; ein Zug kann also `traced=True`
und trotzdem ohne Forderungs-Datei dastehen — dieselbe Lücke gab es bis
Task 7b bei der Behauptung, nur ohne jeden Schreiber). Ein ausgefallener
Wächter darf nie wie ein zufriedener aussehen — das ist derselbe Befund,
den E5 an den Hooks gemacht hat (`hook-health.sh`, Signal LEERLAUF), jetzt
auf allen drei Seiten angewandt statt nur auf der Spur-Seite.
"""
import json
from pathlib import Path


def turn_light(demanded, ran, claimed, traced, demand_known=True, claimed_known=True):
    """Eine Ampel für einen Zug. `demanded` ist [(klasse, skill), …].

    Drei Wächter, drei getrennte Ausfälle: `traced=False` heißt, die
    Spur-Datei hat für diesen Zug keinen Eintrag — der Trace-Hook lief
    nicht. `demand_known=False` heißt, die Forderungs-Datei selbst FEHLT —
    der prompt-gate lief nicht oder brach vor dem Anlegen ab (Task 1 legt
    sie sonst IMMER an, auch leer). `claimed_known=False` heißt, die
    Behauptungs-Datei FEHLT — audit-diff schrieb sie nicht (z.B. weil sich
    die Kopfzeile gar nicht weit genug parsen ließ, um ein Tools-Feld zu
    extrahieren). Keiner dieser drei Ausfälle ist dasselbe wie eine leere
    Liste: eine vorhandene, aber leere Datei ist eine gültige Aussage
    ("geprüft, nichts gefordert/behauptet") und bleibt grau/grün fähig —
    Fehlen heißt "nicht erfasst" (Standard-Werte `demand_known=True`,
    `claimed_known=True` halten bestehende Aufrufer unverändert, die diese
    Dateien gar nicht extra prüfen).
    """
    missing = []
    if not traced:
        missing.append("keine Spur-Datei für diesen Zug — der Trace-Hook "
                        "lief nicht oder schrieb nicht")
    if not demand_known:
        missing.append("keine Forderungs-Datei für diesen Zug — der "
                        "prompt-gate lief nicht oder brach vor dem Anlegen ab")
    if not claimed_known:
        missing.append("keine Behauptungs-Datei für diesen Zug — "
                        "audit-diff schrieb sie nicht")
    if missing:
        # Ohne eine der beiden Quellen ist NICHTS bewiesen — auch nicht das
        # Gute. Beide Lücken benannt, falls beide zutreffen: es sind zwei
        # verschiedene Wächter, kein gemeinsamer Grund.
        return {"light": "nicht erfasst", "reasons": missing}
    reasons = []
    ran_set, claimed_set = set(ran), set(claimed)
    # 1. ausgelassen — NUR `critical`. Immer-Pflicht-Skills färben bewusst
    #    nicht (owner 2026-07-30): sie gelten in jedem Zug, und ein Alarm, der
    #    immer leuchtet, wird überlesen.
    for klasse, skill in demanded:
        if klasse == "critical" and skill not in ran_set:
            reasons.append("Pflicht-Skill '%s' war gefordert und lief nie" % skill)
    # 2. behauptet, nicht gelaufen
    for s in sorted(claimed_set - ran_set):
        reasons.append("'%s' stand in der Kopfzeile, fehlt aber in der Spur" % s)
    # 3. gelaufen, nicht genannt
    for s in sorted(ran_set - claimed_set):
        reasons.append("'%s' lief, stand aber nicht in der Kopfzeile" % s)
    if reasons:
        return {"light": "rot", "reasons": reasons}
    # Abweichung vom Brief-Wortlaut (dokumentiert, siehe task-7-report.md):
    # `if demanded or ran_set or claimed_set` allein macht A5 rot... nein,
    # gruen — und der Brief-eigene Test A5 verlangt grau. Ein rein aus
    # Immer-Pflicht bestehendes `demanded` (nichts lief, nichts wurde
    # behauptet) ist KEIN Zeichen von Aktivität; es steht in JEDEM Zug so
    # da. Nur `critical`/`soft`-Forderungen zaehlen hier als "es wurde
    # etwas gefordert" — sonst faerbt ein Zug ohne jede Aktivität gruen,
    # nur weil die Immer-Pflicht-Zeile in der Datei stand.
    demanded_beyond_always = [d for d in demanded if d[0] != "always"]
    if demanded_beyond_always or ran_set or claimed_set:
        return {"light": "gruen", "reasons": []}
    # Nichts gefordert (ausser Immer-Pflicht), nichts gelaufen, nichts
    # behauptet. Kein Fehler — und es darf auch nicht wie einer aussehen.
    return {"light": "grau", "reasons": []}


def _read_demanded(repo: Path, session_id: str, turn: int):
    """Liest `<klasse>\\t<skill>`-Zeilen aus der Task-1-Datei.

    Gibt `(demanded, demand_known)` zurück. Task 1 legt die Datei
    BEDINGUNGSLOS an, auch leer ("geprüft, nichts gefordert") — genau
    deshalb ist eine leere Datei etwas anderes als eine fehlende: fehlt sie
    ganz, hat der prompt-gate diesen Zug gar nicht erreicht (z.B. sein
    Abbruchweg bei ungültigem Arbeitsordner, der VOR dem Anlegen aussteigt),
    und `demand_known=False` sagt das nach außen weiter, statt eine leere
    Forderung vorzutäuschen, die niemand geprüft hat. Jeder Lesefehler
    (fehlt, kein Zugriff, …) zählt hier gleich: wir wissen nicht, was
    gefordert war.
    """
    path = repo / ".claude" / "session-flags" / ("%s-expected-skills-%d" % (session_id, turn))
    try:
        text = path.read_text()
    except OSError:
        return [], False
    demanded = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t", 1)
        if len(parts) != 2:
            continue
        demanded.append((parts[0], parts[1]))
    return demanded, True


def _read_claimed(repo: Path, session_id: str, turn: int):
    """Liest die Kopfzeilen-Behauptung aus der audit-diff-Datei (Baustein 4).

    Gibt `(claimed, claimed_known)` zurück — genau dasselbe Paar-Muster wie
    `_read_demanded`. audit-diff.sh legt die Datei nur an, wenn sich die
    Kopfzeile weit genug parsen ließ, um ein Tools-Feld herauszuziehen
    (siehe dort); fehlt sie, ist NICHT erfasst, was behauptet wurde — auch
    wenn Spur und Forderung beide vorliegen. Eine LEERE Datei ist dagegen
    eine gültige Aussage: "die Kopfzeile nannte keinen Skill".
    """
    path = repo / ".claude" / "session-flags" / ("%s-claimed-skills-%d" % (session_id, turn))
    try:
        text = path.read_text()
    except OSError:
        return [], False
    claimed = [line.strip() for line in text.splitlines() if line.strip()]
    return claimed, True


def _read_trace(repo: Path, session_id: str) -> dict:
    """Liest die Spur-Datei einmal, gruppiert Skill-Läufe je Zug und merkt
    sich, welche Züge überhaupt EINEN Eintrag haben (das UND NICHTS ANDERES
    ist `traced`, wörtlich nach Brief)."""
    path = repo / ".claude" / "session-trace" / ("%s.jsonl" % session_id)
    ran_by_turn: dict = {}
    traced_turns: set = set()
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return {"ran_by_turn": ran_by_turn, "traced_turns": traced_turns}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            # Eine kaputte Zeile darf die ganze Auswertung nicht zum Absturz
            # bringen — das Modul liest nur, es urteilt nicht über den
            # Schreiber. Sie zählt schlicht nicht als Eintrag.
            continue
        if not isinstance(entry, dict):
            # `null` oder `123` sind GÜLTIGES JSON und kamen deshalb bis hierher
            # durch — `.get()` warf dann einen AttributeError, /data brach ab und
            # das JS verschluckte den Fehler: das Panel fror ein und sah dabei
            # normal aus. Eine Zeile ohne Objekt ist einfach kein Eintrag.
            continue
        turn = entry.get("turn")
        if not isinstance(turn, int):
            continue
        traced_turns.add(turn)
        if entry.get("tool") == "Skill":
            skill = entry.get("skill_name") or ""
            if skill:
                ran_by_turn.setdefault(turn, []).append(skill)
    return {"ran_by_turn": ran_by_turn, "traced_turns": traced_turns}


def flag_file_names(repo: Path) -> list:
    """Alle Dateinamen unter `<repo>/.claude/session-flags` — EINMAL gelesen.

    Gemessen 2026-07-31 an beispiel-repo (234 Sitzungen, 1852 Züge, 3473 Dateien in
    diesem Ordner): `session_trail` listete den Ordner ZWEIMAL je Sitzung, also
    468 Mal, und die Zeitstrahl-Abfrage dauerte 1479 ms — bei einem Abruf alle
    2 Sekunden. Die eigentliche Auswertung (Spur lesen, Forderung/Behauptung je
    Zug lesen) kostete davon 84 ms; der Rest war reines Wiederholen derselben
    Verzeichnis-Listung. Ein Aufrufer, der über viele Sitzungen DESSELBEN Repos
    geht, liest die Namen deshalb einmal und reicht sie durch.
    """
    d = repo / ".claude" / "session-flags"
    try:
        return [e.name for e in d.iterdir()]
    except OSError:
        return []


def session_trail(repo: Path, session_id: str, flag_names=None) -> list:
    """Eine Ampel je Zug für eine ganze Sitzung.

    Liest die drei Quellen, die die Interfaces-Zeile des Tasks nennt: die
    Task-1-Datei (gefordert — inklusive der Frage, ob sie überhaupt
    existiert, siehe `_read_demanded`), die Spur (gelaufen + ob überhaupt
    erfasst) und seit Task 7b die Behauptungs-Datei (was die Kopfzeile der
    Antwort behauptet hat, siehe `_read_claimed`). Bis Task 7b hatte die
    dritte Quelle KEINEN Schreiber — geprüft per grep über alle Hooks und
    alle sieben Briefs, keiner legte so eine Datei an — deshalb stand hier
    ersatzweise `claimed = ran`, was turn_light-Regel 2/3 (Kopfzeile vs.
    Spur) stumm schaltete. Jetzt schreibt `audit-diff.sh` die Datei direkt
    nach der Berechnung von `CLAIMED_SKILLS`, also liest session_trail sie
    genauso wie die Forderungs-Datei: vorhanden-aber-leer heißt "nichts
    behauptet", fehlend heißt "nicht erfasst" — Regel 2/3 greifen jetzt
    wieder echt.
    """
    trace = _read_trace(repo, session_id)

    turns = set(trace["traced_turns"])
    # `flag_names` darf durchgereicht werden (siehe flag_file_names): sonst
    # listet jede Sitzung denselben Ordner erneut. Und eine Runde je Name statt
    # eine je Präfix — der Ordner hat in einem echten Repo mehrere tausend
    # Einträge, die zweite Runde las sie alle ein zweites Mal.
    if flag_names is None:
        flag_names = flag_file_names(repo)
    prefixes = ("%s-expected-skills-" % session_id, "%s-claimed-skills-" % session_id)
    for name in flag_names:
        for prefix in prefixes:
            if name.startswith(prefix):
                suffix = name[len(prefix):]
                if suffix.isdigit():
                    turns.add(int(suffix))
                break

    trail = []
    for turn in sorted(turns):
        demanded, demand_known = _read_demanded(repo, session_id, turn)
        ran = trace["ran_by_turn"].get(turn, [])
        claimed, claimed_known = _read_claimed(repo, session_id, turn)
        traced = turn in trace["traced_turns"]
        light = turn_light(demanded, ran, claimed, traced,
                            demand_known=demand_known, claimed_known=claimed_known)
        trail.append({
            "turn": turn,
            "light": light["light"],
            "reasons": light["reasons"],
            "demanded": demanded,
            "ran": ran,
            "claimed": claimed,
        })
    return trail

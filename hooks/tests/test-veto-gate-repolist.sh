#!/usr/bin/env bash
# repolist: die Liste findet sich selbst — und weiss, was ein Worktree ist.
#
# Der Ordnername sagt NICHTS über das Repo (UL-002: beispiel-repo-compliance war
# ein Worktree von beispiel-repo). Wer 32 lokale Ordner flach listet, zeigt
# dasselbe Projekt zehnmal.
set -uo pipefail
M="$(cd "$(dirname "$0")/../lib/veto-gate" && pwd)/repolist.py"
P=0; F=0
ok(){ if [ "$1" = "$2" ]; then P=$((P+1)); else F=$((F+1)); echo "  FAIL: $3 (got '$1' want '$2')"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/haupt"; git -C "$TMP/haupt" init -q
git -C "$TMP/haupt" config user.email t@t.t; git -C "$TMP/haupt" config user.name t
echo x > "$TMP/haupt/a.txt"; git -C "$TMP/haupt" add -A; git -C "$TMP/haupt" commit -qm init
git -C "$TMP/haupt" worktree add -q -b zweig "$TMP/ableger" 2>/dev/null
mkdir -p "$TMP/keinrepo"

q(){ python3 -c "
import json,sys,pathlib
sys.path.insert(0, '$(dirname "$M")')
import repolist
print(json.dumps(repolist.local_repos(pathlib.Path('$TMP'))))
"; }

ok "$(q | jq -r '[.[].name]|sort|join(",")')" "ableger,haupt" "R1 nur echte Repos, kein keinrepo"
ok "$(q | jq -r '.[]|select(.name=="ableger")|.worktree_of')" "haupt" "R2 Worktree kennt seinen Hauptordner"
ok "$(q | jq -r '.[]|select(.name=="haupt")|.worktree_of')" "null" "R3 der Hauptordner ist keiner"

# R4: ein Ordner ohne Leserecht darf die ganze Liste nicht killen
mkdir -p "$TMP/zu"; chmod 000 "$TMP/zu"
ok "$(q | jq -r '[.[].name]|length')" "2" "R4 unlesbarer Ordner wird uebersprungen, nicht geworfen"
chmod 755 "$TMP/zu"

# GitHub: gepuffert, und ein Fehlschlag meldet seinen GRUND. "0 Repos" wäre
# eine Behauptung über etwas, das nicht geprüft werden konnte (UL-008).
GHFAKE="$TMP/gh"; printf '#!/bin/sh\nprintf %s "[{\\"name\\":\\"nurdort\\",\\"url\\":\\"https://github.com/x/nurdort\\"}]"\n' > "$GHFAKE"
chmod +x "$GHFAKE"
gq(){ python3 -c "
import json,sys,pathlib
sys.path.insert(0, '$(dirname "$M")')
import repolist
print(json.dumps(repolist.github_repos(pathlib.Path('$TMP/ghcache${2:-}.json'), gh_bin='$1')))
"; }

ok "$(gq "$GHFAKE" | jq -r '.repos[0].name')" "nurdort" "G1 GitHub-Liste gelesen"
ok "$(gq "$GHFAKE" | jq -r '.error')" "null" "G2 kein Fehler"
ok "$(test -f "$TMP/ghcache.json" && echo da || echo weg)" "da" "G3 Puffer angelegt"

# G4: fehlendes gh meldet den Grund, nicht "keine Repos". EIGENER Puffer-Pfad
# (nicht ghcache.json von G1-G3): der Puffer kennt nur ein Alter, kein
# gh_bin — gegen denselben frischen Puffer geprüft, läse G4 den Treffer aus
# G1 zurück und würde nie den fehlenden Pfad ausführen (belegt: isolierter
# Vorab-Lauf mit identischem Pfad blieb trotz /nonexistent/gh error:null).
ok "$(gq /nonexistent/gh 2 | jq -r '.error != null')" "true" "G4 fehlendes gh nennt den Grund"
ok "$(gq /nonexistent/gh 2 | jq -r '.repos|length')" "0" "G4b und behauptet keine Repos"

echo "repolist: PASS=$P FAIL=$F"; [ "$F" -eq 0 ]

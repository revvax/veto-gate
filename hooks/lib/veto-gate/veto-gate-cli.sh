#!/usr/bin/env bash
# veto-gate — dispatcher. `veto-gate [watch|--once]` = terminal; `veto-gate serve` = HTML.
set -uo pipefail
# resolve through the ~/.local/bin symlink to find the real script dir
SOURCE="${BASH_SOURCE[0]:-$0}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [ "${SOURCE#/}" = "$SOURCE" ] && SOURCE="$DIR/$SOURCE"
done
HERE="$(cd -P "$(dirname "$SOURCE")" && pwd)"
# HERE is computed AFTER symlink resolution: the dirname of the symlink itself
# would point at the wrong directory (codex find). The env-compat sourcing this
# note was once attached to is gone — the ordering rule is not.
case "${1:-watch}" in
  serve) shift; exec python3 "$HERE/serve.py" "$@";;
  install-precommit)
    # opt-in real git pre-commit (veto3 B6): catches every commit incl.
    # headless auto-sync. Never overwrites a FOREIGN hook (manual decision;
    # auto-chaining is deliberately not offered); own shim is idempotent.
    shift; R="${1:-$PWD}"
    HOOKS=$(git -C "$R" rev-parse --git-path hooks 2>/dev/null) || { echo "kein Git-Repo: $R" >&2; exit 1; }
    case "$HOOKS" in /*) ;; *) HOOKS="$R/$HOOKS";; esac
    DST="$HOOKS/pre-commit"
    # shell-safe path embedding (codex find: quotes/$()/backticks in the
    # install path could break the generated hook or execute foreign code)
    HERE_Q=$(printf '%q' "$HERE")
    SHIM=$(printf '#!/usr/bin/env bash\n# veto-gate pre-commit shim — installed by `veto-gate install-precommit`\nexec bash %s/pre-commit.sh "$@"' "$HERE_Q")
    # Ownership is proven by the EXACT content, never by a marker plus a line count: a foreign hook
    # that happens to mention the marker and call some pre-commit.sh matched the old heuristic and
    # would have been overwritten (codex). Somebody else's automation is not ours to delete.
    if [ -e "$DST" ] && [ "$(cat "$DST" 2>/dev/null)" != "$SHIM" ]; then
      echo "⛔ Es gibt schon einen fremden pre-commit-Hook: $DST — nicht überschrieben." >&2; exit 1
    fi
    # every install step must succeed or the installer fails LOUDLY —
    # reporting success without a working hook is worse than no install
    # (codex find)
    mkdir -p "$HOOKS" || { echo "⛔ Hook-Ordner nicht anlegbar: $HOOKS" >&2; exit 1; }
    printf '%s\n' "$SHIM" > "$DST" \
      || { echo "⛔ Hook nicht schreibbar: $DST" >&2; exit 1; }
    chmod +x "$DST" || { echo "⛔ Hook nicht ausführbar machbar: $DST" >&2; exit 1; }
    echo "veto-gate pre-commit installiert: $DST";;
  install-prepush)
    # The SECOND evidence stage. The commit checks only the tests of the changed files; this runs
    # the whole unit suite. Same rules as the pre-commit installer, and for the same reasons a
    # foreign hook is never overwritten and every step that fails, fails LOUDLY: an installer that
    # reports success without a working hook is worse than no installer at all.
    shift; R="${1:-$PWD}"
    HOOKS=$(git -C "$R" rev-parse --git-path hooks 2>/dev/null) || { echo "kein Git-Repo: $R" >&2; exit 1; }
    case "$HOOKS" in /*) ;; *) HOOKS="$R/$HOOKS";; esac
    DST="$HOOKS/pre-push"
    HERE_Q=$(printf '%q' "$HERE")
    SHIM=$(printf '#!/usr/bin/env bash\n# veto-gate pre-push shim — installed by `veto-gate install-prepush`\nexec bash %s/pre-push.sh "$@"' "$HERE_Q")
    # pre-rename wording is OURS too — upgrade in place (rename transition)
    # Ownership is proven by the EXACT content, never by a marker plus a line count (codex).
    if [ -e "$DST" ] && [ "$(cat "$DST" 2>/dev/null)" != "$SHIM" ]; then
      echo "⛔ Es gibt schon einen fremden pre-push-Hook: $DST — nicht überschrieben." >&2; exit 1
    fi
    mkdir -p "$HOOKS" || { echo "⛔ Hook-Ordner nicht anlegbar: $HOOKS" >&2; exit 1; }
    printf '%s\n' "$SHIM" > "$DST" \
      || { echo "⛔ Hook nicht schreibbar: $DST" >&2; exit 1; }
    chmod +x "$DST" || { echo "⛔ Hook nicht ausführbar machbar: $DST" >&2; exit 1; }
    echo "veto-gate pre-push installiert: $DST";;
  enable|disable)
    # per-repo switch. The three-liner this replaces (mkdir + echo > file) was
    # the last hand-written step of the install, and it silently CLOBBERED an
    # existing config: someone with max_lines/effort/prechecker set lost all of
    # it by following the README. So: merge into the existing object, never
    # replace it, and refuse to touch a file that is not valid JSON.
    ACT="$1"; shift
    [ "$ACT" = enable ] && VAL=true || VAL=false
    R="${1:-$PWD}"
    # written at the repo ROOT, not at $PWD: the gate reads
    # <cwd>/.claude/config/veto-gate.json, and a config parked in a subdirectory
    # is a switch that looks flipped and does nothing.
    ROOT=$(git -C "$R" rev-parse --show-toplevel 2>/dev/null) \
      || { echo "⛔ kein Git-Repo: $R — veto-gate hängt am Commit, ohne Repo gibt es nichts zu prüfen." >&2; exit 1; }
    CFGD="$ROOT/.claude/config"; CFG="$CFGD/veto-gate.json"
    # A `.claude` or `.claude/config` symlink routes this write OUT of the repo —
    # into a shared directory, or into a SECOND repo's config, silently flipped
    # by a command aimed at this one. Every path part that ALREADY exists is
    # checked BEFORE mkdir runs: refusing afterwards still leaves a directory
    # created at the foreign target (codex B01).
    REAL_ROOT=$(cd "$ROOT" && pwd -P) || exit 1
    for part in "$ROOT/.claude" "$CFGD"; do
      [ -e "$part" ] || continue
      RP=$(cd "$part" 2>/dev/null && pwd -P) || RP=""
      case "${RP:-/}/" in
        "$REAL_ROOT"/*) ;;
        *) echo "⛔ $part zeigt aus dem Repo heraus${RP:+ ($RP)} — nichts angelegt, nichts geschrieben." >&2
           echo "   Ein Link an dieser Stelle würde die Config eines fremden Ordners umschalten." >&2; exit 1;;
      esac
    done
    mkdir -p "$CFGD" || { echo "⛔ Ordner nicht anlegbar: $CFGD" >&2; exit 1; }
    # Read-modify-write under ONE held lock. Comparing the file before replacing
    # it only narrows the window; a lock closes it. python3 is required anyway,
    # and it is the only writer here that can hold a lock across the whole
    # read-merge-replace.
    LOCKD="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}/locks"
    python3 - "$CFG" "$VAL" "$LOCKD" <<'PY' || exit 1
import fcntl, hashlib, json, os, sys
cfg, want, lockd = sys.argv[1], sys.argv[2] == "true", sys.argv[3]
# The lock lives OUTSIDE the repo: a .lock next to the config is litter in
# somebody else's working tree, and the first thing they would do is commit it.
# Never unlinked — deleting a lock file lets the next two writers lock two
# different inodes and both believe they hold it (same reasoning as serve.py).
os.makedirs(lockd, exist_ok=True)
lock = os.path.join(lockd, hashlib.sha1(os.path.abspath(cfg).encode()).hexdigest() + ".lock")
with open(lock, "w") as lf:
    fcntl.flock(lf, fcntl.LOCK_EX)
    data = {}
    if os.path.exists(cfg):
        try:
            data = json.load(open(cfg))
        except (OSError, ValueError):
            data = None
        if not isinstance(data, dict):
            sys.exit(f"⛔ {cfg} ist kein gültiges JSON — nichts geändert. Erst von Hand reparieren.")
    data["enabled"] = want
    tmp = cfg + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, cfg)
PY
    if [ "$ACT" = enable ]; then
      echo "✓ veto-gate AN für $ROOT"
      command -v codex >/dev/null 2>&1 \
        || echo "⚠ codex-CLI fehlt — das Gate blockt sonst JEDEN Commit (fail-closed). Prüfen: veto-gate doctor"
    else
      echo "✓ veto-gate AUS für $ROOT"
    fi
    echo "  $CFG: $(jq -c '.' "$CFG")";;
  key)
    # store a provider API key from stdin — never echoed, never in argv.
    # umask only guards NEW files: an existing 0644 key file would keep its
    # open perms, so write a fresh 0600 temp and replace atomically.
    shift; PV="${1:-}"
    case "$PV" in groq|gemini) ;; *) echo "usage: veto-gate key groq|gemini" >&2; exit 64;; esac
    D="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}/keys"
    { mkdir -p "$D" && chmod 700 "$D"; } || { echo "⛔ Key-Ordner nicht anlegbar: $D" >&2; exit 1; }
    [ -t 0 ] && printf 'API-Schlüssel für %s (Eingabe unsichtbar): ' "$PV" >&2
    # restore terminal echo AND abort when the user cancels mid-input
    # (codex hint; qwen find: a bare restore would fall through to the
    # next line and re-hide the input instead of aborting)
    trap 'stty echo 2>/dev/null; echo >&2; exit 130' INT TERM
    stty -echo 2>/dev/null || true
    IFS= read -r K || K=""
    stty echo 2>/dev/null || true; trap - INT TERM; [ -t 0 ] && echo >&2
    [ -n "$K" ] || { echo "leer — nichts gespeichert" >&2; exit 1; }
    T=$(umask 177 && mktemp "$D/.$PV.key.XXXXXX") || { echo "⛔ Temp nicht anlegbar" >&2; exit 1; }
    # never print the key file path — CONVENTIONS: key files stay out of
    # messages/logs entirely (codex find)
    { printf '%s' "$K" > "$T" && chmod 600 "$T" && mv -f "$T" "$D/$PV.key"; } \
      || { rm -f "$T"; echo "⛔ Schlüssel für $PV nicht speicherbar" >&2; exit 1; }
    echo "gespeichert: Schlüssel für $PV (600) — Panel zeigt jetzt 'Schlüssel vorhanden'"
    # free tier is not technically enforceable — warn at store time (§10)
    echo "⚠ §10: Nur Free-Tier-Schlüssel verwenden. Gemini: Projekt OHNE Billing — sonst kostet jeder Aufruf Geld.";;
  doctor)
    # dependency self-check for a fresh install — a clear report, never a
    # silent "probably works". Missing a REQUIRED dep -> exit 1.
    OK=1
    check_required() {
      command -v "$1" >/dev/null 2>&1 \
        && echo "✓ $1 gefunden" \
        || { echo "✗ $1 FEHLT — Pflicht, ohne das läuft veto-gate nicht"; OK=0; }
    }
    check_required git
    check_required python3
    check_required jq
    # perl is REQUIRED, not a timeout fallback: grounding's A2 stage (invented
    # method calls) is pure perl and silently checks nothing without it, so a
    # "timeout OR perl" rule handed out an all-clear to a half-blind gate.
    check_required perl
    if [ "${BASH_VERSINFO[0]}" -lt 3 ]; then
      echo "✗ bash ${BASH_VERSINFO[0]}.x zu alt — Pflicht: bash 3 oder neuer"; OK=0
    else
      echo "✓ bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} (Pflicht: >=3)"
    fi
    # codex is the MAIN reviewer (codex-diff-review.sh); the qwen/groq/gemini
    # choice only covers the pre-checker. Without codex the gate fail-closes on
    # every commit — that install is unusable, not "alle da" (codex find).
    if command -v codex >/dev/null 2>&1; then
      echo "✓ codex-CLI gefunden"
    else
      echo "✗ codex-CLI FEHLT — das Gate blockt JEDEN Commit (fail-closed), bis codex installiert+eingeloggt ist"; OK=0
    fi
    # with-timeout.sh prefers `timeout` and falls back to perl-alarm. Since perl
    # is required above, a backend always exists — so this line is purely which
    # of the two is in use, never a reason to fail.
    if command -v timeout >/dev/null 2>&1; then
      echo "✓ timeout gefunden (schneller Pfad für Zeitbegrenzung)"
    else
      echo "ⓘ timeout fehlt (normal auf macOS) — perl übernimmt die Zeitbegrenzung"
    fi
    if [ "$OK" = 1 ]; then echo "→ Pflicht-Abhängigkeiten: alle da"; exit 0
    else echo "→ Pflicht-Abhängigkeiten: FEHLEN welche, s.o."; exit 1
    fi;;
  reasons)
    # What the deliberate bypasses said. Collecting and never reading is how the
    # last watcher rotted — 1058 findings sat unread in a .pending file for weeks
    # (UL-006) — so the reading is a command, not a promise to grep it someday.
    #
    # Everything printed here comes from outside — the ledger, which takes writes
    # from every caller of log-run.sh, and the environment. So ONE rule instead of
    # a filter per source: no control character leaves this command. Listing the
    # dangerous ones by hand is what missed the C1 range (U+0080–U+009F, invisible
    # terminal commands) after already missing the plain ones.
    scrub(){ jq -Rr 'gsub("\\p{C}";"")'; }
    LOG="${VETO_GATE_LOG_DIR:-$HOME/.claude/veto-gate}/runs.jsonl"
    if [ ! -s "$LOG" ]; then
      echo "Noch kein Protokoll unter $LOG — also kein Lauf und keine Umgehung." | scrub; exit 0
    fi
    # `fromjson?` skips a broken line instead of aborting: the ledger is appended
    # to by a hook that can be killed mid-write, so half a line is a normal event
    # and must never cost the report the other 999.
    #
    # ONE snapshot feeds both numbers. Read separately, a run landing between the
    # two reads makes the report contradict itself — in the worst case more
    # bypasses than runs, which reads like a bug in the gate instead of in here.
    SNAP=$(cat "$LOG" 2>/dev/null)
    TOTAL=$(printf '%s\n' "$SNAP" | jq -Rr 'fromjson? | "1"' 2>/dev/null | grep -c . || true)
    # The same rule inside a reason, with a SPACE as the replacement: a newline
    # is a control character too, and left standing it splits ONE bypass into two
    # counted lines — a report that claims more bypasses than runs.
    LIST=$(printf '%s\n' "$SNAP" | jq -Rr 'fromjson? | select(.result=="override")
      | (if has("reason")
         then (if .reason=="" then "«ohne Grund angegeben»" else .reason end)
         else "«vor dem Grund-Feld protokolliert»" end)
      | gsub("\\p{C}";" ")' 2>/dev/null)
    OVR=$(printf '%s' "$LIST" | grep -c . || true)
    PCT=0; [ "$TOTAL" -gt 0 ] && PCT=$(( OVR * 100 / TOTAL ))
    echo "Umgehungen: $OVR von $TOTAL Läufen ($PCT %)"
    echo "Das Protokoll hält nur die letzten 1000 Läufe — was älter ist, ist gelöscht."
    if [ "$OVR" = 0 ]; then echo "→ niemand ist am Gate vorbeigegangen."; exit 0; fi
    echo
    printf '%s\n' "$LIST" | grep -v '^$' | sort | uniq -c | sort -rn \
      | sed -E 's/^ *([0-9]+) /\1 ×  /'
    exit 0;;
  *)     exec bash "$HERE/watch.sh" "$@";;
esac

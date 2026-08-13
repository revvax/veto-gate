#!/usr/bin/env python3
"""veto-gate serve — localhost live dashboard for the veto-gate run log."""
import datetime, fcntl, json, os, secrets, sys, subprocess, threading, time, http.server, socketserver
import urllib.parse
from pathlib import Path

import repolist
import skilltrail


# The old VETO2_-prefixed fallback was dropped 2026-07-29 with the last dead
# setters. It had stopped being a kindness and become a trap: env-compat.sh was
# already gone, so a stale old-name variable left in someone's shell would have
# steered this server to one directory while every shell stage went to another —
# the exact thing the docstring below promises cannot happen.
def _env(name, default=None):
    """VETO_GATE_* only. Empty counts as unset — matching the shell scripts'
    ${X:-default}, so the CLI and the server resolve the same directories."""
    v = os.environ.get("VETO_GATE_" + name)
    return default if v is None or v == "" else v


def _default_log_dir():
    """The gate's data directory. One name, no fallback."""
    return Path.home() / ".claude" / "veto-gate"


def _cfg_path(d):
    """The repo's gate config. One name, so no caller can outlive a rename."""
    return Path(d) / ".claude" / "config" / "veto-gate.json"


LOG_DIR = Path(_env("LOG_DIR", str(_default_log_dir())))
LOG = LOG_DIR / "runs.jsonl"
FAVORITES_FILE = LOG_DIR / "favorites.json"
PORT = int(_env("PORT", "4003"))
# Ceiling on concurrent worker threads (see _Server). Generous for a personal
# dashboard, low enough that stalled connections cannot exhaust the machine.
MAX_CONNECTIONS = int(_env("MAX_CONNECTIONS", "64"))
HOST = _env("HOST", "127.0.0.1")  # set VETO_GATE_HOST=0.0.0.0 to expose on LAN
# per-start CSRF token: only the served page knows it; foreign tabs cannot
# read it cross-origin, so they cannot drive POST /toggle
TOKEN = secrets.token_hex(16)
# the account's GitHub repos (Task 5): a real gh call, so gh_bin needs a test
# double (never the real account, see repolist.github_repos). The TTL is
# settable for the same reason gh_bin is — a cache that only ever expires after
# 15 minutes cannot be exercised at all; no test uses it today, so this line
# says what it IS (a knob), not what someone might do with it.
GH_BIN = _env("GH_BIN", "gh")
GH_CACHE_TTL = int(_env("GH_CACHE_TTL", "900"))


def read_runs(limit=50):
    if not LOG.exists():
        return []
    out = []
    for line in LOG.read_text().splitlines()[-limit:]:
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def _registry_paths():
    """Raw registry paths from $VETO_GATE_LOG_DIR/repos.json {"repos": [paths]}."""
    f = LOG_DIR / "repos.json"
    if not f.exists():
        return []
    try:
        reg = json.loads(f.read_text())
    except (OSError, ValueError):
        return []
    paths = reg.get("repos", []) if isinstance(reg, dict) else []
    if not isinstance(paths, list):
        return []
    return [p for p in paths if isinstance(p, str) and p]


def _known_repo_paths():
    """Every path this server knows: the registry PLUS every git repo found
    under ~/Desktop. ONE source for the LIST and for resolving a NAME.

    Until 2026-07-31 the list came from both (read_repos) while resolution
    (_repo_path) still came from the registry alone. Measured on this machine:
    9 registry entries against 30 Desktop repos — 22 unregistered, 21 of them
    WITH their own trace files. For those _trail_for returned an empty list and
    the panel printed "noch keine Sitzungen aufgezeichnet": the server had never
    looked and reported a result anyway. The same gap hit every write path
    (/toggle, /config) as "not registered".
    """
    paths = list(_registry_paths())
    seen_real = {os.path.realpath(p) for p in paths}
    for r in repolist.local_repos(Path.home() / "Desktop"):
        real = os.path.realpath(r["path"])
        if real not in seen_real:   # same dir registered by hand AND found on Desktop: once
            paths.append(r["path"])
            seen_real.add(real)
    return paths


def _repo_path(name):
    """Resolve a repo NAME to its path, from _known_repo_paths(). Absolute
    paths never leave the server. Ambiguous names (two known paths with the
    same basename) return the sentinel string "ambiguous" — callers must
    refuse to act."""
    hits = [Path(p) for p in _known_repo_paths() if Path(p).name == name]
    if len(hits) > 1:
        return "ambiguous"
    return hits[0] if hits else None


def _prechecker(cfg):
    """Stage-2.5 reviewer choice. Must resolve exactly like the commit gate:
    an explicit valid value wins; legacy "qwen": false maps to none."""
    pc = cfg.get("prechecker")
    if pc in ("minimax", "groq", "gemini", "none"):
        return pc
    return "none" if cfg.get("qwen") is False else "minimax"


def _docs_status(name, runs):
    """The docs stage's note from the repo's most recent run — pass/skipped/
    unavailable + detail — so the panel shows whether codex got real docs or
    guessed. Only that ONE newest run counts: if it carries no docs proof
    (e.g. the diff never touched an external lib), report '-' rather than
    falling through to an older run's proof, which would look current when
    it is stale (codex find)."""
    for r in reversed(runs):
        if r.get("repo") != name:
            continue
        proofs = r.get("proofs")
        for p in (proofs if isinstance(proofs, list) else []):
            if isinstance(p, dict) and p.get("stage") == "docs":
                return {"status": str(p.get("status", "-")), "detail": str(p.get("detail", ""))}
        return {"status": "-", "detail": ""}
    return {"status": "-", "detail": ""}


def read_keys():
    """Presence only (bool) — key material never leaves the server. ONLY the
    key FILE counts (E3 plan review R3-B1): it is the single source both
    serve.py and the gate/adapter share; an env key in the server process
    says nothing about the git/gate process and would show a false
    'vorhanden'. Env keys stay an adapter test seam, not a panel signal."""
    d = LOG_DIR / "keys"
    return {p: (d / (p + ".key")).is_file() for p in ("groq", "gemini")}


def read_repos():
    """Registry repos, extended by every git repo auto-discovered under
    ~/Desktop, merged against the account's GitHub repos (Task 5).

    The registry was a hand-kept list — repolist.py's own docstring:
    10 entries, one dead since a repo move, against 32 real repos on
    Desktop. Anything already sitting under Desktop no longer needs a
    manual entry; the registry stays only for repos that live elsewhere.
    Matching a local repo to its GitHub counterpart happens by REMOTE URL
    (repolist.merge), never by folder name — a folder name lies (UL-002).

    Returns (repos, github_error): github_error is None on success, or the
    reason the GitHub side of the merge could not be checked (never
    silently "0 repos" — UL-008).
    """
    paths = _known_repo_paths()
    out = []
    for p in paths:
        cfg, d = {}, Path(p)
        cf = _cfg_path(d)
        try:
            cfg = json.loads(cf.read_text())
        except (OSError, ValueError):
            cfg = {}
        if not isinstance(cfg, dict):
            cfg = {}
        rsett = _read_json(d / ".claude" / "settings.json")
        try:
            skills_repo = sum(1 for q in (d / ".claude" / "skills").iterdir() if q.is_dir())
        except OSError:
            skills_repo = 0
        session_style = "-"
        try:
            flags = sorted((d / ".claude" / "session-flags").glob("*-answer-style"),
                           key=lambda q: q.stat().st_mtime)
            if flags:
                raw = flags[-1].read_text(errors="ignore")
                session_style = "".join(c for c in raw if c.islower())[:16] or "-"
        except OSError:
            pass
        # same default as the gate (.max_lines // 300); bool is an int
        # subclass and must not slip through as a line count
        ml = cfg.get("max_lines", 300)
        if not isinstance(ml, int) or isinstance(ml, bool):
            ml = 300
        # Angezeigt wird, was WIRKT: das Gate hebt einen zu kleinen Wert ohnehin
        # an und sagt es (veto-gate.sh VG_TIMEOUT_MIN/VG_TIMEOUT2_MIN, Task 6).
        # Ein Panel, das den rohen Konfig-Wert zeigt, widerspräche dem Lauf-
        # Protokoll. A non-int config value is not a fact (same guard as ml
        # above) and must not reach int() — that would crash /data instead of
        # falling back to the calibrated floor.
        tmo = cfg.get("timeout")
        tmo = tmo if isinstance(tmo, int) and not isinstance(tmo, bool) else 360
        tmo2 = cfg.get("timeout2")
        tmo2 = tmo2 if isinstance(tmo2, int) and not isinstance(tmo2, bool) else 420
        # kreisel_stop/plan_path (Task 6): same defaults as veto-gate.sh reads
        # (`.kreisel_stop // 4`, `.plan_path // "docs/superpowers/plans/"`), so
        # the panel never shows a different value than what the gate runs with.
        # An unusable stored value is not a fact either — it falls back to the
        # same default a missing key would, reusing _valid_config as the ONE
        # source of truth for what "usable" means (same value governs both the
        # write path and this display).
        ks = cfg.get("kreisel_stop")
        ks = ks if _valid_config("kreisel_stop", ks) else 4
        pp = cfg.get("plan_path")
        pp = pp if _valid_config("plan_path", pp) else "docs/superpowers/plans/"
        # sensitive_paths (Task 6): read-only in /data under the name
        # sensitive_extra — CONVENTIONS.md's baseline list is owner-approved and
        # ERGÄNZT (never replaced); non-string entries or a wrong-shaped value
        # are not a fact, so they read as "nothing extra" rather than crashing.
        sp = cfg.get("sensitive_paths")
        sensitive_extra = [s for s in sp if isinstance(s, str)] if isinstance(sp, list) else []
        # "path" travels through repolist.merge() below (it needs the repo's
        # remote URL) and is stripped again right after — absolute paths
        # never leave the server (LAN exposure would leak filesystem layout);
        # repos are addressed by name everywhere else.
        out.append({"name": d.name, "path": str(d), "worktree_of": repolist._worktree_parent(d),
                    "exists": d.exists(),
                    "enabled": bool(cfg.get("enabled", False)),
                    "effort": cfg.get("effort", "-"),
                    "max_lines": ml,
                    "plan_review": bool(cfg.get("plan_review", False)),
                    "prechecker": _prechecker(cfg),
                    "docs": bool(cfg.get("docs", True)),
                    "tests_allowed": _repo_in_allowlist(d),
                    "timeout": max(tmo, 360), "timeout2": max(tmo2, 420),
                    "kreisel_stop": ks, "plan_path": pp, "sensitive_extra": sensitive_extra,
                    "output_style": str(rsett.get("outputStyle", "-") or "-"),
                    "model": str(rsett.get("model", "-") or "-"),
                    "skills_repo": skills_repo, "session_style": session_style})
    gh = repolist.github_repos(LOG_DIR / "github.json", ttl_s=GH_CACHE_TTL, gh_bin=GH_BIN)
    merged = repolist.merge(out, gh)
    for m in merged:
        m.pop("path", None)
    return merged, gh["error"]


CLAUDE_DIR = Path(_env("CLAUDE_DIR", str(Path.home() / ".claude")))


def _valid_config(key, v):
    """Whitelist + type check for POST /config. Returns True only for
    writable keys with a value the gate can safely consume. 'enabled' stays
    on POST /toggle; timeout/timeout2 are data-calibrated and not writable.
    sensitive_paths has no write path here either (Task 6) — the baseline
    list is owner-approved (CONVENTIONS.md) and a panel that could replace it
    would lower review depth with one click; it stays read-only in /data.
    NB: returns a bool on purpose — plan_review False is a VALID falsy value,
    a validate-by-returning-the-value scheme would drop it. bool is an int
    subclass and must not pass as a line count."""
    if key == "effort":
        return v in ("low", "medium", "high")
    if key == "max_lines":
        return isinstance(v, int) and not isinstance(v, bool) and 50 <= v <= 2000
    if key == "plan_review":
        return isinstance(v, bool)
    if key == "prechecker":
        return v in ("minimax", "groq", "gemini", "none")
    if key == "docs":
        return isinstance(v, bool)
    if key == "tests":
        return isinstance(v, bool)
    if key == "kreisel_stop":
        # 0 = aus. Die Kreisel-Erkennung senkt nie die Prüf-Tiefe, sie warnt nur —
        # deshalb ist sie schaltbar, anders als timeout.
        return isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 20
    if key == "plan_path":
        # Ein Pfad, der aus dem Repo zeigt, würde beliebige .md als Plan
        # behandeln und den Prüfmodus auf fremde Dateien richten.
        return (isinstance(v, str) and v.endswith("/") and ".." not in v
                and not v.startswith("/") and len(v) <= 200)
    return False


def _allowlist_path():
    return Path(_env("TEST_ALLOWLIST",
                     str(Path.home() / ".claude" / "config" / "test-allowlist")))


def _repo_in_allowlist(repo_path):
    """Is the repo's canonical path a line in the global allow-list? Matches how
    run-tests.sh compares (pwd -P + grep -qxF)."""
    real = os.path.realpath(str(repo_path))
    try:
        return real in _allowlist_path().read_text().splitlines()
    except (OSError, ValueError):
        # ValueError catches UnicodeDecodeError too — the allowlist is external,
        # hand-editable state, and undecodable bytes must not crash /data (codex B2)
        return False


def _write_allowlist(repo_path, on):
    """Add or remove ONE repo line in the global allow-list, preserving the rest.
    A read-modify-write (unlike the whole-file config write), so it runs under
    an fcntl.flock lock: a second serve instance, a hand-edit or the gate must not
    drop a grant between our read and replace. Canonical path (os.path.realpath),
    because run-tests.sh matches pwd -P + grep -qxF. Returns True on success.

    The lock file is never unlinked after use — deliberately, not an oversight.
    Deleting it would open a classic flock TOCTOU race: process A releases the
    lock and unlinks the file; process B had already opened the OLD inode and
    is still waiting on it; process C opens the freshly-recreated path and
    locks the NEW inode uncontended. Two processes then believe they hold
    mutual exclusion on what are now two different inodes. The file is empty
    and holds no secret, so leaving it in place forever is the safe choice."""
    real = os.path.realpath(str(repo_path))
    p = _allowlist_path()
    lock = p.with_suffix(p.suffix + ".lock")
    try:
        # mkdir INSIDE the try (codex B1): a broken parent path (permission, or a
        # path component that turns out to be a plain file) must answer a clean
        # 409, not crash the request with an uncaught exception mid-response
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(lock, "w") as lf:
            # NON-BLOCKING with a bounded retry (~1s), not a plain blocking LOCK_EX
            # (qwen find): an unbounded lock would hang the request forever if any
            # process ever held it and stalled. Nothing in this system holds it long,
            # but a bounded wait can never deadlock. If it cannot be acquired in time,
            # answer a clean 409 instead of blocking — the write is never done blind.
            deadline = time.monotonic() + 1.0
            while True:
                try:
                    fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        return False
                    time.sleep(0.02)
            if p.exists():
                try:
                    lines = p.read_text().splitlines()
                except (OSError, ValueError):
                    # existing-but-unreadable/undecodable is NOT the same as
                    # missing (codex B1/B2): treating a read error as "empty"
                    # would then replace the whole file, wiping every other
                    # project's grant
                    fcntl.flock(lf, fcntl.LOCK_UN)
                    return False
            else:
                lines = []
            lines = [ln for ln in lines if ln != real]     # remove any existing, dedup
            if on:
                lines.append(real)
            tmp = p.with_suffix(p.suffix + ".tmp")
            tmp.write_text("".join(ln + "\n" for ln in lines))
            os.replace(tmp, p)
            fcntl.flock(lf, fcntl.LOCK_UN)
        return True
    except OSError:
        return False


# Panel writes are read-modify-write on whole JSON files. The server used to be
# single-threaded, which serialized them for free; since it threads requests
# (see _Server) every such cycle must hold this lock, or two concurrent clicks
# read the same config and the second write drops the first one's change.
# Cross-PROCESS safety is separate and unchanged: os.replace is atomic, and the
# allowlist/favorites paths additionally take their flock.
CONFIG_WRITE_LOCK = threading.RLock()


def _write_json_atomic(path, obj):
    """tmp + os.replace: a gate/pre-commit run reading configs per run must
    never see a half-written file (E3 plan review B3). Callers doing a
    read-modify-write cycle must hold CONFIG_WRITE_LOCK around the whole cycle.

    The scratch file is named per writer: a shared ".tmp" path let two writers
    use the same scratch file, so one could replace the target with the other's
    half-written bytes — that produced genuinely corrupt JSON, not just a lost
    update (demonstrated by the control run in test-serve-concurrency.py)."""
    tmp = path.with_suffix(path.suffix + ".tmp.%d.%d" % (os.getpid(), threading.get_ident()))
    try:
        tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)   # never leave scratch files behind
        raise


def read_favorites():
    """Set of favorited repo names. Missing/broken file -> empty set,
    same defensive contract as _registry_paths()."""
    try:
        obj = json.loads(FAVORITES_FILE.read_text())
    except (OSError, ValueError):
        return set()
    if not isinstance(obj, dict):
        return set()
    favs = obj.get("favorites")
    if not isinstance(favs, list):
        return set()
    return {f for f in favs if isinstance(f, str) and f}


def _write_favorite(name, on):
    """Add/remove ONE name in the favorites set, preserving the rest.
    Same bounded-flock contract as _write_allowlist, including its
    exists-vs-broken distinction: a file that exists but fails to parse
    is NOT the same as no file at all — treating it as empty would wipe
    every previously saved favorite on the next click."""
    p = FAVORITES_FILE
    lock = p.with_suffix(p.suffix + ".lock")
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(lock, "w") as lf:
            deadline = time.monotonic() + 1.0
            while True:
                try:
                    fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        return False
                    time.sleep(0.02)
            if p.exists():
                try:
                    obj = json.loads(p.read_text())
                except (OSError, ValueError):
                    fcntl.flock(lf, fcntl.LOCK_UN)
                    return False
                favs_list = obj.get("favorites") if isinstance(obj, dict) else None
                favs = {f for f in favs_list if isinstance(f, str) and f} if isinstance(favs_list, list) else set()
            else:
                favs = set()
            favs.discard(name)
            if on:
                favs.add(name)
            try:
                _write_json_atomic(p, {"favorites": sorted(favs)})
            finally:
                fcntl.flock(lf, fcntl.LOCK_UN)
        return True
    except OSError:
        return False


def _read_json(path):
    """External config files may be missing, broken, or wrong-shaped — never crash."""
    try:
        v = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return v if isinstance(v, dict) else {}


def read_global():
    """Global module state: answer style (triggers.json), model/output style
    (settings.json), global skill count."""
    trig = _read_json(CLAUDE_DIR / "triggers.json")
    sett = _read_json(CLAUDE_DIR / "settings.json")
    astyle = trig.get("answer_style")
    astyle = astyle if isinstance(astyle, dict) else {}
    gate = astyle.get("gate")
    gate = gate if isinstance(gate, dict) else {}
    try:
        skills = sum(1 for p in (CLAUDE_DIR / "skills").iterdir() if p.is_dir())
    except OSError:
        skills = 0
    return {"style": str(astyle.get("default", "-") or "-"),
            "style_gate": bool(gate.get("enabled", False)),
            "model": str(sett.get("model", "-") or "-"),
            "output_style": str(sett.get("outputStyle", "-") or "-"),
            "skills_global": skills}


BLOCK_RESULTS = ("codex-block", "grounding-block", "timeout-block",
                 "size-block", "cap-block", "minimax-block", "quota-block",
                 "groq-block", "gemini-block")


def _age_s(ts):
    try:
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        return int(time.time() - t.timestamp())
    except (ValueError, TypeError):
        return -1


def _int(x):
    """runs.jsonl is external input — numeric fields may be missing or mistyped."""
    try:
        return int(x)
    except (TypeError, ValueError):
        return 0


def read_live(max_age=600):
    """Running-marker files written by the commit gate; stale ones (crashed
    gates, clock skew) are ignored."""
    d = LOG_DIR / "running"
    out = []
    if not d.is_dir():
        return out
    for f in sorted(d.glob("gate-*.json")):
        try:
            m = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(m, dict):
            continue
        age = _age_s(m.get("ts", ""))
        if 0 <= age <= max_age:
            # whitelist fields — never forward unknown marker content to browsers
            out.append({"ts": str(m.get("ts", "")), "repo": str(m.get("repo", "")),
                        "branch": str(m.get("branch", "")), "files": _int(m.get("files", 0)),
                        "stage": str(m.get("stage", "")), "age_s": age})
    return out


def _details(r):
    """Flatten verdict/violations into display cards. Defensive: log entries
    are external input, wrong shapes must never crash /data."""
    out = []
    v = r.get("verdict")
    v = v if isinstance(v, dict) else {}
    for key, kind in (("blocking", "blocking"), ("non_blocking", "hinweis")):
        items = v.get(key)
        for b in items if isinstance(items, list) else []:
            if not isinstance(b, dict):
                continue
            out.append({"kind": kind, "id": str(b.get("id", "")),
                        "claim": str(b.get("claim", b.get("note", ""))),
                        "why": str(b.get("why", "")), "fix": str(b.get("fix", ""))})
    viols = r.get("violations")
    for viol in viols if isinstance(viols, list) else []:
        if not isinstance(viol, dict):
            continue
        sym = str(viol.get("symbol", "") or "")
        claim = ("Erfundenes Symbol: " + sym + " aus " + str(viol.get("import", ""))
                 if sym else "Erfundener Import/Pfad: " + str(viol.get("import", "")))
        out.append({"kind": "blocking", "id": str(viol.get("file", "")),
                    "claim": claim,
                    "why": "Der Code nutzt etwas, das es im Projekt nicht gibt.",
                    "fix": "Pfad/Import korrigieren."})
    return out


def _trail_for(name):
    """Task 8: der Zeitstrahl für EIN Repo — adressiert per NAME, wie jeder
    andere Zugriff hier (kein Pfad verlässt den Server).

    Gibt `(trail, error)` zurück. `error` ist None, wenn NACHGESEHEN werden
    konnte; sonst steht dort der Grund, warum nicht. Vorher lieferten beide
    Fälle dieselbe leere Liste, und das Panel schrieb darauf „noch keine
    Sitzungen aufgezeichnet" — eine Aussage über etwas, das nie geprüft wurde.
    Leer heißt jetzt wirklich leer.

    Eine Zeile je Sitzungsdatei unter <repo>/.claude/session-trace/*.jsonl,
    sortiert nach Dateiname (deterministisch), jede ausgewertet über
    skilltrail.session_trail() (Baustein 4)."""
    if not name:
        return [], None
    target = _repo_path(name)
    if target is None:
        return [], ("'%s' ist hier nicht auflösbar — weder in der Registry noch "
                    "als Git-Repo unter ~/Desktop. Ob Sitzungen aufgezeichnet "
                    "wurden, ist damit UNGEPRÜFT." % name)
    if target == "ambiguous":
        return [], ("'%s' ist mehrdeutig — mehrere bekannte Pfade tragen diesen "
                    "Ordnernamen, und welcher gemeint ist, steht nirgends. "
                    "Nichts geprüft." % name)
    if not target.is_dir():
        return [], ("Der Ordner von '%s' ist nicht (mehr) da — nichts zu lesen, "
                    "nichts geprüft." % name)
    trace_dir = target / ".claude" / "session-trace"
    if not trace_dir.is_dir():
        return [], None
    out = []
    # Die Namen der Zug-Zettel EINMAL je Repo lesen statt je Sitzung: gemessen
    # 2026-07-31 an beispiel-repo (234 Sitzungen, 3473 Zettel) 1479 ms → 195 ms,
    # bei einem Abruf alle 2 Sekunden (Schwelle des Entwurfs: 500 ms).
    # (Erste Fassung dieses Kommentars nannte 92 ms — das war der isolierte
    # Arbeits-Anteil VORHER, nicht der Gesamtwert danach. Eine Zahl, die besser
    # klingt als die Messung, ist genau der Fehler, gegen den dieser Bau läuft.)
    flag_names = skilltrail.flag_file_names(target)
    for f in sorted(trace_dir.glob("*.jsonl")):
        out.append({"session": f.stem,
                    "turns": skilltrail.session_trail(target, f.stem, flag_names=flag_names)})
    return out, None


def build_data(trail_repo=None):
    runs = read_runs(50)
    n = len(runs)
    blocked = sum(1 for r in runs if r.get("result") in BLOCK_RESULTS)
    avg = round(sum(_int(r.get("dur")) for r in runs) / n) if n else 0
    pct = round(blocked * 100 / n) if n else 0
    last = runs[-1] if runs else {}
    for i, r in enumerate(runs):
        res = str(r.get("result", ""))
        r["engine"] = ("codex" if res.startswith("codex") or res in ("timeout-block", "quota-block")
                       else "grounding" if res == "grounding-block"
                       else "minimax" if res == "minimax-block"
                       else "groq" if res == "groq-block"
                       else "gemini" if res == "gemini-block"
                       else "gate" if res in ("size-block", "cap-block") else "-")
        r["details"] = _details(r)
        # a block counts as resolved once a later pass lands on the same repo+branch
        r["resolved"] = any(
            s.get("result") == "codex-pass" and s.get("repo") == r.get("repo")
            and s.get("branch") == r.get("branch") for s in runs[i + 1:]
        ) if res in BLOCK_RESULTS else False
    found = sum(_int(r.get("blocking")) for r in runs if r.get("result") in BLOCK_RESULTS)
    resolved = sum(_int(r.get("blocking")) for r in runs
                   if r.get("result") in BLOCK_RESULTS and r["resolved"])
    fails = [r for r in runs if str(r.get("result", "")).startswith(("timeout", "fail-open"))]
    codex = {"ok": not (fails and runs and runs[-1] is fails[-1]),
             "last_fail_ts": str(fails[-1].get("ts", "")) if fails else "",
             "hint": "Letzter Codex-Kontakt scheiterte — Kontingent/Netz prüfen." if fails else ""}
    # B7: quota countdown — _read_json always yields a dict ({} on missing/
    # broken/non-dict file), so .get() is safe; elapsed windows report null
    quota = None
    q = _read_json(LOG_DIR / "quota.json")
    try:
        rem = int(q.get("reset_epoch", 0)) - int(time.time())
    except (TypeError, ValueError):
        rem = 0
    if rem > 0:
        quota = {"reset_at": str(q.get("reset_at", "?")), "remaining_s": rem}
    codex["quota"] = quota
    repos, github_error = read_repos()
    trail, trail_error = _trail_for(trail_repo)
    favs = read_favorites()
    for rp in repos:
        rp["docs_status"] = _docs_status(rp["name"], runs)
        rp["favorite"] = rp["name"] in favs
    repos.sort(key=lambda r: r["name"])
    repos.sort(key=lambda r: r["favorite"], reverse=True)
    return {"n": n, "blocked_pct": pct, "avg": avg,
            "last_ts": last.get("ts", ""), "last_thread": last.get("thread", ""),
            "found_total": found, "resolved_total": resolved,
            "live": read_live(), "repos": repos, "github_error": github_error,
            "global": read_global(), "keys": read_keys(), "codex": codex,
            # EINE Quelle für die Namen: die Liste steht hier, nicht im JS.
            # Ein Prüfer, der umbenannt wird (qwen → minimax), war sonst an
            # zwei Stellen zu ändern und wurde an einer vergessen.
            "prechecker_options": ["minimax", "groq", "gemini", "none"],
            "runs": list(reversed(runs))[:12],
            # nur für das EINGELOCKTE Repo (Task 8) — jede Sitzung jedes Repos bei
            # jedem 2s-Poll auszuwerten wäre teuer und liefert 99% ungesehene Daten.
            # trail_error trennt "nichts aufgezeichnet" von "gar nicht nachgesehen".
            "trail": trail, "trail_error": trail_error}


HTML = """<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Veto-Gate · Mission Control</title>
<style>
:root{color-scheme:dark}
body{background:#0b0f14;color:#cdd6e4;font:14px ui-monospace,Menlo,monospace;margin:0;padding:22px}
h1{color:#39d0d8;font-size:16px;letter-spacing:2px;margin:0 0 14px;text-shadow:0 0 12px #39d0d855}
#live{margin:0 0 14px;min-height:18px}
.cards{display:flex;gap:10px;flex-wrap:wrap;margin:0 0 14px}
.card{border:1px solid #1b2530;border-radius:8px;padding:10px 14px;min-width:180px}
.card .nm{color:#e6edf3}
.pill{display:inline-block;border-radius:14px;padding:8px 24px;font-size:16px;font-weight:700;letter-spacing:1px;cursor:pointer;margin:4px 0 12px 12px;vertical-align:middle}
.on{background:#3fb95022;color:#3fb950;border:1px solid #3fb950;box-shadow:0 0 16px #3fb95066}
.off{background:#5f6b7a22;color:#5f6b7a;border:1px solid #5f6b7a}
.meta{color:#5f6b7a;font-size:11px;margin-top:4px}
.oval{border:1px solid #1b2530;border-radius:999px;padding:8px 18px;cursor:pointer;
 display:inline-flex;align-items:center;gap:8px;user-select:none}
.oval.locked{border-color:#3fb950;box-shadow:0 0 10px #3fb95055}
.oval .dot-on{color:#3fb950}.oval .dot-off{color:#5f6b7a}
.wtgrp{display:inline-flex;flex-wrap:wrap;gap:10px;align-items:center;
 border-left:2px solid #1b2530;padding-left:10px}
.star{cursor:pointer;color:#5f6b7a;margin-right:2px}
.star.on{color:#d29922;text-shadow:0 0 8px #d2992266}
#settings{border:1px solid #1b2530;border-radius:8px;padding:12px 16px;margin:0 0 10px}
#msg{margin:0 0 14px;min-height:16px}
.row{margin:6px 0}
.opt{border:1px solid #1b2530;border-radius:10px;padding:1px 10px;cursor:pointer;margin-right:6px;display:inline-block}
.opt.sel{border-color:#3fb950;color:#3fb950}
.opt.dis{opacity:.45}
#settings input[type=number]{background:#0b0f14;color:#cdd6e4;border:1px solid #1b2530;width:80px;font:inherit;padding:2px 6px}
#settings input[type=text]{background:#0b0f14;color:#cdd6e4;border:1px solid #1b2530;width:220px;font:inherit;padding:2px 6px}
@media (max-width:700px){body{padding:10px}.oval{width:100%;justify-content:space-between;box-sizing:border-box}}
.trailrow{display:flex;align-items:center;gap:6px;margin:4px 0;flex-wrap:wrap}
.trailrow .sid{color:#5f6b7a;font-size:11px;min-width:90px}
.tbox{display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;
 border-radius:4px;cursor:pointer;font-size:12px;font-weight:700;border:1px solid #1b2530;flex:none}
.tbox.gruen{background:#3fb95033;color:#3fb950;border-color:#3fb950}
.tbox.rot{background:#f8514933;color:#f85149;border-color:#f85149}
.tbox.grau{background:#5f6b7a22;color:#5f6b7a;border-color:#5f6b7a}
.tbox.fehlt{background:repeating-linear-gradient(45deg,#0b0f14,#0b0f14 3px,#3a4553 3px,#3a4553 6px);
 color:#e6edf3;border:1px dashed #cdd6e4}
#trail-detail{border:1px solid #1b2530;border-radius:8px;padding:10px 14px;margin:6px 0 14px}
#trail-detail .cols{display:flex;gap:18px;flex-wrap:wrap;margin-top:4px}
#trail-detail .col{min-width:140px}
#trail-detail .col b{color:#e6edf3;display:block}
.stats{color:#9aa7b8;margin:0 0 16px}.stats b{color:#e6edf3}
.dot-codex{color:#d65ce6}.dot-ground{color:#39d0d8}.dot-idle{color:#5f6b7a}
.pass{color:#3fb950}.block{color:#f85149}.warn{color:#d29922}.empty{color:#5f6b7a}
.codexbad{color:#f85149}
table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:5px 12px;border-bottom:1px solid #1b2530;vertical-align:top}
th{color:#5f6b7a;font-weight:400;font-size:12px}
details.f{border-left:2px solid #f85149;margin:4px 0;padding-left:10px}
details.f.hinweis{border-left-color:#d29922}
details.f div{margin:2px 0;color:#9aa7b8}
details.f b{color:#e6edf3}
summary{cursor:pointer}
@keyframes pulse{50%{opacity:.4}}.pulse{animation:pulse 1.2s infinite}
</style></head><body>
<h1>&#9552;&#9552;&#9552; VETO-GATE &middot; MISSION CONTROL &#9552;&#9552;&#9552;</h1>
<div id="live"></div>
<div id="repos" class="cards"></div>
<button id="repos-toggle" class="opt" type="button"></button>
<div id="repos-rest" class="cards"></div>
<div id="ghinfo"></div>
<div id="settings"></div>
<div id="msg" class="codexbad"></div>
<div class="meta">Zeitstrahl &mdash; ein K&auml;stchen je Zug, rot ist eine L&uuml;cke in einer sonst gr&uuml;nen Reihe</div>
<div id="trail"></div>
<div id="trail-detail"></div>
<div class="stats" id="stats">&#8230;</div>
<table><thead><tr><th>Zeit</th><th>Repo</th><th>Branch</th><th>Pr&uuml;fer</th><th>Ergebnis</th><th>Funde</th><th>Dauer</th></tr></thead>
<tbody id="rows"></tbody></table>
<script>window.VETO_GATE_TOKEN="__VETO_GATE_TOKEN__";</script>
<script>
// All untrusted strings (repo names, branches, claims) are rendered via
// textContent — no data ever flows through innerHTML.
var RESULT_DE={'codex-pass':'\\u2714 sauber','codex-block':'\\u26D4 geblockt',
 'grounding-block':'\\u26D4 erfundener Import','grounding-infra-block':'\\u26D4 Grounding nicht lauffähig',
 'timeout-block':'\\u23F1 Prüfung unmöglich','fail-open-cap':'\\u26A0 zu groß, durchgelassen',
 'size-block':'\\u26D4 Diff zu groß','tests-block':'\\u26D4 Tests rot',
 'kreisel-stop':'\\uD83C\\uDF00 Kreisel gestoppt','minimax-block':'\\u26D4 Vorprüfer (minimax)',
 'groq-block':'\\u26D4 Vorprüfer (groq)','gemini-block':'\\u26D4 Vorprüfer (gemini)',
 'cap-block':'\\u26D4 Bündel über der Kappe','quota-block':'\\u23F1 Fenster zu',
 'claim-block':'\\u26D4 Behauptung ohne Beleg','proof-error':'\\u26D4 Beweis-Zettel kaputt',
 'proof-block':'\\u26D4 Stufe ohne Beweis','override':'\\u23ED bewusst übergangen'};
function el(tag,cls,text){var e=document.createElement(tag);if(cls)e.className=cls;if(text!==undefined)e.textContent=text;return e;}
function renderLive(d){var box=document.getElementById('live');box.replaceChildren();
 if(!d.live.length){box.appendChild(el('span','dot-idle','\\u25CF IDLE \\u2014 kein Lauf aktiv'));return;}
 d.live.forEach(function(m){var row=el('div');
  row.appendChild(el('span',(m.stage==='codex'?'dot-codex':'dot-ground')+' pulse','\\u25CF '+m.stage));
  row.appendChild(el('span','',' \\u203A '+m.repo+'/'+m.branch+' \\u00B7 '+m.files+' Datei(en) \\u00B7 seit '+m.age_s+'s'));
  box.appendChild(row);});}
var SEL=null;
function showMsg(t){var m=document.getElementById('msg');m.textContent=t||'';}
// all writes (/toggle, /style, /config) share ONE path — a failed write
// must be visible, never silent (plan review R1-B4 + R3-B3)
function send(path,body){fetch(path,{method:'POST',
 headers:{'X-Veto-Gate-Token':window.VETO_GATE_TOKEN,'Content-Type':'application/json'},
 body:JSON.stringify(body)}).then(function(resp){
  if(resp.ok){showMsg('');tick();return;}
  resp.json().then(function(e){showMsg('\\u26A0 nicht gespeichert ('+resp.status+'): '+(e.error||''));},
   function(){showMsg('\\u26A0 nicht gespeichert ('+resp.status+')');});
 },function(){showMsg('\\u26A0 Server nicht erreichbar');});}
function toggle(name){send('/toggle',{name:name});}
// takes the TARGET style — a toggle off the current value would save the
// wrong style when the current one is unknown ("-") (codex find)
function styleSwitch(style){send('/style',{style:style});}
function postCfg(name,key,value){send('/config',{name:name,key:key,value:value});}
function favorite(name,on){send('/favorite',{name:name,on:on});}
function repoOval(r){var o=el('span','oval'+(SEL===r.name?' locked':''));
 var star=el('span','star'+(r.favorite?' on':''),r.favorite?'\\u2605':'\\u2606');
 star.title=r.favorite?'Favorit entfernen':'Als Favorit markieren';
 star.addEventListener('click',function(ev){ev.stopPropagation();favorite(r.name,!r.favorite);});
 o.appendChild(star);
 o.appendChild(el('span','nm',r.name+(r.exists?'':' FEHLT')));
 o.appendChild(el('span',r.enabled?'dot-on':'dot-off','\\u25CF'));
 o.addEventListener('click',function(){SEL=(SEL===r.name)?null:r.name;tick();});
 return o;}
var REPOS_OPEN=localStorage.getItem('vg_repos_open')==='1';
// Welcher Hauptordner ist aufgeklappt. Gemessen 2026-07-31: 20 von 30 lokalen
// Repos sind Ableger (Worktrees) desselben Projekts — flach gelistet ist die
// Liste genau die unlesbare, die der Entwurf ausschliesst. Der Zustand lebt nur
// im Tab, wie SEL: der Server merkt sich nichts pro Browser.
var WT_OPEN={};
// Ein Ableger traegt SEINEN EIGENEN Gate-Zustand — gemessen: ein Hauptrepo
// scharf, sein Ableger aus, weil der Worktree eine eigene Konfig-Kopie hat.
// Deshalb bekommt jeder Ableger ein volles Oval, kein blosser Name.
function repoGroup(box,r,kids,d){
 box.appendChild(repoOval(r));
 var ks=kids[r.name]||[];
 if(!ks.length)return;
 var open=!!WT_OPEN[r.name];
 var t=el('span','opt',(open?'\\u25BE ':'\\u25B8 ')+ks.length+' Ableger');
 t.title='Worktrees von '+r.name+' \\u2014 jeder mit eigenem Gate-Zustand';
 t.addEventListener('click',function(){WT_OPEN[r.name]=!open;renderOvals(d);});
 box.appendChild(t);
 if(!open)return;
 var grp=el('span','wtgrp');
 ks.forEach(function(k){grp.appendChild(repoOval(k));});
 box.appendChild(grp);}
function renderOvals(d){
 var box=document.getElementById('repos');box.replaceChildren();
 var rest=document.getElementById('repos-rest');rest.replaceChildren();
 var g=el('span','oval'+(SEL==='GLOBAL'?' locked':''),'GLOBAL');
 g.addEventListener('click',function(){SEL=(SEL==='GLOBAL')?null:'GLOBAL';tick();});
 box.appendChild(g);
 // Ableger unter ihren Hauptordner einsortieren. `worktree_of` traegt den NAMEN
 // des Hauptordners (repolist liest ihn aus der .git-DATEI, nie aus dem
 // Ordnernamen — UL-002). git zeigt von dort immer auf das HAUPT-Repo, eine
 // Kette Ableger-eines-Ablegers kann also nicht entstehen.
 // Ein selbst angehefteter Ableger bleibt oben: eine Anheftung darf nicht durch
 // eine Gruppierung verschwinden.
 var known={};d.repos.forEach(function(r){known[r.name]=true;});
 var kids={},top=[];
 d.repos.forEach(function(r){
  var p=r.worktree_of;
  if(p&&p!==r.name&&known[p]&&!r.favorite){(kids[p]=kids[p]||[]).push(r);}
  else{top.push(r);}});
 var favs=top.filter(function(r){return r.favorite;});
 var others=top.filter(function(r){return !r.favorite;});
 favs.forEach(function(r){repoGroup(box,r,kids,d);});
 var btn=document.getElementById('repos-toggle');
 // gezaehlt werden ALLE Nicht-Favoriten, auch die eingeklappten — sonst
 // verschwaende die Zahl, wie viele Repos hier eigentlich liegen
 btn.textContent=(REPOS_OPEN?'\\u25BE ':'\\u25B8 ')+'Alle Repos ('+(d.repos.length-favs.length)+')';
 btn.onclick=function(){REPOS_OPEN=!REPOS_OPEN;localStorage.setItem('vg_repos_open',REPOS_OPEN?'1':'0');renderOvals(d);};
 rest.style.display=REPOS_OPEN?'flex':'none';
 others.forEach(function(r){repoGroup(rest,r,kids,d);});}
// Warum die GitHub-Spalte fehlt, muss IM Panel stehen. /data liefert den Grund
// seit Task 5, aber kein Skript las ihn: "gh fehlt", "nicht angemeldet" und
// "Zeitablauf" sahen im Panel alle aus wie "GitHub hat nichts". Genau das
// verbietet der Entwurf (UL-008: Abwesenheit ist nicht beweisbar).
function renderGithub(d){var box=document.getElementById('ghinfo');box.replaceChildren();
 if(!d.github_error)return;
 box.appendChild(el('div','warn','\\u26A0 GitHub nicht abrufbar: '+d.github_error+
  ' \\u2014 die Liste zeigt nur, was lokal liegt. Das hei\\u00dft NICHT "keine GitHub-Repos".'));}
function optRow(box,label,opts,cur,warn,mk){var row=el('div','row');
 row.appendChild(el('span','meta',label+' '));
 opts.forEach(function(v){var w=warn&&warn[v];
  // a missing key WARNS but never blocks the choice — the stage fails
  // open to codex, so selecting it is harmless (plan review R1-B1)
  var b=el('span','opt'+(v===cur?' sel':'')+(w?' dis':''),v+(w?' (Schl\\u00fcssel fehlt)':''));
  if(w)b.title='Schl\\u00fcssel fehlt \\u2014 Stufe f\\u00e4llt offen zu codex. Anlegen: veto-gate key '+v;
  b.addEventListener('click',function(){mk(v);});
  row.appendChild(b);});box.appendChild(row);}
function renderSettings(d){var box=document.getElementById('settings');
 // don't rebuild while typing in the max_lines field — the 2s poll would
 // steal focus and drop keystrokes
 if(box.contains(document.activeElement)&&document.activeElement.tagName==='INPUT')return;
 box.replaceChildren();
 if(!SEL){box.appendChild(el('span','empty','Oval anklicken = einlocken \\u2014 Einstellungen erscheinen hier.'));return;}
 if(SEL==='GLOBAL'){var g=d.global||{};
  box.appendChild(el('div','nm','GLOBAL'));
  optRow(box,'antwortstil',['klartext','friese'],g.style,null,function(v){
   if(v!==g.style)styleSwitch(v);});
  box.appendChild(el('div','meta','modell '+(g.model||'-')+' \\u00B7 output '+(g.output_style||'-')+' \\u00B7 skills '+(g.skills_global||0)+' \\u00B7 stil-w\\u00e4chter '+(g.style_gate?'AN':'AUS')));
  return;}
 var r=null;d.repos.forEach(function(x){if(x.name===SEL)r=x;});
 if(!r){SEL=null;return;}
 var head=el('div');head.appendChild(el('span','nm',r.name));
 var pill=el('span','pill '+(r.enabled?'on':'off'),r.enabled?'veto AN':'veto AUS');
 pill.addEventListener('click',function(){toggle(r.name);});
 head.appendChild(pill);box.appendChild(head);
 optRow(box,'pr\\u00fcfer (vorstufe)',(d.prechecker_options||['minimax','none']),r.prechecker,
  {groq:!(d.keys||{}).groq,gemini:!(d.keys||{}).gemini},function(v){postCfg(r.name,'prechecker',v);});
 // privacy consequence visible AT the choice, before any click (R3-B2)
 box.appendChild(el('div','meta','\\u2601 groq/gemini: Diff verl\\u00e4sst den Rechner (Gratis-Stufe darf mittrainieren) \\u00B7 minimax: bleibt lokal \\u00B7 codex: immer Endkontrolle'));
 optRow(box,'effort',['low','medium','high'],r.effort,null,function(v){postCfg(r.name,'effort',v);});
 optRow(box,'plan-pr\\u00fcfmodus',['AN','AUS'],r.plan_review?'AN':'AUS',null,function(v){
  postCfg(r.name,'plan_review',v==='AN');});
 optRow(box,'doku-stufe',['AN','AUS'],r.docs?'AN':'AUS',null,function(v){
  postCfg(r.name,'docs',v==='AN');});
 var ds=r.docs_status||{status:'-',detail:''};
 box.appendChild(el('div','meta','doku (letzter Lauf): '+ds.status+(ds.detail?' \\u2014 '+ds.detail:'')));
 optRow(box,'tests laufen lassen',['AN','AUS'],r.tests_allowed?'AN':'AUS',null,function(v){
  postCfg(r.name,'tests',v==='AN');});
 box.appendChild(el('div','meta','\\u26A0 f\\u00fchrt beim Commit den Testcode DIESES Projekts automatisch aus \\u2014 Freigabe liegt bewusst au\\u00dferhalb des Projekts'));
 var row=el('div','row');row.appendChild(el('span','meta','max_lines '));
 var inp=el('input');inp.type='number';inp.min=50;inp.max=2000;inp.step=10;inp.value=r.max_lines;
 var sv=el('span','opt','speichern');
 sv.addEventListener('click',function(){var n=parseInt(inp.value,10);
  if(n>=50&&n<=2000)postCfg(r.name,'max_lines',n);else showMsg('\\u26A0 max_lines: 50\\u20132000');});
 row.appendChild(inp);row.appendChild(sv);box.appendChild(row);
 // r.cloned===false (Task 5, GitHub-Repo ohne lokalen Klon) hat weder
 // timeout/timeout2 noch kreisel_stop/plan_path/sensitive_extra —
 // repolist.merge() liefert für diese Einträge absichtlich nur 5 Felder, es
 // gibt keine lokale Konfig, aus der ein Wert kommen könnte. "0" wäre eine
 // erfundene Zahl; "nicht hier" ist die ehrliche Aussage (derselbe Wortlaut
 // wie repolist.merge()'s Docstring: "nicht hier", nie "aus").
 if(r.kreisel_stop===undefined){box.appendChild(el('div','meta','kreisel_stop nicht hier'));}
 else{
  var krow=el('div','row');krow.appendChild(el('span','meta','kreisel_stop '));
  var kinp=el('input');kinp.type='number';kinp.min=0;kinp.max=20;kinp.step=1;kinp.value=r.kreisel_stop;
  var ksv=el('span','opt','speichern');
  ksv.addEventListener('click',function(){var n=parseInt(kinp.value,10);
   if(n>=0&&n<=20)postCfg(r.name,'kreisel_stop',n);else showMsg('\\u26A0 kreisel_stop: 0\\u201320');});
  krow.appendChild(kinp);krow.appendChild(ksv);box.appendChild(krow);
 }
 if(r.plan_path===undefined){box.appendChild(el('div','meta','plan_path nicht hier'));}
 else{
  var prow=el('div','row');prow.appendChild(el('span','meta','plan_path '));
  var pinp=el('input');pinp.type='text';pinp.value=r.plan_path;
  var psv=el('span','opt','speichern');
  psv.addEventListener('click',function(){postCfg(r.name,'plan_path',pinp.value);});
  prow.appendChild(pinp);prow.appendChild(psv);box.appendChild(prow);
 }
 var se=r.sensitive_extra;
 var sx=(se===undefined)?'nicht hier':(se.length?se.join(', '):'keine \\u2014 Standardliste gilt');
 box.appendChild(el('div','meta','heikle Pfade zus\\u00e4tzlich: '+sx+
  ' \\u2014 Standardliste bleibt IMMER aktiv, hier nicht ersetzbar'));
 var tl=(r.timeout===undefined)?'nicht hier':(r.timeout+' s / Nachrunde '+r.timeout2+' s');
 box.appendChild(el('div','meta','\\u23F1 Zeitlimit '+tl+
  ' \\u2014 datenkalibriert, hier bewusst nicht schaltbar'));
 box.appendChild(el('div','meta','stil '+(r.session_style||'-')+' \\u00B7 modell '+(r.model||'-')+' \\u00B7 skills '+(r.skills_repo||0)));}
function renderStats(d){var s=document.getElementById('stats');s.replaceChildren();
 if(!d.n){s.appendChild(el('span','empty','noch keine L\\u00e4ufe.'));return;}
 function stat(label,val,cls){s.appendChild(el('span','',label+' '));var b=el('b',cls||'',val);s.appendChild(b);s.appendChild(el('span','',' \\u00B7 '));}
 stat('L\\u00e4ufe(50):',d.n);stat('geblockt:',d.blocked_pct+'%');stat('\\u00D8',d.avg+'s');
 stat('gefunden:',d.found_total);stat('gelöst:',d.resolved_total,d.resolved_total>=d.found_total?'pass':'warn');
 s.title='gelöst = Näherung: späterer sauberer Lauf auf demselben Repo+Branch';
 s.appendChild(el('span',d.codex.ok?'dot-ground':'codexbad','codex '+(d.codex.ok?'\\u25CF ok':'\\u25CF gest\\u00f6rt')));
 if(!d.codex.ok&&d.codex.hint)s.appendChild(el('div','codexbad',d.codex.hint));
 if(d.codex.quota){var q=d.codex.quota,m=Math.floor(q.remaining_s/60),sec=q.remaining_s%60;
  s.appendChild(el('div','warn','\\u23F3 Codex-Fenster zu \\u2014 auf um '+q.reset_at+' (noch '+m+':'+String(sec).padStart(2,'0')+' min)'));}}
function renderRows(d){var tb=document.getElementById('rows');tb.replaceChildren();
 d.runs.forEach(function(r){var tr=el('tr');
  tr.appendChild(el('td','',r.ts?new Date(r.ts).toLocaleTimeString('de-DE',{hour12:false}):''));
  tr.appendChild(el('td','',r.repo||''));
  tr.appendChild(el('td','',(r.branch||'').slice(0,24)));
  tr.appendChild(el('td',r.engine==='codex'?'dot-codex':'dot-ground',r.engine||'-'));
  var rd=RESULT_DE[r.result];
  var res=el('td',rd?({'codex-pass':'pass'}[r.result]||((r.result||'').indexOf('block')>=0?'block':'warn')):'warn',
   rd||('\\u2753 unbekanntes Ergebnis: '+(r.result||'-')));
  if(r.resolved)res.appendChild(el('span','pass',' \\u2714 gel\\u00f6st'));
  else if((r.details||[]).length&&r.result!=='codex-pass')res.appendChild(el('span','warn',' \\u25CF offen'));
  tr.appendChild(res);
  var td=el('td');(r.details||[]).forEach(function(x){
   var de=el('details','f'+(x.kind==='hinweis'?' hinweis':''));
   de.appendChild(el('summary','','['+x.id+'] '+x.claim));
   if(x.why){var w=el('div');w.appendChild(el('b','','Warum: '));w.appendChild(document.createTextNode(x.why));de.appendChild(w);}
   if(x.fix){var f=el('div');f.appendChild(el('b','','Fix: '));f.appendChild(document.createTextNode(x.fix));de.appendChild(f);}
   td.appendChild(de);});
  if(!(r.details||[]).length)td.textContent=String(r.blocking||0);
  tr.appendChild(td);
  tr.appendChild(el('td','',(r.dur||0)+'s'));
  tb.appendChild(tr);});}
// Task 8: vier Ampeln, vier UNTERSCHEIDBARE Zeichen — nicht nur Farbe, damit
// eine schlecht sehende Person die Lücke genauso erkennt wie jede andere.
// 'fehlt' bekommt zusätzlich eine schraffierte Fläche statt einer Vollfarbe.
var LIGHT_CLASS={'gruen':'gruen','rot':'rot','grau':'grau','nicht erfasst':'fehlt'};
var LIGHT_SYMBOL={'gruen':'\\u2713','rot':'\\u2715','grau':'\\u2013','nicht erfasst':'?'};
var LIGHT_LABEL={'gruen':'gr\\u00fcn \\u2014 alles deckungsgleich',
 'rot':'rot \\u2014 etwas ausgelassen, behauptet-aber-nicht-gelaufen, oder gelaufen-aber-nicht-genannt',
 'grau':'grau \\u2014 in diesem Zug war nichts zu pr\\u00fcfen (kein Fehler)',
 'nicht erfasst':'nicht erfasst \\u2014 eine Quelle fehlt'};
function skillList(pairs){return (pairs||[]).map(function(p){return p[1]+' ('+p[0]+')';}).join(', ')||'\\u2014';}
function renderTrailDetail(sess,t){var box=document.getElementById('trail-detail');box.replaceChildren();
 box.appendChild(el('div','nm',sess+' \\u00B7 Zug '+t.turn+' \\u00B7 '+(LIGHT_LABEL[t.light]||t.light)));
 var cols=el('div','cols');
 function col(label,text){var c=el('div','col');c.appendChild(el('span','meta',label+':'));c.appendChild(el('b','',text));return c;}
 cols.appendChild(col('gefordert',skillList(t.demanded)));
 cols.appendChild(col('gelaufen',(t.ran||[]).join(', ')||'\\u2014'));
 cols.appendChild(col('behauptet',(t.claimed||[]).join(', ')||'\\u2014'));
 box.appendChild(cols);
 (t.reasons||[]).forEach(function(r){box.appendChild(el('div','meta','\\u2022 '+r));});}
function renderTrail(d){var box=document.getElementById('trail');box.replaceChildren();
 var dd=document.getElementById('trail-detail');
 if(!SEL||SEL==='GLOBAL'){dd.replaceChildren();
  box.appendChild(el('span','empty','Repo einlocken, um den Zeitstrahl zu sehen.'));return;}
 var r=null;d.repos.forEach(function(x){if(x.name===SEL)r=x;});
 // cloned:false (Task 5, GitHub-Repo ohne lokalen Klon) hat keine lokalen
 // Sitzungsdateien — das ist KEIN leeres Feld, sondern ein ehrlicher Satz
 if(!r||r.cloned===false){dd.replaceChildren();
  box.appendChild(el('span','empty','kein Zeitstrahl \\u2014 Repo ist nicht lokal geklont, keine Daten vorhanden.'));return;}
 // Konnte der Server gar nicht nachsehen, steht hier der GRUND. Ohne das las
 // sich "noch keine Sitzungen aufgezeichnet" wie ein Messergebnis, obwohl
 // nichts gemessen wurde — eine Luecke ist nie gruen und nie leer.
 if(d.trail_error){dd.replaceChildren();
  box.appendChild(el('span','warn','\\u26A0 '+d.trail_error));return;}
 var trail=d.trail||[];
 if(!trail.length){dd.replaceChildren();
  box.appendChild(el('span','empty','noch keine Sitzungen aufgezeichnet.'));return;}
 trail.forEach(function(s){var row=el('div','trailrow');
  row.appendChild(el('span','sid',s.session));
  (s.turns||[]).forEach(function(t){
   var cls=LIGHT_CLASS[t.light]||'fehlt';
   var b=el('span','tbox '+cls,LIGHT_SYMBOL[t.light]||'?');
   b.title='Zug '+t.turn+': '+(LIGHT_LABEL[t.light]||t.light);
   b.addEventListener('click',function(){renderTrailDetail(s.session,t);});
   row.appendChild(b);});
  box.appendChild(row);});}
async function tick(){try{
 var url='/data'+(SEL&&SEL!=='GLOBAL'?'?repo='+encodeURIComponent(SEL):'');
 var d=await(await fetch(url)).json();
 renderLive(d);renderOvals(d);renderGithub(d);renderSettings(d);renderStats(d);renderRows(d);renderTrail(d);}catch(e){}}
tick();setInterval(tick,2000);
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    timeout = 30   # drop half-open connections instead of pinning a thread forever

    def log_message(self, *a):
        pass

    def _send(self, body, ctype):
        b = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.startswith("/data"):
            # ?repo=NAME (Task 8): welches Repo gerade eingelockt ist, lebt nur im
            # Browser-Tab (SEL) — der Server erfährt es je Poll neu, statt es sich
            # zu merken (kein Server-Zustand pro Client, bleibt zustandslos wie /data selbst)
            query = urllib.parse.urlsplit(self.path).query
            repo = (urllib.parse.parse_qs(query).get("repo") or [""])[0]
            self._send(json.dumps(build_data(repo)), "application/json")
        else:
            self._send(HTML.replace("__VETO_GATE_TOKEN__", TOKEN), "text/html; charset=utf-8")

    def _send_json(self, code, obj):
        b = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _post_guards(self):
        """Shared write guards: localhost-only, per-start token, dict body.
        Returns the parsed body or None (error response already sent)."""
        # writes only from THIS machine — LAN viewers stay read-only, the
        # in-page token is no password for remote readers (B3)
        if self.client_address[0] not in ("127.0.0.1", "::1"):
            self._send_json(403, {"error": "writes only from localhost"}); return None
        if self.headers.get("X-Veto-Gate-Token", "") != TOKEN:
            self._send_json(403, {"error": "bad token"}); return None
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except (ValueError, TypeError):
            self._send_json(400, {"error": "bad body"}); return None
        if not isinstance(body, dict):
            self._send_json(400, {"error": "bad body"}); return None
        return body

    def do_POST(self):
        if self.path == "/style":
            self._post_style(); return
        if self.path == "/config":
            self._post_config(); return
        if self.path == "/favorite":
            self._post_favorite(); return
        if self.path != "/toggle":
            self._send_json(404, {"error": "not found"}); return
        body = self._post_guards()
        if body is None:
            return
        name = str(body.get("name", ""))
        target = _repo_path(name)
        if target is None:
            # not "not registered": since 2026-07-31 a repo under ~/Desktop needs
            # no registry entry, so the honest answer is that the NAME resolves
            # nowhere — the same source the list is built from (_known_repo_paths)
            self._send_json(403, {"error": "repo unknown (not in registry, not under ~/Desktop)"}); return
        if target == "ambiguous":
            self._send_json(409, {"error": "ambiguous name"}); return
        if not target.is_dir():
            # never create directories for stale/missing registry entries (B2)
            self._send_json(403, {"error": "repo dir missing"}); return
        cf = _cfg_path(target)
        # No timeout/timeout2 here. Writing 100/150 for a repo with no config
        # contradicted the panel's own promise that the timeout is not switchable,
        # and both numbers sit UNDER the calibrated floors (veto-gate.sh
        # VG_TIMEOUT_MIN=360 / VG_TIMEOUT2_MIN=420). It was harmless only because
        # the gate raises them again — a value that only survives by being
        # overruled has no business being written.
        cfg = {"enabled": False, "effort": "high"}
        with CONFIG_WRITE_LOCK:   # read-modify-write — see CONFIG_WRITE_LOCK
            if cf.exists():
                try:
                    loaded = json.loads(cf.read_text())
                except (OSError, ValueError):
                    loaded = None
                if not isinstance(loaded, dict):
                    # never clobber an existing-but-unreadable config (live-review B2)
                    self._send_json(409, {"error": "config unreadable"}); return
                cfg.update(loaded)
            cfg["enabled"] = not bool(cfg.get("enabled", False))
            try:
                cf.parent.mkdir(parents=True, exist_ok=True)
                _write_json_atomic(cf, cfg)
            except OSError:
                self._send_json(500, {"error": "write failed"}); return
        self._send_json(200, {"name": name, "enabled": cfg["enabled"]})

    def _post_config(self):
        """Whitelisted per-repo settings writes (E3 Task 3). Same repo
        resolution and fail-closed contract as /toggle: existing-but-broken
        configs are never clobbered (409)."""
        body = self._post_guards()
        if body is None:
            return
        key = body.get("key")
        val = body.get("value")
        if not _valid_config(key, val):
            self._send_json(400, {"error": "unknown key or bad value"}); return
        name = str(body.get("name", ""))
        target = _repo_path(name)
        if target is None:
            # not "not registered": since 2026-07-31 a repo under ~/Desktop needs
            # no registry entry, so the honest answer is that the NAME resolves
            # nowhere — the same source the list is built from (_known_repo_paths)
            self._send_json(403, {"error": "repo unknown (not in registry, not under ~/Desktop)"}); return
        if target == "ambiguous":
            self._send_json(409, {"error": "ambiguous name"}); return
        if not target.is_dir():
            self._send_json(403, {"error": "repo dir missing"}); return
        if key == "tests":
            if _write_allowlist(target, bool(val)):
                self._send_json(200, {"name": name, "tests_allowed": bool(val)})
            else:
                self._send_json(409, {"error": "allowlist write failed"})
            return
        cf = _cfg_path(target)
        # No timeout/timeout2 here. Writing 100/150 for a repo with no config
        # contradicted the panel's own promise that the timeout is not switchable,
        # and both numbers sit UNDER the calibrated floors (veto-gate.sh
        # VG_TIMEOUT_MIN=360 / VG_TIMEOUT2_MIN=420). It was harmless only because
        # the gate raises them again — a value that only survives by being
        # overruled has no business being written.
        cfg = {"enabled": False, "effort": "high"}
        with CONFIG_WRITE_LOCK:   # read-modify-write — see CONFIG_WRITE_LOCK
            if cf.exists():
                try:
                    loaded = json.loads(cf.read_text())
                except (OSError, ValueError):
                    loaded = None
                if not isinstance(loaded, dict):
                    # never clobber an existing-but-unreadable config
                    self._send_json(409, {"error": "config unreadable"}); return
                cfg.update(loaded)
            cfg[key] = val
            if key == "prechecker":
                # single source of truth for the stage choice — the legacy
                # "qwen" flag must not linger as a second, conflicting signal
                cfg.pop("qwen", None)
            try:
                cf.parent.mkdir(parents=True, exist_ok=True)
                _write_json_atomic(cf, cfg)
            except OSError:
                self._send_json(500, {"error": "write failed"}); return
        self._send_json(200, {"name": name, "key": key, "value": val})

    def _post_favorite(self):
        """Favorite/unfavorite a repo BY NAME. Same ambiguous-name guard
        as /toggle, but ONLY when turning a favorite ON: two registered
        paths can share a basename, and setting the favorite would
        attribute it to an undefined one of the two — refuse that,
        exactly like _repo_path()'s existing "ambiguous" contract for
        /toggle. Turning OFF is always safe regardless of ambiguity —
        removing a shared name from the set can't misattribute anything,
        and refusing it would leave a stray favorite impossible to clear."""
        body = self._post_guards()
        if body is None:
            return
        name = body.get("name")
        if not isinstance(name, str) or not name or len(name) > 200:
            self._send_json(400, {"error": "bad name"}); return
        on = body.get("on")
        if not isinstance(on, bool):
            self._send_json(400, {"error": "'on' must be true or false"}); return
        if on and _repo_path(name) == "ambiguous":
            self._send_json(409, {"error": "ambiguous name"}); return
        if _write_favorite(name, on):
            self._send_json(200, {"name": name, "favorite": on})
        else:
            self._send_json(409, {"error": "favorites write failed"})

    def _post_style(self):
        """Global answer-style switch (E2 Task 3). Writes ONLY an existing,
        readable triggers.json — a missing file means the style system is not
        set up and must not be invented here (fail-closed, E1-B2 pattern)."""
        body = self._post_guards()
        if body is None:
            return
        style = body.get("style")
        if style not in ("klartext", "friese"):
            self._send_json(400, {"error": "unknown style"}); return
        tf = CLAUDE_DIR / "triggers.json"
        if not tf.exists():
            self._send_json(409, {"error": "style system not set up"}); return
        with CONFIG_WRITE_LOCK:   # read-modify-write — see CONFIG_WRITE_LOCK
            try:
                obj = json.loads(tf.read_text())
            except (OSError, ValueError):
                obj = None
            if not isinstance(obj, dict):
                # never clobber an existing-but-unreadable config
                self._send_json(409, {"error": "triggers.json unreadable"}); return
            astyle = obj.get("answer_style")
            if astyle is not None and not isinstance(astyle, dict):
                # existing-but-wrong-shaped state is broken config — never
                # silently replaced (same 409 contract as the file level)
                self._send_json(409, {"error": "answer_style malformed"}); return
            astyle = astyle if isinstance(astyle, dict) else {}
            astyle["default"] = style
            obj["answer_style"] = astyle
            try:
                _write_json_atomic(tf, obj)
            except OSError:
                self._send_json(500, {"error": "write failed"}); return
        self._send_json(200, {"style": style})


class _Server(socketserver.ThreadingTCPServer):
    """Threaded on purpose: with a single-threaded TCPServer one client that opens
    a socket and never finishes its request blocks every other request until it
    times out — the dashboard window then just stays white (owner 2026-07-21).
    Regression test: test-serve-concurrency.py.

    Threads are capped: with VETO_GATE_HOST=0.0.0.0 the panel is reachable on the
    LAN, where a client could otherwise hold open thousands of connections (30s
    each) and exhaust memory. Over the cap we close new connections immediately
    instead of queueing a thread per socket."""

    allow_reuse_address = True
    daemon_threads = True   # don't keep the process alive for stalled connections

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._slots = threading.BoundedSemaphore(MAX_CONNECTIONS)

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            self.close_request(request)   # refuse cleanly; no thread is started
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._slots.release()   # no worker took ownership of the slot
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


def main():
    if "--data-once" in sys.argv:
        # kein HTTP-Request, also keine Query-String-Auswahl (s. do_GET) — dieselbe
        # Auswahl kommt hier aus einer VETO_GATE_*-Variable, wie jede andere
        # Server-Einstellung in dieser Datei (siehe _env)
        print(json.dumps(build_data(_env("TRAIL_REPO", ""))))
        return
    with _Server((HOST, PORT), Handler) as httpd:
        url = "http://localhost:%d" % PORT
        print("veto-gate serve → %s  (Ctrl-C beendet)" % url)
        if HOST != "127.0.0.1":
            print("  LAN: erreichbar auf http://<diese-mac-ip>:%d — offen im Netz!" % PORT)
        # Browser-Tab NUR auf ausdrücklichen Wunsch (VETO_GATE_OPEN=1). Default: NICHT öffnen.
        # Grund: der Serve-Test startet den Server viele Male; ein unbedingtes `open` spülte
        # dutzende Tabs auf (owner 2026-07-16). Wer den Tab will, setzt VETO_GATE_OPEN=1.
        if _env("OPEN") == "1":
            try:
                subprocess.Popen(["open", url])
            except Exception:
                pass
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()

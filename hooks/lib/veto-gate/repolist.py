"""Wer liegt hier eigentlich — ohne dass jemand es einträgt.

Die Registry war eine Liste von Hand: 10 Einträge, einer davon seit dem
Repo-Umzug am 2026-07-14 tot, gegen 32 Git-Repos auf dem Desktop. Eine Liste,
die gepflegt werden muss, ist am Tag ihrer Erstellung aktuell.

Worktrees werden ERKANNT, nicht geraten: bei einem Worktree ist `.git` eine
DATEI mit `gitdir: /pfad/zum/haupt/.git/worktrees/name` darin (UL-002). Der
Ordnername sagt nichts — `beispiel-repo-compliance` war ein Worktree von
`beispiel-repo` und vier Commits landeten im falschen Repo, weil niemand nachsah.
"""
import json
import subprocess
import time
from pathlib import Path


def _worktree_parent(entry: Path):
    """Hauptordner-NAME, wenn `entry` ein Worktree ist; sonst None."""
    dotgit = entry / ".git"
    if not dotgit.is_file():
        return None
    try:
        text = dotgit.read_text(errors="ignore")
    except OSError:
        return None
    for line in text.splitlines():
        if line.startswith("gitdir:"):
            p = line.split(":", 1)[1].strip()
            # …/haupt/.git/worktrees/name → …/haupt
            marker = "/.git/worktrees/"
            if marker in p:
                return Path(p.split(marker, 1)[0]).name
    return None


def local_repos(root: Path):
    """Jedes Git-Repo direkt unter `root`, Worktrees als solche markiert.

    Ein Ordner, der sich nicht lesen lässt, wird übersprungen — eine Liste,
    die an einem kaputten Eintrag ganz ausfällt, ist schlechter als eine, die
    ihn auslässt.
    """
    out = []
    try:
        entries = sorted(root.iterdir())
    except OSError:
        return out
    for entry in entries:
        try:
            if not entry.is_dir():
                continue
            dotgit = entry / ".git"
            if not (dotgit.is_dir() or dotgit.is_file()):
                continue
        except OSError:
            continue
        out.append({
            "name": entry.name,
            "path": str(entry),
            "worktree_of": _worktree_parent(entry),
        })
    return out


def github_repos(cache: Path, ttl_s: int = 900, gh_bin: str = "gh"):
    """Die Repos des angemeldeten Kontos, gepuffert.

    `gh` kostet Netz und kann hängen — deshalb Puffer mit Frist und ein
    Zeitlimit. Und deshalb meldet ein Fehlschlag seinen GRUND: „0 Repos" wäre
    eine Aussage über etwas, das nie geprüft wurde (UL-008).
    """
    try:
        age = time.time() - cache.stat().st_mtime
        if age < ttl_s:
            return json.loads(cache.read_text())
    except (OSError, ValueError):
        pass
    try:
        raw = subprocess.run(
            [gh_bin, "repo", "list", "--limit", "200", "--json", "name,url"],
            capture_output=True, text=True, timeout=20, check=True,
        ).stdout
        repos = json.loads(raw)
        if not isinstance(repos, list):
            raise ValueError("unerwartete Antwort")
        out = {"repos": [{"name": r.get("name", ""), "url": r.get("url", "")}
                         for r in repos if isinstance(r, dict)], "error": None}
    except FileNotFoundError:
        return {"repos": [], "error": "gh nicht installiert"}
    except subprocess.TimeoutExpired:
        return {"repos": [], "error": "gh antwortet nicht (20 s)"}
    except (subprocess.CalledProcessError, ValueError, OSError) as e:
        return {"repos": [], "error": "gh nicht abrufbar: %s" % type(e).__name__}
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(out))
    except OSError:
        pass
    return out


def _remote_name(path: Path):
    """Repo-Name aus dem origin-URL — der Ordnername lügt (UL-002)."""
    try:
        url = subprocess.run(["git", "-C", str(path), "remote", "get-url", "origin"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    if not url:
        return None
    return url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git") or None


def merge(local, gh):
    """Lokale und GitHub-Repos zu EINER Liste. Ein GitHub-Repo ohne Klon ist
    `cloned: False` und nicht schaltbar — es gibt lokal keine Konfig-Datei, in
    die ein Schalter schreiben könnte. Der Zustand heißt „nicht hier", nie „aus".
    """
    out, seen = [], set()
    for r in local:
        rn = _remote_name(Path(r["path"])) or r["name"]
        seen.add(rn)
        out.append(dict(r, github=any(g["name"] == rn for g in gh.get("repos", [])),
                        cloned=True))
    for g in gh.get("repos", []):
        if g["name"] in seen:
            continue
        out.append({"name": g["name"], "path": None, "worktree_of": None,
                    "github": True, "cloned": False})
    return out

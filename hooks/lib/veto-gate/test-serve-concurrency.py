#!/usr/bin/env python3
"""Regression tests for serving the dashboard concurrently.

1. stalled client   — one rude client must not take the whole dashboard down
2. connection flood — more sockets than MAX_CONNECTIONS must not lock us out
3. config writes    — concurrent read-modify-write cycles must not lose changes

Background: serve.py used to run on a single-threaded socketserver.TCPServer,
so one client that opened a socket and never finished its request pinned the
server until it timed out — the app window then just stayed white. Threading
fixes that but removes the free serialization panel writes relied on, hence
test 3. Run: python3 test-serve-concurrency.py
"""

import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVE = os.path.join(HERE, "serve.py")
BUDGET = 3.0        # a healthy request must answer well inside this
CAP = 4             # MAX_CONNECTIONS used by the flood test
FLOOD = 12          # sockets opened against a cap of CAP

failures = []


def check(ok, passed_msg, failed_msg):
    if ok:
        print("  ✓ %s" % passed_msg)
    else:
        print("  ✗ %s" % failed_msg)
        failures.append(failed_msg)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_until_up(port, timeout=15.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=2):
                return True
        except (urllib.error.URLError, OSError):
            time.sleep(0.2)
    return False


def start_server(**extra_env):
    port = free_port()
    env = dict(os.environ, VETO_GATE_PORT=str(port), PORT=str(port), **extra_env)
    proc = subprocess.Popen(
        [sys.executable, SERVE], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return proc, port


def stop_server(proc):
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


def get_ok(port, budget=BUDGET):
    """(succeeded, seconds) for one GET / against the server."""
    start = time.time()
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=budget) as r:
            return r.status == 200, time.time() - start
    except Exception:
        return False, time.time() - start


def test_stalled_client():
    print("Test 1: hängender Client blockiert den Server nicht")
    proc, port = start_server()
    try:
        if not wait_until_up(port):
            check(False, "", "Server kam auf Port %d nicht hoch" % port)
            return
        rude = socket.create_connection(("127.0.0.1", port), timeout=5)
        rude.sendall(b"GET / HTTP/1.1\r\n")   # no blank line — never completes
        ok, secs = get_ok(port)
        check(ok, "Antwort trotz hängendem Client nach %.2fs" % secs,
              "blockiert durch hängenden Client (%.2fs)" % secs)
        rude.close()
    finally:
        stop_server(proc)


def test_connection_flood():
    """Over the cap the server refuses new connections — that IS the protection,
    so being briefly unreachable under flood is correct. What must hold: the
    process survives, and it recovers as soon as the hogs let go (slots are
    returned, not leaked)."""
    print("Test 2: Verbindungsflut erschöpft den Server nicht (cap=%d)" % CAP)
    proc, port = start_server(VETO_GATE_MAX_CONNECTIONS=str(CAP))
    hogs = []
    try:
        if not wait_until_up(port):
            check(False, "", "Server kam auf Port %d nicht hoch" % port)
            return
        for _ in range(FLOOD):
            try:
                s = socket.create_connection(("127.0.0.1", port), timeout=2)
                s.sendall(b"GET / HTTP/1.1\r\n")
                hogs.append(s)
            except OSError:
                pass   # refused over the cap is the intended behaviour
        check(proc.poll() is None,
              "Prozess lebt nach %d Verbindungen" % len(hogs),
              "Prozess gestorben unter %d Verbindungen" % len(hogs))

        for s in hogs:
            try:
                s.close()
            except OSError:
                pass
        hogs = []

        recovered, secs = False, 0.0
        deadline = time.time() + 10
        while time.time() < deadline:
            recovered, secs = get_ok(port, budget=2.0)
            if recovered:
                break
            time.sleep(0.3)
        check(recovered,
              "nach Loslassen wieder erreichbar (%.2fs)" % secs,
              "bleibt gesperrt, Slots wurden nicht freigegeben")
    finally:
        for s in hogs:
            try:
                s.close()
            except OSError:
                pass
        stop_server(proc)


def test_config_write_lock():
    """Concurrent read-modify-write cycles must not lose changes.

    Exercises CONFIG_WRITE_LOCK + _write_json_atomic directly rather than
    through HTTP: the POST paths need a registry, a repo and a CSRF token,
    which would test the plumbing rather than the locking.
    """
    print("Test 3: gleichzeitige Config-Schreibvorgänge verlieren nichts")
    spec = importlib.util.spec_from_file_location("veto_serve", SERVE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    from pathlib import Path
    import contextlib
    workers = 16

    def run(guard):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "config.json"
            target.write_text("{}")

            def bump(i):
                try:
                    with guard():
                        cfg = json.loads(target.read_text())
                        time.sleep(0.002)      # widen the race window
                        cfg["key%d" % i] = i
                        mod._write_json_atomic(target, cfg)
                except Exception:
                    pass   # the unguarded control run is expected to blow up

            threads = [threading.Thread(target=bump, args=(i,)) for i in range(workers)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            try:
                return len(json.loads(target.read_text()))
            except (OSError, ValueError):
                return -1   # file ended up corrupt — worse than a lost update

    kept = run(lambda: mod.CONFIG_WRITE_LOCK)
    check(kept == workers,
          "alle %d Änderungen erhalten" % workers,
          "%d von %d Änderungen verloren" % (workers - kept, workers))

    # Control run: without the lock the same cycle must lose writes, otherwise
    # the test above proves nothing. Races are not guaranteed, so a surviving
    # control is reported as a warning rather than failing the suite.
    unguarded = run(contextlib.nullcontext)
    if unguarded == -1:
        print("  ✓ Gegenprobe ohne Sperre hinterlässt kaputte Datei — Sperre nötig")
    elif unguarded < workers:
        print("  ✓ Gegenprobe ohne Sperre verliert %d — Test misst den Unterschied"
              % (workers - unguarded))
    else:
        print("  ! Gegenprobe ohne Sperre verlor diesmal nichts — Aussagekraft unklar")


def main():
    test_stalled_client()
    test_connection_flood()
    test_config_write_lock()
    print("\nErgebnis: %s" % ("BESTANDEN" if not failures else "FEHLGESCHLAGEN"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

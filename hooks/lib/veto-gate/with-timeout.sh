#!/usr/bin/env bash
# with-timeout.sh — run a command with a hard wall-clock cap, portably.
# Linux/WSL ship GNU coreutils' `timeout`; macOS does not. Prefer `timeout`
# when present (one less process fork, no perl dependency); fall back to
# the perl-alarm trick (this file's only reason to exist) when it's missing.
#
# Usage: with_timeout <seconds> <cmd> [args...]
# Exit code: the wrapped command's own code on success; on a cap, GNU `timeout`
# gives 124 (TERM) or 137 (KILL) and the perl fallback gives 142 (SIGALRM) —
# every caller in this project already checks `rc >= 124`, so all backends
# satisfy it identically.

with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    # timeout's first move is a polite SIGTERM; a child that ignores TERM would
    # then run forever. -k arms the follow-up SIGKILL (GNU and BSD both take -k).
    timeout -k 5 "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

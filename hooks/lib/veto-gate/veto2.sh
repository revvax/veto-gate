#!/usr/bin/env bash
# veto2 — transitional alias for the renamed CLI (2026-07-17). Keep until
# the old command name is retired; all logic lives in veto-gate-cli.sh.
# Resolves symlinks first: an installed ~/.local/bin/veto2 pointing here
# must find the real script dir, not the symlink's dir (codex find).
SOURCE="${BASH_SOURCE[0]:-$0}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [ "${SOURCE#/}" = "$SOURCE" ] && SOURCE="$DIR/$SOURCE"
done
exec bash "$(cd -P "$(dirname "$SOURCE")" && pwd)/veto-gate-cli.sh" "$@"

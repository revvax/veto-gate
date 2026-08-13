#!/usr/bin/env bash
# veto-cfg.sh — resolve a repo's .claude/config/<file> even from a git WORKTREE.
#
# In some repos the veto configs are gitignored, so they physically exist ONLY
# in the main checkout — that is the case this lookup was built for. (In others
# they are versioned and a worktree gets its own copy; measured 2026-07-29 with
# git ls-files in four repos. The blanket claim that used to stand here was
# wrong, and a wrong reason is a bad guide to whether the mechanism is still
# needed.) A session working in a `git worktree add` tree found no config, and
# every veto hook exited 0 — silently, with no banner. A real project shipped 133
# unreviewed commits from its worktrees before this surfaced (2026-07-13).
#
#   veto_cfg <dir> <file>   → prints the config path (rc 0), or nothing (rc 1)
#
# Lookup order: the worktree's own config (an explicit per-worktree opt-out
# stays possible) → the main checkout the worktree belongs to.
#
# Callers keep their own CWD: the diff must come from the WORKTREE, only the
# CONFIG lookup falls back to the main checkout.

veto_cfg() {
  local dir="$1" name="$2" top common main cfg
  [ -n "$dir" ] && [ -n "$name" ] || return 1

  # path-based first — the gate's opt-in check runs over raw -C/cd candidates
  # that need not be repos at all, so a non-repo dir carrying a config still
  # resolves (codex find #20 keeps this check purely path-based).
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || top=""
  [ -n "$top" ] || top="$dir"
  cfg="$top/.claude/config/$name"
  [ -f "$cfg" ] && { printf '%s' "$cfg"; return 0; }

  # in a worktree --git-common-dir points at the MAIN repo's .git, elsewhere at
  # our own. --path-format needs git >= 2.31; older git prints it relative to
  # the queried dir.
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in /*) ;; *) common="$dir/$common";; esac
  case "$common" in */.git) main=${common%/.git};; *) return 1;; esac  # bare repo → no main checkout
  [ "$main" = "$top" ] && return 1                                     # not a worktree, already checked
  [ -d "$main" ] || return 1

  cfg="$main/.claude/config/$name"
  [ -f "$cfg" ] && { printf '%s' "$cfg"; return 0; }
  return 1
}

# veto_cfg_on <dir> <file> — true if that config exists AND has enabled:true
veto_cfg_on() {
  local c
  c=$(veto_cfg "$1" "$2") || return 1
  [ "$(jq -r '.enabled // false' "$c" 2>/dev/null)" = "true" ]
}

# veto_gate_cfg <dir> — the GATE's config path for that dir. No file name is
# passed in, and none may be written anywhere else.
#
# Why the name lives here and nowhere else: when the file was renamed
# (veto2.json -> veto-gate.json, 2026-07-17) three hooks kept asking for the old
# name, found nothing, treated the gate as OFF and exited 0 without a word. One
# was fixed; the other two stayed dead for eleven days. A caller that cannot name
# a file cannot outlive a rename — the class is gone, not the instance.
veto_gate_cfg() { veto_cfg "$1" veto-gate.json; }

# veto_cfg_sound <file> — the file contains EXACTLY ONE JSON object. jq -e
# 'type=="object"' alone accepts multi-document files whose later .enabled
# reads then return garbage (codex: two concatenated objects disarmed an
# armed gate) — soundness must mean one object, nothing else.
veto_cfg_sound() {
  [ "$(jq -rs 'length==1 and (.[0]|type=="object")' "$1" 2>/dev/null)" = "true" ]
}

# veto_gate_armed <dir> — true when the gate must treat <dir> as opted in.
# The EARLY target checks (hidden commits, -C/cd candidates) share this, so the
# opt-in question is answered in exactly one place.
veto_gate_armed() { veto_cfg_on "$1" veto-gate.json; }

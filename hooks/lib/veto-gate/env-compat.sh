#!/bin/bash
# env-compat.sh — transitional mapping VETO2_* -> VETO_GATE_* (rename 2026-07-17).
# Sourced by every entry point that reads gate env vars. New names always win —
# including a deliberately EMPTY new value (set-but-empty is a decision, not a
# gap). Old names are read-only fallbacks so unmerged sessions and muscle
# memory keep working. Remove this file (and its test) when the VETO2_* names
# are retired.
#
# bash 3.2, no arrays. One line per variable — the test derives the pair list
# from these lines and fails when the frozen inventory (34) is incomplete.
_vg_env_compat(){ # NEW OLD — copy OLD into NEW only when NEW is truly unset
  # `local` keeps the caller's namespace untouched; eval ONLY reads the fixed
  # variable name — the VALUE never passes through eval (a value containing
  # quotes/command chars must stay data). An old value that is SET but empty
  # carries over as empty: mirroring the old environment faithfully beats
  # letting a consumer default kick in behind the user's back.
  local ov
  eval "[ -n \"\${$1+x}\" ]" && return 0
  eval "[ -n \"\${$2+x}\" ]" || return 0
  eval "ov=\${$2:-}"
  export "$1=$ov"
  return 0
}
_vg_env_compat VETO_GATE_CAP VETO2_CAP
_vg_env_compat VETO_GATE_CLAIM_CWD VETO2_CLAIM_CWD
_vg_env_compat VETO_GATE_CLAUDE_DIR VETO2_CLAUDE_DIR
_vg_env_compat VETO_GATE_DIFFSIZE_BIN VETO2_DIFFSIZE_BIN
_vg_env_compat VETO_GATE_DISCORD_DRY_RUN VETO2_DISCORD_DRY_RUN
_vg_env_compat VETO_GATE_DOC_CACHE VETO2_DOC_CACHE
_vg_env_compat VETO_GATE_GEMINI_MAXBYTES VETO2_GEMINI_MAXBYTES
_vg_env_compat VETO_GATE_GEMINI_MODEL VETO2_GEMINI_MODEL
_vg_env_compat VETO_GATE_GEMINI_URL VETO2_GEMINI_URL
_vg_env_compat VETO_GATE_GROQ_MAXBYTES VETO2_GROQ_MAXBYTES
_vg_env_compat VETO_GATE_GROQ_MODEL VETO2_GROQ_MODEL
_vg_env_compat VETO_GATE_GROQ_URL VETO2_GROQ_URL
_vg_env_compat VETO_GATE_GROUNDING_BIN VETO2_GROUNDING_BIN
_vg_env_compat VETO_GATE_HOST VETO2_HOST
_vg_env_compat VETO_GATE_KREISEL_ROUNDS VETO2_KREISEL_ROUNDS
_vg_env_compat VETO_GATE_KREISEL_WINDOW VETO2_KREISEL_WINDOW
_vg_env_compat VETO_GATE_LOG_DIR VETO2_LOG_DIR
_vg_env_compat VETO_GATE_NO_PERL VETO2_NO_PERL
_vg_env_compat VETO_GATE_NO_PY VETO2_NO_PY
_vg_env_compat VETO_GATE_ON VETO2_ON
_vg_env_compat VETO_GATE_OPEN VETO2_OPEN
_vg_env_compat VETO_GATE_PORT VETO2_PORT
_vg_env_compat VETO_GATE_QWEN_MAXBYTES VETO2_QWEN_MAXBYTES
_vg_env_compat VETO_GATE_QWEN_MODEL VETO2_QWEN_MODEL
_vg_env_compat VETO_GATE_QWEN_TIMEOUT VETO2_QWEN_TIMEOUT
_vg_env_compat VETO_GATE_QWEN_URL VETO2_QWEN_URL
_vg_env_compat VETO_GATE_REMOTE_TIMEOUT VETO2_REMOTE_TIMEOUT
_vg_env_compat VETO_GATE_SKIP VETO2_SKIP
_vg_env_compat VETO_GATE_TEST_ALLOWLIST VETO2_TEST_ALLOWLIST
_vg_env_compat VETO_GATE_TEST_PORTS VETO2_TEST_PORTS
_vg_env_compat VETO_GATE_TEST_TIMEOUT VETO2_TEST_TIMEOUT
_vg_env_compat VETO_GATE_TIMEOUT VETO2_TIMEOUT
_vg_env_compat VETO_GATE_TIMEOUT2 VETO2_TIMEOUT2
_vg_env_compat VETO_GATE_TOKEN VETO2_TOKEN
unset -f _vg_env_compat 2>/dev/null || true

# legacy data fallback: an existing install keeps runs/keys/quota in
# ~/.claude/veto2 until the real migration runs. With LOG_DIR unset OR empty
# (consumer rule: an empty path is no storage location — CONVENTIONS.md) and
# ONLY the old dir on disk, point at it so the data stays findable and shell
# consumers agree with serve.py's _default_log_dir. Explicit non-empty values
# and fresh installs (new dir present, or neither dir) are untouched.
if [ -z "${VETO_GATE_LOG_DIR:-}" ] && [ -n "${HOME:-}" ] \
   && [ -d "$HOME/.claude/veto2" ] && [ ! -e "$HOME/.claude/veto-gate" ]; then
  export VETO_GATE_LOG_DIR="$HOME/.claude/veto2"
fi

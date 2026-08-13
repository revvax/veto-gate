#!/usr/bin/env bash
# boot.sh — one command that gets veto-gate onto a machine.
#
# It exists because the README used to ask for six steps (developer tools, jq,
# codex, clone, install, per-repo config) and people stopped at step two. This
# script does the fetching and the wiring; what it will NOT do is install things
# behind your back — every package it wants is named and confirmed first.
#
#   curl -fsSL https://raw.githubusercontent.com/revvax/veto-gate/main/boot.sh | bash
#
# Prefer reading before running (recommended): download it, read it, then run it.
set -uo pipefail

REPO_URL="${VETO_GATE_BOOT_SRC:-https://github.com/revvax/veto-gate.git}"
HOME_DIR="${VETO_GATE_HOME:-$HOME/.veto-gate}"

say()  { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

# Piped into bash, stdin is the script itself — a plain `read` would eat the
# rest of the source instead of waiting for a person. Ask the terminal directly,
# and when there is none (CI, a headless run), never assume yes.
ask() {
  local prompt="$1" reply=""
  # An unattended run must never stall on a prompt nobody will answer, and it
  # must never answer itself with yes: both cases end as "no, install it later".
  [ "${VETO_GATE_BOOT_NONINTERACTIVE:-0}" = 1 ] && { say "  → unattended, skipping: $prompt"; return 1; }
  [ -e /dev/tty ] || { say "  → not a terminal, skipping: $prompt"; return 1; }
  printf '%s [y/N] ' "$prompt" > /dev/tty
  IFS= read -r reply < /dev/tty || return 1
  case "$reply" in y|Y|yes|YES|j|J|ja) return 0;; *) return 1;; esac
}

have() { command -v "$1" >/dev/null 2>&1; }

say "veto-gate — setup"
say

# ── 1. required tools ──────────────────────────────────────────────────────
# Same list as `veto-gate doctor`. perl is genuinely required, not a nicety:
# the grounding stage is written in it and checks NOTHING without it.
MISSING=""
for dep in git python3 jq perl; do have "$dep" || MISSING="$MISSING $dep"; done

if [ -n "$MISSING" ]; then
  say "Missing:$MISSING"
  # On macOS git/python3/perl all arrive with the Command Line Tools, and jq
  # comes from Homebrew — two different sources, so they are offered apart.
  case "$MISSING" in *jq*)
      if have brew; then
        if ask "Install jq via Homebrew?"; then brew install jq || fail "⛔ brew install jq failed."; fi
      else
        say "  jq: install Homebrew first (https://brew.sh), then: brew install jq"
      fi;;
  esac
  case "$MISSING" in *git*|*python3*|*perl*)
      if [ "$(uname -s)" = "Darwin" ]; then
        say "  git/python3/perl come with the Xcode Command Line Tools:"
        say "      xcode-select --install"
      else
        say "  install git, python3 and perl with your package manager"
      fi;;
  esac
  STILL=""
  for dep in git python3 jq perl; do have "$dep" || STILL="$STILL $dep"; done
  [ -n "$STILL" ] && fail "⛔ still missing:$STILL — rerun this script once they are there."
fi
say "✓ required tools present"

# ── 2. the main reviewer ───────────────────────────────────────────────────
# Without codex the gate fail-closes on EVERY commit. Offering to install it is
# fine; logging in is the user's own account and stays their job.
if have codex; then
  say "✓ codex CLI present"
else
  say "⚠ codex CLI missing — without it the gate blocks every commit (fail-closed)."
  if have npm && ask "Install the codex CLI via npm?"; then
    npm install -g @openai/codex || say "⚠ npm install failed — install it by hand: npm install -g @openai/codex"
  elif ! have npm; then
    say "  npm not found — install Node.js, then: npm install -g @openai/codex"
  fi
fi

# ── 3. fetch or update ─────────────────────────────────────────────────────
if [ -d "$HOME_DIR/.git" ]; then
  # An existing checkout is updated, never reset: local edits are somebody's
  # work. --ff-only fails loudly instead of inventing a merge.
  say "→ updating $HOME_DIR"
  git -C "$HOME_DIR" pull --ff-only \
    || say "⚠ update skipped (local changes or diverged history) — continuing with what is there."
elif [ -e "$HOME_DIR" ]; then
  fail "⛔ $HOME_DIR exists and is not a veto-gate checkout — move it away or set VETO_GATE_HOME."
else
  say "→ cloning into $HOME_DIR"
  git clone --depth 1 "$REPO_URL" "$HOME_DIR" || fail "⛔ clone failed: $REPO_URL"
fi

# ── 4. wire it in ──────────────────────────────────────────────────────────
[ -x "$HOME_DIR/install.sh" ] || fail "⛔ $HOME_DIR/install.sh missing or not executable — the checkout looks incomplete."
say
VETO_GATE_BOOT=1 bash "$HOME_DIR/install.sh" \
  || fail "⛔ install.sh failed — see above. Nothing left half-wired: it aborts before linking."

# ── 5. make the command reachable ──────────────────────────────────────────
# install.sh links `veto-gate` into ~/.local/bin. If that is not on PATH the
# whole simplification collapses at the last step: the user is told to run
# `veto-gate enable` and the shell answers "command not found".
BIN="$HOME/.local/bin"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    say
    say "⚠ $BIN is not on your PATH — the veto-gate command would not be found."
    # Shell startup files are the user's own. Appending one guarded line is the
    # most that is acceptable, only after a yes, and only if it is not there yet.
    RC=""
    case "${SHELL:-}" in */zsh) RC="$HOME/.zshrc";; */bash) RC="$HOME/.bash_profile";; esac
    LINE='export PATH="$HOME/.local/bin:$PATH"'
    if [ -n "$RC" ] && ask "Append the PATH line to $(basename "$RC")?"; then
      if grep -qF -- "$LINE" "$RC" 2>/dev/null; then
        say "  → already there, nothing appended."
      else
        printf '\n# added by veto-gate boot.sh\n%s\n' "$LINE" >> "$RC" \
          && say "  ✓ appended to $RC — open a new terminal, or: source $RC" \
          || say "  ⛔ could not write $RC — add this line yourself: $LINE"
      fi
    else
      say "  Add this to your shell startup file: $LINE"
    fi;;
esac

# ── 6. what is left for a human ────────────────────────────────────────────
say
say "Next:"
if have codex; then
  say "  1. codex login          (once, your own account — veto-gate pays for nothing)"
else
  say "  1. install the codex CLI, then: codex login"
fi
say "  2. cd <your-project> && veto-gate enable"
say
say "Check anytime:  veto-gate doctor"

# Changelog

## v1.1.0 — 2026-07-17

Rename: the tool is called **veto-gate** everywhere now (CLI, config file,
environment variables, suite names). Old names keep working as transitional
aliases — nothing breaks on upgrade:

- CLI: `veto-gate` (new primary, `veto-gate-cli.sh`); `veto2` stays as a
  thin wrapper. `install.sh` links both, `uninstall.sh` removes both.
- Config: `.claude/config/veto-gate.json` preferred; `veto2.json` is still
  read when the new file does not exist.
- Environment: `VETO_GATE_*` names, with every old `VETO2_*` name mapped by
  a compatibility layer (`env-compat.sh`, new names always win).
- Test suites renamed to `test-veto-gate-*`; stale old-name copies removed.
- README and `docs/INSTALL.md` rewritten in plain language with explicit
  LLM plug-in points (main reviewer, local pre-checker, remote pre-checker).

## v1.0.0 — 2026-07-16

Initial public release. Extracted from a private monorepo where this tool
had been developed and dogfooded for several months (400+ internal test
runs against its own commits before this release).

- `veto-gate.sh` — PreToolUse/Bash hook, reviews `git commit` diffs via
  OpenAI Codex, with an optional local pre-check stage.
- Evidence ledger (`proof.sh`) — every review stage leaves a note; a stage
  that silently skips is a red test, not a silent pass.
- Portable timeout wrapper (`with-timeout.sh`) — prefers GNU `timeout`,
  falls back to a `perl`-based alarm on systems without it (e.g. macOS).
- `veto2 doctor` — one-command dependency self-check.
- `secret-scan.sh` — scans the repo for secret-shaped strings before a push.
- `install.sh` / `uninstall.sh` — symlink-based installer, never overwrites
  a foreign hook or a foreign `settings.json` entry.
- `docs/INSTALL.md` — step-by-step setup for macOS and Windows (WSL2 only).

Found and fixed while preparing this release, listed because it shaped the
dependency list users see: `perl` is required, not merely a `timeout` fallback.
The grounding stage that catches invented method calls is written in perl and
silently checked nothing without it, while `veto2 doctor` still reported an
all-clear. It now refuses to run rather than pass a diff off as reviewed.

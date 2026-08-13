#!/usr/bin/env bash
# generated-files.sh — ONE list of machine-written dependency lockfiles, shared by
# pack-diff.sh (what ships whole), diff-size.sh (what counts as a hand-written line)
# and veto-gate.sh / pre-commit.sh (the size gate). Three private copies would drift,
# and a drifted list means the same file is "generated" for one stage and "code" for
# the next — the worst kind of gap, because both stages would look correct alone.
#
# What qualifies: the package manager WRITES it, its content is fully derived from a
# manifest, and it cannot be split into its own commit — manifest and lockfile are ONE
# statement (between two commits the declared version is not the installed one). That
# is why they need their own handling instead of the "split it up" advice, which is
# impossible to follow here.
#
# What deliberately does NOT qualify: every manifest (package.json, Cargo.toml,
# pyproject.toml, Gemfile). Those are hand-written, they carry the install scripts,
# and they are exactly where a supply-chain attack is authored. They stay code.
#
# The anchors matter: `(^|/)` and `$` require the name to be the WHOLE basename, so
# a hand-written `src/my-package-lock.json` is not swept in by resemblance.
VETO_GENERATED_ERE='(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb|Cargo\.lock|poetry\.lock|uv\.lock|Pipfile\.lock|Gemfile\.lock|composer\.lock|go\.sum|mix\.lock|pubspec\.lock|gradle\.lockfile|packages\.lock\.json)$'

# veto_is_generated <repo-relative-path> — rc 0 when the path is such a lockfile.
# The path is the SUBJECT here, never the pattern, so a name containing regex
# characters cannot change what is matched.
veto_is_generated() {
  printf '%s' "${1:-}" | grep -qE "$VETO_GENERATED_ERE"
}

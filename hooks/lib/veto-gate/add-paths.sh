#!/usr/bin/env bash
# add-paths.sh — print the file arguments of every `git add` in the command
# read from stdin, one per line, quotes stripped. Emits the sentinel ::ALL::
# for add -A/--all/. — the caller then treats every untracked file as added.
# Undecidable spans (command substitutions, backticks) are never scanned; if
# nothing is extractable the caller falls back to its conservative superset.
set -uo pipefail
perl -0777 -e '
  my $cmd = <STDIN>;
  # blank out substitution bodies — an add inside $(...)/`...` is undecidable
  $cmd =~ s/\$\([^)]*\)/" " x length($&)/ge;
  $cmd =~ s/`[^`]*`/" " x length($&)/ge;
  # split into segments on unquoted ; & | (quote- and escape-aware scan)
  my (@segs, $cur, $q) = ((), "", "");
  my @chars = split //, $cmd;
  for (my $i = 0; $i <= $#chars; $i++) {
    my $c = $chars[$i];
    if ($c eq "\\" && $q ne "\x27" && $i < $#chars) { $cur .= $c . $chars[++$i]; next; }
    if ($q) { $cur .= $c; $q = "" if $c eq $q; next; }
    if ($c eq "\"" || $c eq "\x27") { $q = $c; $cur .= $c; next; }
    if ($c eq ";" || $c eq "&" || $c eq "|" || $c eq "\n") { push @segs, $cur; $cur = ""; next; }
    $cur .= $c;
  }
  push @segs, $cur;
  my $tok = qr/(?:"[^"]*"|\x27[^\x27]*\x27|(?:\\.|[^\s"\x27])+)/;
  for my $s (@segs) {
    next unless $s =~ /^\s*git\s+(?:-C\s+$tok\s+)?add(?:\s+(.*))?$/s;
    my $args = defined $1 ? $1 : "";
    my ($dashdash, $all, $var, $upd, $dot, @paths) = (0, 0, 0, 0, 0);
    while ($args =~ /\G\s*($tok)/gc) {
      my $t = $1;
      # A redirection ends the git arguments — everything after it belongs to the
      # shell. Without this, `git add a.ts > /dev/null` yielded the paths
      # "a.ts", ">" and "/dev/null"; git then rejected the pathspec outside the
      # repo, the narrowed diff came back EMPTY, and the gate found nothing to
      # review and exited 0. Measured live 2026-07-29: the identical commit
      # without the redirect was blocked. Stopping is the conservative end —
      # it can only drop paths from the narrowing, never invent one, and a
      # narrower add-list widens the review, it does not shrink it.
      last if $t =~ /^(?:[0-9]*[<>]|&[<>])/;
      # does the shell EXPAND a $ in this token? single quotes keep it
      # literal; before a $, only an ODD backslash count escapes it —
      # backslash-backslash-dollar is a literal backslash then an
      # EXPANDING variable (codex finds)
      my $expands = 0;
      if ($t !~ /^\x27/) { $expands = 1 if $t =~ /(?<!\\)(\\\\)*\$/; }
      # strip one layer of quotes, then unescape
      if ($t =~ /^"(.*)"$/s or $t =~ /^\x27(.*)\x27$/s) { $t = $1; }
      else { $t =~ s/\\(.)/$1/g; }
      if (!$dashdash && $t eq "--") { $dashdash = 1; next; }
      if (!$dashdash && ($t eq "-A" || $t eq "--all")) { $all = 1; next; }
      # add -u/--update stages TRACKED changes only — this whole add (incl.
      # its pathspecs) contributes no untracked files (codex finds)
      if (!$dashdash && ($t eq "-u" || $t eq "--update")) { $upd = 1; next; }
      if (!$dashdash && $t =~ /^-/) { next; }   # other options
      # a dot means everything for a plain add, but under -u it is
      # tracked-only (codex find) — decide after the token loop
      if ($t eq ".") { $dot = 1; next; }
      # an EXPANDED $VAR token is not statically resolvable; a literal path
      # starting with :: could spoof our sentinels — both are undecidable
      # and widen conservatively (codex finds)
      if ($expands or $t =~ /^::/) { $var = 1; next; }
      push @paths, $t;
    }
    $all = 1 if $dot && !$upd;
    if ($upd) {
      # a dot under -u stages ALL tracked mods (no untracked) — same as a
      # bare -u for the caller
      @paths = () if $dot;
      # explicit -A still wins (it does take untracked); -u never takes
      # untracked files. A variable under -u is undecidable even for the
      # tracked side — ::TRACKEDVAR:: tells the caller to review wide but
      # size-count narrow. Statically known paths are emitted ALONGSIDE
      # the sentinel so the size gate still counts them (codex finds).
      if ($all) { print "::ALL::\n"; }
      else {
        print "::TRACKEDVAR::\n" if $var;
        if (@paths)   { print "::TRACKED::$_\n" for @paths; }
        elsif (!$var) { print "::TRACKED::\n"; }
      }
    } else {
      # an undecidable token (expanding $VAR, ::-lookalike) makes the WHOLE
      # chain fallback territory — ::VAR:: survives next to paths of the
      # same or other adds so the caller never mistakes the list for
      # complete, while named paths still feed the size gate (F6 rule in
      # CONVENTIONS; codex finds).
      if ($all) { print "::ALL::\n"; }
      else {
        print "::VAR::\n" if $var;
        print "$_\n" for @paths;
      }
    }
  }
'

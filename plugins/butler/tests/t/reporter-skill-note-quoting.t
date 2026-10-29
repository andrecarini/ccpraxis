#!/usr/bin/env perl
# platform: any
# t/104 — a02-api-and-guard-defects, DEFECT 4.
# skills/reporter/SKILL.md shows `--note "<guidance>"` inline (lines ~112, ~128
# at scout time); a backticked example inside a double-quoted shell argument is
# command-substituted BEFORE the script ever sees it, silently delivering a
# mandate with a hole in it. Spec §2.8 / AC-10.
#
# WRITTEN BLIND TO THE IMPLEMENTATION. Static-text assertions only; no script is
# invoked. Every "must be present" assertion below is expected to FAIL against
# the pre-change tree: today the file has no `<<'EOF'` heredoc form binding
# --note at all, and DOES have at least one bare inline `--note "<...>"` example.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $SKILL = "$Bin/../../skills/reporter/SKILL.md";

ok(-f $SKILL, "harness sanity: $SKILL exists") or BAIL_OUT("cannot find SKILL.md at $SKILL");

open my $fh, '<:raw', $SKILL or die "read $SKILL: $!";
local $/; my $text = <$fh>; close $fh;

# ── AC-10: every --note example reads a single-quoted heredoc on stdin ───────
# The shape: `--note - <<'EOF'` ... `EOF`. It used to be
# `NOTE=$(cat <<'EOF' ... EOF)` + `--note "$NOTE"`, which closed the
# substitution hole but opened another: bash 3.2 (macOS /bin/bash) parses a
# heredoc inside $(...) for parentheses and quotes, so an operator's note with
# a stray ")" or apostrophe broke the command. stdin needs no substitution.
my @heredoc_feeds = ($text =~ /--note\s+-\s+<<'EOF'\n.*?\nEOF\n/gs);
ok(scalar(@heredoc_feeds) >= 1,
    'AC-10: at least one `--note - <<\'EOF\'` single-quoted heredoc feed is present')
    or diag('found none; scanned ' . length($text) . ' bytes of SKILL.md');
unlike($text, qr/\$\(cat\s*<</, 'AC-10: no heredoc inside a command substitution anywhere (bash 3.2 mis-parses it)');

# Every `--note` use in the doc must read stdin (`-`) or a file, never an
# inline literal string.
my @note_uses = ($text =~ /--note\s+("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+)/g);
ok(scalar(@note_uses) >= 1, 'AC-10: SKILL.md contains at least one --note usage to check')
    or diag('found no --note usage at all in the file');

my @bad_inline = grep { $_ ne '-' } @note_uses;
is_deeply(\@bad_inline, [],
    'AC-10: every --note usage reads the heredoc on stdin (`--note -`); no inline literal example remains')
    or diag('offending --note argument(s): ' . join(', ', @bad_inline));

# No example anywhere uses an UNquoted heredoc delimiter (`<<EOF` without quotes),
# which re-opens the exact substitution hazard the quoted form exists to close.
unlike($text, qr/<<EOF\b/, 'AC-10: no unquoted `<<EOF` heredoc delimiter anywhere (must be `<<\'EOF\'`)');

# ── AC-10: prose states WHY -- an inline double-quoted --note substitutes before
#           the script sees it ─────────────────────────────────────────────────
# Deliberately index()/small-window checks rather than like() over the whole
# 17KB doc: a failing like() on the full text dumps the entire file as diag
# noise on every red run, without adding any diagnostic value here.
my $has_before_script_phrasing = ($text =~ /substitut\w*.{0,200}before the script/is) ? 1 : 0;
my $has_backtick_dollar_paren  = ($text =~ /backtick.{0,300}\$\(/is) ? 1 : 0;
ok($has_before_script_phrasing || $has_backtick_dollar_paren,
    'AC-10: prose explains WHY (substitution happens before the script sees the argument, '
  . 'backticks/$(...) named) -- checked as two narrow patterns, not dumped verbatim');

# Regression: docs-consistency check convention elsewhere in this suite (t/86 grep
# pattern style) -- the section documenting the new set-test-paths verb (defect 2)
# should sit near --widen-write-set per spec §2.8, but that is DEFECT-2 territory
# and is asserted in 102, not duplicated here.

done_testing();

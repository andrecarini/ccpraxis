#!/usr/bin/env perl
# platform: any
# Regression for 20260911-225720-4c57 (defect 2): a registered project whose
# path holds a space AND a non-ASCII character (steward's real job-search
# entry: "/c/Users/André/Personal Files/Job search") was silently absent from
# `collect` -- no error, no row, nothing. Root cause was the registry's JSON
# being decoded without ->utf8 against raw bytes, corrupting the path before
# it ever reached opendir.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use utf8;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

my $HOME = tempdir(CLEANUP => 1);
my $BASE = tempdir(CLEANUP => 1);
(my $BASE_WIN = $BASE) =~ s{\\}{/}g;

# A directory whose name carries BOTH a space and a non-ASCII character, the
# same shape as the real registry entry that went missing.
my $ODD_NAME = "Caf\x{e9} Notes";   # 'é' via a \x{...} escape -> a real Unicode codepoint
my $ODD_DIR  = "$BASE_WIN/$ODD_NAME";
# APFS (macOS) refuses a file name that is not valid UTF-8 (EILSEQ). The
# "\x{e9}" in $ODD_NAME is stored as the single byte 0xE9, which is what
# perl hands the filesystem, so on darwin the path is utf8::upgrade'd: the same
# characters, now stored and handed over as UTF-8 bytes, which is what a
# real macOS path is. Elsewhere the byte form is kept as it was.
utf8::upgrade($ODD_DIR) if $^O eq 'darwin';
mkdir $ODD_DIR or die "mkdir $ODD_DIR: $!";

sub run {
    my (@args) = @_;
    my $cmd = qq{ALMANAC_HOME="$HOME" perl "$A" } . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}

my ($rc_f, $out_f) = run('file', '--project', qq{"$ODD_DIR"}, '--title', '"filed from the odd path"',
                          '--body', '"must survive registry round-trip"');
is($rc_f, 0, 'fixture: report filed under the space+non-ASCII project') or diag $out_f;

# Write the registry MYSELF, encoding with ->utf8 (the correct producer side)
# so this test isolates the READ-side bug this fix addresses.
mkdir "$HOME/.claude" or die $!;
mkdir "$HOME/.claude/claude-code-vault" or die $!;
my %j = (version => 1, projects => { 'odd-fixture' => { path => $ODD_DIR } });
open my $fh, '>:raw', "$HOME/.claude/claude-code-vault/.registry-local.json" or die $!;
print {$fh} JSON::PP->new->utf8->canonical->encode(\%j);
close $fh;

# Some OTHER, unrelated project is the caller's --project root, so the odd
# path is reachable ONLY via the registry -- exactly how job-search was
# reachable only via steward's registry, never via --project.
my $CALLER = tempdir(CLEANUP => 1);
(my $CALLER_WIN = $CALLER) =~ s{\\}{/}g;

my ($rc_c, $out_c) = run('collect', '--project', qq{"$CALLER_WIN"}, '--json');
is($rc_c, 0, 'collect: succeeds') or diag $out_c;
my $rows = eval { JSON::PP->new->decode($out_c) };
ok(ref $rows eq 'ARRAY', 'collect --json: parses') or diag $out_c;

my @mine = grep { ($_->{title} // '') eq 'filed from the odd path' } @$rows;
is(scalar(@mine), 1,
   'collect: a registered project whose path has a space AND non-ASCII is COLLECTED, not silently skipped')
    or diag('rows: ' . join(', ', map { $_->{project} // '?' } @$rows));

done_testing();

#!/usr/bin/env perl
# platform: host
# Regression for 20260911-225720-4c57 (defect 1): two spellings of ONE root
# ("C:/x" vs "/c/x") used to double-count every report under it, because the
# root dedupe compared raw strings rather than a canonical form. Also pins
# that the plain single-spelling case is unchanged.
#
# macOS has its own two-spellings shape: default APFS is case-insensitive
# and Cwd::abs_path keeps the case it was given, so "<tmp>/CaseRoot" and
# "<tmp>/caseroot" are one directory under two canonical_root values unless
# that folds case on darwin.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A = "$S/almanac-bug.pl";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');

my $WIN = ($^O =~ /^(MSWin32|cygwin|msys)$/) ? 1 : 0;
my $MAC = ($^O eq 'darwin') ? 1 : 0;
plan skip_all => 'requires a Windows-style drive-lettered filesystem or macOS'
    unless $WIN || $MAC;

my $HOME = tempdir(CLEANUP => 1);
my $PROJ = tempdir(CLEANUP => 1);
(my $PROJ_WIN = $PROJ) =~ s{\\}{/}g;                       # e.g. C:/Users/.../XXXX
(my $PROJ_POSIX = $PROJ_WIN) =~ s{^([A-Za-z]):}{'/' . lc($1)}e;  # -> /c/Users/.../XXXX

sub run {
    my (@args) = @_;
    my $cmd = qq{ALMANAC_HOME="$HOME" perl "$A" } . join(' ', @args) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}

sub write_registry {
    my (%projects) = @_;
    mkdir "$HOME/.claude" or die $! unless -d "$HOME/.claude";
    mkdir "$HOME/.claude/claude-code-vault" or die $!
        unless -d "$HOME/.claude/claude-code-vault";
    my %j = (version => 1, projects => { map { $_ => { path => $projects{$_} } } keys %projects });
    open my $fh, '>:raw', "$HOME/.claude/claude-code-vault/.registry-local.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode(\%j);
    close $fh;
}

SKIP: {
    skip 'the drive-letter spelling exists only on Windows', 4 unless $WIN;

# One report, filed under the Windows-drive spelling of the root.
my ($rc_f, $out_f) = run('file', '--project', qq{"$PROJ_WIN"}, '--title', '"one report, one root"',
                          '--body', '"should be counted exactly once"');
is($rc_f, 0, 'fixture: report filed') or diag $out_f;

# The registry (steward's, which `collect` walks) records the SAME directory
# under its OWN, POSIX spelling -- exactly the two-spelling shape that hid
# every report in ccpraxis's own store on this machine.
write_registry('dedup-fixture' => $PROJ_POSIX);

my ($rc_c, $out_c) = run('collect', '--project', qq{"$PROJ_WIN"}, '--json');
is($rc_c, 0, 'collect: succeeds') or diag $out_c;
my $rows = eval { JSON::PP->new->decode($out_c) };
ok(ref $rows eq 'ARRAY', 'collect --json: parses') or diag $out_c;

my @mine = grep { ($_->{title} // '') eq 'one report, one root' } @$rows;
is(scalar(@mine), 1,
   'collect: a root reachable under two spellings (--project + registry) yields the report ONCE, not twice')
    or diag(explain_rows($rows));
}

# ---- macOS and Windows: two CASE spellings of one root --------------
SKIP: {
    skip 'case spellings of one root are a macOS (APFS) or Windows (NTFS) shape', 4 unless $MAC || $WIN;
    my $base = tempdir(CLEANUP => 1);
    my $UPPER = "$base/CaseRoot";
    mkdir $UPPER or die "fixture: mkdir $UPPER: $!";
    my $LOWER = "$base/caseroot";
    skip 'this volume is case-sensitive: the two spellings are two directories', 4 unless -d $LOWER;

    my ($rc_m, $out_m) = run('file', '--project', qq{"$UPPER"}, '--title', '"one report, two cases"',
                              '--body', '"should be counted exactly once"');
    is($rc_m, 0, 'macOS fixture: report filed under the mixed-case spelling') or diag $out_m;
    write_registry('case-fixture' => $LOWER);
    my ($rc_mc, $out_mc) = run('collect', '--project', qq{"$UPPER"}, '--json');
    is($rc_mc, 0, 'macOS collect: succeeds') or diag $out_mc;
    my $rows_m = eval { JSON::PP->new->decode($out_mc) };
    ok(ref $rows_m eq 'ARRAY', 'macOS collect --json: parses') or diag $out_mc;
    my @mine_m = grep { ($_->{title} // '') eq 'one report, two cases' } @{ $rows_m || [] };
    is(scalar(@mine_m), 1,
       'macOS collect: a root reachable under two case spellings (--project + registry) yields the report ONCE')
        or diag(explain_rows($rows_m || []));
}

# ---- simple, single-spelling case is unchanged -----------------------------
my $PROJ2 = tempdir(CLEANUP => 1);
(my $PROJ2_WIN = $PROJ2) =~ s{\\}{/}g;
my ($rc_f2, $out_f2) = run('file', '--project', qq{"$PROJ2_WIN"}, '--title', '"plain single-project report"',
                            '--body', '"unrelated to the dedup fixture"');
is($rc_f2, 0, 'fixture 2: report filed') or diag $out_f2;
write_registry();   # empty registry -- PROJ2 is reached only via --project, not doubled by it
my ($rc_c2, $out_c2) = run('collect', '--project', qq{"$PROJ2_WIN"}, '--json');
is($rc_c2, 0, 'collect: still succeeds with an empty registry') or diag $out_c2;
my $rows2 = eval { JSON::PP->new->decode($out_c2) };
is(scalar(@$rows2), 1, 'collect: the ordinary single-project, single-spelling case still yields exactly one row');

sub explain_rows { my ($r) = @_; return join(', ', map { "$_->{project} / $_->{title}" } @$r) }

done_testing();

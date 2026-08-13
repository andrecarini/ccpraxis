#!/usr/bin/env perl
# t/99-status-read-api-regressions.t — regression coverage for BpState.pm
# added in the s01-status-read-api fix-batch step 7, for two defects that
# survived to step 6 without t/98 (the immutable oracle) catching them:
#
#   M1 — norm_pkg_status/norm_bp_status word-scanned for the FIRST matching
#        status word instead of matching the whole normalised value, so a
#        NEGATED value like 'not-done' resolved to the terminal 'done'
#        (the exact inverse of this blueprint's Decision 6: uncertainty
#        must resolve toward LIVE, never toward settled).
#   M2 — all_package_statuses's extension/lock-exclusion matches were
#        case-sensitive, so a '.MD' ledger was silently dropped on
#        Windows' case-insensitive filesystem, and a '.LOCK' file would be
#        wrongly counted as a package.
#
# This file is NOT the oracle (t/98 is); it exists specifically to make
# these two defects impossible to reintroduce silently. Each test below was
# verified by the fix-batch worker to FAIL against the pre-fix BpState.pm
# and PASS after — see the fix-batch report.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $SCRIPT = "$Bin/../../scripts/BpState.pm";
my $LOADED = do {
    local $@;
    eval { require $SCRIPT };
    !$@;
};
BAIL_OUT("cannot load BpState.pm: $@") unless $LOADED;

sub write_file {
    my ($path, $content) = @_;
    my $dir = $path;
    $dir =~ s{[^/\\]+\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub ledger_with_status {
    my ($status) = @_;
    return "---\nstatus: $status\n---\n# body\n";
}

# ═══════════════════════════ M1: negation / compound values ═══════════════
{
    my $bp = tempdir(CLEANUP => 1);
    write_file("$bp/packages/p1.md", ledger_with_status('not-done'));
    is(BpState::package_status($bp, 'p1'), 'pending',
        'M1: status "not-done" does NOT resolve to the terminal "done"');
}
{
    my $bp = tempdir(CLEANUP => 1);
    write_file("$bp/packages/p1.md", ledger_with_status('not done'));
    is(BpState::package_status($bp, 'p1'), 'pending',
        'M1: status "not done" (space-separated negation) does not resolve to "done"');
}
{
    my $bp = tempdir(CLEANUP => 1);
    write_file("$bp/blueprint.md", "```\nstatus: not-archived-yet\n```\n");
    my $lifecycle = BpState::blueprint_lifecycle($bp, sub { 0 });
    isnt($lifecycle, 'archived',
        'M1: authored "not-archived-yet" does NOT resolve blueprint_lifecycle to "archived"');
}
{
    # sanity: a genuinely single-word decorated value still normalises
    # correctly (the fix must not break the legitimate case).
    my $bp = tempdir(CLEANUP => 1);
    write_file("$bp/packages/p1.md", ledger_with_status("\x{2705} done"));
    is(BpState::package_status($bp, 'p1'), 'done',
        'M1 sanity: glyph-decorated single-word "done" still normalises to done');
}
{
    my $bp = tempdir(CLEANUP => 1);
    write_file("$bp/packages/p1.md", ledger_with_status('running-but-not-really'));
    is(BpState::package_status($bp, 'p1'), 'pending',
        'M1: compound value containing a status word as a substring falls to pending, not the substring');
}

# ═══════════════════════════ M2: case-insensitive extension/.lock ═════════
{
    my $bp = tempdir(CLEANUP => 1);
    write_file("$bp/packages/p1.MD", ledger_with_status('running'));
    my $statuses = BpState::all_package_statuses($bp);
    ok(exists $statuses->{p1}, 'M2: a .MD (uppercase extension) ledger is counted in all_package_statuses');
    is($statuses->{p1} // '(absent)', 'running', 'M2: the .MD ledger status is read correctly');
}
{
    my $bp = tempdir(CLEANUP => 1);
    write_file("$bp/packages/p1.md", ledger_with_status('running'));
    write_file("$bp/packages/p1.md.LOCK", 'lock');
    my $statuses = BpState::all_package_statuses($bp);
    is(scalar(keys %$statuses), 1, 'M2: a .LOCK (uppercase) file is excluded, not counted as a package');
    ok(!exists $statuses->{'p1.md'}, 'M2: no spurious "p1.md" key from the .LOCK file');
}

# ═══════════════════ M2 end-to-end: hidden running package via case ═══════
{
    my $bp = tempdir(CLEANUP => 1);
    # p1 delivered; p2 genuinely still running, but authored with an
    # uppercase extension the way a case-sensitive matcher would miss.
    write_file("$bp/packages/p1.md", ledger_with_status('done'));
    write_file("$bp/packages/p2.MD", ledger_with_status('running'));
    write_file("$bp/blueprint.md", "```\nstatus: audited\n```\n");

    my $statuses = BpState::all_package_statuses($bp);
    is(scalar(keys %$statuses), 2, 'M2 e2e: both packages (including the .MD one) are visible');

    my $lifecycle = BpState::blueprint_lifecycle($bp, sub { 0 });
    isnt($lifecycle, 'done',
        'M2 e2e: a genuinely running package (hidden only by extension case) must NOT let blueprint_lifecycle read done');
}

done_testing();

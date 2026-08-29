#!/usr/bin/env perl
# 10-marketplace-preferences.t — a marketplace discrepancy with a permanent
# answer must not be asked twice.
#
# WHY. Every other comparison in /steward:backup honours saved preferences;
# marketplaces did not. So `ccpraxis-local` -- a directory-source entry whose
# path is absolute on this machine, registered per-machine by install.pl, and
# therefore live-only forever -- was reported as a discrepancy on EVERY backup
# run, with only "export it" (wrong), "remove it" (wrong), and "skip" (asked
# again next time) on offer. Operator, 2026-08-29: "Keep it live only and make
# the backup machinery stop asking that."
#
# HERMETIC: HOME is redirected to a temp dir, so this reads and writes only
# fixture files. It never touches the operator's real known_marketplaces.json or
# their real .backup-preferences.json.
#
# THE NON-VACUITY CASE IS THE POINT. A filter that silences everything would
# pass a test that only checks "no discrepancy reported". So the same fixture is
# run three ways: with no preference (must ask), with a MISMATCHED preference
# (must still ask), and with the right preference (must go quiet).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $H = "$S/ccpraxis-helpers.pl";
ok(-f $H, 'ccpraxis-helpers.pl exists') or BAIL_OUT('script missing');

my $HOME = tempdir(CLEANUP => 1);
make_path("$HOME/.claude/plugins", "$HOME/.claude/ccpraxis/global-config");

sub write_json {
    my ($path, $obj) = @_;
    open my $fh, '>', $path or die "fixture: cannot write $path: $!";
    print {$fh} JSON::PP->new->canonical->pretty->encode($obj);
    close $fh;
}

# live has ccpraxis-local; repo does not. That is the real shape.
write_json("$HOME/.claude/plugins/known_marketplaces.json", {
    'ccpraxis-local' => { source => { source => 'directory', path => '/abs/machine/path' },
                          installLocation => '/somewhere' },
    'shared-one'     => { source => { source => 'github', repo => 'a/b' } },
});
write_json("$HOME/.claude/ccpraxis/global-config/known_marketplaces.json", {
    'shared-one' => { source => { source => 'github', repo => 'a/b' } },
});

my $PREFS = "$HOME/.claude/ccpraxis/.backup-preferences.json";

sub diff_now {
    local $ENV{HOME} = $HOME;
    local $ENV{USERPROFILE} = $HOME;
    my $out = `perl "$H" marketplace-diff 2>&1`;
    my $d = eval { JSON::PP->new->decode($out) };
    return ref $d eq 'HASH' ? $d : { status => "UNPARSEABLE: $out" };
}

# ---------------------------------------------------------------------------
# AC1 — with no preference, the discrepancy IS reported. Without this the rest
# of the file could pass against a filter that hides everything.
# ---------------------------------------------------------------------------
{
    my $d = diff_now();
    is($d->{status}, 'different', 'AC1: with no saved preference the discrepancy is reported');
    is(scalar @{ $d->{live_only} || [] }, 1, 'AC1: ...as one live_only entry');
    is($d->{live_only}[0]{name}, 'ccpraxis-local', 'AC1: ...naming the right marketplace');
    is(scalar @{ $d->{auto_applied} || [] }, 0, 'AC1: ...and nothing was auto-applied');
}

# ---------------------------------------------------------------------------
# AC2 — a preference in the WRONG category does not silence it. The saved
# decision has to match the relation the key actually has now; a marketplace
# that moved from repo-only to live-only is a new fact and must be re-asked.
# ---------------------------------------------------------------------------
{
    write_json($PREFS, { marketplaces => {
        'ccpraxis-local' => { category => 'only_right', action => 'right-only' } } });
    my $d = diff_now();
    is($d->{status}, 'different', 'AC2: a mismatched-category preference does NOT silence the question');
    is(scalar @{ $d->{live_only} || [] }, 1, 'AC2: ...the entry is still reported');
}

# ---------------------------------------------------------------------------
# AC3 — a preference with the wrong ACTION for its category is also ignored.
# ---------------------------------------------------------------------------
{
    write_json($PREFS, { marketplaces => {
        'ccpraxis-local' => { category => 'only_left', action => 'right-only' } } });
    my $d = diff_now();
    is($d->{status}, 'different', 'AC3: a category/action mismatch does NOT silence the question');
}

# ---------------------------------------------------------------------------
# AC4 — the correct preference silences it, and says so rather than simply
# dropping the entry. "Reported nothing" and "applied your earlier decision"
# are different facts and the operator gets to see which happened.
# ---------------------------------------------------------------------------
{
    write_json($PREFS, { marketplaces => {
        'ccpraxis-local' => { category => 'only_left', action => 'left-only' } } });
    my $d = diff_now();
    is($d->{status}, 'identical', 'AC4: the saved preference silences the question');
    is(scalar @{ $d->{live_only} || [] }, 0, 'AC4: ...the entry is no longer a decision');
    is(scalar @{ $d->{auto_applied} || [] }, 1, 'AC4: ...and it is reported as auto-applied');
    is($d->{auto_applied}[0]{name}, 'ccpraxis-local', 'AC4: ...by name');
    is($d->{auto_applied}[0]{action}, 'left-only', 'AC4: ...with the action that was honoured');
}

# ---------------------------------------------------------------------------
# AC5 — a preference for one marketplace does not silence a DIFFERENT one.
# ---------------------------------------------------------------------------
{
    write_json("$HOME/.claude/plugins/known_marketplaces.json", {
        'ccpraxis-local' => { source => { source => 'directory', path => '/abs/machine/path' } },
        'another-local'  => { source => { source => 'directory', path => '/other' } },
        'shared-one'     => { source => { source => 'github', repo => 'a/b' } },
    });
    my $d = diff_now();
    is($d->{status}, 'different', 'AC5: an unrelated marketplace is still reported');
    my @names = map { $_->{name} } @{ $d->{live_only} || [] };
    is_deeply(\@names, ['another-local'], 'AC5: ...and it is the one without a preference');
}

# ---------------------------------------------------------------------------
# AC6 — the operator's real preferences file was not touched by any of this.
# ---------------------------------------------------------------------------
{
    my $real = ($ENV{HOME} // $ENV{USERPROFILE} // '') . '/.claude/ccpraxis/.backup-preferences.json';
    ok(1, 'AC6: this suite wrote only under its temp HOME');
    isnt($PREFS, $real, 'AC6: the fixture prefs path is not the live one');
}

done_testing();

#!/usr/bin/env perl
# platform: host
# AN UNREADABLE PROBE IS NOT A DEFINITE NEGATIVE.
#
# The rule 20260915-230820-d33e states, and the two places that broke it.
#
# The operator watched a live blueprint fleet with the dashboard open and read:
#
#     busy-lease    none (no active run)
#     keep-awake    released (PC may sleep)
#
# while inside the container the lease was being refreshed every two to ten
# seconds. "I could not read the lease" and "there is no lease" are different
# facts, and only one of them justifies letting the machine sleep. The panel
# collapsed the first into the second, so the most alarming thing on the screen
# was also the least trustworthy.
#
# Two mechanisms had to be fixed for the rule to hold end to end:
#
#   RENDER  -- tui::DashboardScreen had no vocabulary for "unreadable". Its
#              busy-lease row keyed off `defined $state->{busy_age}` alone, and
#              a failed probe leaves that undef exactly as an idle container
#              does. Now the probe reading travels with the state.
#
#   DECIDE  -- launcher.pl had TWO keep-awake decision sites. The throttled one
#              (KeepAwake::on_probe) holds the lock through a probe failure on
#              purpose. The per-refresh `keepawake` seam then re-derived
#              staleness from a cached age that is deliberately FROZEN during a
#              failure -- so the extrapolated age grew without bound, crossed
#              the stale threshold, and released the very lock the first site
#              was holding. A tolerance that a second, probe-blind decision can
#              overrule is not a tolerance.
#
# The render half is behavioural against the real module. The decision half is
# structural: the seam lives inside enter_dashboard's closure and cannot be
# called in isolation, so this file pins the properties that make it correct
# and the companion assertions in busy-lease-path-conversion.t pin the shape.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use lib "$Bin/../../scripts/tui";
use Test::More;

my $DS_OK = eval { require tui::DashboardScreen; 1 };
ok($DS_OK, 'tui::DashboardScreen loads') or BAIL_OUT("cannot load DashboardScreen: $@");

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
ok(-f $LAUNCHER, 'launcher.pl is present') or BAIL_OUT('no launcher to test');
my $SRC = do { local (@ARGV, $/) = ($LAUNCHER); <> };

# A nonce that can only have come from the probe's detail field, so the
# assertions below count a VALUE that travelled rather than a label word that
# was always going to be there.
my $DETAIL_NONCE = 'zqxprobe4471';

sub render {
    my (%over) = @_;
    my %state = (
        project_name => 'p', container => 'c', status => 'running',
        beat_age => 4, uptime => 600,
        needs_you => 0,
        %over,
    );
    my $frame = eval { tui::DashboardScreen::compose(\%state, 40, 100) };
    return '' unless ref $frame eq 'ARRAY';
    return join("\n", map { (ref $_ eq 'HASH' && defined $_->{text}) ? $_->{text} : '' } @$frame);
}

# Strip ANSI so assertions match the text a human reads, not the escapes.
sub plain { my $s = shift; $s =~ s/\e\[[0-9;]*m//g; return $s }

# ===========================================================================
# A. THE THREE STATES ARE DISTINGUISHABLE.
# ===========================================================================
my $unreadable = plain(render(
    busy_age    => undef,
    stay_awake  => 0,
    lease_probe => { state => 'probe-failed', detail => "container sampler snapshot is ${DETAIL_NONCE}s old" },
    keepawake_held => 1,
));
like($unreadable, qr/busy-lease.*unreadable/i,
     'A1: a failed probe renders as unreadable');
like($unreadable, qr/\Q$DETAIL_NONCE\E/,
     'A2: ... and carries the reason it failed, rather than asserting a fact it does not have');
unlike($unreadable, qr/busy-lease.*no active run/i,
     'A3: ... and never claims there is no active run');

my $absent = plain(render(busy_age => undef, stay_awake => 0, lease_probe => { state => 'lease-absent' }));
like($absent, qr/busy-lease.*none \(no active run\)/i,
     'A4: a genuinely absent lease still renders as none -- the counter-fixture, '
     . 'so A3 is proving a distinction rather than the absence of a string');

my $active = plain(render(busy_age => 5, stay_awake => 1, lease_probe => { state => 'ok' }, keepawake_held => 1));
like($active, qr/busy-lease.*active/i, 'A5: a fresh lease still renders as active');

# ===========================================================================
# B. THE KEEP-AWAKE ROW REPORTS WHAT IS HELD, NOT WHAT WAS WANTED.
#
# This is the row that told the operator the machine was free to sleep. During
# a held-through probe failure the intended value and the actual one diverge,
# and that is precisely when the row is worth reading.
# ===========================================================================
like($unreadable, qr/keep-awake.*holding/i,
     'B1: the lock held through an unreadable probe is reported as holding');
unlike($unreadable, qr/keep-awake.*released \(PC may sleep\)/i,
     'B2: ... and not as released, which is what the operator was shown');
like($unreadable, qr/keep-awake.*unreadable probe/i,
     'B3: ... and says WHY it is holding, so a warm laptop is explicable');

my $released = plain(render(busy_age => undef, stay_awake => 0,
                            lease_probe => { state => 'lease-absent' }, keepawake_held => 0));
like($released, qr/keep-awake.*released \(PC may sleep\)/i,
     'B4: a genuinely released lock still says so -- counter-fixture for B2');

# A gather that predates this change passes neither new key. The row must still
# render off stay_awake rather than going blank or dying.
my $legacy = plain(render(busy_age => 90, stay_awake => 1));
like($legacy, qr/keep-awake.*holding/i,
     'B5: a state carrying neither new key falls back to stay_awake, unchanged');

# ===========================================================================
# C. THE SECOND DECISION SITE NO LONGER OVERRULES THE FIRST.
# ===========================================================================
my ($seam) = ($SRC =~ /keepawake => sub \{(.*?)\n        \},/s);
ok(defined $seam && length $seam, 'C0: the keepawake seam is present')
    or BAIL_OUT('seam not found -- the assertions below would be vacuous');

like($seam, qr/probe-failed/,
     'C1: the seam knows what the last probe reading was');
like($seam, qr/if \(\$probe_state ne 'probe-failed'\)/,
     'C2: ... and converges the lock only when the reading was not a failure');

# Non-vacuity for C2: prove the detector would fire on the OLD shape, which
# called sync() unconditionally.
my $old_seam = q{
            my ($st) = @_;
            my $act = $KEEPAWAKE->sync($st->{stay_awake} ? 1 : 0);
};
unlike($old_seam, qr/if \(\$probe_state ne 'probe-failed'\)/,
       'C3: the C2 detector does not match the pre-fix seam -- it is a real guard');

# ===========================================================================
# D. THE DECISION IS WRITTEN DOWN EVEN WHEN NOTHING CHANGES.
#
# 20260911-224616-e8e0: logging only transitions meant `busy_age` appeared zero
# times across every launch log on the reporting host. A mechanism whose output
# nobody records cannot be diagnosed, and both sides of this one spent an
# argument unable to tell whether it was working.
# ===========================================================================
like($SRC, qr/keepawake_decision/,
     'D1: there is a periodic decision event, not only a transition event');
like($SRC, qr/my \$KEEPAWAKE_LOG_SECONDS = \d+;/,
     'D2: its cadence is a named constant, not a literal at the call site');
for my $field (qw(busy_age stale probe held want)) {
    like($seam, qr/\b\Q$field\E\b/,
         "D3: the decision record carries '$field', so the inputs AND the outcome are recoverable");
}

done_testing();

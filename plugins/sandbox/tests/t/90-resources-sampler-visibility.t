#!/usr/bin/env perl
# t01-resources-sampler — the oracle for blueprint tui-operator-feedback.
#
# Closes the operator's first reported complaint, verbatim: "the resources
# section on the TUI are saying 'sampling - no reading yet' forever".
#
# The panel already distinguishes fresh/stale/failed once a snapshot exists.
# The one collapsed case is "no snapshot has EVER been written", which renders a
# single hardcoded string regardless of whether the sampler is healthy, failed
# to fork, or died before writing. The fact needed to tell those apart already
# exists -- _resources_sampler_start knows whether fork() succeeded, and the
# failure is even logged -- but it is stored in a teardown-only lexical and
# never reaches the screen.
#
# Conventions honoured from this suite (t/44's header states them):
#   * launcher.pl is NEVER require'd -- source-text slurp + regex only, plus
#     `perl -c` in a subprocess. The suite has no way to call into it.
#   * pure logic under test lives in real modules (Resources.pm,
#     tui/DashboardScreen.pm) precisely so it CAN be called.
#   * no real clock and no sleep -- elapsed values are supplied, never measured.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $LAUNCHER_PATH = "$SCRIPTS_DIR/launcher.pl";

my $RES_OK = eval { require Resources;            1 };
my $DS_OK  = eval { require tui::DashboardScreen; 1 };
ok($RES_OK, 'Resources.pm loads')            or diag("  require failed: $@");
ok($DS_OK,  'tui/DashboardScreen.pm loads')  or diag("  require failed: $@");

# Slurp launcher.pl as TEXT. Never execute it: it builds container images and
# starts containers.
my $LSRC = do { local $/; open(my $fh, '<', $LAUNCHER_PATH) or die "open $LAUNCHER_PATH: $!"; <$fh> };
ok(length($LSRC) > 0, 'launcher.pl was read as source text');

# ===========================================================================
# PART 1 -- Resources::sampler_start_outcome: the pure translation from a
# fork() result into the plain-data fact the TUI will consume.
# ===========================================================================
SKIP: {
    skip 'Resources.pm did not load', 6 unless $RES_OK;

    my $ok = eval { Resources::sampler_start_outcome(4242, undef, 1000) };
    is(ref($ok), 'HASH', 'AC1: sampler_start_outcome returns a hash for a successful fork')
        or diag("  died: $@");
    SKIP: {
        skip 'no hash returned', 2 unless ref($ok) eq 'HASH';
        is($ok->{status},     'ok', 'AC1: a successful fork yields status ok');
        is($ok->{pid},        4242, 'AC1: the child pid is carried through');
    }

    my $bad = eval { Resources::sampler_start_outcome(undef, 'Cannot fork', 1000) };
    SKIP: {
        skip 'no hash returned', 3 unless ref($bad) eq 'HASH';
        is($bad->{status}, 'failed',            'AC2: a failed fork yields status failed');
        is($bad->{reason}, 'fork: Cannot fork', 'AC2: the errno text is carried through, prefixed');
        ok(!exists $bad->{pid},                 'AC2: no pid key is invented for a failed fork');
    }
}

# ===========================================================================
# PART 2 -- tui::DashboardScreen::sampler_wait_spans: the pure translation
# from that fact into what the operator reads. Four distinct outcomes where
# there was one string.
#
# Decision 2 (blueprint): no colon in any VALUE text. The label gutter's own
# colon belongs to package t05-no-colons and is deliberately not touched here.
# ===========================================================================
sub value_of {
    my ($spans) = @_;
    return '(not an array)' unless ref($spans) eq 'ARRAY';
    return '(empty)' unless @$spans;
    my $last = $spans->[-1];
    return '(not a hash)' unless ref($last) eq 'HASH';
    return defined $last->{text} ? $last->{text} : '(undef)';
}
sub role_of {
    my ($spans) = @_;
    return '(none)' unless ref($spans) eq 'ARRAY' && @$spans && ref($spans->[-1]) eq 'HASH';
    return defined $spans->[-1]{role} ? $spans->[-1]{role} : '(undef)';
}

SKIP: {
    skip 'tui/DashboardScreen.pm did not load', 14 unless $DS_OK;

    # Case 3 -- healthy and early. The text the operator already knows, but now
    # only shown when it is actually true.
    my $early = eval { tui::DashboardScreen::sampler_wait_spans(
        { status => 'ok', pid => 42, elapsed => 3, grace => 60, child_alive => 1 }) };
    is(value_of($early), 'sampling - no reading yet',
        'AC3: a healthy sampler inside its grace window still reads as sampling');
    is(role_of($early), 'text.muted', 'AC3: and stays muted');

    # Case 4 -- the fork never happened. Say so immediately; never wait.
    my $failed = eval { tui::DashboardScreen::sampler_wait_spans(
        { status => 'failed', reason => 'fork: Cannot fork', elapsed => 0, grace => 60 }) };
    is(value_of($failed), 'FAILED - sampler failed to start; no reading possible',
        'AC4: a sampler that never forked says so, and does not pretend to be sampling');
    is(role_of($failed), 'state.crit', 'AC4: and is critical');

    # Case 5 -- forked, then died before writing. The case the optimistic
    # resources_sampler_started log actively hid.
    my $gone = eval { tui::DashboardScreen::sampler_wait_spans(
        { status => 'ok', pid => 42, elapsed => 2, grace => 60, child_alive => 0 }) };
    is(value_of($gone), 'FAILED - sampler exited before writing a reading',
        'AC5: a sampler confirmed gone is reported immediately, regardless of elapsed time');
    is(role_of($gone), 'state.crit', 'AC5: and is critical');

    # Case 6 -- alive but past the grace window. Not dead, not working.
    my $stalled = eval { tui::DashboardScreen::sampler_wait_spans(
        { status => 'ok', pid => 42, elapsed => 900, grace => 60, child_alive => 1 }) };
    like(value_of($stalled), qr/^STALLED - sampler still running, no reading after /,
        'AC6: a live sampler past its grace window reads as stalled, not as sampling');
    is(role_of($stalled), 'state.warn', 'AC6: and warns');

    # Case 9 -- liveness not yet checked must never be reported as "exited".
    my $unchecked = eval { tui::DashboardScreen::sampler_wait_spans(
        { status => 'ok', pid => 42, elapsed => 2, grace => 60 }) };
    is(value_of($unchecked), 'sampling - no reading yet',
        'AC9: an unchecked liveness is not a dead child -- no false exited claim');

    # Case 8 -- defensive degrade. Never die, never fabricate a status.
    for my $bad (undef, {}, 'nonsense', []) {
        my $d = eval { tui::DashboardScreen::sampler_wait_spans($bad) };
        my $label = defined $bad ? (ref($bad) || "'$bad'") : 'undef';
        is(value_of($d), 'sampling - no reading yet',
            "AC8: a missing or malformed fact ($label) degrades to the neutral text rather than dying");
    }

    # Decision 2 -- no colon in any value text this package introduces.
    my @all = ($early, $failed, $gone, $stalled, $unchecked);
    my $with_colon = scalar grep { value_of($_) =~ /:/ } @all;
    is($with_colon, 0, 'AC10 (Decision 2): no value text introduced here contains a colon');
}

# ===========================================================================
# PART 3 -- the launcher wiring. Source-text assertions only: this suite never
# require's launcher.pl, so these are weaker than the pure-function tests above
# and are stated as such rather than dressed up as behaviour.
# ===========================================================================
like($LSRC, qr/resources_sampler_forked/,
    'AC11: the fork-succeeded log event is named for what it establishes');
# Asserted against the EMITTING CALL, not against the whole file. The first
# draft of this check forbade the string anywhere in launcher.pl and then failed
# on the comment that explains the rename -- an oracle forbidding the source from
# describing its own history. Package d01 of the predecessor initiative spent a
# fix-batch on exactly that shape (pinning prose in a file the package does not
# own), so the assertion is narrowed to what actually matters instead.
unlike($LSRC, qr/log_ev\(\s*'resources_sampler_started'/,
    'AC12: no event is emitted under the old name -- it read as proof the sampler was alive, which fork success is not');
like($LSRC, qr/sampler_start_outcome/,
    'AC13: launcher.pl builds the outcome fact via the pure helper rather than inline');
# AMENDED BY t02 (blueprint tui-operator-feedback, and the same shape blueprint
# Decision 8 rules on). t02 adds a second detached sampler for spend, which
# needs the identical non-blocking reap check, so the helper was renamed from
# _resources_sampler_child_alive to _sampler_child_alive -- nothing in its body
# was ever resources-specific. Keeping the old name while calling it for a
# second sampler would have made the name a lie; a second copy under a second
# name would have made two places to get WNOHANG wrong.
#
# THE INTENT IS PRESERVED, which is what makes this an amendment and not a
# weakening: this still asserts that a liveness check EXISTS and that the
# resources sampler is the thing being checked. It still fails if the check is
# deleted, or if the resources sampler stops consulting it.
like($LSRC, qr/_sampler_child_alive\(\s*\$RESOURCES_SAMPLER_CHILD\s*\)/,
    'AC14: a liveness check exists and the resources sampler uses it, so "started but gone" is distinguishable from "still starting"');
like($LSRC, qr/resources_sampler\s*=>/,
    'AC15: the fact is threaded into the state hash the renderer reads');

# perl -c, the suite's established substitute for executing launcher.pl.
my $out = `perl -c "$LAUNCHER_PATH" 2>&1`;
like($out, qr/syntax OK/, 'AC16: launcher.pl still compiles');

done_testing();
